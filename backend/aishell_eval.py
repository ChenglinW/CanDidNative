"""Small, reproducible AISHELL-4 evaluation suites; never load a user's database."""
import hashlib
import json
import math
from pathlib import Path
import re
import tempfile
import time
import unicodedata

from asr import read_wav
from llm import ModelError


def normalize(text):
    """Version 1: NFKC, lowercase, remove punctuation/space. Do not rewrite numbers."""
    text = unicodedata.normalize('NFKC', text).lower()
    return ''.join(c for c in text if not c.isspace() and unicodedata.category(c)[0] not in {'P', 'Z', 'C'})


def cer(reference, hypothesis):
    ref, hyp = normalize(reference), normalize(hypothesis)
    previous = list(range(len(hyp)+1))
    for i, a in enumerate(ref, 1):
        current = [i]
        for j, b in enumerate(hyp, 1):
            current.append(min(previous[j]+1, current[j-1]+1, previous[j-1]+(a != b)))
        previous = current
    errors = previous[-1]
    return {'errors': errors, 'reference_characters': len(ref),
            'cer': errors/len(ref) if ref else None}


def annotations(path):
    from praatio import textgrid
    tg = textgrid.openTextgrid(str(path), includeEmptyIntervals=False, reportingMode='error')
    rows = []
    for speaker in tg.tierNames:
        tier = tg.getTier(speaker)
        if not isinstance(tier, textgrid.IntervalTier):
            raise ValueError('Expected speaker interval tiers')
        for entry in tier.entries:
            if entry.label.strip():
                if not math.isfinite(entry.start) or not math.isfinite(entry.end) or not 0 <= entry.start < entry.end:
                    raise ValueError('Invalid annotation interval')
                rows.append({'speaker': speaker, 'start': entry.start, 'end': entry.end, 'text': entry.label})
    return sorted(rows, key=lambda r: (r['start'], r['end'], r['speaker']))


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''): h.update(block)
    return h.hexdigest()


