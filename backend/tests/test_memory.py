import hashlib
import json
import sqlite3
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime,timedelta,timezone
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,Fault,L1,L2,L3,ident,now,CONFIG,TABLES

A='11111111-1111-4111-8111-111111111111';B='22222222-2222-4222-8222-222222222222'
@pytest.fixture
def m(tmp_path):return Memory(tmp_path/'db.sqlite',tmp_path/'storage')
def occasion(m,owner=A):return m.put('occasions',owner,{'title':'面试','scenario':'interview','fields':{},'status':'active'},L3,actor=owner)
def session(m,owner=A,consent='yes'):
    return m.create_session(owner,{'client_request_id':ident(),'scenario':'interview','kind':'live','consent':consent,'consent_ack_text_version':'v1'})
def evidence(m,owner=A):
    s=session(m,owner)
    seg=m.put('transcript_segments',owner,{'session_id':s['id'],'speaker':'self','start_ms':0,'end_ms':20000,'text':'用户原文'},L1)
    return s,{'session_id':s['id'],'start_ms':0,'end_ms':20000}
def asset(m,owner=A,trust=L2):
    return m.put('assets',owner,{'title':'素材','body':{'text':'经历'},'status':'draft' if trust==L2 else 'confirmed','version':1,'producer':'fixture@1','rubric_version':'interview@1.2','scenario':'interview'},trust,'ai' if trust==L2 else 'user',actor=owner if trust==L3 else None)

def test_T1_owner_isolation(m):
    a=asset(m,B)
    assert m.rows('assets',A)==[]
    with pytest.raises(Fault) as e:m.get('assets',A,a['id'])
    assert e.value.status==404
def test_T2_ai_cannot_confirm_database_guard(m):
    a=asset(m)
    with pytest.raises(sqlite3.IntegrityError):
        m.update('assets',A,a['id'],{'trust':L3,'source':'user','confirmed_by':A,'confirmed_at':now(),'status':'confirmed'})
def test_T3_diagnosis_requires_evidence(m):
    with pytest.raises(Fault) as e:m.put('diagnoses',A,{'producer':'fixture@1','rubric_version':'interview@1.2'},L2,'ai')
    assert e.value.code=='EVIDENCE_MISSING'
def test_T4_version_required(m):
    with pytest.raises(Fault):m.put('metrics',A,{'producer':'fixture@1'},L2,'ai')
def test_T5_consent_guard_api(tmp_path,monkeypatch):
    monkeypatch.setenv('CANDID_DATA_DIR',str(tmp_path/'api'));monkeypatch.setenv('CANDID_LOCAL_TOKEN','test-token')
    import app
    from fastapi.testclient import TestClient
    app.store=Memory(tmp_path/'api.sqlite',tmp_path/'storage');app.LOCAL_TOKEN='test-token'
    client=TestClient(app.app);h={'Authorization':'Bearer test-token'}
    s=client.post('/v1/sessions',json={'client_request_id':ident(),'kind':'live','consent':'unknown'},headers=h).json()
    r=client.post('/v1/sessions/'+s['id']+'/media',json={'storage_path':'invalid','sha256':'a'*64,'mime':'audio/mp4','bytes':1},headers=h)
    assert r.status_code==403 and r.json()['error']['code']=='CONSENT_REQUIRED'
    assert client.get('/v1/assets').status_code==401
    assert client.post('/v1/assets',json={'owner_id':B},headers=h).status_code==400
def prepare_purge(m):
    s,ref=evidence(m);sid=s['id']
    m.put('transcript_segments',A,{'session_id':sid,'speaker':'other','start_ms':0,'end_ms':10000,'text':'不能进入准备的对方原话'})
    m.put('diagnoses',A,{'session_id':sid,'producer':'fixture@1','rubric_version':'interview@1.2','evidence_refs':[ref]},L2,'ai')
    (m.root/A).mkdir(exist_ok=True);p=m.root/A/'test.audio';p.write_bytes(b'abc')
    m.put('session_media',A,{'session_id':sid,'storage_path':A+'/test.audio','sha256':hashlib.sha256(b'abc').hexdigest()})
    m.update('sessions',A,sid,{'purge_at':(datetime.now(timezone.utc)-timedelta(days=1)).isoformat()})
    return s,p
