import sys,json,threading
from pathlib import Path
from types import SimpleNamespace
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,Fault,L1,ident
from tasks.workspaces import WorkspaceStore
from tasks.business import BusinessJobs
from onboarding import Onboarding
from memory_library import Library
from roleplay import Roleplay,Create,Turn,Adopt,ACTOR,COACH

OWNER='11111111-1111-4111-8111-111111111111'
OTHER='22222222-2222-4222-8222-222222222222'
class Gateway:
    configured=True;model='test';base='https://test.invalid'
    def __init__(self):self.calls=[];self.fail=False;self.block=None
    def complete(self,messages,**kw):
        self.calls.append((messages,kw));data=json.loads(messages[1]['content'])
        if self.fail:raise Fault('MODEL_FAILED','供应商暂不可用',502)
        if self.block:self.block()
        if messages[0]['content']==COACH:
            user=next(t for t in data['conversation'] if t['role']=='user')
            value={'summary':'问清了需求。','strengths':['先澄清现状。'],'improvements':[{'turn_id':user['id'],'quote':user['text'][:8],'reason':'问清下一步。','suggested_text':'我们先确认试点范围。'}]}
        elif messages[0]['content']==ACTOR:value={'reply':'你希望先解决哪个问题？','stage':'需求澄清'}
        else:value={'hint':'先问清现状，再谈方案。'}
        return {'content':json.dumps(value,ensure_ascii=False)}
@pytest.fixture
def domain(tmp_path):
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');g=Gateway();business=BusinessJobs(store,g,WorkspaceStore(store));library=Library(store,business,Onboarding(store,business));service=Roleplay(store,business,library)
    yield store,g,business,service
    business.close();store.db.close()
def make(d,**kw):return d[3].create(OWNER,Create(client_request_id=ident(),scenario='sales',**kw))
def run(d,s):
    d[2].run(OWNER,d[0].get('business_jobs',OWNER,s['job_id']));return d[3].get(OWNER,s['id'])
def answer(d,s,text='我们先确认实际需求。',request=None):return d[3].turn(OWNER,s['id'],Turn(client_request_id=request or ident(),text=text,generation=s['generation']))

def test_full_rehearsal_review_has_quotes_and_no_real_pipeline_writes(domain):
    d=domain;s=run(d,make(d));assert s['turns'][0]['role']=='assistant'
    s=run(d,answer(d,s));s=run(d,d[3].command(OWNER,s['id'],'hint'));assert s['hint'] and len(s['turns'])==3
    s=run(d,d[3].command(OWNER,s['id'],'review'));assert s['state']=='completed'
    correction=s['review']['improvements'][0];assert correction['quote'] in s['turns'][1]['text']
    for table in ['sessions','recording_knowledge','chat_messages','personal_memories','library_items']:assert not d[0].rows(table,OWNER)
    assert all(not args.get('tools') for _,args in d[1].calls)

def test_request_idempotency_and_stale_generation(domain):
    d=domain;body=Create(client_request_id=ident(),scenario='sales');s=d[3].create(OWNER,body);assert d[3].create(OWNER,body)['id']==s['id']
    s=run(d,s);rid=ident();result=answer(d,s,request=rid);assert answer(d,s,request=rid)['generation']==result['generation']
    assert len(result['turns'])==2
    d[3].interrupt(OWNER,s['id'])
    with pytest.raises(Fault):answer(d,result)

def test_failure_retry_and_reboot_recovery(domain):
    d=domain;d[1].fail=True;s=run(d,make(d));assert s['error'] and s['state']=='active'
    d[1].fail=False;job=d[2].retry(OWNER,s['job_id']);d[2].run(OWNER,job);s=d[3].get(OWNER,s['id']);assert len(s['turns'])==1
    s=answer(d,s);d[0].update('business_jobs',OWNER,s['job_id'],{'status':'running'});d[2].recover();assert d[3].get(OWNER,s['id'])['error']

def test_cancelled_running_reply_cannot_publish(domain):
    d=domain;s=make(d);entered=threading.Event();release=threading.Event()
    d[1].block=lambda:(entered.set(),release.wait(5))
    worker=threading.Thread(target=run,args=(d,s));worker.start();assert entered.wait(2)
    d[3].interrupt(OWNER,s['id']);release.set();worker.join(5)
    assert not d[3].get(OWNER,s['id'])['turns']

