"""Real adapter/runtime state regressions; HTTP/model boundaries are controlled here."""
import json,time,sys
from pathlib import Path
from dataclasses import replace
import pytest,httpx
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,Fault,ident
from companion import Companion
from adapters.monid import Monid
from agent_runtime.config import RuntimeConfig
from agent_runtime.context import RunContext
from agent_runtime.research_policy import policy
from agent import TextAgent

OWNER='11111111-1111-4111-8111-111111111111'
@pytest.fixture
def setup(tmp_path,monkeypatch):
    monkeypatch.setenv('MONID_API_KEY','offline-monid-test')
    s=Memory(tmp_path/'db.sqlite',tmp_path/'files');t=Companion(s).thread(OWNER)
    c=RunContext(OWNER,t['id'],ident(),ident(),'test','test',RuntimeConfig().budget('chat'),deadline=time.monotonic()+60,workspace_id=t['workspace_id'])
    yield s,t,c
    s.db.close()

def receipt(output,code=200,status='COMPLETED'):
    return {'runId':ident(),'status':status,'providerResponse':{'httpStatus':code},'output':output,'billing':{'reportedCost':{'currency':'USD','value':1000,'unit':'MICRO_DOLLAR'}}}

def search_output():return {'results':[{'title':'官网','snippet':'真实公开业务简介','link':'https://example.com/about'}]}

def stub(m,output=None,code=200,status='COMPLETED'):
    calls=[]
    def request(method,path,body=None):
        calls.append((method,path,body));return receipt(search_output() if output is None else output,code,status)
    m.request=request;return calls

@pytest.mark.parametrize('code',[403,404,429,503])
def test_non_2xx_run_receipt_is_parsed_and_retained(setup,monkeypatch,code):
    s,t,c=setup;m=Monid(s);r=receipt(None,code)
    original=httpx.Client
    monkeypatch.setattr('adapters.monid.httpx.Client',lambda **kw:original(transport=httpx.MockTransport(lambda req:httpx.Response(code,json=r)),**kw))
    if code==404:
        run,output=m.execute(c,'company',{'name':'missing'});assert output is None
    else:
        with pytest.raises(Fault):m.execute(c,'read',{'url':'https://example.com'})
    run=s.rows('provider_runs',OWNER)[0]
    assert run['external_id']==r['runId'] and run['status']=='COMPLETED'
    assert run['billing']==r['billing'] and run['response']['providerResponse']['httpStatus']==code

@pytest.mark.parametrize('code',[401,429])
def test_rejected_request_without_run_id_is_not_unknown_submission(setup,monkeypatch,code):
    s,t,c=setup;m=Monid(s);original=httpx.Client
    monkeypatch.setattr('adapters.monid.httpx.Client',lambda **kw:original(transport=httpx.MockTransport(lambda req:httpx.Response(code,json={'error':'rejected'})),**kw))
    with pytest.raises(Fault) as e:m.execute(c,'search',{'query':'test'})
    assert e.value.code=='MONID_REQUEST_REJECTED'
    row=s.rows('provider_runs',OWNER)[0];assert row['status']=='REJECTED' and row['retryable']==(code==429)


def test_definite_failure_only_retries_on_explicit_new_attempt(setup):
    s,t,c=setup;m=Monid(s);calls=stub(m,code=503)
    for _ in range(2):
        with pytest.raises(Fault):m.tool(c,'search',{'query':'same'},[])
    assert len(calls)==1
    calls2=stub(m)
    result=m.tool(replace(c,attempt=2),'search',{'query':'same'},[])
    assert len(calls2)==1 and result['items'] and len(s.rows('provider_runs',OWNER))==2


def test_unknown_submission_never_reposts_even_after_resume(setup):
    s,t,c=setup;m=Monid(s);calls=[]
    def uncertain(*a,**kw):calls.append(a);raise Fault('MONID_UNAVAILABLE','连接中断',502)
    m.request=uncertain
    with pytest.raises(Fault):m.tool(c,'search',{'query':'same'},[])
    with pytest.raises(Fault) as e:m.tool(replace(c,attempt=2),'search',{'query':'same'},[])
    assert e.value.code=='PROVIDER_SUBMIT_UNCERTAIN' and len([x for x in calls if x[0]=='POST'])==1


