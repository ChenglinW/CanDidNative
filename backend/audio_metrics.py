"""Cached, local acoustic estimates for explicitly claimed speaker intervals."""
import hashlib
import json
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
from memory import Fault

POLICY = 'claimed-acoustics@3'
RATE, FRAME = 16000, 640  # Non-overlapping 40 ms windows.


def turns(lines):
    """Bridge short same-speaker gaps, but never include another/unknown speaker."""
    mine = sorted((r for r in lines if r.get('speaker') == 'self'), key=lambda r: r['start_ms'])
    excluded = [(r['start_ms'], r['end_ms']) for r in lines if r.get('speaker') != 'self']
    active = []
    for row in mine:
        active = [prior for prior in active if prior['end_ms'] > row['start_ms']]
        for prior in active:
            if (prior.get('speaker_id'), prior.get('part')) != (row.get('speaker_id'), row.get('part')):
                excluded.append((row['start_ms'], min(prior['end_ms'], row['end_ms'])))
        active.append(row)
    groups = []
    for row in mine:
        start, end = max(0, row['start_ms']), row['end_ms']
        identity = (row.get('speaker_id'), row.get('part', 0))
        if end <= start:
            continue
        if (groups and identity == groups[-1][2] and start - groups[-1][1] <= 1500
                and not any(a < start and b > groups[-1][1] for a, b in excluded)):
            groups[-1][1] = max(groups[-1][1], end)
        else:
            groups.append([start, end, identity])
    output = []
    for start, end, _ in groups:
        pieces = [(start, end)]
        for a, b in excluded:
            pieces = [(x, y) for left, right in pieces
                      for x, y in ((left, min(right, a)), (max(left, b), right)) if y > x]
        output.extend(pieces)
    return output


def compute_pvq(pitches):
    """The rubric's 100/150 scale has no verified mapping to measured F0.

    Hincks (2005) uses SD(F0)/mean(F0), not 100 times semitone SD.
    Do not manufacture a conversion just to match the rubric thresholds.
    """
    return None


def answer_onset_ms(lines):
    """Starts of self speech immediately after other/unknown — thinking pause window anchors."""
    onsets, prior_other = [], None
    for row in sorted(lines or [], key=lambda r: (r.get('start_ms', 0), r.get('end_ms', 0))):
        if row.get('speaker') != 'self':
            prior_other = row.get('end_ms')
            continue
        if prior_other is not None:
            onsets.append(row.get('start_ms', 0))
            prior_other = None
    return onsets


def segment_boundaries_ms(lines):
    mine = sorted((r for r in (lines or []) if r.get('speaker') == 'self'), key=lambda r: r['start_ms'])
    marks = []
    for row in mine:
        text = (row.get('text') or '').rstrip()
        if text and text[-1] in '。！？；.!?;':
            marks.append(row['end_ms'])
    return sorted(set(marks))


def classify_pauses(pause_events, lines, acoustic_ms):
    """Boundary vs non-boundary; exempt pre-answer thinking 0–3s."""
    boundaries = segment_boundaries_ms(lines)
    onsets = answer_onset_ms(lines)
    boundary_durs, non_boundary, long_count, scored = [], 0, 0, 0
    for event in pause_events or []:
        start, end, dur = event['start_ms'], event['end_ms'], event['duration_ms']
        center = (start + end) / 2
        if any(end <= onset and 0 <= onset - start <= 3000 for onset in onsets):
            continue  # thinking pause exempt from scoring tallies
        scored += 1
        near_boundary = any(start - 200 <= b <= end + 200 for b in boundaries)
        if near_boundary:
            boundary_durs.append(dur / 1000)
        elif dur >= 300:
            non_boundary += 1
        if dur >= 1500:
            long_count += 1
    total = max(scored, 1)
    return {
        'boundary_pause_median_s': round(float(np.median(boundary_durs)), 3) if boundary_durs else None,
        'boundary_pause_samples': len(boundary_durs),
        'non_boundary_pause_ratio': round(non_boundary / total, 4) if scored else None,
        'long_pause_rate': round(long_count * 60000 / acoustic_ms, 2) if acoustic_ms and scored else None,
    }


