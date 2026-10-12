import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from llm import DeepSeek, ModelError
from memory import Memory, L3, ident, now

OWNER = '11111111-1111-4111-8111-111111111111'
TEXT = '我先确认客户需求，再安排试点。'


def output(segment_id):
    citation = {'segment_id': segment_id, 'quote': '先确认客户需求'}
    return {'diagnoses': [{'dimension': 'result_specificity', 'finding': '还缺少试点结果',
                          'suggestion': '补充可核实的结果，未完成时说明进度。', 'citations': [citation]}],
            'asset_title': '确认需求', 'asset_citation': citation}


def response(request):
    payload = json.loads(request.content)
    assert payload['model'] == 'deepseek-v4-pro'
    assert payload['response_format'] == {'type': 'json_object'}
    evidence = json.loads(payload['messages'][1]['content'])['segments']
    assert len(evidence) == 1 and evidence[0]['text'] == TEXT
    return httpx.Response(200, json={'choices': [{'finish_reason': 'stop',
        'message': {'content': json.dumps(output(evidence[0]['segment_id']))}}]})


@pytest.fixture
def m(tmp_path):
    return Memory(tmp_path/'db.sqlite', tmp_path/'storage',
                  llm=DeepSeek('test-secret', transport=httpx.MockTransport(response)))


def evidence(m):
    s = m.create_session(OWNER, {'client_request_id': ident(), 'kind': 'oral_debrief', 'consent': 'unknown'})
    seg = m.put('transcript_segments', OWNER, {'session_id': s['id'], 'speaker': 'self',
                                            'start_ms': 0, 'end_ms': 1000, 'text': TEXT})
    m.update('sessions', OWNER, s['id'], {'llm_consent_at': now()})
    return s, seg


def test_real_pipeline_preserves_evidence_and_human_confirmation(m):
    s, seg = evidence(m)
    m.put('transcript_segments', OWNER, {'session_id': s['id'], 'speaker': 'other',
                                       'start_ms': 1000, 'end_ms': 2000, 'text': '对方私密原话'})
    m.retry(OWNER, s['id'], 'transcribing'); m.tick()
    assert m.get('sessions', OWNER, s['id'])['pipeline_status'] == 'done'
    diagnosis = m.rows('diagnoses', OWNER)[0]
    assert diagnosis['producer'] == 'deepseek/deepseek-v4-pro@candid-v1'
    assert diagnosis['evidence_refs'] == [{'session_id': s['id'], 'start_ms': 0, 'end_ms': 1000}]
    asset = m.rows('assets', OWNER)[0]
    assert asset['status'] == 'draft' and asset['body']['text'] in TEXT
    m.mutate_asset(OWNER, asset['id'], 1, status='confirmed')
    m.retry(OWNER, s['id'], 'diagnosing'); m.tick()
    assert len(m.rows('assets', OWNER)) == 1
    assert m.get('assets', OWNER, asset['id'])['trust'] == L3
    assert m.get('transcript_segments', OWNER, seg['id']) == seg
    assert not m.rows('metrics', OWNER) and not m.rows('weaknesses', OWNER)


@pytest.mark.parametrize(('status', 'code'), [(401, 'LLM_AUTH_FAILED'), (402, 'LLM_BALANCE_REQUIRED'),
    (429, 'LLM_RATE_LIMITED'), (500, 'LLM_UNAVAILABLE'), (404, 'LLM_MODEL_UNAVAILABLE')])
def test_provider_errors_do_not_expose_response_or_secret(status, code):
    model = DeepSeek('test-secret', transport=httpx.MockTransport(
        lambda r: httpx.Response(status, text='sensitive upstream body')))
    with pytest.raises(ModelError) as e:
        model.analyze({'id': 's', 'scenario': 'sales'}, [{'id': 'x', 'session_id': 's', 'speaker': 'self', 'text': TEXT}])
    assert e.value.code == code
    assert 'secret' not in e.value.message and 'sensitive' not in e.value.message


@pytest.mark.parametrize('kind', ['wrong_id', 'invented_quote', 'truncated', 'invalid_json', 'extra_field'])
def test_invalid_output_rejected(kind):
    result = output('x')
    if kind == 'wrong_id': result['asset_citation']['segment_id'] = 'someone-else'
    if kind == 'invented_quote': result['asset_citation']['quote'] = '业绩增长500%'
    if kind == 'extra_field': result['confirmed'] = True
    body = {'choices': [{'finish_reason': 'length' if kind == 'truncated' else 'stop',
                        'message': {'content': 'bad json' if kind == 'invalid_json' else json.dumps(result)}}]}
    model = DeepSeek('test-secret', transport=httpx.MockTransport(lambda r: httpx.Response(200, json=body)))
    with pytest.raises(ModelError) as e:
        model.analyze({'id': 's', 'scenario': 'sales'}, [{'id': 'x', 'session_id': 's', 'speaker': 'self', 'text': TEXT}])
    assert e.value.code == 'LLM_INVALID_OUTPUT'