def test_T6_purge_preserves_self_and_diagnosis(m):
    s,p=prepare_purge(m);assert m.purge_expired()['purged']==1
    assert not p.exists() and not m.rows('session_media',A)
    assert len(m.rows('transcript_segments',A))==1 and len(m.rows('diagnoses',A))==1
    assert m.db.execute('SELECT count(*) FROM deletion_log').fetchone()[0]==2
def test_T7_purge_idempotent(m):
    prepare_purge(m);m.purge_expired();assert m.purge_expired()=={'purged':0,'failed':0}
def test_T8_retention_shorten_and_extend(m):
    s=session(m);m.change_retention(A,7);s=m.get('sessions',A,s['id']);assert s['retention_days']==7
    m.change_retention(A,180);assert m.get('sessions',A,s['id'])['retention_days']==7
def test_T9_session_idempotency(m):
    d={'client_request_id':ident(),'kind':'practice','consent':'unknown'}
    a=m.create_session(A,d);b=m.create_session(A,d);assert a['id']==b['id'] and a['consent']=='yes'
def test_T10_retry_does_not_touch_evidence(m):
    o=occasion(m);s=m.fixture(A,o['id'])
    for _ in range(3):m.tick()
    before=m.rows('transcript_segments',A);m.retry(A,s['id'],'diagnosing')
    m.tick();m.tick();assert m.rows('transcript_segments',A)==before
    assert len(m.rows('diagnoses',A))==1
def test_T11_context_excludes_old_rubric(m):
    o=occasion(m);asset(m,trust=L3)
    m.put('weaknesses',A,{'scenario':'interview','state':'open','description':'旧标准','producer':'old@1','rubric_version':'interview@0.1'},L2,'ai')
    context=m.context(A,'prep',o['id']);assert '旧标准' not in json.dumps(context,ensure_ascii=False)
def test_T12_budget_preserves_confirmed_experience(m):
    o=occasion(m);m.put('experiences',A,{'title':'确认经历','body':{'text':'事实'},'status':'confirmed'},L3,actor=A)
    for _ in range(20):asset(m,trust=L3)
    c=m.context(A,'prep',o['id'],budget=400)
    assert c['truncated'] and c['token_count']<=400
    assert any(s['key']=='confirmed_experiences' and s['items'] for s in c['sections'])
def test_T13_other_speech_never_in_context(m):
    s,p=prepare_purge(m)
    c=m.context(A,'diagnose',session_id=s['id'])
    assert '不能进入准备的对方原话' not in json.dumps(c,ensure_ascii=False)
def test_T14_concurrent_confirmation(m):
    a=asset(m)
    def do():
        try:m.mutate_asset(A,a['id'],1,status='confirmed');return 200
        except Fault as e:return e.status
    with ThreadPoolExecutor(max_workers=2) as pool:assert sorted(pool.map(lambda _:do(),range(2)))==[200,409]
def test_T15_no_ten_asset_limit(m):
    for _ in range(11):asset(m)
    assert len(m.rows('assets',A))==11
def test_T16_delete_memory_blocks_reads_and_removes_content(m):
    prepare_purge(m);asset(m);m.profile(A);m.delete_memory(A)
    assert all(not m.rows(t,A) for t in TABLES)
    assert not list((m.root/A).glob('*'))
    with pytest.raises(Fault):m.check_owner(A)
def test_T17_weakness_state_machine(m):
    w=m.put('weaknesses',A,{'state':'open','hit_count':2,'consecutive_pass':0,'producer':'fixture@1','rubric_version':'interview@1.2'},L2,'ai')
    assert m.transition(A,w['id'],'pass',ident())['state']=='improving'
    assert m.transition(A,w['id'],'pass',ident())['state']=='resolved'
    assert m.transition(A,w['id'],'hit',ident())['state']=='open'
def test_l1_cannot_update(m):
    s,ref=evidence(m);seg=m.rows('transcript_segments',A)[0]
    with pytest.raises(sqlite3.IntegrityError):m.update('transcript_segments',A,seg['id'],{'text':'覆盖'})
def test_evidence_must_belong_to_self(m):
    s,ref=evidence(m,B)
    with pytest.raises(Fault):m.put('diagnoses',A,{'producer':'fixture@1','rubric_version':'interview@1.2','evidence_refs':[ref]},L2,'ai')
