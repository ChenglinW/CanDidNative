"""Real runtime/storage regressions for preparation, progress and explicit retries."""
import json,time,sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,Fault,ident
from companion import Companion
from agent import TextAgent

OWNER='11111111-1111-4111-8111-111111111111'
INTENT='帮我准备客户甲沟通，目标是确认试点范围。'

def data(**changes):
    return {'client':'客户甲','goal':'确认试点范围','scenario':'sales','sections':[
        {'title':'目标','text':'确认试点范围。'},{'title':'问题','text':'目前有哪些业务需求？'},
        {'title':'待核实','text':'预算和排期未知，不作承诺。'}],**changes}

def call(name,args):
    return {'role':'assistant','content':'','tool_calls':[{'id':ident(),'type':'function','function':{'name':name,'arguments':json.dumps(args,ensure_ascii=False)}}]}

class Gateway:
    configured=True;model='preparation-regression';base='https://test.invalid'
    def __init__(self,handler):self.handler=handler;self.calls=0;self.messages=[]
    def complete(self,messages,**kw):
        self.calls+=1;self.messages=messages
        return self.handler(self,messages)

@pytest.fixture
def domain(tmp_path):
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');d=Companion(store)
    yield d
    store.db.close()

def wait(agent,tid,status):
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        task=agent.tasks.get(OWNER,tid)
        if task['status']==status:return task
        if task['status']=='failed' and status!='failed':raise AssertionError(task.get('error'))
        time.sleep(.01)
    raise AssertionError((status,task.get('status'),task.get('error')))

def packs(d):return d.store.rows('companion_preparations',OWNER)

@pytest.mark.parametrize('separate',[False,True])
def test_productive_preparation_exceeds_old_round_and_tool_caps(domain,separate):
    t=domain.thread(OWNER)
    if separate:t=domain.store.get('chat_threads',OWNER,domain.spaces.create(OWNER,'客户甲','试点',ident())['default_thread_id'])
    def handler(g,m):
        if g.calls<=13:return call('search_materials',{'query':'待核实项目'+str(g.calls)})
        if g.calls==14:return call('save_preparation',data(user_quote='这是模型改写的原话，不能作为证据'))
        return {'role':'assistant','content':'准备包已保存。'}
    g=Gateway(handler);a=TextAgent(domain.store,gateway=g)
    try:
        task=a.submit(OWNER,t['id'],INTENT,ident());done=wait(a,task['id'],'completed')
        assert g.calls==14 and done['budget_usage']=={'model_rounds':14,'tool_calls':14}
        assert done['effective_budget']['max_rounds'] is None and done['effective_budget']['max_tool_calls'] is None
        assert done['effective_budget']['timeout_seconds'] is None and done['effective_budget']['model_timeout_seconds']>0
        assert len(packs(domain))==1 and packs(domain)[0]['workspace_id']==t['workspace_id']
        assert not any(m.get('user_quote') for m in packs(domain))
    finally:a.close()

def test_multiple_turn_input_then_save_has_no_round_cutoff(domain):
    def handler(g,m):
        if g.calls<=4:return call('search_materials',{'query':'对象资料'+str(g.calls)})
        if g.calls==5:return call('request_input',{'question':'这次和谁沟通、希望达成什么？'})
        if g.calls==6:
            assert any('王总' in x.get('content','') for x in m)
            return call('save_preparation',data(client='王总'))
        return {'role':'assistant','content':'准备包已保存。'}
    g=Gateway(handler);a=TextAgent(domain.store,gateway=g)
    try:
        task=a.submit(OWNER,domain.thread(OWNER)['id'],'帮我准备下一场沟通。',ident())
        pending=wait(a,task['id'],'waiting_input')
        a.answer_input(OWNER,task['id'],ident(),pending['input_request']['id'],'和王总确认试点范围。',pending['attempt'])
        done=wait(a,task['id'],'completed')
        assert done['attempt']==2 and len(packs(domain))==1 and g.calls==6
    finally:a.close()