def analyze_wav(path, intervals, guard=lambda: None, lines=None):
    """Energy pauses and autocorrelation F0; estimates, never expression scores."""
    pause_events, voiced, duration, pitches, levels = [], 0, 0, [], []
    with wave.open(str(path), 'rb') as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, RATE):
            raise ValueError('expected mono 16 kHz PCM16')
        for start, end in intervals:
            guard()
            first, last = round(start * RATE / 1000), min(audio.getnframes(), round(end * RATE / 1000))
            if last <= first:
                continue
            audio.setpos(first)
            energies, turn_pitches = [], []
            remaining = last - first
            while remaining >= FRAME:
                guard()
                n = min(remaining // FRAME, 250)
                samples = np.frombuffer(audio.readframes(n * FRAME), dtype='<i2').astype(float) / 32768
                frames = samples.reshape(-1, FRAME)
                remaining -= len(samples)
                frames -= frames.mean(axis=1, keepdims=True)
                rms = np.sqrt(np.mean(frames ** 2, axis=1))
                energies.extend(rms.tolist())
                candidates = frames[rms >= .003]
                if not len(candidates):
                    continue
                spectrum = np.fft.rfft(candidates, n=2048, axis=1)
                ac = np.fft.irfft(spectrum * spectrum.conj(), n=2048, axis=1)[:, :FRAME]
                lo, hi = RATE // 400, RATE // 70
                lag = np.argmax(ac[:, lo:hi + 1], axis=1) + lo
                quality = ac[np.arange(len(lag)), lag] / np.maximum(ac[:, 0], 1e-12)
                turn_pitches.extend((RATE / lag[quality >= .6]).tolist())
            if not energies:
                continue
            rms = np.asarray(energies)
            threshold = max(.003, float(np.percentile(rms, 90)) * .08)
            active = rms >= threshold
            bounds = np.flatnonzero(active)
            if not len(bounds):
                continue
            active = active[bounds[0]:bounds[-1] + 1]
            duration += len(active) * 40
            voiced += int(active.sum()) * 40
            origin = start + int(bounds[0]) * 40
            run = 0
            for index, speaking in enumerate(active):
                if not speaking:
                    run += 40
                else:
                    if run >= 240:
                        pause_start = origin + (index * 40) - run
                        pause_events.append({'start_ms': pause_start, 'end_ms': pause_start + run, 'duration_ms': run})
                    run = 0
            levels.extend((20 * np.log10(np.maximum(rms[rms >= threshold], 1e-12))).tolist())
            pitches.extend(turn_pitches)
    pauses = [e['duration_ms'] for e in pause_events]
    sufficient = voiced >= 1000 and len(pitches) >= 25
    pitch = np.asarray(pitches)
    values = {
        'pause_count': len(pauses) if sufficient else None,
        'pause_rate': round(len(pauses) * 60000 / duration, 2) if sufficient and duration else None,
        'pause_mean_seconds': round(float(np.mean(pauses)) / 1000, 2) if pauses and sufficient else None,
        'pitch_range_st': round(float(np.diff(np.percentile(12 * np.log2(pitch), [10, 90]))[0]), 2) if sufficient and len(pitch) >= 25 else None,
        'volume_range_db': round(float(np.diff(np.percentile(levels, [10, 90]))[0]), 2) if sufficient else None,
        'pvq': compute_pvq(pitches) if sufficient else None,
        'acoustic_ms': duration, 'voiced_ms': voiced,
        'acoustic_status': 'ready' if sufficient else 'insufficient',
    }
    if sufficient:
        values.update(classify_pauses(pause_events, lines or [], duration))
    else:
        values.update({'boundary_pause_median_s': None, 'boundary_pause_samples': 0,
                       'non_boundary_pause_ratio': None, 'long_pause_rate': None})
    return values


class AudioMetrics:
    def __init__(self, store, business):
        self.store, self.business = store, business
        business.handlers['audio_metrics'] = self.run

    def plan(self, owner, session, media, lines):
        path = (self.store.root / media.get('storage_path', '')).resolve()
        if (session.get('audio_purged_at') or not media.get('storage_path')
                or not path.is_relative_to(self.store.root.resolve()) or not path.is_file()):
            return None
        spans = turns(lines)
        digest = hashlib.sha256(json.dumps([POLICY, media.get('sha256'), media.get('storage_path'),
            session.get('transcript_revision', 1), sorted((r['id'], r['start_ms'], r['end_ms'],
            r.get('speaker'), r.get('speaker_id'), r.get('part')) for r in lines)], sort_keys=True).encode()).hexdigest()
        return path, spans, digest, lines

    def snapshot(self, owner, session, media, lines):
        plan = self.plan(owner, session, media, lines)
        if not plan:
            return {'acoustic_status': 'unavailable'}
        _, _, digest, _ = plan
        cached = session.get('audio_metrics', {})
        if cached.get('digest') == digest and cached.get('policy') == POLICY:
            return cached['values']
        job = self.business.submit(owner, 'audio_metrics', session['id'], digest)
        return {'acoustic_status': job['status'], 'acoustic_job_id': job['id']}

    def run(self, owner, job):
        def current():
            session = self.store.get('sessions', owner, job['object_id'])
            if session.get('consent') != 'yes':
                raise Fault('RECORDING_CONSENT_REQUIRED', '录音授权已变化', 409)
            media = self.store.rows('session_media', owner, session_id=session['id'])
            lines = [r for r in self.store.rows('transcript_segments', owner, session_id=session['id'])
                     if r.get('transcript_revision', 1) == session.get('transcript_revision', 1)]
            plan = self.plan(owner, session, media[0], lines) if media else None
            if not plan or plan[2] != job['revision']:
                raise Fault('AUDIO_METRICS_CHANGED', '音频或说话人已变化，请重新读取', 409)
            return plan
        path, spans, digest, lines = current()
        with tempfile.TemporaryDirectory(prefix='candid-acoustics-') as folder:
            decoded = Path(folder) / 'audio.wav'
            native = False
            try:
                with wave.open(str(path), 'rb') as source:
                    native = (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (1, 2, RATE)
            except (OSError, EOFError, wave.Error):
                pass
            try:
                if not native:
                    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(path), '-vn',
                        '-ac', '1', '-ar', str(RATE), '-c:a', 'pcm_s16le', str(decoded)],
                        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
            except (OSError, subprocess.SubprocessError):
                raise Fault('AUDIO_METRICS_DECODE_FAILED', '音频分析失败，请检查原音频与解码服务后重试', 422) from None
            # Pass lines positionally so test doubles that forward *args keep working.
            values = analyze_wav(path if native else decoded, spans, lambda: self.business.guard(owner, job), lines)
        with self.store.transaction(owner):
            self.business.guard(owner, job)
            current()
            self.store.update('sessions', owner, job['object_id'],
                              {'audio_metrics': {'digest': digest, 'policy': POLICY, 'values': values}})
        return values