@pytest.mark.parametrize('scenario',['sales','interview'])
def test_empty_library_starts_without_form_or_extra_model(domain,scenario):
    context=domain[3].context(OWNER,scenario);assert context['goal'] and context['sources']==[] and not domain[1].calls

def test_cross_owner_access_and_workspace_scope(domain):
    d=domain;s=make(d)
    with pytest.raises(Fault):d[3].get(OTHER,s['id'])
    a=d[2].workspaces.create(OWNER,'客户甲','试点',ident());b=d[2].workspaces.create(OWNER,'客户乙','预算',ident())
    doc=d[0].put('documents',OWNER,{'title':'甲试点','text':'甲客户预算50万','workspace_id':a['id']},L1)
    other=d[0].put('documents',OTHER,{'title':'秘密资料','text':'不可读取'},L1)
    assert d[3].context(OWNER,'sales',workspace_id=b['id'])['sources']==[]
    assert d[3].context(OWNER,'sales',workspace_id=a['id'])['sources'][0]['source_id']=='document:'+doc['id']
    assert not any(x['source_id']=='document:'+other['id'] for x in d[3].context(OWNER,'sales')['sources'])

def test_actor_only_reads_question_not_reference_answer_and_sources_can_be_excluded(domain):
    d=domain;item=d[0].put('library_items',OWNER,{'title':'试点费用','original_question':'怎么确定预算？','text':'私有最佳参考答案XYZ','item_type':'faq','scenario':'sales','status':'active','version':1,'evidence_refs':[]},L1)
    s=run(d,make(d,item_id=item['id']));payload=json.loads(d[1].calls[-1][0][1]['content'])
    assert '私有最佳参考答案XYZ' not in json.dumps(payload,ensure_ascii=False)
    assert '怎么确定预算' in json.dumps(payload,ensure_ascii=False)
    s=make(d,item_id=item['id'],excluded_source_ids=['faq:'+item['id']]);assert not s['sources']

def test_source_version_change_drops_old_snapshot(domain):
    d=domain;doc=d[0].put('documents',OWNER,{'title':'产品试点','text':'旧内容'},L1);s=make(d)
    # Raw documents are immutable: removal invalidates the source before the job reads it.
    d[0].remove('documents',OWNER,doc['id']);run(d,s)
    assert json.loads(d[1].calls[-1][0][1]['content'])['actor_context']==[]

def test_practice_adoption_is_explicit_and_idempotent(domain):
    d=domain;s=run(d,make(d));s=run(d,answer(d,s));s=run(d,d[3].command(OWNER,s['id'],'review'))
    assert not d[0].rows('library_items',OWNER)
    body=Adopt(correction_index=0,text='我的新说法');one=d[3].adopt(OWNER,s['id'],body);two=d[3].adopt(OWNER,s['id'],body)
    assert one['id']==two['id'] and one['practice_source_id']==s['id']
    assert not d[3].context(OWNER,'sales')['sources'], 'Unverified practice text cannot silently become actor facts'

def test_retry_uses_actual_preceding_question(domain):
    d=domain;s=run(d,make(d));s=run(d,answer(d,s));original=s['turns'][1]
    retry=make(d,parent_id=s['id'],retry_turn_id=original['id']);assert d[0].get('roleplay_sessions',OWNER,retry['id'])['context']['retry_question']==s['turns'][0]['text']

def test_empty_finish_and_no_unrequested_coaching(domain):
    d=domain;s=run(d,make(d))
    with pytest.raises(Fault) as error:d[3].command(OWNER,s['id'],'review')
    assert error.value.code=='PRACTICE_EMPTY'
    assert d[1].calls[0][0][0]['content']==ACTOR

def test_reused_request_cannot_replace_payload(domain):
    d=domain;body=Create(client_request_id=ident(),scenario='sales');s=d[3].create(OWNER,body)
    with pytest.raises(Fault):d[3].create(OWNER,body.model_copy(update={'scenario':'interview'}))
    s=run(d,s);rid=ident();answer(d,s,request=rid)
    with pytest.raises(Fault):answer(d,s,text='另一个回答',request=rid)