def test_provider_empty_match_is_empty_and_does_not_save_null(setup):
    s,t,c=setup;m=Monid(s);stub(m,code=404)
    result=m.tool(c,'company',{'name':'not found'},[])
    assert result['items']==[] and s.rows('agent_sources',OWNER)==[]

@pytest.mark.parametrize('output',[{}, {'status':404,'error':'missing'}, {'name':'unknown'}, {'name':'','id':'x'}])
def test_empty_or_error_company_payload_never_becomes_evidence(setup,output):
    s,t,c=setup;m=Monid(s);stub(m,output)
    assert m.tool(c,'company',{'name':'unknown'},[])['items']==[]
    assert not s.rows('agent_sources',OWNER)


def test_success_false_and_non_string_read_payload_is_rejected(setup):
    s,t,c=setup;m=Monid(s);stub(m,{'success':False,'error':'blocked','data':{}})
    with pytest.raises(Fault) as e:m.tool(c,'read',{'url':'https://example.com'},[])
    assert e.value.code=='SOURCE_UNREADABLE' and not s.rows('agent_sources',OWNER)


def test_unsupported_reddit_and_invalid_video_never_bill(setup):
    s,t,c=setup;m=Monid(s);calls=stub(m)
    for url in ['https://reddit.com/r/test','https://old.reddit.com/r/test']:
        with pytest.raises(Fault) as e:m.tool(c,'read',{'url':url},[])
        assert e.value.code=='SOURCE_UNSUPPORTED'
    with pytest.raises(Fault) as e:m.tool(c,'youtube',{'url':'https://www.youtube.com/watch?v=too-short'},[])
    assert e.value.code=='URL_INVALID' and not calls and not s.rows('provider_runs',OWNER)


def test_cache_reuse_preserves_fetch_age_scope_and_does_not_duplicate_billing(setup):
    s,t,c=setup;m=Monid(s);calls=stub(m)
    original=m.tool(c,'search',{'query':'company'},[])
    space=Companion(s).spaces.create(OWNER,'另一客户','',ident())
    later=replace(c,task_id=ident(),workspace_id=space['id'],thread_id=space['default_thread_id'])
    a=m.tool(later,'search',{'query':'company'},[]);b=m.tool(later,'search',{'query':'company'},[])
    assert len(calls)==1 and a['items'][0]['source_id']==b['items'][0]['source_id']
    assert a['items'][0]['source_id']!=original['items'][0]['source_id']
    assert a['items'][0]['fetched_at']==original['items'][0]['fetched_at']
    alias=s.rows('provider_runs',OWNER,task_id=later.task_id)[0]
    assert alias['cache_reuse'] and alias['billing']=={} and alias['cost'] is None
    assert len(s.rows('agent_sources',OWNER))==2


def test_fresh_refresh_bypasses_cache_once_and_expired_cache_is_not_extended(setup):
    s,t,c=setup;m=Monid(s);calls=stub(m)
    m.tool(c,'search',{'query':'company'},[])
    fresh=replace(c,task_id=ident());m.tool(fresh,'search',{'query':'company','force_refresh':True},[]);m.tool(fresh,'search',{'query':'company','force_refresh':True},[])
    assert len(calls)==2
    for r in s.rows('provider_runs',OWNER):s.update('provider_runs',OWNER,r['id'],{'created_at':'2020-01-01T00:00:00+00:00'})
    m.tool(replace(c,task_id=ident()),'search',{'query':'company'},[])
    assert len(calls)==3


def test_no_research_call_cap_after_twenty_new_requests(setup):
    s,t,c=setup;m=Monid(s);calls=stub(m)
    for i in range(23):assert m.tool(c,'search',{'query':'query '+str(i)},[])['items']
    assert len(calls)==23 and len(s.rows('provider_runs',OWNER))==23


def test_read_refresh_uses_upstream_max_age_zero(setup):
    s,t,c=setup;m=Monid(s);calls=stub(m,{'success':True,'data':{'markdown':'真实正文'}})
    assert m.tool(c,'read',{'url':'https://example.com','force_refresh':True},[])['items']
    assert calls[0][2]['input']['body']['maxAge']==0