def test_stalled_loop_can_resume_with_accounting_and_without_duplicate_publication(domain):
    ready=False
    def handler(g,m):
        if not ready:return call('search_materials',{'query':'同一份资料'})
        if not packs(domain):return call('save_preparation',data())
        return {'role':'assistant','content':'准备包已保存。'}
    g=Gateway(handler);a=TextAgent(domain.store,gateway=g)
    try:
        task=a.submit(OWNER,domain.thread(OWNER)['id'],INTENT,ident());failed=wait(a,task['id'],'failed')
        assert failed['error']['code']=='AGENT_STALLED' and g.calls==4
        ready=True;a.resume(OWNER,task['id'],ident(),failed['attempt']);done=wait(a,task['id'],'completed')
        assert done['attempt']==2 and done['budget_usage']['model_rounds']>4
        assert len(packs(domain))==1
        assert len(domain.store.rows('chat_messages',OWNER,preparation_package_id=packs(domain)[0]['id']))==1
        assert len([m for m in domain.store.rows('chat_messages',OWNER) if m['role']=='user'])==1
    finally:a.close()

@pytest.mark.parametrize('invalid',['sections','source'])
def test_model_gets_specific_repairable_parameter_errors(domain,invalid):
    def handler(g,m):
        if g.calls==1:return call('save_preparation',data(**({'sections':data()['sections'][:2]} if invalid=='sections' else {'source_ids':['document:missing']})))
        if g.calls==2:
            output=json.loads(m[-1]['content'])
            assert output['error']['code']==('TOOL_ARGUMENTS_INVALID' if invalid=='sections' else 'SOURCE_UNAVAILABLE')
            assert output['error']['retryable']
            return call('save_preparation',data())
        return {'role':'assistant','content':'准备包已保存。'}
    g=Gateway(handler);a=TextAgent(domain.store,gateway=g)
    try:
        t=a.submit(OWNER,domain.thread(OWNER)['id'],INTENT,ident());wait(a,t['id'],'completed');assert len(packs(domain))==1
    finally:a.close()

@pytest.mark.parametrize('committed',[False,True])
def test_retry_saves_staged_report_without_regeneration_or_duplicate(domain,monkeypatch,committed):
    original=Companion.save_preparation;fail=True
    def saving(self,*args,**kw):
        if fail:
            if committed:original(self,*args,**kw)
            raise Fault('STORAGE_DOWN','保存暂不可用',503)
        return original(self,*args,**kw)
    monkeypatch.setattr(Companion,'save_preparation',saving)
    def handler(g,m):
        if g.calls==1:return call('save_preparation',data())
        if g.calls==2:raise Fault('UPSTREAM_TIMEOUT','连接中断',504)
        assert any('服务端已恢复并回读准备包' in x.get('content','') for x in m)
        return {'role':'assistant','content':'准备包已保存。'}
    g=Gateway(handler);a=TextAgent(domain.store,gateway=g)
    try:
        t=a.submit(OWNER,domain.thread(OWNER)['id'],INTENT,ident())
        if committed:
            wait(a,t['id'],'completed');assert g.calls==1
        else:
            old=wait(a,t['id'],'failed')
            assert old['preparation_draft']['data']['client']=='客户甲'
            fail=False;a.resume(OWNER,t['id'],ident(),old['attempt']);wait(a,t['id'],'completed')
            assert g.calls==2
        assert len(packs(domain))==1
        assert len(domain.store.rows('chat_messages',OWNER,preparation_package_id=packs(domain)[0]['id']))==1
    finally:a.close()

