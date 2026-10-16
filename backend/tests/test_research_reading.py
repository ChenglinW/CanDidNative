"""Regression for long-page coverage and news freshness, with exact offsets."""
import json,time,sys
from datetime import date
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,ident,Fault
from companion import Companion
from agent import TextAgent
from adapters.sources import source,version
from adapters.web_reading import unread_sections
from agent_runtime.research_time import window,classify,publication,dated_news_violations
from test_preparation_recovery import Gateway,call,wait,OWNER

BODY='# Company\nSonar and AI\n'+('Background paragraph.\n'*500)+'\n## Our Team\nNorman Chan, Co-founder. Larry Ho, Business Development.\n'+('Team details.\n'*150)+'\n## History\nFounded 2022.'

def research_row(**kw):return {'id':ident(),'title':'AIqua','text':BODY,'url':'https://www.aiqua.ai/','reading_range':'page_excerpt','status':'active',**kw}

def test_long_page_navigation_requires_actual_late_team_text():
    row=research_row();item=source('research',row,reading_range='page_excerpt')
    assert 'Norman' not in item['text'] and item['next_offset']==2200
    gaps=unread_sections([item],'核实团队和创始人')
    assert gaps and gaps[0]['offset']>2200
    offset=gaps[0]['offset']
    tail={**item,'offset':offset,'end_offset':min(offset+6000,len(BODY)),'text':BODY[offset:offset+6000]}
    assert not unread_sections([item,tail],'核实团队和创始人')
    assert unread_sections([item,{**tail,'source_version':'different-version'}],'核实团队和创始人')
    assert not unread_sections([item],'只概括首段')


def test_contiguous_ranges_cover_heading_split_at_preview_boundary():
    row=research_row(text='x'*2000+'\n## Our Team\n'+'Norman '*300)
    first=source('research',row,reading_range='page_excerpt');end=first['end_offset']
    following={**first,'offset':end,'end_offset':len(row['text']),'text':row['text'][end:]}
    assert not unread_sections([first,following],'团队')


@pytest.mark.parametrize('value,expected',[('2024-09-23','historical'),('2025-03-01','historical'),('2026-09-12','recent'),('2026-10-17','future'),(None,'unknown'),('2026','unknown'),('2026-02-30','unknown')])
def test_fresh_fetch_does_not_change_old_or_unknown_publication(value,expected):
    timing=window(as_of=date(2026,10,16))
    assert timing['recent_since']=='2026-07-18'
    assert classify(value,timing)['classification']==expected


def test_publication_only_from_metadata_or_explicit_dateline():
    assert publication('Copyright 2026. We won in 2024.')=={}
    assert publication('Published: 2024-09-23\nFuture plans 2027-01-01')['published_at']=='2024-09-23'
    assert publication('',{'article:published_time':'2024-09-23T12:00:00Z'})['publication_date_basis'].startswith('provider_metadata:')
    assert classify('2024年9月23日',window(as_of=date(2026,10,16)))['classification']=='historical'
    assert window('最近一个月',date(2026,10,16))['window_days']==30
    assert window('近2年',date(2026,10,16))['window_days']==730


def test_final_report_cannot_label_historical_dates_as_recent():
    timing=window(as_of=date(2026,10,16))
    assert dated_news_violations('## 近期动态\n2024-09-23 创业采访\n## 历史背景\n2025-03-01 展会',timing)==['2024-09-23']
    assert not dated_news_violations('## 近期动态\n近90天未找到消息。\n## 历史背景\n2024-09-23 创业采访',timing)


def test_actual_reader_keyword_scope_and_version(tmp_path):
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');agent=TextAgent(store,gateway=Gateway(lambda *x: {'role':'assistant','content':'ok'}))
    t=Companion(store).thread(OWNER)
    from agent_runtime.context import RunContext
    from agent_runtime.config import RuntimeConfig
    context=RunContext(OWNER,t['id'],ident(),ident(),'test','test',RuntimeConfig().budget('chat'),deadline=time.monotonic()+30,workspace_id=t['workspace_id'])
    row=store.put('agent_sources',OWNER,research_row(workspace_id=t['workspace_id']))
    try:
        result=agent.registry.execute(context,'read_material_part',{'source_id':'research:'+row['id'],'query':'Norman'},[])
        assert not result.error and 'Larry Ho' in result.sources[0]['text']
        assert result.sources[0]['offset']>2200 and result.sources[0]['source_version']==version(row)
        absent=agent.registry.execute(context,'read_material_part',{'source_id':'research:'+row['id'],'query':'NO SUCH PERSON'},[])
        assert absent.data['matched'] is False and not absent.sources
        other=Companion(store).spaces.create(OWNER,'Other','',ident())
        from dataclasses import replace
        denied=agent.registry.execute(replace(context,workspace_id=other['id']),'read_material_part',{'source_id':'research:'+row['id']},[])
        assert denied.error
    finally:agent.close();store.db.close()