def tool_call(name,args):return {'role':'assistant','content':'','tool_calls':[{'id':ident(),'function':{'name':name,'arguments':json.dumps(args,ensure_ascii=False)}}]}

def pack_args(sources=None):return {'client':'安克采购王总','goal':'确认试点','scenario':'sales','sections':[{'title':'目标','text':'确认试点'},{'title':'提纲','text':'讨论范围'},{'title':'待核实','text':'时间未知'}],'source_ids':sources or []}

class Gateway:
    configured=True;model='monid-regression';base='https://test.invalid'
    def __init__(self,handler):self.handler=handler;self.calls=0
    def complete(self,messages,**kw):self.calls+=1;return self.handler(self,messages,kw)

def wait(a,id,status):
    until=time.monotonic()+6
    while time.monotonic()<until:
        t=a.tasks.get(OWNER,id)
        if t['status']==status:return t
        if t['status']=='failed':raise AssertionError(t.get('error'))
        time.sleep(.01)
    raise AssertionError(t['status'])

@pytest.mark.parametrize('separate',[False,True])
def test_preparation_requires_real_read_then_saves_after_research_skill_switch(setup,separate):
    s,t,c=setup
    if separate:t=s.get('chat_threads',OWNER,Companion(s).spaces.create(OWNER,'客户','',ident())['default_thread_id'])
    def handler(g,m,kw):
        names={x['function']['name'] for x in kw['schemas']}
        assert {'read_source','save_preparation'}<=names
        if g.calls==1:return tool_call('save_preparation',pack_args())
        if g.calls==2:
            assert json.loads(m[-1]['content'])['error']['code']=='RESEARCH_REQUIRED'
            return tool_call('read_source',{'url':'https://example.com/about'})
        if g.calls==3:return tool_call('run_skill',{'name':'company_research','inputs':{'company_name':'安克'}})
        sid='research:'+s.rows('agent_sources',OWNER)[0]['id']
        return tool_call('save_preparation',pack_args([sid]))
    a=TextAgent(s,gateway=Gateway(handler));stub(a.monid,{'success':True,'data':{'markdown':'公司官网真实业务资料'}})
    try:
        task=a.submit(OWNER,t['id'],'帮我准备安克客户沟通，目标确认试点，先联网读取 https://example.com/about 再保存准备包。',ident())
        done=wait(a,task['id'],'completed');packs=s.rows('companion_preparations',OWNER)
        assert len(packs)==1 and len(packs[0]['evidence_refs'])==1 and a.gateway.calls==4
        assert done['active_skill_snapshot']['name']=='company_research'
    finally:a.close()


def test_offline_preparation_blocks_accidental_network_without_breaking_save(setup):
    s,t,c=setup
    def handler(g,m,kw):
        if g.calls==1:return tool_call('read_source',{'url':'https://example.com'})
        assert json.loads(m[-1]['content'])['error']['code']=='RESEARCH_NOT_ALLOWED'
        return tool_call('save_preparation',pack_args())
    a=TextAgent(s,gateway=Gateway(handler));calls=stub(a.monid)
    try:
        task=a.submit(OWNER,t['id'],'不要联网，帮我准备安克采购王总沟通，目标确认试点。',ident());wait(a,task['id'],'completed')
        assert not calls and len(s.rows('companion_preparations',OWNER))==1
    finally:a.close()


def test_skill_input_schema_is_visible_and_errors_are_actionable(setup):
    from agent_runtime.rules import compose_prompt
    from agent_runtime.skills import SkillCatalog,load_soul
    s,t,c=setup;a=TextAgent(s,gateway=Gateway(lambda *a:None))
    try:
        index=a.catalog.index(a.registry.names);prompt=compose_prompt(load_soul(),index,{})
        assert 'company_name' in prompt and 'additionalProperties' in prompt
        with pytest.raises(Fault) as error:a.catalog.load('company_research',index,{'company':'错误字段'})
        assert 'company_name' in error.value.message and 'company' in error.value.message
    finally:a.close()


