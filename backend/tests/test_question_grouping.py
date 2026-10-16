"""Production grouping: benchmark policy, durable jobs and private source lifecycle."""
import math
from types import SimpleNamespace
import pytest
from memory import Memory, L1, ident, now
from companion import Companion
from tasks.business import BusinessJobs
from tasks.workspaces import WorkspaceStore
from question_grouping import average_groups

A = '11111111-1111-4111-8111-111111111111'
B = '22222222-2222-4222-8222-222222222222'

@pytest.fixture
def setup(tmp_path):
    store = Memory(tmp_path/'db.sqlite', tmp_path/'files')
    business = BusinessJobs(store, SimpleNamespace(model='test'), WorkspaceStore(store))
    calls = []
    def encode(texts):
        calls.extend(texts)
        return [[0, 1, 0] if '交付' in text else [1, 0, 0] for text in texts]
    business.question_grouping.encoder_factory = lambda: SimpleNamespace(encode=encode)
    yield store, business, calls
    business.close()
    store.db.close()

def question(store, text, owner=A):
    s = store.create_session(owner, {'client_request_id':ident(), 'scenario':'sales', 'kind':'live',
                                    'consent':'yes', 'consent_ack_text_version':'v1'})
    store.update('sessions', owner, s['id'], {'transcript_revision':1, 'llm_consent_at':now()})
    line = store.put('transcript_segments', owner, {'session_id':s['id'], 'speaker':'other',
        'text':text, 'start_ms':100, 'end_ms':3000, 'transcript_revision':1}, L1)
    Companion(store).save_expressions(owner, s['id'], '1', {'expressions':[
        {'title':text, 'text':'先确认适用范围。', 'quote':text, 'segment_id':line['id'], 'kind':'客户常问'}]}, [line], 0)
    return s

def finish(business, owner=A):
    snapshot = business.question_grouping.snapshot(owner)
    job = business.store.get('business_jobs', owner, snapshot['job_id'])
    business.run(owner, job)
    return business.question_grouping.snapshot(owner)

def test_average_linkage_prevents_transitive_bridge():
    vectors = [[math.cos(a), math.sin(a)] for a in (0, math.pi/4, math.pi/2)]
    assert sorted(map(len, average_groups(vectors))) == [1, 2]
    assert average_groups([[1,0], [1,0], [0,1]]) == [[0,1], [2]]
    assert average_groups([]) == []

def test_durable_grouping_cached_and_isolated(setup):
    store, business, calls = setup
    question(store, '多少钱？'); question(store, '价格是多少？'); question(store, '何时交付？')
    pending = business.question_grouping.snapshot(A)
    assert pending['status'] == 'queued' and not calls
    assert pending == business.question_grouping.snapshot(A)
    ready = finish(business)
    assert ready['status'] == 'ready'
    assert sorted(g['occurrences'] for g in ready['groups']) == [1,2]
    assert len(calls) == 3
    question(store, '多少钱？')
    assert finish(business)['groups'][0]['occurrences'] == 3
    assert len(calls) == 3
    question(store, '多少钱？', B)
    assert finish(business, B)['groups'][0]['occurrences'] == 1
    assert len(calls) == 4, 'No cross-owner embedding cache reuse'
    store.delete_memory(A)
    assert not store.rows('question_embeddings', A)
    assert not store.rows('question_groupings', A)
    assert store.rows('question_embeddings', B)

def test_source_revision_invalidates_group_and_during_network_commit(setup):
    store, business, _ = setup
    s = question(store, '价格是多少？'); question(store, '多少钱？')
    assert finish(business)['groups'][0]['occurrences'] == 2
    store.update('sessions', A, s['id'], {'transcript_revision':2})
    pending = business.question_grouping.snapshot(A)
    assert pending['status'] == 'queued' and pending['groups'][0]['occurrences'] == 1
    s2 = question(store, '交付周期？')
    def change_while_encoding(texts):
        store.update('sessions', A, s2['id'], {'transcript_revision':2})
        return [[0,1,0] for _ in texts]
    business.question_grouping.encoder_factory = lambda: SimpleNamespace(encode=change_while_encoding)
    snapshot = business.question_grouping.snapshot(A)
    job = store.get('business_jobs', A, snapshot['job_id'])
    business.run(A, job)
    assert store.get('business_jobs', A, job['id'])['result']['superseded']
    assert len(store.rows('question_embeddings', A)) == 1
    assert all(g['occurrences'] == 1 for g in business.question_grouping.snapshot(A)['groups'])

def test_provider_failure_visible_and_retryable(setup):
    store, business, _ = setup
    question(store, '价格？')
    good = business.question_grouping.encoder_factory
    def missing(): raise ValueError('not configured')
    business.question_grouping.encoder_factory = missing
    failed = finish(business)
    assert failed['status'] == 'failed' and failed['error']
    assert not store.rows('question_groupings', A)
    business.question_grouping.encoder_factory = good
    business.retry(A, failed['job_id'])
    assert finish(business)['status'] == 'ready'

def test_memory_http_returns_grouping_without_vectors(setup, bind_app_store):
    import app
    from fastapi.testclient import TestClient
    store, _, _ = setup
    bind_app_store(app, store)
    question(store, '价格？')
    response = TestClient(app.app).get('/v1/companion/memory', headers={'Authorization':'Bearer test-token'})
    assert response.status_code == 200
    assert response.json()['question_grouping']['status'] == 'queued'
    assert 'vector' not in response.text
    assert response.json()['delivery']['recording_count'] == 0

def test_all_sources_removed_clears_cache_and_restoring_requeues(setup):
    store, business, _ = setup
    s = question(store, '价格？')
    assert finish(business)['status'] == 'ready'
    store.update('sessions', A, s['id'], {'transcript_revision':2})
    assert business.question_grouping.snapshot(A)['groups'] == []
    assert store.rows('question_embeddings', A) == []
    assert store.rows('question_groupings', A) == []
    store.update('sessions', A, s['id'], {'transcript_revision':1})
    assert finish(business)['status'] == 'ready'

def test_delivery_counts_only_recorded_current_sources(setup):
    store, _, _ = setup
    s = question(store, '价格？')
    store.put('session_media', A, {'session_id':s['id']}, L1)
    store.put('recording_knowledge', A, {'session_id':s['id'], 'revision':'1',
        'review':{'next_steps':['核对方案范围']}, 'status':'active'}, L1)
    store.put('transcript_segments', A, {'session_id':s['id'], 'speaker':'self',
        'text':'先核对方案范围', 'start_ms':3000, 'end_ms':5900, 'transcript_revision':1}, L1)
    delivery = Companion(store).delivery(A)
    assert delivery['recording_count'] == delivery['reviewed_count'] == delivery['next_step_count'] == 1
    assert delivery['speaking_samples'][0]['speaking_share'] == 50
    store.update('sessions', A, s['id'], {'transcript_revision':2})
    delivery = Companion(store).delivery(A)
    assert delivery['reviewed_count'] == delivery['next_step_count'] == 0
    assert delivery['speaking_samples'] == []
    store.update('sessions', A, s['id'], {'fixture':True})
    assert Companion(store).delivery(A)['recording_count'] == 0


def test_invalid_vector_batch_does_not_poison_cache(setup):
    store, business, _ = setup
    question(store, '价格？'); question(store, '交付时间？')
    business.question_grouping.encoder_factory = lambda: SimpleNamespace(encode=lambda texts: [[1,0], [1,0,0]])
    assert finish(business)['status'] == 'failed'
    assert store.rows('question_embeddings', A) == []