def test_runtime_requires_late_team_read_before_accepting_answer(tmp_path,monkeypatch):
    monkeypatch.setenv('MONID_API_KEY','offline-test')
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');thread=Companion(store).thread(OWNER)
    def handler(g,m):
        if g.calls==1:return call('read_source',{'url':'https://www.aiqua.ai/'})
        if g.calls==2:return {'role':'assistant','content':'官网没有找到团队信息。'}
        if g.calls==3:
            assert 'Norman Chan' in m[-1]['content'] and 'Larry Ho' in m[-1]['content']
        return {'role':'assistant','content':'官网团队为 Norman Chan 和 Larry Ho，属于官网自述。'}
    agent=TextAgent(store,gateway=Gateway(handler))
    from test_monid import receipt
    agent.monid.request=lambda *a,**k:receipt({'data':{'markdown':BODY,'metadata':{'title':'AIqua'}}})
    try:
        task=agent.submit(OWNER,thread['id'],'读取 https://www.aiqua.ai/ 核实团队和创始人，不用额外搜索。',ident())
        done=wait(agent,task['id'],'completed')
        assert agent.gateway.calls==3
        assert any(s['name']=='read_material_part' and s['status']=='done' for s in done['tool_steps'])
    finally:agent.close();store.db.close()


def test_runtime_recent_search_required_and_empty_results_are_honest(tmp_path,monkeypatch):
    monkeypatch.setenv('MONID_API_KEY','offline-test')
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');thread=Companion(store).thread(OWNER)
    def handler(g,m):
        if g.calls==1:return call('read_source',{'url':'https://example.com/'})
        if g.calls==2:return {'role':'assistant','content':'## 近期动态\n2024-09-23 获奖。'}
        if g.calls==3:
            gate=m[-1]['content'];assert 'recent_search_required' in gate and 'historical_or_future_dates' in gate
            return call('search_company',{'query':'Example 最近90天新闻','time_range':'year','force_refresh':True})
        return {'role':'assistant','content':'## 近期动态\n近90天未找到可核实消息。\n## 历史背景\n2024-09-23 获奖。'}
    agent=TextAgent(store,gateway=Gateway(handler))
    from test_monid import receipt
    agent.monid.request=lambda method,path,body=None:receipt({'results':[]} if body['provider']=='search1api' else {'data':{'markdown':'Published: 2024-09-23\nAn old award.','metadata':{'title':'Example'}}})
    try:
        task=agent.submit(OWNER,thread['id'],'联网查 Example 近期动态。',ident())
        done=wait(agent,task['id'],'completed')
        assert agent.gateway.calls==4
        runs=store.rows('provider_runs',OWNER,task_id=task['id'])
        assert any(x.get('kind')=='search' and x.get('outcome')=='empty' for x in runs)
    finally:agent.close();store.db.close()


def test_monid_keeps_publication_distinct_from_fetch_and_storage_limit(tmp_path,monkeypatch):
    from test_monid import receipt
    monkeypatch.setenv('MONID_API_KEY','offline-test')
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');thread=Companion(store).thread(OWNER)
    from adapters.monid import Monid
    from agent_runtime.context import RunContext
    from agent_runtime.config import RuntimeConfig
    c=RunContext(OWNER,thread['id'],ident(),ident(),'test','test',RuntimeConfig().budget('chat'),deadline=time.monotonic()+30,workspace_id=thread['workspace_id'])
    monid=Monid(store);monid.request=lambda *a,**k:receipt({'data':{'markdown':'Published: 2024-09-23\n'+'x'*200010,'metadata':{'title':'Old news'}}})
    try:
        result=monid.tool(c,'read',{'url':'https://example.com/'},[]);item=result['items'][0]
        assert item['published_at']=='2024-09-23' and item['fetched_at']!=item['published_at']
        assert item['publication_time']['classification']=='historical'
        assert item['total_chars']==200000 and item['original_total_chars']>200000 and item['storage_truncated']
        saved=source('research',store.rows('agent_sources',OWNER)[0],reading_range='page_excerpt')
        assert saved['published_at']=='2024-09-23'
    finally:store.db.close()