def test_unknown_submission_reconciles_exact_receipt_without_reposting(setup):
    from memory import now
    s,t,c=setup;m=Monid(s);posts=[];value=receipt(search_output());body={'query':'same','max_results':5,'crawl_results':0}
    value.update(provider='search1api',endpoint='/search',createdAt=now(),input={'body':body})
    def request(method,path,payload=None):
        if method=='POST':posts.append(payload);raise Fault('MONID_UNAVAILABLE','connection lost',502)
        if path.startswith('/v1/runs?'):return {'items':[value]}
        return value
    m.request=request
    with pytest.raises(Fault):m.tool(c,'search',{'query':'same'},[])
    result=m.tool(replace(c,attempt=2),'search',{'query':'same'},[])
    assert result['items'] and len(posts)==1
    assert s.rows('provider_runs',OWNER)[0]['external_id']==value['runId']


def test_ambiguous_unknown_receipts_never_authorize_new_post(setup):
    from memory import now
    s,t,c=setup;m=Monid(s);posts=[];body={'query':'same','max_results':5,'crawl_results':0}
    values=[{**receipt(search_output()),'provider':'search1api','endpoint':'/search','createdAt':now(),'input':{'body':body}} for _ in range(2)]
    def request(method,path,payload=None):
        if method=='POST':posts.append(payload);raise Fault('MONID_UNAVAILABLE','lost',502)
        if path.startswith('/v1/runs?'):return {'items':values}
        return next(v for v in values if path.endswith(v['runId']))
    m.request=request
    with pytest.raises(Fault):m.tool(c,'search',{'query':'same'},[])
    with pytest.raises(Fault) as e:m.tool(replace(c,attempt=2),'search',{'query':'same'},[])
    assert e.value.code=='PROVIDER_SUBMIT_UNCERTAIN' and len(posts)==1


def test_search_snippet_remains_snippet_when_read_again(setup):
    from adapters.sources import source
    s,t,c=setup;m=Monid(s);stub(m)
    m.tool(c,'search',{'query':'company'},[])
    row=s.rows('agent_sources',OWNER)[0]
    assert source('research',row,reading_range='source_excerpt')['reading_range']=='search_snippet'


def test_user_url_punctuation_and_freshness_policy():
    p=policy('请联网读取 https://example.com/，根据最新业务准备。')
    assert p['urls']==['https://example.com/'] and p['required'] and p['fresh']
    assert policy('无需联网，使用已有资料')['offline']


def test_actual_runtime_prompt_contains_skill_input_fields(setup):
    s,t,c=setup
    def handler(g,m,kw):
        text='\n'.join(x.get('content','') for x in m)
        assert 'company_name' in text and 'additionalProperties' in text
        return {'role':'assistant','content':'你好。'}
    a=TextAgent(s,gateway=Gateway(handler))
    try:
        task=a.submit(OWNER,t['id'],'你好',ident());wait(a,task['id'],'completed')
    finally:a.close()


def test_late_provider_receipt_is_kept_but_cannot_publish_sources(setup):
    s,t,c=setup;m=Monid(s);value=receipt(search_output())
    def request(*a,**kw):time.sleep(.04);return value
    m.request=request
    with pytest.raises(Fault) as e:m.tool(replace(c,deadline=time.monotonic()+.02),'search',{'query':'late response'},[])
    assert e.value.code=='AGENT_TIMEOUT' and not s.rows('agent_sources',OWNER)
    assert s.rows('provider_runs',OWNER)[0]['external_id']==value['runId']


def test_cached_repeat_is_not_false_progress_from_changing_age(setup,monkeypatch):
    s,t,c=setup;counter=iter(range(10000))
    monkeypatch.setattr('adapters.monid.age',lambda row:next(counter))
    a=TextAgent(s,gateway=Gateway(lambda *args:tool_call('search_company',{'query':'same public query'})));calls=stub(a.monid)
    try:
        task=a.submit(OWNER,t['id'],'请搜索一个公开问题。',ident());done=wait(a,task['id'],'failed')
        assert done['error']['code']=='AGENT_STALLED' and a.gateway.calls==4 and len(calls)==1
    finally:a.close()