@pytest.mark.parametrize('pending',[False,True])
@pytest.mark.parametrize('legacy_version',['agent-runtime@10-recovery','agent-runtime@11-progress','agent-runtime@12-research'])
def test_explicit_legacy_retry_migrates_policy_and_preserves_user_answers(domain,pending,legacy_version):
    ready=False
    def handler(g,m):
        if not ready:
            if pending:return call('request_input',{'question':'沟通对象和目标是什么？'})
            return {'role':'assistant','content':'报告还没保存。'}
        if pending:assert any('周总' in x.get('content','') for x in m if x['role']=='user')
        if not packs(domain):return call('save_preparation',data())
        return {'role':'assistant','content':'准备包已保存。'}
    g=Gateway(handler);a=TextAgent(domain.store,gateway=g)
    try:
        t=a.submit(OWNER,domain.thread(OWNER)['id'],INTENT,ident());old=wait(a,t['id'],'waiting_input' if pending else 'failed')
        snapshot=old['config_snapshot'];snapshot['runtime_version']=legacy_version;snapshot['budget']['max_rounds']=4
        a.tasks.update(OWNER,t['id'],{'config_snapshot':snapshot,'budget_usage':{'model_rounds':4,'tool_calls':12}})
        ready=True
        if pending:a.answer_input(OWNER,t['id'],ident(),old['input_request']['id'],'周总，确认试点范围。',old['attempt'])
        else:a.resume(OWNER,t['id'],ident(),old['attempt'])
        done=wait(a,t['id'],'completed');assert done['execution_policy_upgrade']=='progress-aware-preparation-v1'
        assert done['budget_usage']['model_rounds']>4 and len(packs(domain))==1
    finally:a.close()


def test_fabricated_quote_does_not_grant_intent(domain):
    def handler(g,m):
        if g.calls==1:return call('save_preparation',data(user_quote=INTENT))
        assert json.loads(m[-1]['content'])['error']['code']=='USER_INTENT_REQUIRED'
        return {'role':'assistant','content':'你想准备下一场沟通时再告诉我。'}
    a=TextAgent(domain.store,gateway=Gateway(handler))
    try:
        t=a.submit(OWNER,domain.thread(OWNER)['id'],'介绍一下你能做什么。',ident());wait(a,t['id'],'completed');assert packs(domain)==[]
    finally:a.close()


@pytest.mark.parametrize('separate',[False,True])
def test_unsaved_success_claim_never_finishes_or_streams(domain,separate):
    t=domain.thread(OWNER)
    if separate:t=domain.store.get('chat_threads',OWNER,domain.spaces.create(OWNER,'客户甲','试点',ident())['default_thread_id'])
    def handler(g,m):
        return {'role':'assistant','content':'准备包已完成。'}
    g=Gateway(handler)
    # Deliberately imitate a provider that streams a premature success claim.
    original=g.complete
    def stream(messages,**kw):
        kw['on_delta']('准备包已完成。')
        return original(messages,**kw)
    g.complete=stream;a=TextAgent(domain.store,gateway=g)
    try:
        task=a.submit(OWNER,t['id'],INTENT,ident());failed=wait(a,task['id'],'failed')
        assert failed['error']['code']=='AGENT_STALLED' and g.calls==3
        assert packs(domain)==[]
        assert not [e for e in a.tasks.events.after(OWNER,task['id'],0) if e['kind']=='text.delta']
    finally:a.close()


def test_stale_staged_report_reloads_current_evidence(domain,monkeypatch):
    from tasks.materials import Materials
    workspace=domain.spaces.create(OWNER,'客户甲','试点',ident());space=workspace['id']
    thread=workspace['default_thread_id']
    doc=Materials(domain.store,domain.spaces).save(OWNER,space,'客户甲预算','预算尚未确认。')
    source_id='document:'+doc['id']
    original=Companion.save_preparation;fail=True
    def saving(self,*args,**kw):
        if fail:raise Fault('STORAGE_DOWN','保存暂不可用',503)
        return original(self,*args,**kw)
    monkeypatch.setattr(Companion,'save_preparation',saving)
    def handler(g,m):
        if g.calls in [1,4]:
            if g.calls==4:assert any('依据已修订' in x.get('content','') for x in m)
            return call('search_materials',{'query':'预算'})
        if g.calls in [2,5]:return call('save_preparation',data(source_ids=[source_id]))
        if g.calls==3:raise Fault('UPSTREAM_TIMEOUT','连接中断',504)
        return {'role':'assistant','content':'准备包已保存。'}
    a=TextAgent(domain.store,gateway=Gateway(handler))
    try:
        t=a.submit(OWNER,thread,INTENT,ident());old=wait(a,t['id'],'failed')
        assert old['preparation_draft']['references']
        domain.spaces.set_scope(OWNER,source_id,'unassigned',[],0)
        replacement=Materials(domain.store,domain.spaces).save(OWNER,space,'客户甲预算更新','预算需要重新核对。')
        source_id='document:'+replacement['id']
        fail=False;a.resume(OWNER,t['id'],ident(),old['attempt']);done=wait(a,t['id'],'completed')
        assert done['rejected_preparation_draft']['references']!=packs(domain)[0]['evidence_refs']
    finally:a.close()


