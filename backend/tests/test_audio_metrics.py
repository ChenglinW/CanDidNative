import hashlib
from pathlib import Path
import sys
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audio_metrics import analyze_wav, turns, RATE
from memory import Memory, L1, ident

OWNER = '11111111-1111-4111-8111-111111111111'
HEADERS = {'Authorization': 'Bearer test-token'}


def tone(seconds, hz=200, amplitude=.2):
    return amplitude * np.sin(2 * np.pi * hz * np.arange(round(seconds * RATE)) / RATE)


def wav(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(RATE)
        output.writeframes((samples * 32767).astype('<i2').tobytes())
    return path


def test_acoustic_pause_pitch_and_volume_are_measured(tmp_path):
    samples = np.concatenate([tone(2), np.zeros(round(.4 * RATE)), tone(2, 400, .06)])
    result = analyze_wav(wav(tmp_path / 'voice.wav', samples), [(0, 4400)])
    assert result['acoustic_status'] == 'ready'
    assert result['pause_count'] == 1
    assert result['pause_mean_seconds'] == pytest.approx(.4, abs=.04)
    assert result['pause_rate'] == pytest.approx(60000 / 4400, abs=.1)
    assert result['pitch_range_st'] == pytest.approx(12, abs=.5)
    assert result['volume_range_db'] > 8


def test_flat_voice_zero_variation_and_silence_not_zero_score(tmp_path):
    path = wav(tmp_path / 'flat.wav', np.concatenate([np.zeros(RATE), tone(2), np.zeros(RATE)]))
    result = analyze_wav(path, [(0, 4000)])
    assert result['pause_count'] == 0  # Boundary silence is not a speech pause.
    assert result['pause_mean_seconds'] is None
    assert result['pitch_range_st'] == pytest.approx(0, abs=.2)
    for samples in [np.zeros(RATE * 2), tone(.4), np.random.default_rng(7).normal(0, .1, RATE * 2)]:
        result = analyze_wav(wav(tmp_path / 'insufficient.wav', samples), [(0, 2000)])
        assert result['acoustic_status'] == 'insufficient'
        assert result['pause_rate'] is None and result['pitch_range_st'] is None


def test_turn_boundaries_unknown_and_overlap_excluded(tmp_path):
    rows = [dict(start_ms=0, end_ms=2000, speaker='self', speaker_id='a'),
            dict(start_ms=2400, end_ms=4400, speaker='self', speaker_id='a')]
    assert turns(rows) == [(0, 4400)]
    rows.append(dict(start_ms=2000, end_ms=2400, speaker='unknown'))
    assert turns(rows) == [(0, 2000), (2400, 4400)]
    path = wav(tmp_path / 'turn.wav', np.concatenate([tone(2), np.zeros(6400), tone(2)]))
    assert analyze_wav(path, turns(rows))['pause_count'] == 0
    rows.append(dict(start_ms=1000, end_ms=1500, speaker='other'))
    assert turns(rows) == [(0, 1000), (1500, 2000), (2400, 4400)]
    assert turns([dict(start_ms=0, end_ms=2000, speaker='self', speaker_id='a'),
                  dict(start_ms=1000, end_ms=3000, speaker='self', speaker_id='b')]) == [(0, 1000), (2000, 3000)]


@pytest.fixture
def system(tmp_path, bind_app_store):
    import app
    store = Memory(tmp_path / 'db.sqlite', tmp_path / 'files')
    bind_app_store(app, store)
    library = app.library_service()
    session = store.create_session(OWNER, {'client_request_id': ident(), 'kind': 'live',
        'consent': 'yes', 'consent_ack_text_version': 'test', 'scenario': 'sales'})
    sid = session['id']
    path = wav(store.root / OWNER / 'voice.wav', np.concatenate([tone(2), np.zeros(6400), tone(2, 300)]))
    store.put('session_media', OWNER, {'session_id': sid, 'storage_path': str(path.relative_to(store.root)),
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}, L1)
    line = store.put('transcript_segments', OWNER, {'session_id': sid, 'speaker': 'self',
        'speaker_id': 'part0:0', 'start_ms': 0, 'end_ms': 4400, 'text': '测试本人表达', 'transcript_revision': 1}, L1)
    return library, TestClient(app.app), sid, line, path


def revise(library, sid, line, revision, speaker):
    library.store.put('transcript_segments', OWNER, {'session_id': sid, 'speaker': speaker,
        'speaker_id': 'part0:0', 'start_ms': line['start_ms'], 'end_ms': line['end_ms'],
        'text': line['text'], 'transcript_revision': revision}, L1)
    library.store.update('sessions', OWNER, sid, {'transcript_revision': revision})


def test_async_api_cache_and_identity_invalidation(system, monkeypatch):
    library, client, sid, line, path = system
    assert client.get('/v1/library/metrics').status_code == 401
    first = client.get('/v1/library/metrics', headers=HEADERS).json()['sessions'][0]
    assert first['acoustic_status'] == 'queued' and 'pause_rate' not in first
    job = library.store.get('business_jobs', OWNER, first['acoustic_job_id'])
    library.business.run(OWNER, job)
    second = library.metrics(OWNER)['sessions'][0]
    assert second['pause_count'] == 1 and second['acoustic_status'] == 'ready'
    import audio_metrics
    monkeypatch.setattr(audio_metrics, 'analyze_wav', lambda *a: pytest.fail('cached audio must not run twice'))
    assert library.metrics(OWNER)['sessions'][0]['pause_count'] == 1
    assert len(library.store.rows('business_jobs', OWNER, kind='audio_metrics')) == 1
    # Speaker selection creates a new immutable transcript revision.
    revise(library, sid, line, 2, 'self')
    assert library.metrics(OWNER)['sessions'][0]['acoustic_status'] == 'queued'
    # The old job cannot save against a new revision / claim.
    with pytest.raises(Exception, match='音频或说话人已变化'):
        library.audio_metrics.run(OWNER, job)
    library.store.update('sessions', OWNER, sid, {'audio_purged_at': 'now'})
    row = library.metrics(OWNER)['sessions'][0]
    assert row['acoustic_status'] == 'unavailable' and 'pause_rate' not in row


def test_scores_api_uses_real_timestamps_and_scenario_windows(system):
    library, client, sid, line, path = system
    library.store.put('transcript_segments', OWNER, {'session_id':sid,'speaker':'self',
        'speaker_id':'part0:0','start_ms':10000,'end_ms':14400,'text':'真实时间点测试','transcript_revision':2},L1)
    library.store.update('sessions', OWNER, sid, {'transcript_revision':2})
    session=library.store.create_session(OWNER, {'client_request_id':ident(),'kind':'live',
        'consent':'yes','consent_ack_text_version':'test','scenario':'interview'})
    library.store.put('session_media', OWNER, {'session_id':session['id'],
        'storage_path':str(path.relative_to(library.store.root)), 'sha256':'other'}, L1)
    library.store.put('transcript_segments', OWNER, {'session_id':session['id'],'speaker':'self',
        'speaker_id':'part0:0','start_ms':0,'end_ms':4400,'text':'面试回答','transcript_revision':1},L1)
    response=client.get('/v1/library/metrics',headers=HEADERS)
    assert response.status_code==200
    payload=response.json()
    assert payload['score_recent'] is None
    assert set(payload['score_windows'])=={'sales','interview'}
    for window in payload['score_windows'].values():
        assert window['recent']['session_count']==1 and window['baseline'] is None
    row=next(r for r in payload['sessions'] if r['id']==sid)
    source=row['expression_scores']['axes']['filler']['sources'][0]
    assert (source['from_ms'],source['to_ms'])==(10000,14400)
    assert row['expression_scores']['axes']['pace']['score'] is None  # audio queued
    assert row['expression_scores']['axes']['pitch']['score'] is None


def test_missing_unclaimed_and_failure_do_not_fabricate_metrics(system, monkeypatch):
    library, client, sid, line, path = system
    revise(library, sid, line, 2, 'unknown')
    assert library.metrics(OWNER)['sessions'] == []
    assert not library.store.rows('business_jobs', OWNER, kind='audio_metrics')
    revise(library, sid, line, 3, 'self')
    row = library.metrics(OWNER)['sessions'][0]
    import audio_metrics
    monkeypatch.setattr(audio_metrics, 'analyze_wav', lambda *a: (_ for _ in ()).throw(ValueError('bad audio')))
    job = library.store.get('business_jobs', OWNER, row['acoustic_job_id'])
    library.business.run(OWNER, job)
    assert library.metrics(OWNER)['sessions'][0]['acoustic_status'] == 'failed'
    assert len(library.store.rows('business_jobs', OWNER, kind='audio_metrics')) == 1
    path.unlink()
    assert library.metrics(OWNER)['sessions'][0]['acoustic_status'] == 'unavailable'


def test_compressed_audio_decode_and_late_revision_guard(system, monkeypatch):
    library, client, sid, line, path = system
    path.write_bytes(b'compressed-audio-placeholder')
    import audio_metrics
    calls = []
    def decode(command, **kwargs):
        calls.append(command)
        assert ['-ac', '1', '-ar', '16000'] == command[command.index('-ac'):command.index('-ac') + 4]
        wav(Path(command[-1]), tone(2))
    monkeypatch.setattr(audio_metrics.subprocess, 'run', decode)
    first = library.metrics(OWNER)['sessions'][0]
    job = library.store.get('business_jobs', OWNER, first['acoustic_job_id'])
    library.business.run(OWNER, job)
    assert calls and not Path(calls[0][-1]).exists()  # Decoded audio is temporary.
    assert library.metrics(OWNER)['sessions'][0]['acoustic_status'] == 'ready'
    revise(library, sid, line, 2, 'self')
    queued = library.metrics(OWNER)['sessions'][0]
    original = audio_metrics.analyze_wav
    def changed(*args):
        result = original(*args)
        revise(library, sid, line, 3, 'self')
        return result
    monkeypatch.setattr(audio_metrics, 'analyze_wav', changed)
    library.business.run(OWNER, library.store.get('business_jobs', OWNER, queued['acoustic_job_id']))
    assert library.store.get('business_jobs', OWNER, queued['acoustic_job_id'])['status'] == 'failed'
    assert library.metrics(OWNER)['sessions'][0]['acoustic_status'] == 'queued'
