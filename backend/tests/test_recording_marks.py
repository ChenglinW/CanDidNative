from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from types import SimpleNamespace
import pytest
from fastapi.testclient import TestClient
from memory import Memory,L1,L2,ident
from adapters.sources import version
A='11111111-1111-4111-8111-111111111111';H={'Authorization':'Bearer test-token'}
@pytest.fixture
def setup(tmp_path,bind_app_store,monkeypatch):
 import app
 store=Memory(tmp_path/'db.sqlite',tmp_path/'files');bind_app_store(app,store)
 app.business.gateway=SimpleNamespace(configured=True,model='test')
 calls=[]
 def structured(*args,**kwargs):
  calls.append(args[1]);return {'title':'预算与交期','summary':'这一段讨论了预算和交期，需要核对范围。','topics':['需求','待核实'],'suggestion':'可以结合现有资料核对。'}
 monkeypatch.setattr(app.business,'structured',structured)
 session=store.create_session(A,{'client_request_id':ident(),'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'v1'})
 store.update('sessions',A,session['id'],{'duration_ms':180000,'transcript_revision':1,'llm_consent_at':'2026-10-16T00:00:00Z'})
 yield app,TestClient(app.app),session['id'],calls
 store.db.close()
def lines(app,sid,rev=1):
 return [app.store.put('transcript_segments',A,{'session_id':sid,'transcript_revision':rev,'speaker':'unknown','speaker_id':'part0:'+str(i),'start_ms':start,'end_ms':end,'text':text},L1) for i,(start,end,text) in enumerate([(0,12000,'预算是二十万元，什么时候交付？'),(13000,35000,'我先核对交付资料，下次再确认。'),(140000,170000,'另外讨论了其他事情。')])]
def snapshot(app,sid):return app.recordings.marks.snapshot(A,sid)
def finish(app,sid):
 state=snapshot(app,sid)
 if state['job_id']:app.business.run(A,app.store.get('business_jobs',A,state['job_id']))
 return snapshot(app,sid)
def mark(c,sid,*times):
 r=c.post('/v1/sessions/'+sid+'/marks',headers=H,json={'marks':[{'t_ms':t,'user_label':'unlabeled'} for t in times]});assert r.status_code==200,r.text;return r.json()['data']

def test_late_marks_are_analyzed_idempotently_and_link_existing_outputs(setup):
 app,c,sid,calls=setup;source=lines(app,sid)
 faq=app.store.put('library_items',A,{'title':'预算怎么回答','text':'保留原说法','source_session_id':sid,'item_type':'faq','status':'active','version':1,'evidence_refs':[{'source_id':'transcript:'+source[0]['id'],'source_version':version(source[0])}],'producer':'test','rubric_version':'test'},L2,source='ai')
 action=app.store.put('project_items',A,{'kind':'gap','text':'核对交期','evidence_refs':[{'source_id':'transcript:'+source[1]['id']}]},L1)
 mark(c,sid,10000,18000);mark(c,sid,10000)
 assert len(app.store.rows('marks',A,session_id=sid))==2
 result=finish(app,sid);assert result['items'][0]['status']=='ready'
 assert len(result['items'])==1 and len(result['items'][0]['mark_ids'])==2
 assert result['items'][0]['faq_links']==[{'id':faq['id'],'title':faq['title']}]
 assert result['items'][0]['action_ids']==[action['id']]
 assert len(result['items'][0]['segments'])==2
 assert len(calls)==1
 finish(app,sid);assert len(calls)==1
 assert app.store.get('library_items',A,faq['id'])['text']=='保留原说法'
 assert app.store.rows('personal_memories',A)==[]

def test_mark_before_transcript_and_revision_replaces_only_ai_summary(setup):
 app,c,sid,calls=setup;raw=mark(c,sid,10000)[0]
 assert snapshot(app,sid)['items'][0]['status']=='waiting_transcript'
 assert snapshot(app,sid)['job_id'] is None
 lines(app,sid);old=snapshot(app,sid)['job_id']
 app.store.update('sessions',A,sid,{'transcript_revision':2});lines(app,sid,2)
 app.business.run(A,app.store.get('business_jobs',A,old))
 assert app.store.get('business_jobs',A,old)['result']['superseded']
 result=finish(app,sid);assert result['items'][0]['summary']
 r=c.patch(f'/v1/recordings/{sid}/marks/{raw["id"]}',headers=H,json={'title':'我自己的重点标题'});assert r.status_code==200
 app.store.update('sessions',A,sid,{'transcript_revision':3});lines(app,sid,3)
 assert snapshot(app,sid)['items'][0]['summary']==''
 assert finish(app,sid)['items'][0]['title']=='我自己的重点标题'

def test_remove_group_keeps_raw_evidence_and_existing_knowledge(setup):
 app,c,sid,calls=setup;lines(app,sid);mark(c,sid,10000,15000)
 result=finish(app,sid);hid=result['items'][0]['id']
 r=c.delete(f'/v1/recordings/{sid}/highlights/{hid}',headers=H);assert r.status_code==200 and r.json()['items']==[]
 assert len(app.store.rows('marks',A,session_id=sid))==2
 assert len(app.recordings.segments(A,sid))==3
 mark(c,sid,10000);assert snapshot(app,sid)['items']==[]
 bad=c.post('/v1/sessions/'+sid+'/marks',headers=H,json={'marks':[{'t_ms':190000}]});assert bad.status_code==400

def test_mark_failure_is_retryable_and_other_sessions_not_linked(setup,monkeypatch):
 app,c,sid,calls=setup;lines(app,sid);mark(c,sid,0,180000)
 original=app.business.structured
 def fail(*a,**k):raise RuntimeError('provider failure')
 monkeypatch.setattr(app.business,'structured',fail)
 state=finish(app,sid);assert state['status']=='failed' and state['error']
 assert state['items'][0]['segments'] and not state['items'][0]['faq_ids']
 monkeypatch.setattr(app.business,'structured',original);app.business.retry(A,state['job_id'])
 assert finish(app,sid)['items'][0]['status']=='ready'
 foreign=app.store.put('marks','22222222-2222-4222-8222-222222222222',{'session_id':sid,'t_ms':1},L1)
 assert c.delete(f'/v1/recordings/{sid}/marks/{foreign["id"]}',headers=H).status_code==404

def test_ask_uses_selected_final_context_without_switching_user_workspace(setup,monkeypatch):
 app,c,sid,calls=setup;lines(app,sid);mark(c,sid,10000);hid=finish(app,sid)['items'][0]['id']
 captured={}
 def submit(owner,thread,text,request,**kw):captured.update(owner=owner,thread=thread,text=text,**kw);return {'id':'test-task'}
 monkeypatch.setattr(app.agent,'submit',submit)
 r=c.post(f'/v1/recordings/{sid}/highlights/{hid}/ask',headers=H,json={'question':'这段有什么要核实？','client_request_id':ident()})
 assert r.status_code==200,r.text
 doc=app.store.get('documents',A,captured['live_source_id'].split(':')[1])
 assert '预算是二十万元' in doc['text'] and 'unknown' in doc['text']
 assert '其他事情' not in doc['text']
 assert doc['evidence_refs'] and doc['session_id']==sid

def test_agent_can_find_marked_context_and_snapshot_invalidates_on_revision(setup,monkeypatch):
 from adapters.sqlite_memory import SQLiteMemoryAdapter
 from memory import Fault
 app,c,sid,calls=setup;source=lines(app,sid);mark(c,sid,10000)
 adapter=SQLiteMemoryAdapter(app.store)
 listing=adapter.query(A,'list_sessions',{},[])
 assert next(r for r in listing['items'] if r['session_id']==sid)['mark_count']==1
 read=adapter.query(A,'read_session',{'session_id':sid},[])
 assert read['marks']==[{'t_ms':10000}]
 monkeypatch.setattr(app.agent,'submit',lambda *a,**k:{'id':'selected-mark-task'})
 hid=finish(app,sid)['items'][0]['id']
 r=c.post(f'/v1/recordings/{sid}/highlights/{hid}/ask',headers=H,json={'question':'核对这里','client_request_id':ident()});assert r.status_code==200,r.text
 doc=app.store.rows('documents',A,material_kind='recording_mark_snapshot')[0]
 assert adapter.resolve(A,'document:'+doc['id'])[1]['text']
 app.store.update('sessions',A,sid,{'transcript_revision':2});lines(app,sid,2)
 with pytest.raises(Fault):adapter.resolve(A,'document:'+doc['id'])

def test_mark_arriving_during_model_call_does_not_commit_old_result(setup,monkeypatch):
 app,c,sid,calls=setup;lines(app,sid);mark(c,sid,10000)
 original=app.business.structured;state=snapshot(app,sid)
 def late(*a,**k):
  mark(c,sid,15000)
  return original(*a,**k)
 monkeypatch.setattr(app.business,'structured',late)
 app.business.run(A,app.store.get('business_jobs',A,state['job_id']))
 assert app.store.get('business_jobs',A,state['job_id'])['result']['superseded']
 assert not app.store.get('sessions',A,sid).get('mark_analysis')
 monkeypatch.setattr(app.business,'structured',original)
 assert len(finish(app,sid)['items'][0]['mark_ids'])==2