def prepare_suite(source, output, limit=20, channel=0):
    """Select deterministic disjoint test clips. Microphone channel != speaker."""
    import soundfile as sf
    source, output = Path(source).resolve(), Path(output).resolve()
    if not 1 <= limit <= 100: raise ValueError('limit must be 1..100')
    if output.exists(): raise ValueError('Output already exists; choose a new suite directory')
    candidates = {'numbers': [], 'uncertainty': [], 'clean_single': [], 'overlap': [], 'unlabelled_gap': []}
    sources = []
    for grid in sorted(source.rglob('*.TextGrid')):
        if grid.parent.name != 'TextGrid': continue
        split = grid.parent.parent
        if split.name != 'test': continue
        audio = next((split/'wav'/(grid.stem+ext) for ext in ['.wav', '.flac']
                      if (split/'wav'/(grid.stem+ext)).exists()), None)
        if not audio: continue
        info = sf.info(str(audio))
        if info.samplerate != 16000 or not 0 <= channel < info.channels:
            raise ValueError('Expected 16 kHz audio and a valid microphone channel')
        rows = annotations(grid)
        if any(r['end'] > info.duration+.01 for r in rows): raise ValueError('Annotation exceeds audio')
        sources.append({'meeting': grid.stem, 'audio_sha256': sha256(audio),
                        'textgrid_sha256': sha256(grid), 'channels': info.channels})
        def candidate(a, b, text, speaker, group):
            return {'meeting': grid.stem, '_audio': audio, 'start': a, 'end': b,
                    'reference_text': text, 'speaker': speaker, 'group': group}
        for row in rows:
            a, b, text = row['start'], row['end'], row['text']
            if not 2 <= b-a <= 25 or len(normalize(text)) < 8: continue
            others = [r for r in rows if r['speaker'] != row['speaker'] and r['start'] < b and r['end'] > a]
            if others:
                # Partial/overlapping reference speech has no unambiguous text ordering.
                candidates['overlap'].append(candidate(a, b, None, None, 'overlap'))
                continue
            if '<' in text or '>' in text: continue  # exclude uncertain/nonlexical tags from CER
            group = ('numbers' if re.search(r'\d|[十百千万亿]|百分之', text)
                     else 'uncertainty' if re.search(r'没|不确定|可能|应该|但是|不过|不对', text)
                     else 'clean_single')
            candidates[group].append(candidate(a, b, text, row['speaker'], group))
        # Union of all tiers: a gap in one speaker's tier is not global silence.
        cursor = 0.0
        for row in rows + [{'start': info.duration, 'end': info.duration}]:
            if row['start']-cursor >= 2:
                end = min(cursor+5, row['start'])
                candidates['unlabelled_gap'].append(candidate(cursor, end, '', None, 'unlabelled_gap'))
            cursor = max(cursor, row['end'])
    if not sources: raise ValueError('No matched test/TextGrid + test/wav files found')
    selected = []
    while len(selected) < limit and any(candidates.values()):
        for group, pool in candidates.items():
            while pool and len(selected) < limit:
                item = pool.pop(0)
                if any(s['meeting'] == item['meeting'] and s['start'] < item['end'] and s['end'] > item['start'] for s in selected): continue
                selected.append(item)
                break
    if not selected: raise ValueError('No eligible test clips')
    (output/'clips').mkdir(parents=True)
    for i, item in enumerate(selected, 1):
        clip_id = f'{item["meeting"]}-{i:03d}'
        first, last = round(item['start']*16000), round(item['end']*16000)
        with sf.SoundFile(str(item.pop('_audio'))) as audio:
            audio.seek(first)
            frames = audio.read(last-first, dtype='int16', always_2d=True)
        if len(frames) != last-first: raise ValueError('Truncated audio source')
        target = output/'clips'/(clip_id+'.wav')
        sf.write(str(target), frames[:, channel], 16000, subtype='PCM_16')
        _, duration = read_wav(target)
        item.update(id=clip_id, audio='clips/'+target.name, sha256=sha256(target),
                    source_start_ms=round(first/16), source_end_ms=round(last/16), duration_ms=duration,
                    microphone_channel=channel, speaker_source='AISHELL-4 annotation (oracle)',
                    review_allowed=item['speaker'] is not None, source='AISHELL-4/test')
        item.pop('start'); item.pop('end')
    manifest = {'version': 1, 'dataset': 'AISHELL-4', 'split': 'test',
                'purpose': 'meeting speech engineering evaluation; not a labeled interview/sales benchmark',
                'selection': 'deterministic round-robin, annotation-bounded, disjoint clips; NOT full-set CER',
                'normalization': 'nfkc-lower-no-punctuation-space-v1; numerals unchanged',
                'sources': sources, 'cases': selected,
                'coverage': {g: sum(c['group'] == g for c in selected) for g in candidates}}
    (output/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    return manifest


def load_suite(path):
    path = Path(path).resolve()
    manifest = json.loads(path.read_text('utf8'))
    if manifest.get('version') != 1 or manifest.get('split') != 'test': raise ValueError('Unsupported manifest')
    seen = set()
    for case in manifest['cases']:
        if not isinstance(case['id'], str) or case['id'] in seen: raise ValueError('Duplicate case ID')
        seen.add(case['id'])
        audio = (path.parent/case['audio']).resolve()
        if not audio.is_relative_to(path.parent): raise ValueError('Audio path escapes suite')
        if sha256(audio) != case['sha256']: raise ValueError('Clip checksum mismatch')
        _, duration = read_wav(audio)
        if duration != case['duration_ms']: raise ValueError('Clip duration mismatch')
        reference = case['reference_text']
        if reference is not None and (not isinstance(reference, str) or len(reference) > 20000):
            raise ValueError('Invalid reference text')
        if case['review_allowed'] and (case['group'] not in {'clean_single', 'numbers', 'uncertainty'} or not case['speaker'] or not reference):
            raise ValueError('Only annotated single-speaker clips can enter review')
    return manifest


def review_text(text, provider, scenario='sales', duration_ms=1000, asr_producer='manual_user@1'):
    """Exercise the existing evidence → diagnosis → draft pipeline in a disposable DB."""
    from memory import Memory, ident, now
    owner = '11111111-1111-4111-8111-111111111111'
    with tempfile.TemporaryDirectory(prefix='candid-eval-') as temp:
        m = Memory(Path(temp)/'eval.sqlite', Path(temp)/'storage', llm=provider)
        try:
            s = m.create_session(owner, {'client_request_id': ident(), 'kind': 'practice',
                                        'consent': 'yes', 'scenario': scenario})
            m.put('transcript_segments', owner, {'session_id': s['id'], 'speaker': 'self',
                  'start_ms': 0, 'end_ms': duration_ms, 'text': text, 'asr_producer': asr_producer,
                  'speaker_assignment': 'evaluation oracle, not model identification'}, source='device')
            m.update('sessions', owner, s['id'], {'llm_consent_at': now(), 'duration_ms': duration_ms})
            m.retry(owner, s['id'], 'diagnosing'); m.tick()
            s = m.get('sessions', owner, s['id'])
            if s['pipeline_status'] != 'done':
                raise ModelError(s.get('pipeline_error', 'REVIEW_FAILED'), '复盘测试未完成；本次不自动重复计费')
            return {'diagnoses': m.rows('diagnoses', owner), 'draft_assets': m.rows('assets', owner),
                    'model': provider.model, 'status': 'evidence_checks_passed',
                    'semantic_quality': 'requires_human_review'}
        finally: m.db.close()


def run_suite(manifest_path, asr, live=False, review_provider=None):
    manifest_path = Path(manifest_path).resolve()
    manifest = load_suite(manifest_path)
    results = []
    for case in manifest['cases']:
        row = {k: case[k] for k in ['id', 'group', 'reference_text', 'speaker', 'duration_ms',
                                  'audio', 'sha256', 'source_start_ms', 'source_end_ms']}
        if not live:
            row.update(status='prepared_not_run', cer=None)
        else:
            started = time.monotonic()
            try:
                recognition = asr.transcribe(manifest_path.parent/case['audio'])
                row.update(status='transcribed', hypothesis=recognition['text'], producer=recognition['producer'],
                           elapsed_seconds=round(time.monotonic()-started, 3))
                reference = case['reference_text']
                if reference is not None:
                    row.update(cer(reference, recognition['text']))
                    if not reference:
                        row['unlabelled_gap_output_characters'] = len(normalize(recognition['text']))
                else: row.update(cer=None, metric_note='overlap: manual review only; no diarization capability')
                if review_provider is not None and case['review_allowed'] and recognition['text']:
                    try:
                        row['review'] = review_text(recognition['text'], review_provider,
                            duration_ms=case['duration_ms'], asr_producer=recognition['producer'])
                    except ModelError as e: row['review'] = {'status': 'failed', 'error_code': e.code}
                else: row['review'] = {'status': 'not_requested_or_ineligible'}
            except ModelError as e:
                row.update(status='failed', error_code=e.code, cer=None)
        results.append(row)
    errors = sum(r.get('errors', 0) for r in results if r.get('reference_characters', 0) > 0)
    characters = sum(r.get('reference_characters', 0) for r in results)
    scored_expected = sum(bool(normalize(c['reference_text'] or '')) for c in manifest['cases'])
    scored_actual = sum(r.get('reference_characters', 0) > 0 for r in results)
    return {'mode': 'live' if live else 'dry_run', 'asr_model': asr.model, 'asr_configured': asr.configured,
            'coverage': manifest['coverage'], 'cases': results,
            'summary': {'prepared': len(results), 'transcribed': sum(r['status'] == 'transcribed' for r in results),
                        'failed': sum(r['status'] == 'failed' for r in results),
                        'reference_characters': characters, 'edit_errors': errors,
                        'micro_cer_successful_clips': errors/characters if characters else None,
                        'scored_expected': scored_expected, 'scored_actual': scored_actual,
                        'complete_asr_evaluation': live and all(r['status'] == 'transcribed' for r in results),
                        'review_failed': sum(r.get('review', {}).get('status') == 'failed' for r in results)},
            'limits': ['Not a full-test-set score.', 'Oracle annotation boundaries and speaker identities.',
                       'No diarization score; overlap is not assigned to self.',
                       'CER does not measure diagnosis quality; compare review to reference manually.']}


def write_report(report, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists(): raise ValueError('Report already exists; choose a new output path')
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