def test_delete_during_network_request_cannot_resurrect_memory(m):
    started, release = Event(), Event()
    def slow(request):
        started.set()
        assert release.wait(5)
        return response(request)
    m.llm.transport = httpx.MockTransport(slow)
    s, _ = evidence(m); m.retry(OWNER, s['id'], 'diagnosing')
    with ThreadPoolExecutor(max_workers=2) as pool:
        work = pool.submit(m.tick)
        assert started.wait(5)
        try:
            # This must finish while network IO is blocked.
            pool.submit(m.delete_memory, OWNER).result(timeout=2)
        finally: release.set()
        work.result(timeout=5)
    assert not m.rows('sessions', OWNER) and not m.rows('diagnoses', OWNER)


def test_api_explicit_consent_idempotency_and_real_review(m, monkeypatch, tmp_path):
    monkeypatch.setenv('CANDID_DATA_DIR', str(tmp_path/'api'))
    import app
    from fastapi.testclient import TestClient
    monkeypatch.setattr(app, 'store', m); monkeypatch.setattr(app, 'LOCAL_TOKEN', 'test-token')
    c = TestClient(app.app); headers = {'Authorization': 'Bearer test-token'}
    assert c.get('/v1/capabilities').status_code == 401
    capability = c.get('/v1/capabilities', headers=headers).json()
    assert capability['llm_model'] == 'deepseek-v4-pro' and 'secret' not in json.dumps(capability)
    s = c.post('/v1/sessions', headers=headers, json={
        'client_request_id': ident(), 'kind': 'oral_debrief', 'consent': 'unknown'}).json()
    base = '/v1/sessions/' + s['id']
    body = {'segments': [{'speaker': 'self', 'start_ms': 0, 'end_ms': 1000, 'text': TEXT}]}
    assert c.post(base+'/transcript', headers=headers, json=body).json()['pipeline_status'] == 'awaiting_model'
    assert m.db.execute('SELECT count(*) FROM jobs').fetchone()[0] == 0
    assert c.post(base+'/retry', headers=headers, json={'stage': 'diagnosing'}).status_code == 403
    body['analyze'] = True
    for _ in range(2):
        assert c.post(base+'/transcript', headers=headers, json=body).json()['pipeline_status'] == 'queued'
    assert m.db.execute('SELECT count(*) FROM jobs').fetchone()[0] == 1
    m.tick()
    review = c.get(base+'/review', headers=headers).json()
    assert review['session']['pipeline_status'] == 'done' and len(review['diagnoses']) == 1
    c.post(base+'/transcript', headers=headers, json=body)
    assert m.db.execute('SELECT count(*) FROM jobs').fetchone()[0] == 0


def test_auth_failure_is_terminal_and_does_not_generate_fixture(m):
    s, _ = evidence(m)
    m.llm.transport = httpx.MockTransport(lambda r: httpx.Response(401))
    m.retry(OWNER, s['id'], 'diagnosing'); m.tick()
    assert m.get('sessions', OWNER, s['id'])['pipeline_error'] == 'LLM_AUTH_FAILED'
    assert m.db.execute('SELECT status FROM jobs').fetchone()[0] == 'failed'
    assert not m.rows('diagnoses', OWNER) and not m.rows('assets', OWNER)


def test_audio_only_still_needs_asr(m):
    s = m.create_session(OWNER, {'client_request_id': ident(), 'kind': 'practice', 'consent': 'yes'})
    m.retry(OWNER, s['id'], 'transcribing'); m.tick()
    assert m.get('sessions', OWNER, s['id'])['pipeline_error'] == 'ASR_NOT_CONFIGURED'


def test_input_budget_and_timeout():
    model = DeepSeek('test-secret')
    s = {'id': 's', 'scenario': 'sales'}
    segments = [{'id': 'x', 'session_id': 's', 'speaker': 'self', 'text': '字'*20001}]
    with pytest.raises(ModelError) as e: model.analyze(s, segments)
    assert e.value.code == 'LLM_INPUT_TOO_LARGE'
    def timeout(r): raise httpx.ReadTimeout('sensitive')
    model.transport = httpx.MockTransport(timeout)
    segments[0]['text'] = TEXT
    with pytest.raises(ModelError) as e: model.analyze(s, segments)
    assert e.value.code == 'LLM_TIMEOUT'