def test_fixture_does_not_require_external_provider(m):
    o=occasion(m);s=m.fixture(A,o['id']);[m.tick() for _ in range(3)]
    assert m.get('sessions',A,s['id'])['pipeline_status']=='done'
    assert m.rows('assets',A)[0]['status']=='draft'
def test_signed_upload_and_hash_confirmation(tmp_path,monkeypatch):
    import app
    from fastapi.testclient import TestClient
    app.store=Memory(tmp_path/'api.sqlite',tmp_path/'storage');app.LOCAL_TOKEN='test-token'
    c=TestClient(app.app);h={'Authorization':'Bearer test-token'}
    c.patch('/v1/profile',json={'product_use_consent':True},headers=h)
    s=c.post('/v1/sessions',json={'client_request_id':ident(),'kind':'practice','consent':'yes','recording_source':'soundcore','device_file_id':1701234567},headers=h).json()
    assert s['recording_source']=='soundcore' and s['device_file_id']==1701234567
    u=c.post('/v1/sessions/'+s['id']+'/upload-url',headers=h).json()['upload_url']
    r=c.put(u,content=b'abc',headers={'Content-Type':'audio/mp4'}).json()
    r2=c.put(u+'?offset=3',content=b'def',headers={'Content-Type':'audio/mp4'}).json()
    assert r2['bytes']==6
    r2['duration_ms']=6000
    saved=c.post('/v1/sessions/'+s['id']+'/media',json=r2,headers=h)
    assert saved.status_code==200
    assert c.get('/v1/sessions/'+s['id'],headers=h).json()['duration_ms']==6000
    assert c.get('/v1/sessions/'+s['id'],headers=h).json()['recording_source']=='soundcore'
    replay=c.post('/v1/sessions/'+s['id']+'/media',json=r2,headers=h)
    assert replay.json()['id']==saved.json()['id']
    a=c.get('/v1/sessions/'+s['id']+'/audio',headers=h).json()
    assert c.get(a['url']).content==b'abcdef'
    c.delete('/v1/sessions/'+s['id']+'/audio',headers=h)
    assert c.get(a['url']).status_code==409

def test_missing_l2_version_rejected_by_sql(m):
    payload={'id':ident(),'owner_id':A,'visibility':'private','source':'ai','trust':L2,'producer':'test@1'}
    with pytest.raises(sqlite3.IntegrityError):m.db.execute('INSERT INTO metrics VALUES(?,?,?,?)',(payload['id'],A,now(),json.dumps(payload)))

def test_processing_consent_required(tmp_path):
    import app
    from fastapi.testclient import TestClient
    app.store=Memory(tmp_path/'api.sqlite',tmp_path/'storage');app.LOCAL_TOKEN='test-token'
    c=TestClient(app.app);h={'Authorization':'Bearer test-token'}
    s=c.post('/v1/sessions',json={'client_request_id':ident(),'kind':'practice','consent':'yes'},headers=h).json()
    r=c.post('/v1/sessions/'+s['id']+'/upload-url',headers=h)
    assert r.status_code==403 and r.json()['error']['code']=='PROCESSING_CONSENT_REQUIRED'

def test_disagreement_survives_aggregate_retry(m):
    o=occasion(m)
    for _ in range(2):
        s=m.fixture(A,o['id']);[m.tick() for _ in range(3)]
    w=m.rows('weaknesses',A)[0];m.update('weaknesses',A,w['id'],{'state':'disputed','user_disagrees':True,'dispute_hits':0})
    m.retry(A,s['id'],'aggregating');m.tick()
    assert m.rows('weaknesses',A)[0]['user_disagrees'] is True
    assert not next(x for x in m.context(A,'prep',o['id'])['sections'] if x['key']=='weaknesses')['items']

def test_expired_unregistered_upload_deleted(m):
    s=session(m);(m.root/A).mkdir(exist_ok=True);p=m.root/A/(s['id']+'.part');p.write_bytes(b'partial')
    m.update('sessions',A,s['id'],{'purge_at':(datetime.now(timezone.utc)-timedelta(days=1)).isoformat()})
    m.purge_expired();assert not p.exists()
