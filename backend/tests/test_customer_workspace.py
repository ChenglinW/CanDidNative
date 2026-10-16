"""Customer dashboard acceptance: explicit assignment, scoped publication and stable activity."""
from pathlib import Path
import sys
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from fastapi.testclient import TestClient
from memory import Memory,L1,L2,ident,now,Fault
from companion import Companion
from tasks.workspaces import WorkspaceStore
from adapters.sources import version

A='11111111-1111-4111-8111-111111111111'
B='22222222-2222-4222-8222-222222222222'
HEADERS={'Authorization':'Bearer test-token'}

@pytest.fixture
def api(tmp_path,bind_app_store):
    import app
    store=Memory(tmp_path/'customer.sqlite',tmp_path/'files')
    bind_app_store(app,store)
    yield TestClient(app.app),app,store


def create_recording(client):
    reply=client.post('/v1/recordings',headers=HEADERS,json={'client_request_id':ident(),'consent':'yes','recording_source':'soundcore','customer_assignment_required':True})
    assert reply.status_code==200,reply.text
    return reply.json()


def complete(store,sid):
    store.update('sessions',A,sid,{'pipeline_status':'done','transcript_revision':1})
    line=store.put('transcript_segments',A,{'session_id':sid,'speaker':'unknown','speaker_id':'part0:0','start_ms':0,'end_ms':2000,'text':'客户要核实实施范围','transcript_revision':1},L1)
    refs=[{'source_id':'transcript:'+line['id'],'source_version':version(line)}]
    knowledge=store.put('recording_knowledge',A,{'session_id':sid,'revision':'1','part':0,'text':'实施范围仍需核实','title':'复盘','evidence_refs':refs,'producer':'test','rubric_version':'test'},L2,source='ai')
    return line,knowledge


def test_assignment_is_one_confirmation_idempotent_and_isolated(api):
    client,app,store=api
    spaces=WorkspaceStore(store)
    a=spaces.create(A,'客户甲','试点',ident());b=spaces.create(A,'客户乙','扩展',ident())
    row=create_recording(client);sid=row['id'];line,knowledge=complete(store,sid)
    for space in (a,b):store.put('recording_tags',A,{'session_id':sid,'workspace_id':space['id'],'label':space['name'],'active':True,'kind':'client','revision':1},L1)
    app.business.product.sync_recording(A,sid)
    assert not store.rows('recording_links',A,session_id=sid,active=True)
    assert not spaces.allowed(A,'transcript',line,a['id'])
    assert not Companion(store).publish_recording(A,sid,'1')['published']
    assert spaces.view(A,a)['confirmed_recording_count']==0
    payload={'workspace_id':a['id'],'expected_revision':0}
    first=client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json=payload)
    assert first.status_code==200,first.text
    stamp=first.json()['customer_confirmed_at']
    assert client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json=payload).json()['customer_confirmed_at']==stamp
    assert spaces.view(A,a)['confirmed_recording_count']==1
    assert spaces.view(A,b)['confirmed_recording_count']==0
    assert spaces.allowed(A,'transcript',line,a['id'])
    assert spaces.allowed(A,'knowledge',knowledge,a['id'])
    assert not spaces.allowed(A,'transcript',line,b['id'])
    messages=store.rows('chat_messages',A,recording_id=sid)
    assert len(messages)==1 and messages[0]['thread_id']==a['default_thread_id']
    assert len(store.rows('recording_tags',A,session_id=sid,active=True))==2
    assert len(store.rows('recording_links',A,session_id=sid,active=True))==1
    assert client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json={**payload,'workspace_id':b['id']}).status_code==409
    foreign=spaces.create(B,'其他用户','',ident())
    assert client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json={**payload,'workspace_id':foreign['id']}).status_code==404


def test_confirm_before_review_publishes_when_ready_and_updates_same_message(api):
    client,app,store=api;spaces=WorkspaceStore(store);a=spaces.create(A,'客户甲','',ident())
    sid=create_recording(client)['id']
    assert client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json={'workspace_id':a['id'],'expected_revision':0}).status_code==200
    assert store.rows('chat_messages',A,recording_id=sid)==[]
    complete(store,sid);domain=Companion(store)
    domain.publish_recording(A,sid,'1');domain.publish_recording(A,sid,'1')
    assert len(store.rows('chat_messages',A,recording_id=sid))==1
    assert spaces.view(A,a)['confirmed_recording_count']==1


