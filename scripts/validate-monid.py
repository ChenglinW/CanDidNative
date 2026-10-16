"""Isolated real Monid + configured text-agent acceptance. Never logs service keys.
Run with backend/.venv/bin/python scripts/validate-monid.py --output .build/monid-fix/live.json
Uses only public/synthetic input, temporary local storage, and real paid provider calls.
"""
import argparse,json,sys,tempfile,time,threading,concurrent.futures
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'backend'))
from run import load_service_environment
from memory import Memory,Fault,ident
from companion import Companion
from agent import TextAgent
from agent_runtime.context import RunContext
from agent_runtime.config import RuntimeConfig
from adapters.monid import Monid

p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'.build/monid-fix/live.json');p.add_argument('--only',choices=['all','interfaces','agent'],default='all');p.add_argument('--case',action='append',default=[],help='Only named checks; useful for a targeted rerun, preserves earlier output when using a new --output');args=p.parse_args()
load_service_environment([x for x in [ROOT.parents[1]/'.env.anker.local',ROOT/'.env.monid.local',ROOT/'.env.team.local'] if x.exists()])
report={'synthetic_and_public_only':True,'checks':[]};lock=threading.Lock()
def record(row):
    with lock:
        report['checks'].append(row);args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(row['case'],row['status'],row.get('seconds'),flush=True)

def selected(name):return not args.case or name in args.case