def test_http_auth_and_live_pcm_output(domain):
    import base64
    from fastapi import FastAPI,Request
    from fastapi.testclient import TestClient
    from roleplay import install
    d=domain;app=FastAPI()
    def owner(req:Request):
        if req.headers.get('Authorization')!='Bearer test':raise Fault('UNAUTHORIZED','未授权',401)
        return OWNER
    from fastapi.responses import JSONResponse
    @app.exception_handler(Fault)
    async def error(req,e):return JSONResponse({'error':e.code},status_code=e.status)
    class Speech:
        def stream_synthesize(self,text,callback,guard,cancellation):
            guard();callback(b'\x01\x00'*480);callback(b'\x02\x00'*480)
    install(app,owner,d[3],Speech());client=TestClient(app)
    assert client.get('/v1/practice/sessions').status_code==401
    response=client.post('/v1/practice/sessions',headers={'Authorization':'Bearer test'},json={'scenario':'sales','client_request_id':ident()});assert response.status_code==202
    s=run(d,response.json());turn=s['turns'][0]
    with client.websocket_connect('/v1/practice/sessions/'+s['id']+'/audio/'+turn['id']) as ws:
        ws.send_json({'token':'test','generation':s['generation']})
        for seq in (1,2):
            packet=ws.receive_json();assert packet['seq']==seq and base64.b64decode(packet['audio'])
            ws.send_json({'type':'played','seq':seq})
        assert ws.receive_json()['type']=='finished'


def test_unfounded_review_quote_is_discarded(domain):
    d=domain;s=run(d,make(d));s=run(d,answer(d,s));job=d[3].command(OWNER,s['id'],'review')
    d[1].complete=lambda *a,**k:{'content':json.dumps({'summary':'练习完成','strengths':[],'improvements':[{'turn_id':s['turns'][1]['id'],'quote':'从没说过的话','reason':'x','suggested_text':'y'}]})}
    result=run(d,job);assert result['review']['improvements']==[]

def test_adopting_faq_uses_start_version_not_latest(domain):
    from memory_library import Edit
    d=domain;item=d[0].put('library_items',OWNER,{'title':'试点范围','text':'旧说法','item_type':'faq','scenario':'sales','topic':'需求与场景','version':1,'status':'active','expression_state':'improve','evidence_refs':[]},L1)
    s=run(d,make(d,item_id=item['id']));assert s['item_version']==1
    s=run(d,answer(d,s));s=run(d,d[3].command(OWNER,s['id'],'review'))
    d[3].library.edit(OWNER,item['id'],Edit(expected_version=1,text='用户在另一处修改的新说法'))
    with pytest.raises(Fault) as error:d[3].adopt(OWNER,s['id'],Adopt(correction_index=0,text='练习建议',expected_version=s['item_version']))
    assert error.value.code=='VERSION_CONFLICT'
    assert d[0].get('library_items',OWNER,item['id'])['text']=='用户在另一处修改的新说法'

def test_previous_practice_focus_is_scoped_by_scenario_and_workspace(domain):
    d=domain;s=run(d,make(d));s=run(d,answer(d,s));s=run(d,d[3].command(OWNER,s['id'],'review'))
    assert d[3].context(OWNER,'sales')['training_focus']==['问清下一步。']
    assert not d[3].context(OWNER,'interview')['training_focus']
    space=d[2].workspaces.create(OWNER,'不同客户','目标',ident())
    assert not d[3].context(OWNER,'sales',workspace_id=space['id'])['training_focus']

@pytest.mark.parametrize('scenario',['sales','interview'])
def test_retry_begins_at_exact_previous_question_without_paid_regeneration(domain,scenario):
    d=domain;s=d[3].create(OWNER,Create(client_request_id=ident(),scenario=scenario));s=run(d,s);s=run(d,answer(d,s));user=s['turns'][1]
    retry=d[3].create(OWNER,Create(client_request_id=ident(),scenario=scenario,parent_id=s['id'],retry_turn_id=user['id']))
    count=len(d[1].calls);retry=run(d,retry);assert len(d[1].calls)==count
    assert retry['turns'][0]['text']==s['turns'][0]['text']