def test_legacy_publication_moves_once_to_confirmed_customer(api):
    client,app,store=api;spaces=WorkspaceStore(store);a=spaces.create(A,'客户甲','',ident())
    row=store.create_session(A,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'v1'})
    sid=row['id'];complete(store,sid);domain=Companion(store);domain.publish_recording(A,sid,'1')
    original=store.rows('chat_messages',A,recording_id=sid)[0]
    assert client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json={'workspace_id':a['id'],'expected_revision':0}).status_code==200
    result=store.rows('chat_messages',A,recording_id=sid)
    assert len(result)==1 and result[0]['id']==original['id'] and result[0]['thread_id']==a['default_thread_id']
    assert store.get('chat_threads',A,original['thread_id'])['message_count']==0


def test_workspace_search_pagination_and_view_does_not_change_activity(api):
    client,app,store=api;spaces=WorkspaceStore(store)
    rows=[spaces.create(A,'香港客户'+str(n),'',ident()) for n in range(4)]
    spaces.create(A,'其他客户','',ident());Companion(store).thread(A)
    first=client.get('/v1/project-spaces',headers=HEADERS,params={'customers_only':True,'q':'香港','limit':2}).json()
    second=client.get('/v1/project-spaces',headers=HEADERS,params={'customers_only':True,'q':'香港','limit':2,'cursor':first['next_cursor']}).json()
    assert len({s['id'] for s in first['data']+second['data']})==4
    assert second['next_cursor'] is None
    before=spaces.view(A,rows[0])['last_active_at']
    client.get('/v1/project-spaces',headers=HEADERS)
    assert spaces.view(A,rows[0])['last_active_at']==before
    message=store.put('chat_messages',A,{'thread_id':rows[0]['default_thread_id'],'role':'user','content':'继续推进','sources':[],'tool_steps':[]},L1)
    assert spaces.view(A,rows[0])['last_active_at']==message['created_at']
    client.get('/v1/project-spaces',headers=HEADERS)
    assert spaces.view(A,rows[0])['last_active_at']==message['created_at']


def test_older_app_can_still_process_recordings_without_new_assignment_ui(api):
    client,app,store=api
    row=client.post('/v1/recordings',headers=HEADERS,json={'client_request_id':ident(),'consent':'yes'}).json()
    assert not row['customer_assignment_required']
    complete(store,row['id'])
    assert Companion(store).publish_recording(A,row['id'],'1')['published']


def test_manual_cross_customer_read_does_not_change_primary_or_count(api):
    client,app,store=api;spaces=WorkspaceStore(store)
    a=spaces.create(A,'客户甲','',ident());b=spaces.create(A,'客户乙','',ident())
    sid=create_recording(client)['id'];line,knowledge=complete(store,sid)
    client.put(f'/v1/recordings/{sid}/customer',headers=HEADERS,json={'workspace_id':a['id'],'expected_revision':0})
    assert not spaces.allowed(A,'transcript',line,b['id'])
    spaces.set_scope(A,'session:'+sid,'spaces',[a['id'],b['id']],0)
    assert spaces.allowed(A,'transcript',line,b['id'])
    assert spaces.view(A,b)['confirmed_recording_count']==0
    assert store.get('sessions',A,sid)['customer_workspace_id']==a['id']


def test_interview_preparation_keeps_scenario_after_product_migration(api):
    client,app,store=api;spaces=WorkspaceStore(store)
    a=spaces.create(A,'','',ident())
    Companion(store).save_preparation(A,a['default_thread_id'],ident(),{'client':'产品经理面试','goal':'了解岗位与项目要求','scenario':'interview','sections':[]},[])
    updated=spaces.get(A,a['id'])
    assert updated['scenario']=='interview' and updated['name']=='产品经理面试'
    app.business.product.migrate(A)
    updated=spaces.get(A,a['id'])
    assert updated['scenario']=='interview' and updated['stage']=='preparing'
    manual=spaces.create(A,'我保留的客户称呼','',ident())
    Companion(store).save_preparation(A,manual['default_thread_id'],ident(),{'client':'模型称呼','goal':'澄清目标','scenario':'sales','sections':[]},[])
    assert spaces.get(A,manual['id'])['name']=='我保留的客户称呼'
