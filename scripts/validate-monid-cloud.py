"""Real deployed HTTPS/Agent acceptance; disposable owners and no printed credentials."""
import argparse,json,time,uuid,concurrent.futures,threading
from pathlib import Path
import httpx
p=argparse.ArgumentParser();p.add_argument('--base',default='https://47.129.137.212');p.add_argument('--output',type=Path,default=Path('.build/monid-fix/cloud.json'));args=p.parse_args()
report={'base':args.base,'synthetic_only':True,'cases':[]};lock=threading.Lock()
def uid():return str(uuid.uuid4())
def record(r):
 with lock:
  report['cases'].append(r);args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(r['case'],r['status'],r.get('seconds'),flush=True)
cases=[('home-web-preparation',False,'帮我准备与安克创新采购王总讨论门店收银SaaS方案，目标确认三家门店试点。我们提供门店收银SaaS，时间预算待定。先联网读取 https://www.anker-in.com/ 核实主要业务再保存准备包。无需额外公司数据库。','web_save'),('workspace-web-preparation',True,'帮我准备与安克创新采购王总讨论门店收银SaaS方案，目标确认三家门店试点。我们提供门店收银SaaS，时间预算待定。先联网读取 https://www.anker-in.com/ 核实主要业务再保存准备包。无需额外公司数据库。','web_save'),('home-offline-preparation',False,'不要联网，帮我准备和客户甲采购王总讨论门店收银SaaS，目标确认三家门店试点。时间预算待定，只用这些信息保存准备包。','offline_save'),('reddit-honest-fallback',True,'在Reddit搜索soundcore Liberty 4 NC的用户反馈，简短总结两点并引用来源。正文不支持就只用搜索摘要并说明，别反复抓取，无需公司数据库。','reddit')]
def run(case):
 name,separate,text,kind=case;r={'case':name,'input':text};token='';task=None;start=time.monotonic()
 with httpx.Client(base_url=args.base,timeout=60) as client:
  def api(method,path,**kw):
   x=client.request(method,path,headers={'Authorization':'Bearer '+token},**kw);x.raise_for_status();return x.json()
  try:
   auth=client.post('/v1/auth/device',json={'installation_secret':uuid.uuid4().hex+uuid.uuid4().hex});auth.raise_for_status();token=auth.json()['access_token']
   api('PATCH','/v1/profile',json={'product_use_consent':True})
   snapshot=api('GET','/v1/companion');thread=snapshot['thread']
   skills=api('GET','/v1/agent/skills')['data'];assert next(x for x in skills if x['name']=='communication_prep')['version']=='2.2.0'
   if separate:
    space=api('POST','/v1/project-spaces',json={'name':'Monid修复验收','goal':'公开资料流程验收','client_request_id':uid()});thread={'id':space['default_thread_id'],'workspace_id':space['id']}
   task=api('POST','/v1/chat/threads/'+thread['id']+'/tasks',json={'content':text,'client_request_id':uid()});deadline=time.monotonic()+250
   while time.monotonic()<deadline:
    state=api('GET','/v1/agent/tasks/'+task['id'])
    if state['status'] not in {'queued','running'}:break
    time.sleep(1)
   r.update(task_status=state['status'],error=state.get('error'),steps=state.get('tool_steps',[]))
   assert state['status']=='completed',str(state.get('error') or state.get('input_request') or state['status'])
   detail=api('GET','/v1/chat/threads/'+thread['id']);answer=next(m for m in detail['messages'] if m.get('task_id')==task['id'] and m['role']=='assistant')
   r['answer']=answer['content'];r['sources']=[{k:s.get(k) for k in ['source_id','title','url','reading_range','fetched_at']} for s in answer.get('sources',[])]
   names=[s['name'] for s in state['tool_steps']]
   if kind.endswith('save'):
    snapshot=api('GET','/v1/companion');packs=[x for x in snapshot['preparations'] if x['thread_id']==thread['id']]
    assert len(packs)==1 and len([m for m in detail['messages'] if m.get('preparation_package_id')==packs[0]['id']])==1
    assert packs[0]['workspace_id']==thread['workspace_id'] and len(packs[0]['sections'])>=3
    assert snapshot['next_preparation']['id']==packs[0]['id'];r.update(saved_once=True,same_home_and_chat_id=True,sections=len(packs[0]['sections']))
    if kind=='web_save':assert any(x['source_id'].startswith('research:') for x in packs[0]['evidence_refs']) and 'read_source' in names
    else:assert not any(n in names for n in ['read_source','search_company','enrich_company','get_video_transcript'])
   else:
    assert 'search_company' in names and 'enrich_company' not in names
    assert sum(n=='read_source' for n in names)<=1
    assert any(x in answer['content'] for x in ['摘要','片段'])
   r['status']='passed'
  except Exception as e:
   r.update(status='failed',failure=getattr(e,'code',type(e).__name__),message=str(e).replace(token,'[redacted]')[:600] if token else str(e)[:600])
   if task:
    try:api('POST','/v1/agent/tasks/'+task['id']+'/cancel',json={})
    except Exception:pass
  finally:
   if token:
    try:api('DELETE','/v1/memory');r['cleanup_status']=client.get('/v1/profile',headers={'Authorization':'Bearer '+token}).status_code
    except Exception as e:r['cleanup_error']=type(e).__name__
 r['seconds']=round(time.monotonic()-start,2);record(r)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,cases))
raise SystemExit(1 if any(r['status']!='passed' or r.get('cleanup_status')!=410 for r in report['cases']) else 0)