def test_preparation_cannot_save_before_reading_team_section(tmp_path,monkeypatch):
    from test_preparation_recovery import data
    from test_monid import receipt
    monkeypatch.setenv('MONID_API_KEY','offline-test')
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');thread=Companion(store).thread(OWNER)
    sid=''
    def handler(g,m):
        nonlocal sid
        if g.calls==1:return call('read_source',{'url':'https://www.aiqua.ai/'})
        if not sid:
            result=json.loads(next(x['content'] for x in reversed(m) if x['role']=='tool'))
            sid=result['sources'][0]['source_id']
        if g.calls==2:return call('save_preparation',data(source_ids=[sid]))
        if g.calls==3:
            result=json.loads(m[-1]['content']);assert result['error']['code']=='RESEARCH_REQUIRED'
            assert not store.rows('companion_preparations',OWNER)
            return call('read_material_part',{'source_id':sid,'query':'Our Team'})
        return call('save_preparation',data(source_ids=[sid]))
    agent=TextAgent(store,gateway=Gateway(handler));agent.monid.request=lambda *a,**k:receipt({'data':{'markdown':BODY,'metadata':{'title':'AIqua'}}})
    try:
        task=agent.submit(OWNER,thread['id'],'帮我准备与AIqua团队沟通，目标了解创始人背景，先读取 https://www.aiqua.ai/ 不用额外搜索。',ident())
        done=wait(agent,task['id'],'completed')
        assert agent.gateway.calls==4 and len(store.rows('companion_preparations',OWNER))==1
    finally:agent.close();store.db.close()


def test_partial_date_precision_cannot_turn_old_month_into_recent():
    timing=window(as_of=date(2026,10,16))
    assert classify('2024-09',timing)['classification']=='historical'
    assert classify('2025',timing)['classification']=='historical'
    assert classify('2026-07',timing)['classification']=='unknown'
    assert dated_news_violations('## 近期动态\n- 2024年：获奖\n- 2025-03：展会',timing)==['2024年','2025-03']


def test_model_tool_envelope_keeps_one_copy_and_public_sources_remain_complete():
    from agent_runtime.tools import ToolResult
    item={'source_id':'research:a','source_version':'v','ref':'r','citation':'[1]','text':'Long original body','sections':[{'title':'Team','offset':5000}]}
    result=ToolResult('ok',{'items':[item]},[item])
    assert json.dumps(result.as_dict()).count('Long original body')==2
    assert json.dumps(result.model_dict()).count('Long original body')==1
    assert result.model_dict()['sources'][0]['citation']=='[1]'
    assert result.as_dict()['sources'][0]['text']=='Long original body'
    # Other tools that supply evidence outside items must retain that evidence.
    assert ToolResult('ok',{'summary':'x'},[item]).model_dict()['sources'][0]['text']=='Long original body'


@pytest.mark.parametrize('status,code,outcome,accepted',[('COMPLETED',200,'content',True),('COMPLETED',200,'empty',True),('COMPLETED',403,None,True),('REJECTED',401,None,True),('submitting',None,None,False),('PENDING',200,None,False)])
def test_recent_search_failure_can_be_disclosed_without_forcing_retry(status,code,outcome,accepted):
    from agent_runtime.research_policy import recent_search_attempted
    run={'kind':'search','request':{'time_range':'year'},'status':status,'outcome':outcome,'response':{'providerResponse':{'httpStatus':code}}}
    assert bool(recent_search_attempted(run)) is accepted
    assert not recent_search_attempted({**run,'request':{}})


@pytest.mark.parametrize('body',[None,[],{}])
def test_missing_markdown_does_not_turn_empty_page_into_retryable_error(body):
    assert publication(body,{})=={}