def run():
 with tempfile.TemporaryDirectory(prefix='candid-monid-acceptance-') as folder:
  root=Path(folder);store=Memory(root/'db.sqlite',root/'files');agent=TextAgent(store)
  if not agent.monid.configured:raise RuntimeError('Monid is not configured')
  direct_owner=ident();thread=Companion(store).thread(direct_owner)
  def context():return RunContext(direct_owner,thread['id'],ident(),ident(),'acceptance','acceptance',RuntimeConfig().budget('chat'),deadline=time.monotonic()+130,workspace_id=thread['workspace_id'])
  direct=[('search-google','search',{'query':'Anker Innovations official website','platform':'google'}),('search-bing','search',{'query':'Anker Innovations official website','platform':'bing'}),('search-baidu','search',{'query':'安克创新 科技股份有限公司 业务','platform':'baidu'}),('search-reddit','search',{'query':'soundcore Liberty 4 NC review','platform':'reddit'}),('search-youtube','search',{'query':'soundcore Liberty 4 NC review','platform':'youtube'}),('search-wechat','search',{'query':'安克创新','platform':'wechat'}),('search-bilibili','search',{'query':'声阔 耳机 评测','platform':'bilibili'}),('read-fresh-official','read',{'url':'https://www.anker-in.com/','force_refresh':True}),('company-stripe','company',{'name':'Stripe','website':'https://stripe.com'}),('company-anker','company',{'name':'Anker Innovations','website':'https://www.anker-in.com'}),('company-empty-match','company',{'name':'CanDidAcceptanceUnknown9z73s','website':'https://candid-unknown9z73s.example'}),('video-real-subtitles','youtube',{'url':'https://www.youtube.com/watch?v=OUrAxCvAA0Q','language':'en'})]
  def interface(case):
    name,kind,value=case;c=context();m=Monid(store);start=time.monotonic();r={'case':name}
    try:
        result=m.tool(c,kind,value,[]);expected_empty=name=='company-empty-match'
        r['item_count']=len(result['items'])
        rows=store.rows('provider_runs',direct_owner,task_id=c.task_id)
        r['provider_outcomes']=[{'http_status':x.get('response',{}).get('providerResponse',{}).get('httpStatus'),'outcome':x.get('outcome')} for x in rows]
        assert bool(result['items'])!=expected_empty, 'supplier returned empty result'
        assert rows and rows[0].get('external_id')
        if expected_empty:assert rows[0]['response']['providerResponse']['httpStatus']==404
        if value.get('force_refresh'):assert rows[0]['request']['maxAge']==0
        r.update(status='passed',item_count=len(result['items']),runs=[{'run_id':x.get('external_id'),'status':x.get('status'),'outcome':x.get('outcome'),'http_status':x.get('response',{}).get('providerResponse',{}).get('httpStatus'),'billing':x.get('billing'),'cost':x.get('cost')} for x in rows])
    except Exception as e:r.update(status='failed',error_code=getattr(e,'code',type(e).__name__),message=getattr(e,'message',str(e))[:400])
    r['seconds']=round(time.monotonic()-start,2);record(r)
  if args.only in {'all','interfaces'}:
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(interface,[c for c in direct if selected(c[0])]))
    # Exercise actual non-2xx run JSON, independent of the app's known-unsupported
    # Reddit capability shortcut. A real 403 receipt must survive the HTTP layer.
    if selected('real-403-receipt-retained'):
     c=context();r={'case':'real-403-receipt-retained'}
     try:
         try:Monid(store).execute(c,'read',{'url':'https://www.reddit.com/r/Earbuds/comments/14mzvpl/my_real_soundcore_liberty_4_nc_review_no_youtube/','formats':['markdown'],'onlyMainContent':True,'timeout':60000})
         except Fault as e:assert e.code=='SOURCE_UNSUPPORTED',e.code
         else:raise AssertionError('expected known unsupported provider response')
         row=store.rows('provider_runs',direct_owner,task_id=c.task_id)[0];assert row.get('external_id') and row['response']['providerResponse']['httpStatus']==403
         r.update(status='passed',run_id=row['external_id'],billing=row['billing'])
     except Exception as e:r.update(status='failed',error_code=getattr(e,'code',type(e).__name__))
     record(r)
  if args.only in {'all','interfaces'} and selected('real-receipt-reconciliation'):
    # Real provider execution plus an intentionally lost client receipt. Recovery
    # must find that exact run through the actual runs API without a second POST.
    from dataclasses import replace
    c=context();m=Monid(store);request=m.request;sent=[];lost=[];body={'query':'Anker official recovery receipt '+ident(),'max_results':3,'crawl_results':0}
    def lose_receipt(method,path,payload=None):
        value=request(method,path,payload)
        if method=='POST':
            sent.append(1);lost.append(value['runId']);raise Fault('MONID_UNAVAILABLE','验收模拟客户端回执丢失',502)
        return value
    m.request=lose_receipt;r={'case':'real-receipt-reconciliation','client_failure_injected':True}
    try:
        try:m.execute(c,'search',body)
        except Fault as e:assert e.code=='MONID_UNAVAILABLE'
        run,output=m.execute(replace(c,attempt=2),'search',body)
        assert run['external_id']==lost[0] and len(sent)==1
        r.update(status='passed',run_id=run['external_id'],paid_posts=len(sent))
    except Exception as e:r.update(status='failed',error_code=getattr(e,'code',type(e).__name__),message=getattr(e,'message',str(e))[:300])
    record(r)
  cases=[
    ('home-web-preparation',False,'帮我准备与安克创新采购王总讨论门店收银SaaS方案，目标确认三家门店试点。我们提供门店收银SaaS，时间与预算待定，不需要再补问。先联网读取 https://www.anker-in.com/ 核实主要业务，再保存准备包。','read_save'),
    ('workspace-web-preparation',True,'帮我准备与安克创新采购王总讨论门店收银SaaS方案，目标确认三家门店试点。我们提供门店收银SaaS，时间与预算待定。先联网读取 https://www.anker-in.com/ 核实主要业务，再保存准备包。','read_save'),
    ('home-offline-preparation',False,'不要联网。帮我准备与客户甲采购王总讨论门店收银SaaS，目标确认三家门店试点。时间预算未定，按已有信息保存准备包。','offline_save'),
    ('greeting',False,'你好，今天有点紧张，用一句话安慰我。','offline'),
    ('rewrite',False,'把“这个价格不能再降了”改得委婉，只改表达，不需要公司资料。','offline'),
    ('single-url',True,'请读取 https://www.anker.com/about-us ，用三句话概括该页业务，附来源，不用额外搜索或公司数据库。','read'),
    ('reddit-feedback',True,'在Reddit搜索soundcore Liberty 4 NC用户反馈，简短总结两点并引用来源。如果正文不支持，直接说明只能基于摘要，不要反复尝试。无需公司数据库。','reddit'),
    ('video-agent',True,'读取 https://www.youtube.com/watch?v=OUrAxCvAA0Q 的英文字幕，总结评测里的两个缺点。必须依据字幕，不凭标题猜。','video'),
    ('fresh-company-news',True,'请联网搜索安克创新最近一个月的业务动态，使用最新结果，列出两条有日期和来源的内容；核实不了日期就明确说明，不用公司数据库。','fresh')]
  def agent_case(case):
    name,separate,text,expected=case;owner=ident();start=time.monotonic();r={'case':name,'input':text};task=None
    try:
        t=Companion(store).thread(owner)
        if separate:t=store.get('chat_threads',owner,agent.workspaces.create(owner,'公开公司验收','独立上下文',ident())['default_thread_id'])
        task=agent.submit(owner,t['id'],text,ident());deadline=time.monotonic()+250
        while time.monotonic()<deadline:
            state=agent.tasks.get(owner,task['id'])
            if state['status'] not in {'running','queued'}:break
            time.sleep(.5)
        r['task_status']=state['status'];r['task_error']=state.get('error');r['steps']=[{'name':x['name'],'status':x['status'],'error':x.get('error')} for x in state.get('tool_steps',[])]
        assert state['status']=='completed',str(state.get('error') or state.get('input_request') or state['status'])
        detail=agent.detail(owner,t['id']);answer=next((m for m in reversed(detail['messages']) if m.get('task_id')==task['id'] and m['role']=='assistant'),{})
        r['answer']=answer.get('content');r['sources']=[{k:s.get(k) for k in ['source_id','title','url','reading_range','fetched_at']} for s in answer.get('sources',[])]
        runs=store.rows('provider_runs',owner,task_id=task['id']);packs=store.rows('companion_preparations',owner)
        r['runs']=[{k:x.get(k) for k in ['kind','external_id','status','outcome','cache_reuse','billing']}|{'http_status':x.get('response',{}).get('providerResponse',{}).get('httpStatus')} for x in runs]
        if expected in {'read_save','read'}:assert any(x['kind']=='read' and x.get('outcome')=='content' for x in runs)
        if expected.endswith('save'):
            assert len(packs)==1 and len([m for m in detail['messages'] if m.get('preparation_package_id')==packs[0]['id']])==1
            assert packs[0]['workspace_id']==t['workspace_id'];r['saved_once']=True;r['report_sections']=len(packs[0]['sections'])
            if expected=='read_save':assert any(x['source_id'].startswith('research:') for x in packs[0]['evidence_refs'])
        if expected.startswith('offline'):assert not runs
        if expected=='video':assert any(x['kind']=='youtube' and x.get('outcome')=='content' for x in runs)
        if expected=='reddit':
            assert any(x['kind']=='search' and x.get('outcome')=='content' for x in runs)
            assert not any(x['kind']=='read' for x in runs)
            assert any(x in (r.get('answer') or '') for x in ['摘要','片段'])
        if expected=='fresh':assert any(x['request'].get('time_range') and not x.get('cache_reuse') for x in runs)
        assert not any(x['kind']=='company' for x in runs), 'unnecessary company database call'
        r['status']='passed'
    except Exception as e:
        r.update(status='failed',error_code=getattr(e,'code',type(e).__name__),message=getattr(e,'message',str(e))[:600])
        if task:
            try:
                if agent.tasks.get(owner,task['id'])['status'] in {'queued','running'}:agent.cancel(owner,task['id'],preserve_partial=True)
            except Exception:pass
    r['seconds']=round(time.monotonic()-start,2);record(r)
  try:
    if args.only in {'all','agent'}:
        if not agent.gateway.configured:raise RuntimeError('Text model is not configured')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(agent_case,[c for c in cases if selected(c[0])]))
  finally:
    agent.close();store.db.close()
run()
raise SystemExit(1 if not report['checks'] or any(r['status']!='passed' for r in report['checks']) else 0)
