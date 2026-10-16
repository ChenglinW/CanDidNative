"""Product regression: migration, scopes, grounded jobs and user-authorized writes.
No provider requests, microphone, notification permissions or production database.
"""
import json,sys,zipfile
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,Fault,L1,L2,L3,ident,now
from product import Product
from tasks.business import BusinessJobs
from tasks.workspaces import WorkspaceStore
from adapters.sqlite_memory import SQLiteMemoryAdapter
from adapters.sources import version
from product_routes import word_document
A='11111111-1111-4111-8111-111111111111';B='22222222-2222-4222-8222-222222222222'
class Gateway:
    model='offline-model';base='https://offline.invalid';configured=True
    result={'items':[]}
    def complete(self,*args,**kwargs):return {'content':json.dumps(self.result,ensure_ascii=False)}
@pytest.fixture
def domain(tmp_path):
    store=Memory(tmp_path/'test.sqlite',tmp_path/'storage');gateway=Gateway();jobs=BusinessJobs(store,gateway,WorkspaceStore(store));p=jobs.product
    yield p
    jobs.close();store.db.close()
def project(p,owner=A,name='客户甲',scenario='sales'):
    return p.create(owner,{'name':name,'scenario':scenario,'goal':'推进试点','organization':'','opportunity':'','participants':[]},ident())
def meeting(p,pr=None):
    pr=pr or project(p)
    return p.meeting(A,pr['id'],{'title':'第三场','goal':'确认接口','actual_at':now()},ident())
