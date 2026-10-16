"""Real AIqua regression, either isolated local runtime or deployed HTTPS API.
Paid public research only; local temp DB or disposable cloud account, always cleaned up.
"""
import argparse,json,sys,tempfile,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'backend'))
p=argparse.ArgumentParser();p.add_argument('--smoke',action='store_true',help='Only validate one official-page read after deployment, without repeating the full research');p.add_argument('--base');p.add_argument('--output',type=Path,required=True);args=p.parse_args()
PROMPT='请调研香港的 aiqua 公司，给我一份中文公司背景报告：先确认公司身份与官网，不要把同名产品混成香港公司；再核实主要业务和产品、目标客户、团队或创始人、香港背景、近期公开动态及可能的合作沟通切入点。请用Monid实际联网搜索并读取主要来源，区分官网正文与搜索摘要，对查不到的资料如实说明，附可打开的来源网址。'
if args.smoke:PROMPT='只读取 https://www.aiqua.ai/ ，告诉我开头的简介内容，两句话即可。不用额外搜索或公司数据库。'
report={'input':PROMPT,'base':args.base or 'isolated_local_runtime','public_synthetic_only':True};start=time.monotonic()
def save():
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
def watch(get,cancel):
    last='';deadline=time.monotonic()+900
    while time.monotonic()<deadline:
        state=get();steps=state.get('tool_steps',[])
        report.update(task_status=state['status'],error=state.get('error'),steps=steps,validation=state.get('research_validation'),seconds=round(time.monotonic()-start,2));save()
        progress=str([(x['name'],x['status']) for x in steps])
        if progress!=last:print(round(time.monotonic()-start),progress[-350:],flush=True);last=progress
        if state['status'] not in {'running','queued'}:return
        time.sleep(1)
    cancel();raise RuntimeError('acceptance observer timed out after 900s')
if args.base:
    import httpx
    token='';client=httpx.Client(base_url=args.base,timeout=60)
    def api(method,path,**kw):
        for attempt in range(4):
            try:
                r=client.request(method,path,headers={'Authorization':'Bearer '+token},**kw)
                if method in {'GET','DELETE'} and r.status_code in {502,503,504} and attempt<3:
                    time.sleep(attempt+1);continue
                r.raise_for_status();return r.json()
            except httpx.TransportError:
                if method not in {'GET','DELETE'} or attempt==3:raise
                time.sleep(attempt+1)
    try:
        r=client.post('/v1/auth/device',json={'installation_secret':uuid.uuid4().hex+uuid.uuid4().hex});r.raise_for_status();token=r.json()['access_token']
        api('PATCH','/v1/profile',json={'product_use_consent':True});thread=api('GET','/v1/companion')['thread']['id']
        task=api('POST','/v1/chat/threads/'+thread+'/tasks',json={'content':PROMPT,'client_request_id':str(uuid.uuid4())})
        report['task_id']=task['id'];save()
        watch(lambda:api('GET','/v1/agent/tasks/'+task['id']),lambda:api('POST','/v1/agent/tasks/'+task['id']+'/cancel',json={}))
        messages=api('GET','/v1/chat/threads/'+thread)['messages']
        answer=next((m for m in reversed(messages) if m.get('task_id')==task['id'] and m['role']=='assistant'),{})
        report.update(answer=answer.get('content',''),sources=answer.get('sources',[]))
    except Exception as error:
        report.update(last_observed_status=report.get('task_status'),task_status='observer_failed',
                      observer_error=type(error).__name__,observer_message=str(error).replace(token,'[redacted]')[:300] if token else str(error)[:300])
    finally:
        if token:
            try:
                try:api('DELETE','/v1/memory')
                except httpx.HTTPStatusError as error:
                    if error.response.status_code!=410:raise
                report['cleanup_status']=client.get('/v1/profile',headers={'Authorization':'Bearer '+token}).status_code
            except Exception as error:report['cleanup_status']='failed';report['cleanup_error']=type(error).__name__
        client.close();save()
else:
    from run import load_service_environment
    from memory import Memory,ident
    from companion import Companion
    from agent import TextAgent
    load_service_environment([x for x in [ROOT.parents[1]/'.env.anker.local',ROOT/'.env.monid.local',ROOT/'.env.team.local'] if x.exists()])
    with tempfile.TemporaryDirectory(prefix='candid-aiqua-reading-') as folder:
        store=Memory(Path(folder)/'db.sqlite',Path(folder)/'files');agent=TextAgent(store);owner=ident()
        try:
            thread=Companion(store).thread(owner);task=agent.submit(owner,thread['id'],PROMPT,ident())
            watch(lambda:agent.tasks.get(owner,task['id']),lambda:agent.cancel(owner,task['id'],preserve_partial=True))
            messages=store.rows('chat_messages',owner,thread_id=thread['id'])
            answer=next((m for m in reversed(messages) if m.get('task_id')==task['id'] and m['role']=='assistant'),{})
            report.update(answer=answer.get('content',''),sources=answer.get('sources') or agent.tasks.get(owner,task['id']).get('checkpoint',{}).get('sources',[]),validation=agent.tasks.get(owner,task['id']).get('research_validation'),partial_text=agent.tasks.get(owner,task['id']).get('partial_text',''),runs=[{'kind':r.get('kind'),'request':r.get('request'),'status':r.get('status'),'outcome':r.get('outcome'),'external_id':r.get('external_id'),'cost':r.get('cost')} for r in store.rows('provider_runs',owner,task_id=task['id'])])
        finally:agent.close();store.db.close();report['cleanup_status']='temporary_store_removed';save()
from agent_runtime.research_time import window,dated_news_violations
checks={'completed':report.get('task_status')=='completed',
        'official_team_read':any('aiqua.ai' in s.get('url','') and 'Norman' in s.get('text','') and 'Larry' in s.get('text','') for s in report.get('sources',[])),
        'team_in_report':all(x.lower() in report.get('answer','').lower() for x in ['Norman','Larry']),
        'long_reader_used':any(x['name']=='read_material_part' and x['status']=='done' for x in report.get('steps',[])),
        'no_old_dates_in_recent_section':not dated_news_violations(report.get('answer',''),window(PROMPT)),
        'time_scope_disclosed':any(x in report.get('answer','') for x in ['90天','90 天',window(PROMPT)['recent_since']]),
        'cleaned_up':report.get('cleanup_status') in {410,'temporary_store_removed'}}
if args.smoke:
    checks={k:checks[k] for k in ('completed','cleaned_up')}
    checks['real_official_body']=any('aiqua.ai' in s.get('url','') and s.get('reading_range')=='page_excerpt' and s.get('text') for s in report.get('sources',[]))
    checks['long_page_navigation_exposed']=any(s.get('total_chars',0)>2200 and s.get('next_offset')==2200 and s.get('sections') for s in report.get('sources',[]))
report['checks']=checks;report['passed']=all(checks.values());save()
args.output.with_suffix('.md').write_text(report.get('answer',''))
print(json.dumps({'passed':report['passed'],'checks':checks,'seconds':report['seconds']},ensure_ascii=False),flush=True)
sys.exit(0 if report['passed'] else 1)