def test_cancel_at_save_boundary_does_not_publish_then_explicit_resume_can_save(domain,monkeypatch):
    import threading
    reached=threading.Event();release=threading.Event();finished=threading.Event()
    original=Companion.save_preparation;block=True
    def saving(self,*args,**kw):
        try:
            if block:reached.set();release.wait(3)
            return original(self,*args,**kw)
        finally:finished.set()
    monkeypatch.setattr(Companion,'save_preparation',saving)
    def handler(g,m):
        if g.calls==1:return call('save_preparation',data())
        return {'role':'assistant','content':'准备包已保存。'}
    a=TextAgent(domain.store,gateway=Gateway(handler))
    try:
        t=a.submit(OWNER,domain.thread(OWNER)['id'],INTENT,ident());assert reached.wait(3)
        a.cancel(OWNER,t['id'],preserve_partial=True,expected_attempt=1)
        release.set();assert finished.wait(3);assert packs(domain)==[]
        block=False;a.resume(OWNER,t['id'],ident(),1);wait(a,t['id'],'completed')
        assert len(packs(domain))==1
    finally:release.set();a.close()


def test_preparation_survives_failed_history_summary_without_inventing_memory(domain,monkeypatch):
    from dataclasses import replace
    from memory import L1
    thread=domain.thread(OWNER)
    for i in range(24):
        domain.store.put('chat_messages',OWNER,{'thread_id':thread['id'],'role':'user','content':f'旧沟通原话{i}：客户甲希望了解试点范围。','sources':[],'tool_steps':[]},L1)
    def handler(g,m):
        assert any('历史原话片段' in x.get('content','') for x in m)
        return call('save_preparation',data())
    a=TextAgent(domain.store,gateway=Gateway(handler))
    def fail(*args,**kw):raise Fault('AGENT_COMPACTION_FAILED','历史摘要未能可靠生成',502)
    monkeypatch.setattr(a.context_manager.summaries,'extend',fail)
    try:
        t=a.submit(OWNER,thread['id'],INTENT,ident());done=wait(a,t['id'],'completed')
        assert done['context_summary_status']=='raw_user_excerpts' and len(packs(domain))==1
        assert domain.store.rows('agent_summaries',OWNER)==[]
    finally:a.close()


def test_preparation_summary_fallback_does_not_bypass_evidence_errors(domain,monkeypatch):
    from memory import L1
    thread=domain.thread(OWNER)
    for i in range(24):domain.store.put('chat_messages',OWNER,{'thread_id':thread['id'],'role':'user','content':str(i),'sources':[],'tool_steps':[]},L1)
    a=TextAgent(domain.store,gateway=Gateway(lambda g,m:call('save_preparation',data())))
    def fail(*args,**kw):raise Fault('AGENT_EVIDENCE_CHANGED','资料已变化',409)
    monkeypatch.setattr(a.context_manager.summaries,'extend',fail)
    try:
        t=a.submit(OWNER,thread['id'],INTENT,ident());done=wait(a,t['id'],'failed')
        assert done['error']['code']=='AGENT_EVIDENCE_CHANGED' and packs(domain)==[]
    finally:a.close()