def recording(p,mid,text='我明天提供接口文档。',speaker='self'):
    s=p.store.create_session(A,{'client_request_id':ident(),'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'v1'})
    p.store.update('sessions',A,s['id'],{'transcript_revision':1,'llm_consent_at':now()})
    line=p.store.put('transcript_segments',A,{'session_id':s['id'],'speaker':speaker,'speaker_id':'part0:0','start_ms':1000,'end_ms':4000,'text':text,'transcript_revision':1},L1)
    p.link(A,mid,s['id']);return s,line
def analyze(p,m,line,**extra):
    job=p.queue_analysis(A,m['id']);job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    p.business.gateway.result={'items':[{'kind':'action','text':'提供接口文档','quote':line['text'],'source_id':'transcript:'+line['id'],'owner':'我','external_safe':True,**extra}]}
    return p.analyze(A,job)
def test_future_meeting_without_recording_and_multiple_links(domain):
    p=domain;a=project(p);b=project(p,name='客户乙');ma=meeting(p,a);mb=meeting(p,b)
    assert p.evidence(A,ma['id'])==[]
    s,l=recording(p,ma['id']);p.link(A,mb['id'],s['id']);p.link(A,mb['id'],s['id'])
    assert len(p.store.rows('recording_links',A))==2
    assert p.spaces.allowed(A,'transcript',l,a['id']) and p.spaces.allowed(A,'transcript',l,b['id'])
    p.link(A,mb['id'],s['id'],False);assert not p.spaces.allowed(A,'transcript',l,b['id'])
def test_owner_and_scene_boundaries(domain):
    p=domain;pr=project(p)
    with pytest.raises(Fault):p.project(B,pr['id'])
    with pytest.raises(Fault):p.create(A,{'name':'路演','scenario':'pitch'},ident())
def test_project_retry_payload_and_optimistic_version(domain):
    p=domain;rid=ident();body={'name':'甲','scenario':'sales'};pr=p.create(A,body,rid)
    assert p.create(A,body,rid)['id']==pr['id']
    with pytest.raises(Fault):p.create(A,{'name':'乙','scenario':'sales'},rid)
    p.update_project(A,pr['id'],{'stage':'proposal'},1)
    with pytest.raises(Fault):p.update_project(A,pr['id'],{'stage':'won'},1)
    with pytest.raises(Fault):p.update_project(A,pr['id'],{'stage':'hr'},2)
def test_meeting_timezone_and_retry(domain):
    p=domain;pr=project(p);rid=ident();body={'title':'第三场','scheduled_at':'2026-10-15T14:00:00+08:00','timezone':'Asia/Hong_Kong'}
    m=p.meeting(A,pr['id'],body,rid);assert p.meeting(A,pr['id'],body,rid)['id']==m['id']
    with pytest.raises(Fault):p.meeting(A,pr['id'],{**body,'title':'第四场'},rid)
    with pytest.raises(Fault):p.meeting(A,pr['id'],{'title':'场次','scheduled_at':'2026-10-15T14:00:00'},ident())
def test_legacy_migration_preserves_ids_and_is_idempotent(domain):
    p=domain;o=p.store.put('occasions',A,{'title':'老项目','scenario':'sales','fields':{},'status':'active'},L3,actor=A)
    s=p.store.create_session(A,{'client_request_id':ident(),'occasion_id':o['id'],'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'v1'})
    p.migrate(A);first=p.projects(A);p.migrate(A)
    assert first==p.projects(A) and len(p.store.rows('business_meetings',A))==1
    assert p.store.get('sessions',A,s['id'])['id']==s['id']
def test_ambiguous_old_chats_not_merged(domain):
    p=domain;o=p.store.put('occasions',A,{'title':'甲','scenario':'sales','fields':{}},L1)
    for n in ['方向甲','方向乙']:p.spaces.create(A,n,'',ident(),o['id'])
    p.migrate(A);assert len(p.projects(A))==2
    assert not any(s.get('occasion_ids') for s in p.projects(A))
@pytest.mark.parametrize('mode',['personal','all','scenario','meeting'])
def test_scope_context_does_not_become_business_project(domain,mode):
    p=domain;pr=project(p);m=meeting(p,pr);s,l=recording(p,m['id'])
    scope={'mode':mode};scope.update({'scenario':'sales'} if mode=='scenario' else {'meeting_id':m['id']} if mode=='meeting' else {})
    t=p.scope_thread(A,scope);assert p.scope_thread(A,scope)['id']==t['id'];assert len(p.projects(A))==1
    assert p.spaces.allowed(A,'transcript',l,t['workspace_id'])==(mode!='personal')
def test_meeting_and_scenario_exclude_other_project(domain):
    p=domain;pr=project(p);m=meeting(p,pr);s,l=recording(p,m['id'])
    other=meeting(p,pr);s2,l2=recording(p,other['id'])
    thread=p.scope_thread(A,{'mode':'meeting','meeting_id':m['id']})
    assert p.spaces.allowed(A,'transcript',l,thread['workspace_id']);assert not p.spaces.allowed(A,'transcript',l2,thread['workspace_id'])
    thread=p.scope_thread(A,{'mode':'scenario','scenario':'interview'});assert not p.spaces.allowed(A,'transcript',l,thread['workspace_id'])
def test_grounded_analysis_idempotency_and_unknown_dates(domain):
    p=domain;m=meeting(p);s,line=recording(p,m['id']);analyze(p,m,line,due_at='2026-10-16T12:00:00+08:00')
    i=p.items(A,mid=m['id'])[0];assert i['owner']=='我' and i['due_at'] is None
    job=p.queue_analysis(A,m['id']);p.analyze(A,p.store.get('business_jobs',A,job['id']))
    assert len(p.items(A,mid=m['id']))==1
def test_analysis_rejects_fabricated_quote_owner_and_other_speaker_story(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id'],speaker='other');analyze(p,m,l,owner='王总')
    assert p.items(A,mid=m['id'])[0]['owner']==''
    p.business.gateway.result={'items':[{'kind':'story','text':'我做过项目','quote':l['text'],'source_id':'transcript:'+l['id']}]}
    # A new evidence revision must not become a personal story from someone else's words.
    s2,l2=recording(p,m['id'],speaker='other');job=p.queue_analysis(A,m['id']);job=p.store.update('business_jobs',A,job['id'],{'status':'running'});p.analyze(A,job)
    assert not any(i['kind']=='story' for i in p.items(A))
def test_transcript_revision_invalidates_items_and_confirmation(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l)
    ids=p.discovery_candidates(A,m['project_id'],[{'title':'表达','text':'会确认接口','evidence_refs':p.items(A)[0]['evidence_refs']}])
    p.store.update('sessions',A,s['id'],{'transcript_revision':2})
    assert p.items(A)[0]['reference_status']=='superseded'
    with pytest.raises(Fault):p.confirm_discoveries(A,[{'id':ids[0],'expected_version':1,'status':'confirmed'}])
def test_cross_discovery_batch_confirmation_and_withdrawal(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l);item=p.items(A)[0]
    ids=p.discovery_candidates(A,m['project_id'],[{'title':'表达','text':'主动确认接口','evidence_refs':item['evidence_refs']}])
    d=p.store.get('discoveries',A,ids[0]);assert d['status']=='pending' and d['trust']==L2
    p.confirm_discoveries(A,[{'id':d['id'],'expected_version':1,'status':'confirmed'}]);assert p.store.get('discoveries',A,d['id'])['trust']==L3
    assert SQLiteMemoryAdapter(p.store).search(A,'接口',workspace_id=m['project_id'])['items']
    p.confirm_discoveries(A,[{'id':d['id'],'expected_version':2,'status':'withdrawn'}]);assert SQLiteMemoryAdapter(p.store).search(A,'接口',workspace_id=m['project_id'])['items']==[]
def test_batch_version_conflict_rolls_back_all(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l);refs=p.items(A)[0]['evidence_refs']
    ids=p.discovery_candidates(A,m['project_id'],[{'title':'a','text':'a','evidence_refs':refs},{'title':'b','text':'b','evidence_refs':refs}])
    with pytest.raises(Fault):p.confirm_discoveries(A,[{'id':ids[0],'expected_version':1,'status':'confirmed'},{'id':ids[1],'expected_version':2,'status':'confirmed'}])
    assert all(d['status']=='pending' for d in p.store.rows('discoveries',A))
def test_external_draft_internal_separation_and_actual_sent_state(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l)
    internal=p.store.put('project_items',A,{**{k:v for k,v in p.items(A)[0].items() if k not in {'id','created_at','updated_at'}},'kind':'internal','text':'内部审批尚未通过','external_safe':False},L2,source='ai')
    external=p.draft(A,m['id'],'wechat');inside=p.draft(A,m['id'],'email',True)
    assert '内部审批' not in external['text'] and '内部审批' in inside['text']
    assert p.sent(A,external['id'],'cancelled')['send_status']=='draft'
    with pytest.raises(Fault):p.sent(A,external['id'],'sent')
    receipt=p.sent(A,external['id'],'sent',True);assert receipt['delivery_status']=='unknown'
    with pytest.raises(Fault):p.sent(A,inside['id'],'sent',True)
def test_email_saved_cancelled_failed_not_sent(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l);d=p.draft(A,m['id'],'email')
    for state in ['saved','cancelled','failed']:assert p.sent(A,d['id'],state)['send_status']=='draft'
    assert p.sent(A,d['id'],'sent')['receipt_source']=='mail_composer'
def test_faq_one_operation_confirmation_and_idempotent(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l,kind='answer');item=p.items(A)[0]
    a=p.faq(A,item['id']);assert a['trust']==L3 and p.faq(A,item['id'])['id']==a['id']
def test_progress_excludes_simulations_and_examples(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l)
    assert p.stats(A)['sample_count']==1
    p.store.update('business_meetings',A,m['id'],{'is_practice':True});assert p.stats(A)['sample_count']==0
    p.store.update('business_meetings',A,m['id'],{'is_practice':False,'is_example':True});assert p.stats(A)['sample_count']==0
    assert p.stats(A)['acoustic_metrics'] is None
def test_word_export_valid_package_escapes_xml():
    data=word_document('客户 & 公司','<内容>\n粤语原话')
    with zipfile.ZipFile(BytesIO(data)) as z:
        from xml.etree import ElementTree as ET
        root=ET.fromstring(z.read('word/document.xml'));assert '粤语原话' in ''.join(root.itertext())
def test_http_contract_and_speaker_revision(tmp_path,monkeypatch,bind_app_store):
    import app
    from fastapi.testclient import TestClient
    store=Memory(tmp_path/'api.sqlite',tmp_path/'files');bind_app_store(app,store)
    client=TestClient(app.app);headers={'Authorization':'Bearer test-token'}
    p=client.post('/v1/projects',headers=headers,json={'client_request_id':ident(),'name':'客户','scenario':'sales'}).json()
    m=client.post('/v1/projects/'+p['id']+'/meetings',headers=headers,json={'client_request_id':ident(),'title':'第一场'}).json()
    s,l=recording(app.business.product,m['id'])
    result=client.patch('/v1/recordings/'+s['id']+'/speakers',headers=headers,json={'expected_revision':1,'speakers':[{'speaker_id':'part0:0','name':'王总','is_self':False}]})
    assert result.status_code==200
    assert app.recordings.segments(A,s['id'])[0]['speaker_name']=='王总'
    assert client.post('/v1/chat/scopes',headers=headers,json={'mode':'project'}).status_code==422
    assert client.get('/v1/projects').status_code==401
    assert client.get('/v1/projects',headers=headers).status_code==200

def test_archive_new_personal_conclusion_pending_historical_facts_untouched(domain):
    p=domain;pr=project(p)
    thread=p.store.get('chat_threads',A,pr['default_thread_id'])
    message=p.store.put('chat_messages',A,{'thread_id':thread['id'],'role':'user','content':'我喜欢先确认接口再承诺。'},L1)
    archived=p.spaces.archive(A,pr['id'],1)
    assert archived['archive_confirmation_policy']=='review_new_conclusions'
    job=p.business.submit(A,'archive',pr['id'],archived['archived_at']);job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    p.business.gateway.result={'items':[{'title':'沟通偏好','text':'喜欢先确认接口','source_id':'message:'+message['id'],'quote':message['content'],'general_personal':True}]}
    result=p.business.archive(A,job)
    assert result['candidate_count']==1 and result['memory_count']==0
    assert p.store.rows('discoveries',A)[0]['status']=='pending'
    assert p.store.rows('personal_memories',A)==[]
    p.business.archive(A,job);assert len(p.store.rows('discoveries',A))==1

def test_preparation_grounding_and_persistent_job_recovery(domain):
    p=domain;pr=project(p);m=meeting(p,pr);s,l=recording(p,m['id']);analyze(p,m,l)
    upcoming=p.meeting(A,pr['id'],{'title':'下一场','goal':'确认排期'},ident())
    p.business.gateway.result={'sections':[{'title':'建议提问','text':'接口确认到哪一步？','source_ids':['transcript:'+l['id']]}]}
    job=p.queue_preparation(A,upcoming['id']);job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    p.prepare(A,job);packs=p.store.rows('preparation_packs',A);assert len(packs)==1
    assert any(section['evidence_refs'] for section in packs[0]['sections'])
    p.business.recover();assert p.store.get('business_jobs',A,job['id'])['status']=='interrupted'
    assert p.store.rows('preparation_packs',A)==packs

def test_question_recurrence_answers_and_wording_kept(domain):
    p=domain;pr=project(p);m=meeting(p,pr);s,l=recording(p,m['id'])
    analyze(p,m,l,kind='question',question_key='接口准备')
    second=meeting(p,pr);s2,l2=recording(p,second['id']);analyze(p,second,l2,kind='question',question_key='接口准备')
    third=meeting(p,pr);s3,l3=recording(p,third['id']);analyze(p,third,l3,kind='answer',question_key='接口准备',text='接口将在下周确认')
    groups=p.tracking(A,pr['id']);assert groups[0]['occurrences']==2 and groups[0]['status']=='answered'
    assert len(groups[0]['questions'])==2 and len(groups[0]['answers'])==1

def test_simulation_chat_separate_from_actual_project(domain):
    p=domain;pr=project(p,scenario='interview');actual=p.scope_thread(A,{'mode':'project','project_id':pr['id']})
    practice=p.scope_thread(A,{'mode':'project','project_id':pr['id'],'practice':True})
    assert practice['id']!=actual['id'] and len(p.projects(A))==1
    message=p.store.put('chat_messages',A,{'thread_id':practice['id'],'role':'user','content':'练习故事'},L1)
    assert not p.spaces.allowed(A,'message',message,pr['id'])

def test_cancelled_analysis_cannot_write_after_model_response(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);job=p.queue_analysis(A,m['id']);job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    def complete(*args,**kwargs):
        p.business.cancel(A,job['id'])
        return {'content':json.dumps({'items':[{'kind':'action','text':'接口文档','quote':l['text'],'source_id':'transcript:'+l['id']}]})}
    p.business.gateway.complete=complete
    with pytest.raises(Fault):p.analyze(A,job)
    assert p.items(A)==[]

def test_automatic_recording_tag_creates_scene_without_moving_audio(domain):
    p=domain;pr=project(p);m=meeting(p,pr);s,l=recording(p,m['id'])
    p.link(A,m['id'],s['id'],False)
    p.store.put('recording_tags',A,{'session_id':s['id'],'workspace_id':pr['id'],'label':'客户甲','kind':'client','active':True,'revision':1},L1)
    p.sync_recording(A,s['id'])
    links=p.store.rows('recording_links',A,session_id=s['id'],active=True);assert len(links)==1
    assert links[0]['association_source']=='ai_tag'
    p.sync_recording(A,s['id']);assert len(p.store.rows('recording_links',A,session_id=s['id'],active=True))==1
    tag=p.store.rows('recording_tags',A)[0];p.store.update('recording_tags',A,tag['id'],{'active':False});p.sync_recording(A,s['id'])
    assert p.store.rows('recording_links',A,session_id=s['id'],active=True)==[]

def test_sent_revision_does_not_mark_later_edits_as_sent(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l);d=p.draft(A,m['id'],'email')
    revised=p.patch_draft(A,d['id'],{'text':'修改后的稿件'},1)
    sent=p.sent(A,d['id'],'sent',sent_version=1)
    assert sent['sent_version']==1 and sent['send_status']=='draft'
    versions=p.store.rows('followup_versions',A,draft_id=d['id']);assert len(versions)==2
    assert any(v['text']==d['text'] and v['draft_version']==1 for v in versions)

def test_followup_rewrite_grounded_and_new_numbers_rejected(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id']);analyze(p,m,l);d=p.draft(A,m['id'],'wechat');i=p.items(A)[0]
    job=p.business.submit(A,'followup_rewrite',d['id'],'revision1',{'instruction':'更简短','draft_version':1});job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    p.business.gateway.result={'paragraphs':[{'text':'将提供接口文档。','item_ids':[i['id']]}]}
    p.rewrite_followup(A,job);assert p.store.get('followup_drafts',A,d['id'])['version']==2
    job=p.business.submit(A,'followup_rewrite',d['id'],'revision2',{'instruction':'更简短','draft_version':2});job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    p.business.gateway.result={'paragraphs':[{'text':'价格 9999 元。','item_ids':[i['id']]}]}
    with pytest.raises(Fault):p.rewrite_followup(A,job)
    assert p.store.get('followup_drafts',A,d['id'])['text']=='将提供接口文档。'

def test_project_documents_are_in_preparation_and_export_sources(domain):
    p=domain;pr=project(p);m=meeting(p,pr)
    from tasks.materials import Materials
    material=Materials(p.store,p.spaces).save(A,pr['id'],'职位 JD','JD 原文：负责产品需求与跨团队协作。')
    # Materials.save returns the persisted document, and the model must cite that exact identity.
    sid='document:'+material['id']
    p.business.gateway.result={'sections':[{'title':'岗位依据','text':'负责产品需求与跨团队协作','source_ids':[sid]}]}
    job=p.queue_preparation(A,m['id']);job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    p.prepare(A,job);pack=p.store.rows('preparation_packs',A)[0]
    assert any(e['source_id']==sid and e['source_version'] for e in pack['evidence_refs'])

def test_internals_stay_hidden_if_model_mislabels_external(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id'],text='内部审批还没有通过，不对外说。')
    analyze(p,m,l,text='内部审批尚未通过',external_safe=True)
    assert not p.items(A)[0]['external_safe']
    with pytest.raises(Fault):p.draft(A,m['id'],'email')

def test_long_discovery_reads_later_parts_and_reuses_checkpoint(domain):
    p=domain;m=meeting(p);s,l=recording(p,m['id'],text='本人说法。'*3500)
    s2,l2=recording(p,m['id'],text='后半段确认接口。')
    seen=[]
    def complete(messages,**kwargs):
        data=json.loads(messages[-1]['content']);seen.extend(e['source_id'] for e in data['evidence'])
        last=data['evidence'][-1]
        return {'content':json.dumps({'items':[{'title':'发现','text':'会确认接口','source_ids':[last['source_id']]}]})}
    p.business.gateway.complete=complete
    job=p.business.submit(A,'discovery',m['project_id'],'test');job=p.store.update('business_jobs',A,job['id'],{'status':'running'})
    result=p.discover(A,job);assert 'transcript:'+l2['id'] in seen and result['parts']==2
    count=len(seen);p.discover(A,job);assert len(seen)==count

def test_chat_progress_written_once_and_scoped_from_global_to_project(domain):
    from tools.product_tools import register_progress_tool
    from agent_runtime.tools import ToolRegistry
    from agent_runtime.context import RunContext
    from agent_runtime.config import RuntimeConfig
    import time
    p=domain;pr=project(p);thread=p.scope_thread(A,{'mode':'all'});tid=ident();quote='客户回复了，希望下周再沟通。'
    p.store.put('agent_tasks',A,{'id':tid,'thread_id':thread['id'],'input':{'content':quote},'status':'running'},L1)
    message=p.store.put('chat_messages',A,{'thread_id':thread['id'],'task_id':tid,'role':'user','content':quote},L1)
    context=RunContext(A,thread['id'],tid,ident(),'model','config',RuntimeConfig().task_budget,deadline=time.monotonic()+60,workspace_id=thread['workspace_id'],allow_mutations=True)
    registry=ToolRegistry();register_progress_tool(registry,p.store)
    try:
        args={'project_id':pr['id'],'user_quote':quote};result=registry.execute(context,'record_project_update',args,[])
        assert result.status=='ok';assert registry.execute(context,'record_project_update',args,[]).status=='ok'
        assert len(p.items(A,pr['id']))==1
        assert SQLiteMemoryAdapter(p.store).read_evidence(A,[{'source_id':'message:'+message['id']}],workspace_id=pr['id'])['items']
    finally:registry.close()


def test_speaker_names_partial_updates_clear_conflict_and_recording_scope(tmp_path,monkeypatch,bind_app_store):
    import app
    from fastapi.testclient import TestClient
    store=Memory(tmp_path/'speakers.sqlite',tmp_path/'files');bind_app_store(app,store)
    # Keep this contract test offline and observe queued analysis without executing it.
    submitted=[]
    monkeypatch.setattr(app.business,'submit',lambda *args:submitted.append(args) or {})
    client=TestClient(app.app);headers={'Authorization':'Bearer test-token'}
    p=app.business.product;m=meeting(p);s,original=recording(p,m['id'])
    other,_=recording(p,m['id'])
    store.put('transcript_segments',A,{'session_id':s['id'],'speaker':'other','speaker_id':'part0:1','speaker_name':'张总','start_ms':5000,'end_ms':6000,'text':'请明确排期。','transcript_revision':1},L1)
    def patch(rev,rows):
        return client.patch('/v1/recordings/'+s['id']+'/speakers',headers=headers,json={'expected_revision':rev,'speakers':rows})
    def row(sid,name,self=False):return {'speaker_id':sid,'name':name,'is_self':self}
    assert patch(1,[row('part0:0',' 林晓 ',True)]).json()=={'revision':2}
    lines=app.recordings.segments(A,s['id'])
    assert lines[0]['speaker_name']=='林晓' and lines[0]['speaker']=='self'
    assert lines[1]['speaker_name']=='张总'
    session=store.get('sessions',A,s['id'])
    assert session['speaker_names']=={'part0:0':'林晓','part0:1':'张总'}
    assert session['self_speaker_ids']==['part0:0']
    assert store.get('transcript_segments',A,original['id']).get('speaker_name') is None
    assert app.recordings.segments(A,other['id'])[0].get('speaker_name') is None
    assert patch(2,[row('part0:0','林晓',True)]).json()=={'revision':2}
    assert len(submitted)==1
    assert patch(1,[row('part0:0','过期',True)]).status_code==409
    assert patch(2,[row('missing','未知')]).status_code==422
    assert patch(2,[row('part0:0','甲'),row('part0:0','乙')]).status_code==422
    assert patch(2,[row('part0:0',' ',True)]).json()=={'revision':3}
    session=store.get('sessions',A,s['id'])
    assert session['speaker_names']=={'part0:1':'张总'} and session['self_speaker_ids']==['part0:0']
    assert app.recordings.segments(A,s['id'])[0]['speaker_name']==''
    assert patch(3,[]).json()=={'revision':3}
    assert len(submitted)==2


def test_background_recording_review_can_finish_beyond_chat_timeout(domain):
    from tasks.recordings import Recordings
    p = domain
    m = meeting(p)
    session, line = recording(p, m['id'])
    service = Recordings(p.store, p.business, SimpleNamespace())
    calls = []
    def complete(messages, **kwargs):
        calls.append(kwargs)
        return {'content': json.dumps({'title':'沟通复盘','summary':'确认后续提供接口文档。','tags':[], 'expressions':[]}, ensure_ascii=False)}
    p.business.gateway.complete = complete
    job = p.business.submit(A, 'recording_knowledge', session['id'], '1')
    job = p.store.update('business_jobs', A, job['id'], {'status':'running'})
    service.knowledge(A, job)
    assert calls[0]['timeout_seconds'] == 240
    assert p.store.get('sessions', A, session['id'])['pipeline_status'] == 'done'
    assert len(p.store.rows('recording_knowledge', A, session_id=session['id'])) == 1
    p.business.structured('another background task', {})
    assert calls[-1]['timeout_seconds'] == 90
