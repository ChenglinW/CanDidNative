import asyncio
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import jwt
from fastapi import FastAPI, Depends, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, FileResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.exceptions import HTTPException
from memory import Memory, Fault, CONFIG, TABLES, L1, L2, L3, encode, now, ident
from llm import DeepSeek
from agent import TextAgent
from adapters.sqlite_memory import SQLiteMemoryAdapter
from tools.memory_tools import SourceReference
from device_auth import DeviceAuth

ROOT=Path(os.environ.get('CANDID_DATA_DIR',str(Path(__file__).parent/'data')))
ROOT.mkdir(parents=True,exist_ok=True)
MODE=os.environ.get('CANDID_AUTH_MODE','local')
TOKEN_PATH=ROOT/'local-access.txt'
if MODE=='local':
    if not TOKEN_PATH.exists():TOKEN_PATH.write_text(secrets.token_urlsafe(32),encoding='utf8')
    LOCAL_TOKEN=os.environ.get('CANDID_LOCAL_TOKEN') or TOKEN_PATH.read_text('utf8').strip()
else:LOCAL_TOKEN=''
LOCAL_OWNER='11111111-1111-4111-8111-111111111111'
SIGN_KEY=secrets.token_bytes(32)
store=Memory(ROOT/'memory.sqlite3',ROOT/'storage',llm=DeepSeek.from_config(ROOT))
device_auth=DeviceAuth(store,ROOT)
memory_service=SQLiteMemoryAdapter(store)
agent=TextAgent(store,memory_adapter=memory_service)
from tasks.business import BusinessJobs
business=BusinessJobs(store,agent.gateway,agent.workspaces)
JWKS=None
if MODE=='supabase':
    URL=os.environ['SUPABASE_URL'].rstrip('/')
    JWKS=jwt.PyJWKClient(URL+'/auth/v1/.well-known/jwks.json',lifespan=300)

async def loop():
    last=0
    while True:
        try:
            await asyncio.to_thread(store.tick)
            await asyncio.to_thread(business.tick)
            if time.time()-last>=60:
                await asyncio.to_thread(store.purge_expired);last=time.time()
        except Exception:
            # No content, audio paths, or signed URLs in logs.
            import logging;logging.getLogger('candid').error('WORKER_FAILED')
        await asyncio.sleep(.25)

@asynccontextmanager
async def lifespan(app):
    await asyncio.to_thread(agent.workspaces.migrate_legacy)
    for row in store.db.execute('SELECT DISTINCT owner_id FROM project_spaces').fetchall():
        await asyncio.to_thread(business.product.migrate,row['owner_id'])
    await asyncio.to_thread(business.recover)
    await asyncio.to_thread(agent.tasks.interrupt_running)
    task=asyncio.create_task(loop())
    try:
        yield
    finally:
        task.cancel()
        try:await task
        except asyncio.CancelledError:pass
        business.close()
        agent.close()

app=FastAPI(title='CanDid Dynamic Memory Prototype',version='2.0.0',lifespan=lifespan)

@app.exception_handler(Fault)
async def fault(req,e):return JSONResponse({'error':{'code':e.code,'message':e.message,'details':e.details}},status_code=e.status)
@app.exception_handler(RequestValidationError)
async def invalid(req,e):return JSONResponse({'error':{'code':'BAD_REQUEST','message':'参数类型或字段不正确','details':{}}},status_code=400)
@app.exception_handler(HTTPException)
async def http_error(req,e):return JSONResponse({'error':{'code':'NOT_FOUND' if e.status_code==404 else 'BAD_REQUEST','message':'请求不可用','details':{}}},status_code=e.status_code)

def owner(req:Request):
    token=req.headers.get('Authorization','').removeprefix('Bearer ')
    if MODE=='local':
        if token and hmac.compare_digest(token,LOCAL_TOKEN):uid=LOCAL_OWNER
        else:uid=device_auth.owner(token)
    elif MODE=='supabase':
        try:
            key=JWKS.get_signing_key_from_jwt(token).key
            claims=jwt.decode(token,key,algorithms=['ES256','RS256'],audience='authenticated',issuer=URL+'/auth/v1',options={'require':['exp','sub','iss','aud']})
            if claims.get('role')!='authenticated':raise ValueError()
            uid=str(UUID(claims['sub']))
        except Exception:raise Fault('UNAUTHORIZED','登录令牌无效或已过期',401)
    else:raise Fault('AUTH_NOT_CONFIGURED','鉴权模式未配置',503)
    store.check_owner(uid);return uid

class Input(BaseModel):model_config=ConfigDict(extra='forbid')
class DeviceRegistrationIn(Input):
    installation_secret:str=Field(pattern=r'^[a-f0-9]{64}$')
class SessionIn(Input):
    client_request_id:UUID
    occasion_id:UUID|None=None
    kind:Literal['practice','live','oral_debrief']
    consent:Literal['yes','no','unknown']
    consent_ack_text_version:str|None=None
    recording_source:Literal['iphone','soundcore']|None=None
    device_file_id:int|None=Field(default=None,ge=0,le=4294967295)
    audience_id:UUID|None=None
    device_id:str|None=None
    retention_days:Literal[0,7,30,90,180]|None=None
    scenario:Literal['interview','pitch','academic','sales']='interview'
class OccasionIn(Input):
    client_request_id:UUID
    scenario:Literal['interview','pitch','academic','sales']
    title:str=Field(min_length=1,max_length=200)
    fields:dict=Field(default_factory=dict)
    target_date:str|None=None
    created_from_text:str|None=None
class AssetIn(Input):
    kind:Literal['story','qa_answer','objection_answer','phrasing','example']='story'
    scenario:Literal['interview','pitch','academic','sales']|None=None
    title:str=Field(min_length=1,max_length=200)
    body:dict
    tags:list[str]=Field(default_factory=list)
class ConfirmIn(Input):
    version:int=Field(ge=1)
    body:dict|None=None
    tags:list[str]|None=None
class RetentionIn(Input):retention_days:Literal[0,7,30,90,180]
class AgentPreferencesIn(Input):
    display_name:str|None=Field(default=None,max_length=80)
    answer_style:Literal['natural','concise','detailed']|None=None
    communication_goal:str|None=Field(default=None,max_length=1000)
class ProfileIn(Input):
    timezone:str|None=Field(default=None,max_length=80)
    target_roles:list[str]|None=None
    concerns:list[str]|None=None
    preferences:dict|None=None
    product_use_consent:bool|None=None
    cross_border_consent:bool|None=None
    agent_preferences:AgentPreferencesIn|None=None
class AudienceIn(Input):role_key:str=Field(min_length=1,max_length=80);label:str=Field(min_length=1,max_length=100)
class OutcomeIn(Input):session_id:UUID|None=None;result:str=Field(max_length=100);note:str=Field(default='',max_length=4000)
class MarkIn(Input):t_ms:int=Field(ge=0);user_label:Literal['good','bad','unlabeled']='unlabeled'
class MarksIn(Input):marks:list[MarkIn]=Field(max_length=1000)
class SegmentIn(Input):
    speaker:Literal['self','other','unknown']='self'
    start_ms:int=Field(ge=0)
    end_ms:int=Field(gt=0)
    text:str=Field(min_length=1,max_length=20000)
class TranscriptIn(Input):
    segments:list[SegmentIn]=Field(min_length=1,max_length=1000)
    analyze:bool=False  # Explicit consent to send this session's self text to DeepSeek.
class MediaIn(Input):
    storage_path:str
    sha256:str=Field(pattern=r'^[0-9a-f]{64}$')
    mime:str
    bytes:int=Field(gt=0)
    duration_ms:int|None=Field(default=None,ge=0)
class FeedbackIn(Input):verdict:Literal['agree','disagree','adopted'];note:str=Field(default='',max_length=4000)
class DocumentIn(Input):kind:str;sha256:str=Field(pattern=r'^[0-9a-f]{64}$');occasion_id:UUID|None=None;name:str=Field(max_length=200)
class RetryIn(Input):stage:Literal['transcribing','segmenting','diagnosing','aggregating']='diagnosing'
class ContextIn(Input):
    purpose:Literal['prep','rehearse','diagnose','review','chat']
    occasion_id:UUID|None=None
    session_id:UUID|None=None
class FixtureIn(Input):occasion_id:UUID
class ChatThreadIn(Input):occasion_id:UUID|None=None
class ChatMessageIn(Input):
    content:str=Field(min_length=1,max_length=12000)
    client_request_id:UUID
class ChatDraftIn(Input):
    title:str=Field(default='对话中的表达',min_length=1,max_length=200)
class TaskActionIn(Input):
    client_request_id:UUID
    expected_attempt:int=Field(ge=1)
class TaskCancelIn(Input):
    expected_attempt:int=Field(ge=1)
class TaskInputIn(TaskActionIn):
    input_id:UUID
    content:str=Field(min_length=1,max_length=12000)
class WorkspaceIn(Input):
    client_request_id:UUID
    name:str=Field(default='',max_length=80)
    goal:str=Field(default='',max_length=1200)
class WorkspaceUpdateIn(Input):
    name:str=Field(min_length=1,max_length=80)
    goal:str=Field(default='',max_length=1200)
    expected_version:int=Field(ge=1)
class WorkspaceActionIn(Input):expected_version:int=Field(ge=1)
class MaterialScopeIn(Input):
    source_id:str=Field(min_length=3,max_length=200)
    mode:Literal['unassigned','spaces','personal']
    workspace_ids:list[UUID]=Field(default_factory=list,max_length=30)
    expected_revision:int=Field(ge=0)

class MemorySearchIn(Input):
    query:str=Field(min_length=1,max_length=500)
    occasion_id:UUID|None=None
    session_id:UUID|None=None
    limit:int=Field(default=6,ge=1,le=6)

class EvidenceReadIn(Input):
    references:list[SourceReference]=Field(min_length=1,max_length=24)

class ReferencesStatusIn(Input):
    references:list[SourceReference]=Field(min_length=1,max_length=100)

def data(model):return model.model_dump(mode='json',exclude_none=True)
def list_page(rows,cursor=None,limit=50):
    limit=max(1,min(limit,100))
    if cursor:
        try:anchor=json.loads(base64.urlsafe_b64decode(cursor+'='*(-len(cursor)%4)))
        except Exception:raise Fault('BAD_REQUEST','分页游标无效')
        rows=[r for r in rows if (r['created_at'],r['id'])<tuple(anchor)]
    result=rows[:limit];next_cursor=None
    if len(rows)>limit:next_cursor=base64.urlsafe_b64encode(encode([result[-1]['created_at'],result[-1]['id']]).encode()).decode().rstrip('=')
    return {'data':result,'next_cursor':next_cursor}

@app.get('/health')
def health():return {'status':'ok','schema_version':'2.0.0','storage':'sqlite_prototype','auth_mode':MODE,
                    'ai_provider':'anker' if agent.gateway.configured else 'not_configured'}
@app.get('/v1/profile')
def profile(uid=Depends(owner)):return memory_service.profile(uid)
@app.post('/v1/auth/device')
def register_device(body:DeviceRegistrationIn,response:Response):
    if MODE!='local':raise Fault('NOT_FOUND','设备接入未启用',404)
    response.headers['Cache-Control']='no-store'
    return device_auth.register(body.installation_secret)
@app.patch('/v1/profile')
def patch_profile(body:ProfileIn,uid=Depends(owner)):
    patch=data(body);preferences=patch.pop('preferences',None)
    if body.timezone is not None:
        try:ZoneInfo(body.timezone)
        except (ZoneInfoNotFoundError,ValueError):raise Fault('TIMEZONE_INVALID','请选择有效的设备时区',422)
    agent_preferences=patch.pop('agent_preferences',None)
    if preferences is not None:
        if set(preferences)-{'audio_retention_days'}:raise Fault('BAD_REQUEST','该原型只支持音频保留设置')
        if 'audio_retention_days' in preferences:store.change_retention(uid,preferences['audio_retention_days'])
    if patch.pop('cross_border_consent',None):patch['cross_border_consent_at']=now()
    elif body.cross_border_consent is False:patch['cross_border_consent_at']=None
    if patch.pop('product_use_consent',None):patch['product_use_consent_at']=now();patch['terms_version']='prototype@1'
    elif body.product_use_consent is False:patch['product_use_consent_at']=None
    with store.transaction(uid):
        profile=memory_service.profile(uid)
        if agent_preferences is not None:
            patch['agent_preferences']={**profile.get('agent_preferences',{}),**agent_preferences}
        return memory_service.update('profiles',uid,profile['id'],patch,actor=uid)

@app.post('/v1/occasions')
def create_occasion(body:OccasionIn,uid=Depends(owner)):
    with store.transaction(uid):
        key=str(body.client_request_id)
        r=store.db.execute("SELECT object_id FROM requests WHERE owner_id=? AND request_id=? AND kind='occasion'",(uid,key)).fetchone()
        if r:return memory_service.get('occasions',uid,r[0])
        row=memory_service.put('occasions',uid,{**data(body),'status':'active','template_version':body.scenario+'@1'},L3,actor=uid)
        store.db.execute('INSERT INTO requests VALUES(?,?,?,?)',(uid,key,'occasion',row['id']));return row
@app.get('/v1/occasions')
def occasions(cursor:str|None=None,limit:int=50,uid=Depends(owner)):return list_page(memory_service.rows('occasions',uid),cursor,limit)
@app.get('/v1/occasions/{id}')
def occasion(id:str,uid=Depends(owner)):
    row=memory_service.get('occasions',uid,id)
    return {**row,'artifacts':memory_service.rows('occasion_artifacts',uid,occasion_id=id),'audiences':memory_service.rows('audiences',uid,occasion_id=id)}
@app.post('/v1/occasions/{id}/audiences')
def audiences(id:str,body:AudienceIn,uid=Depends(owner)):
    memory_service.get('occasions',uid,id)
    with store.transaction(uid):
        existing=memory_service.rows('audiences',uid,occasion_id=id,role_key=body.role_key)
        return existing[0] if existing else memory_service.put('audiences',uid,{**data(body),'occasion_id':id,'agent_config_version':body.role_key+'@1'},L3,actor=uid)
@app.post('/v1/occasions/{id}/outcome')
def outcome(id:str,body:OutcomeIn,uid=Depends(owner)):
    memory_service.get('occasions',uid,id)
    if body.session_id and memory_service.get('sessions',uid,str(body.session_id)).get('occasion_id')!=id:raise Fault('BAD_REQUEST','场次不属于该场合')
    with store.transaction(uid):
        old=[o for o in memory_service.rows('outcomes',uid,occasion_id=id) if o.get('session_id')==(str(body.session_id) if body.session_id else None)]
        payload={**data(body),'occasion_id':id,'reported_at':now()}
        row=memory_service.update('outcomes',uid,old[0]['id'],payload,actor=uid) if old else memory_service.put('outcomes',uid,payload,L3,actor=uid)
        memory_service.update('occasions',uid,id,{'status':'completed'},actor=uid);return row

@app.post('/v1/sessions')
def create_session(body:SessionIn,uid=Depends(owner)):return memory_service.create_session(uid,data(body))
@app.get('/v1/capabilities')
def capabilities(uid=Depends(owner)):
    return {'llm_configured':store.llm.configured,'llm_provider':'DeepSeek',
            'llm_model':store.llm.model,'asr_configured':speech.configured,
            'agent_configured':agent.gateway.configured,'agent_provider':'Anker',
            'agent_model':agent.gateway.model,'agent_tools':agent.registry.names,
            'agent_runtime_version':agent.config.version,
            'agent_services':agent.config.services.public_status(),
            'agent_context_policy':agent.config.context_policy,
            'agent_memory_contract':memory_service.contract_version,
            'agent_skill_mode':'internal_fixed',
            'agent_task_transport':'sse','agent_task_queue':'per_thread',
            'agent_recovery_policy':'manual_after_server_restart','agent_cancel_partial':'keep_incomplete',
            'project_spaces_configured':True,'project_space_memory_policy':'explicit_scope_only',
            'project_archive_analysis_configured':agent.gateway.configured,'recording_knowledge_configured':agent.gateway.configured,
            'monid_research_configured':agent.monid.configured,'tts_configured':speech.configured,
            'recording_mode':'hybrid',
            'agent_skills':[{k:e[k] for k in ('name','title','version','available','missing_tools')}
                            for e in agent.catalog.index(agent.registry.names)]}

@app.get('/v1/agent/skills')
def agent_skills(uid=Depends(owner)):
    # Development capability metadata only; no Skill selection is added to the App.
    return {'mode':'internal_fixed','data':agent.catalog.index(agent.registry.names)}

@app.get('/v1/project-spaces')
def project_spaces(cursor:str|None=None,limit:int=50,uid=Depends(owner)):
    return list_page(sorted([agent.workspaces.view(uid,r) for r in agent.workspaces.list(uid)],key=lambda r:(r['created_at'],r['id']),reverse=True),cursor,limit)

@app.post('/v1/project-spaces',status_code=201)
def create_project_space(body:WorkspaceIn,uid=Depends(owner)):
    name=body.name.strip()
    row=agent.workspaces.create(uid,name,body.goal.strip(),str(body.client_request_id))
    return agent.workspaces.view(uid,row)

@app.patch('/v1/project-spaces/{id}')
def update_project_space(id:str,body:WorkspaceUpdateIn,uid=Depends(owner)):
    name=body.name.strip()
    if not name:raise Fault('BAD_REQUEST','空间名称不能为空',422)
    return agent.workspaces.view(uid,agent.workspaces.update(uid,id,name,body.goal.strip(),body.expected_version))

@app.post('/v1/project-spaces/{id}/archive')
def archive_project_space(id:str,body:WorkspaceActionIn,uid=Depends(owner)):
    space=agent.workspaces.archive(uid,id,body.expected_version)
    business.submit(uid,'archive',id,str(space['archived_at']))
    return agent.workspaces.view(uid,space)

@app.post('/v1/project-spaces/{id}/restore')
def restore_project_space(id:str,body:WorkspaceActionIn,uid=Depends(owner)):
    return agent.workspaces.view(uid,agent.workspaces.archive(uid,id,body.expected_version,restore=True))

@app.get('/v1/project-spaces/{id}/materials')
def project_materials(id:str,cursor:str|None=None,limit:int=50,uid=Depends(owner)):
    return list_page(agent.workspaces.materials(uid,id),cursor,limit)

@app.put('/v1/agent/material-scope')
def set_material_scope(body:MaterialScopeIn,uid=Depends(owner)):
    return agent.workspaces.set_scope(uid,body.source_id,body.mode,[str(i) for i in body.workspace_ids],body.expected_revision)

@app.post('/v1/chat/threads')
def create_chat(body:ChatThreadIn,uid=Depends(owner)):
    return agent.create(uid,str(body.occasion_id) if body.occasion_id else None)

@app.get('/v1/chat/threads')
def chat_threads(cursor:str|None=None,limit:int=50,uid=Depends(owner)):
    # Stable creation cursor; the App sorts the collected rows by latest activity.
    return list_page(store.rows('chat_threads',uid),cursor,limit)

@app.get('/v1/chat/threads/{id}')
def chat_detail(id:str,uid=Depends(owner)):return agent.detail(uid,id)

@app.post('/v1/chat/threads/{id}/messages')
async def chat_message(id:str,body:ChatMessageIn,uid=Depends(owner)):
    content=body.content.strip()
    if not content:raise Fault('BAD_REQUEST','消息不能为空')
    return await asyncio.to_thread(agent.send,uid,id,content,str(body.client_request_id))

@app.get('/v1/agent/tasks')
def agent_tasks(thread_id:str|None=None,cursor:str|None=None,limit:int=50,uid=Depends(owner)):
    return list_page([agent.tasks.public(t) for t in agent.tasks.list(uid,thread_id)],cursor,limit)

@app.get('/v1/agent/tasks/{id}')
def agent_task(id:str,uid=Depends(owner)):return agent.tasks.public(agent.tasks.get(uid,id))

@app.post('/v1/chat/threads/{id}/tasks',status_code=202)
def submit_chat_task(id:str,body:ChatMessageIn,uid=Depends(owner)):
    return agent.submit(uid,id,body.content.strip(),str(body.client_request_id))

@app.post('/v1/agent/tasks/{id}/resume',status_code=202)
def resume_agent_task(id:str,body:TaskActionIn,uid=Depends(owner)):
    return agent.resume(uid,id,str(body.client_request_id),body.expected_attempt)

@app.post('/v1/agent/tasks/{id}/input',status_code=202)
def answer_agent_task(id:str,body:TaskInputIn,uid=Depends(owner)):
    return agent.answer_input(uid,id,str(body.client_request_id),str(body.input_id),body.content,body.expected_attempt)

@app.post('/v1/agent/tasks/{id}/cancel')
def cancel_agent_task(id:str,body:TaskCancelIn,uid=Depends(owner)):
    return agent.cancel(uid,id,preserve_partial=True,expected_attempt=body.expected_attempt)

@app.get('/v1/agent/tasks/{id}/events',response_class=StreamingResponse,
         responses={200:{'content':{'text/event-stream':{'schema':{'type':'string'}}}}})
async def agent_events(id:str,request:Request,after:int=0,uid=Depends(owner)):
    from tasks.events import TERMINAL
    supplied=request.headers.get('Last-Event-ID')
    try:
        cursor=int(supplied) if supplied is not None else after
    except ValueError:
        raise Fault('AGENT_EVENT_CURSOR_INVALID','事件位置无效',400) from None
    # Validate authorization and cursor before starting a 200 SSE response.
    agent.tasks.events.after(uid,id,cursor)
    async def stream():
        position=cursor; heartbeat=time.monotonic()
        try:
            while not await request.is_disconnected():
                rows=await asyncio.to_thread(agent.tasks.events.after,uid,id,position)
                for event in rows:
                    store.check_owner(uid)
                    position=event['seq']
                    yield 'id: '+str(position)+'\nevent: '+event['kind']+'\ndata: '+json.dumps(agent.tasks.events.public(event),ensure_ascii=False)+'\n\n'
                state=agent.tasks.get(uid,id)
                if state['status'] in TERMINAL | {'waiting_input'} and position>=state.get('event_seq',0):
                    break
                if time.monotonic()-heartbeat>=10:
                    heartbeat=time.monotonic();yield ': keep-alive\n\n'
                await asyncio.sleep(.25)
        except Fault:
            # Owner deletion revokes access; no content is emitted after revocation.
            return
    return StreamingResponse(stream(),media_type='text/event-stream',
        headers={'Cache-Control':'no-cache, no-transform','X-Accel-Buffering':'no'})

@app.post('/v1/agent/memory/search')
def agent_memory_search(body:MemorySearchIn,uid=Depends(owner)):
    return memory_service.search(uid,body.query,occasion_id=str(body.occasion_id) if body.occasion_id else None,
                                 session_id=str(body.session_id) if body.session_id else None,limit=body.limit)

@app.post('/v1/agent/sources/read')
def agent_source_read(body:EvidenceReadIn,uid=Depends(owner)):
    return memory_service.read_evidence(uid,data(body)['references'])

@app.post('/v1/agent/references/status')
def agent_reference_status(body:ReferencesStatusIn,uid=Depends(owner)):
    return {'data':memory_service.references_status(uid,data(body)['references'])}

@app.get('/v1/chat/threads/{id}/context-state')
def context_state(id:str,uid=Depends(owner)):
    thread=store.get('chat_threads',uid,id)
    summary=agent.context_manager.summaries.current(uid,id)
    if summary:
        history=agent.detail(uid,id)['messages']
        safe,_=agent.context_manager._safe_history(uid,history,thread.get('workspace_id'))
        if not agent.context_manager.summaries.valid(uid,summary,safe,thread.get('workspace_id')):
            agent.context_manager.summaries.invalidate(uid,summary)
            summary=None
    return {'policy':agent.config.context_policy,'summary':summary,
            'summary_note':'任务摘要是 AI 整理的上下文，不是用户确认的长期记忆；此接口不调用模型。'}

@app.post('/v1/chat/messages/{id}/draft')
def chat_draft(id:str,body:ChatDraftIn,uid=Depends(owner)):
    message=store.get('chat_messages',uid,id)
    if message['role']!='assistant' or message.get('incomplete'):raise Fault('BAD_REQUEST','只可将已完成的 AI 回复保存为待确认草稿')
    thread=store.get('chat_threads',uid,message['thread_id'])
    occasion=memory_service.get('occasions',uid,thread['occasion_id']) if thread.get('occasion_id') else None
    scenario=(occasion or {}).get('scenario','interview')
    with store.transaction(uid):
        existing=[r for r in memory_service.rows('assets',uid) if r.get('source_chat_message_id')==id]
        if existing:return existing[0]
        return memory_service.put('assets',uid,{'title':body.title,'body':{'text':message['content']},
            'kind':'phrasing','scenario':scenario,'status':'draft','version':1,'tags':[],
            'source_chat_message_id':id,'workspace_id':thread.get('workspace_id'),'producer':message['producer'],
            'rubric_version':CONFIG['rubrics'][scenario],'chat_sources':message['sources']},L2,source='ai')
@app.get('/v1/sessions')
def sessions(cursor:str|None=None,limit:int=50,uid=Depends(owner)):return list_page(memory_service.rows('sessions',uid),cursor,limit)
@app.get('/v1/sessions/{id}')
def session(id:str,uid=Depends(owner)):
    row=memory_service.get('sessions',uid,id)
    # Other speech can be read only within its own session and only with consent.
    segments=memory_service.rows('transcript_segments',uid,session_id=id)
    if row['consent']!='yes':segments=[s for s in segments if s['speaker']=='self']
    return {**row,'transcript_segments':sorted(segments,key=lambda s:s['start_ms']),'marks':memory_service.rows('marks',uid,session_id=id)}
@app.get('/v1/sessions/{id}/review')
def review(id:str,uid=Depends(owner)):
    row=memory_service.get('sessions',uid,id)
    current=CONFIG['rubrics'][row['scenario']]
    return {'session':row,'diagnoses':memory_service.rows('diagnoses',uid,session_id=id),'metrics':memory_service.rows('metrics',uid,session_id=id),
            'draft_assets':memory_service.rows('assets',uid,source_session_id=id,status='draft'),
            'comparison_status':'current' if row['rubric_version']==current else 'old_rubric',
            'audio_note':'原音频已删除，用户原文与复盘仍保留' if row['audio_purged_at'] else None}
@app.post('/v1/sessions/{id}/marks')
def marks(id:str,body:MarksIn,uid=Depends(owner)):
    s=memory_service.get('sessions',uid,id)
    with store.transaction(uid):
        for m in body.marks:
            if s['duration_ms'] and m.t_ms>s['duration_ms']:raise Fault('BAD_REQUEST','标记超出场次范围')
            if not memory_service.rows('marks',uid,session_id=id,t_ms=m.t_ms):memory_service.put('marks',uid,{**data(m),'session_id':id},source='device')
    return {'data':memory_service.rows('marks',uid,session_id=id)}
@app.post('/v1/sessions/{id}/transcript')
def transcript(id:str,body:TranscriptIn,uid=Depends(owner)):
    s=memory_service.get('sessions',uid,id)
    if s['kind']=='live' and s['consent']=='no':raise Fault('CONSENT_REQUIRED','请使用口述复盘',403)
    with store.transaction(uid):
        added=False
        for x in body.segments:
            if x.end_ms<=x.start_ms:raise Fault('BAD_REQUEST','原文时间范围无效')
            if s['consent']!='yes' and x.speaker!='self':raise Fault('CONSENT_REQUIRED','无法确认同意时只保存本人片段',403)
            prior=memory_service.rows('transcript_segments',uid,session_id=id,start_ms=x.start_ms,end_ms=x.end_ms,speaker=x.speaker)
            if prior:
                if prior[0]['text']!=x.text:raise Fault('L1_IMMUTABLE','相同证据范围的原文不可覆盖',409)
            else:
                memory_service.put('transcript_segments',uid,{**data(x),'session_id':id,'asr_producer':'manual_user@1'},source='user')
                added=True
        if added:
            # Invalidate an in-flight result when its evidence snapshot changes.
            store.db.execute('DELETE FROM jobs WHERE owner_id=? AND session_id=?',(uid,id))
            for table in ['qa_units','metrics','diagnoses','assets']:
                for row in memory_service.rows(table,uid):
                    if row['trust']==L2 and (row.get('session_id')==id or row.get('source_session_id')==id):
                        memory_service.remove(table,uid,row['id'])
            s=memory_service.update('sessions',uid,id,{'pipeline_status':'awaiting_model','llm_consent_at':None,
                'pipeline_error':None,'pipeline_error_message':None,
                'duration_ms':max(s['duration_ms'],max(x.end_ms for x in body.segments))})
        if body.analyze:return queue_analysis(uid,id)
        return s

def queue_analysis(uid,id):
    # Caller owns the transaction. Repeated submits do not cause duplicate billable work.
    s=memory_service.get('sessions',uid,id)
    if s.get('fixture'):raise Fault('BAD_REQUEST','示例场次不会发送至模型')
    if not memory_service.rows('transcript_segments',uid,session_id=id,speaker='self'):
        raise Fault('EVIDENCE_MISSING','请先保存本人原文',422)
    if s['pipeline_status']=='done' or (s.get('llm_consent_at') and store.db.execute("SELECT 1 FROM jobs WHERE owner_id=? AND session_id=? AND status IN ('queued','running')",(uid,id)).fetchone()):
        return s
    store.db.execute('DELETE FROM jobs WHERE owner_id=? AND session_id=?',(uid,id))
    store.db.execute('INSERT INTO jobs(id,owner_id,session_id,stage,available_at) VALUES(?,?,?,?,?)',(ident(),uid,id,'diagnosing',now()))
    return memory_service.update('sessions',uid,id,{'pipeline_status':'queued','llm_consent_at':now(),
                       'pipeline_error':None,'pipeline_error_message':None})

@app.post('/v1/sessions/{id}/analyze')
def analyze(id:str,uid=Depends(owner)):
    """Explicitly agree to send this session's self transcript to DeepSeek for analysis."""
    with store.transaction(uid):return queue_analysis(uid,id)
@app.post('/v1/sessions/{id}/retry')
def retry(id:str,body:RetryIn,uid=Depends(owner)):return store.retry(uid,id,body.stage)

def sign(owner,kind,object_id):
    raw=base64.urlsafe_b64encode(encode({'owner':owner,'kind':kind,'id':object_id,'exp':int(time.time())+300}).encode()).decode()
    return raw+'.'+hmac.new(SIGN_KEY,raw.encode(),hashlib.sha256).hexdigest()
def verify(ticket,kind):
    try:
        raw,sig=ticket.split('.')
        if not hmac.compare_digest(sig,hmac.new(SIGN_KEY,raw.encode(),hashlib.sha256).hexdigest()):raise ValueError()
        value=json.loads(base64.urlsafe_b64decode(raw))
        if value['kind']!=kind or value['exp']<time.time():raise ValueError()
        store.check_owner(value['owner']);return value
    except Fault:raise
    except Exception:raise Fault('NOT_FOUND','签名链接无效或已过期',404)
def consent(s):
    if s['kind']=='live' and s['consent']!='yes':raise Fault('CONSENT_REQUIRED','开始录音前需要确认已告知对方；可转口述复盘',403)
    if s['audio_purged_at']:raise Fault('ALREADY_PURGED','原音频已删除',409)
    if not memory_service.profile(s['owner_id']).get('product_use_consent_at'):raise Fault('PROCESSING_CONSENT_REQUIRED','请先同意在此后端保存与处理音频',403)

@app.post('/v1/sessions/{id}/upload-url')
def upload_url(id:str,uid=Depends(owner)):
    s=memory_service.get('sessions',uid,id);consent(s)
    if s.get('fixture'):raise Fault('BAD_REQUEST','示例场次不可上传真实音频')
    return {'upload_url':'/v1/uploads/audio/'+sign(uid,'upload_audio',id),'expires_in':300}
def file_digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

@app.put('/v1/uploads/audio/{ticket}')
async def upload_audio(ticket:str,req:Request,offset:int=0,final:bool=True):
    value=verify(ticket,'upload_audio');uid,id=value['owner'],value['id']
    s=memory_service.get('sessions',uid,id);consent(s)
    folder=store.root/uid;folder.mkdir(exist_ok=True)
    partial=folder/(id+'.part');path=folder/(id+'.audio')
    if memory_service.rows('session_media',uid,session_id=id):raise Fault('L1_IMMUTABLE','已入库音频不可覆盖',409)
    if path.exists():raise Fault('L1_IMMUTABLE','上传已完成，请提交校验回调',409)
    if offset<0 or (partial.stat().st_size if partial.exists() else 0)!=offset:raise Fault('OFFSET_CONFLICT','上传位置不一致',409)
    # Stream to disk; final endpoint verifies hash before acknowledging synchronization.
    size=offset
    with partial.open('ab') as f:
        async for chunk in req.stream():
            size+=len(chunk)
            if size>CONFIG['max_upload_bytes']:raise Fault('UPLOAD_TOO_LARGE','单个上传文件超过2GB，请拆分文件',413)
            f.write(chunk)
    return {'storage_path':uid+'/'+id+'.part','bytes':size,'sha256':file_digest(partial) if final else '0'*64,'mime':req.headers.get('Content-Type','audio/mp4')}
@app.post('/v1/sessions/{id}/media')
def media(id:str,body:MediaIn,uid=Depends(owner)):
    with store.transaction(uid):
        s=memory_service.get('sessions',uid,id);consent(s)
        if s.get('fixture'):raise Fault('BAD_REQUEST','示例不接受真实音频')
        old=memory_service.rows('session_media',uid,session_id=id)
        if old:
            if old[0]['sha256']==body.sha256:return old[0]
            raise Fault('L1_IMMUTABLE','该场次已有不可变音频',409)
        expected=uid+'/'+id+'.part'
        if body.storage_path!=expected:raise Fault('NOT_FOUND','文件不存在',404)
        path=store.root/expected
        if not path.exists():raise Fault('NOT_FOUND','上传尚未完成',404)
        if path.stat().st_size!=body.bytes or file_digest(path)!=body.sha256:raise Fault('HASH_MISMATCH','音频校验失败，保留本地文件',409)
        final=uid+'/'+id+'.audio';path.replace(store.root/final)
        row=memory_service.put('session_media',uid,{**data(body),'storage_path':final,'session_id':id},source='device')
        memory_service.update('sessions',uid,id,{'pipeline_status':'queued','duration_ms':body.duration_ms or s['duration_ms']})
        recordings.queue(uid,id)
        return row
@app.get('/v1/sessions/{id}/audio')
def audio(id:str,start_ms:int=0,end_ms:int|None=None,uid=Depends(owner)):
    s=memory_service.get('sessions',uid,id)
    if s['audio_purged_at']:raise Fault('ALREADY_PURGED','原音频已删除',409)
    media=memory_service.rows('session_media',uid,session_id=id)
    if not media:raise Fault('NOT_FOUND','该场次没有可播放音频',404)
    if start_ms<0 or end_ms is not None and end_ms<=start_ms:raise Fault('BAD_REQUEST','回听范围无效')
    return {'url':'/v1/audio/'+sign(uid,'audio',id),'expires_in':300,'start_ms':start_ms,'end_ms':end_ms,'range_mode':'client_seek'}
@app.get('/v1/audio/{ticket}')
def audio_file(ticket:str):
    v=verify(ticket,'audio');s=memory_service.get('sessions',v['owner'],v['id'])
    if s['audio_purged_at']:raise Fault('ALREADY_PURGED','音频已删除',409)
    items=memory_service.rows('session_media',v['owner'],session_id=v['id'])
    if not items or not (store.root/items[0]['storage_path']).exists():raise Fault('NOT_FOUND','音频不存在',404)
    return FileResponse(store.root/items[0]['storage_path'],media_type=items[0]['mime'])
@app.delete('/v1/sessions/{id}/audio')
def delete_audio(id:str,uid=Depends(owner)):return store.purge_audio(uid,id)
@app.patch('/v1/sessions/{id}/retention')
def retention(id:str,body:RetentionIn,uid=Depends(owner)):return store.change_retention(uid,body.retention_days,id)

@app.get('/v1/assets')
def assets(scenario:str|None=None,kind:str|None=None,status:str|None=None,tag:str|None=None,cursor:str|None=None,limit:int=50,uid=Depends(owner)):
    rows=memory_service.rows('assets',uid,scenario=scenario,kind=kind,status=status)
    if tag:rows=[a for a in rows if tag in a.get('tags',[])]
    return list_page(rows,cursor,limit)
@app.post('/v1/assets')
def asset(body:AssetIn,uid=Depends(owner)):
    with store.transaction(uid):return memory_service.put('assets',uid,{**data(body),'status':'confirmed','version':1},L3,actor=uid)
@app.patch('/v1/assets/{id}')
def patch_asset(id:str,body:ConfirmIn,uid=Depends(owner)):return memory_service.mutate_asset(uid,id,**data(body))
@app.post('/v1/assets/{id}/confirm')
def confirm(id:str,body:ConfirmIn,uid=Depends(owner)):return memory_service.mutate_asset(uid,id,status='confirmed',**data(body))
@app.post('/v1/assets/{id}/archive')
def archive(id:str,body:ConfirmIn,uid=Depends(owner)):return memory_service.mutate_asset(uid,id,status='archived',**data(body))
@app.get('/v1/assets/{id}/revisions')
def revisions(id:str,uid=Depends(owner)):
    memory_service.get('assets',uid,id);return {'data':memory_service.rows('asset_revisions',uid,asset_id=id)}
@app.get('/stories')
def stories(uid=Depends(owner)):return list_page(memory_service.rows('assets',uid,kind='story'))
@app.get('/v1/experiences')
def experiences(status:str|None=None,uid=Depends(owner)):return list_page(memory_service.rows('experiences',uid,status=status))
@app.post('/v1/experiences')
def experience(body:AssetIn,uid=Depends(owner)):
    with store.transaction(uid):return memory_service.put('experiences',uid,{**data(body),'status':'confirmed','version':1},L3,actor=uid)
@app.post('/v1/experiences/{id}/confirm')
def confirm_experience(id:str,body:ConfirmIn,uid=Depends(owner)):return memory_service.mutate_asset(uid,id,status='confirmed',table='experiences',**data(body))
@app.post('/v1/diagnoses/{id}/feedback')
def feedback(id:str,body:FeedbackIn,uid=Depends(owner)):
    d=memory_service.get('diagnoses',uid,id)
    with store.transaction(uid):
        old=memory_service.rows('diagnosis_feedback',uid,diagnosis_id=id)
        row=memory_service.update('diagnosis_feedback',uid,old[0]['id'],data(body),actor=uid) if old else memory_service.put('diagnosis_feedback',uid,{**data(body),'diagnosis_id':id},L3,actor=uid)
        if body.verdict=='disagree':
            s=memory_service.get('sessions',uid,d['session_id'])
            for w in memory_service.rows('weaknesses',uid,scenario=s['scenario'],dimension=d['dimension']):memory_service.update('weaknesses',uid,w['id'],{'state':'disputed','user_disagrees':True,'dispute_hits':0})
        return row
@app.get('/v1/progress')
def progress(scenario:Literal['interview','pitch','academic','sales']='interview',uid=Depends(owner)):
    version=CONFIG['rubrics'][scenario]
    sessions=[s for s in memory_service.rows('sessions',uid,scenario=scenario) if s['rubric_version']==version and s['pipeline_status']=='done']
    return {'rubric_version':version,'status':'ready' if len(sessions)>=3 else 'insufficient_data',
        'baselines':[b for b in memory_service.rows('baselines',uid) if b['rubric_version']==version],
        'weaknesses':[w for w in memory_service.rows('weaknesses',uid,scenario=scenario) if w['rubric_version']==version and w['state']!='observed'],
        'n_sessions':len(sessions)}
@app.post('/v1/context-preview')
def context(body:ContextIn,uid=Depends(owner)):return memory_service.context(uid,**data(body))

@app.post('/v1/documents')
def document(body:DocumentIn,uid=Depends(owner)):
    if body.occasion_id:memory_service.get('occasions',uid,str(body.occasion_id))
    existing=memory_service.rows('documents',uid,sha256=body.sha256)
    if existing:return existing[0]
    id=ident()
    return {'id':id,'upload_url':'/v1/uploads/document/'+sign(uid,'upload_document',id), 'metadata':data(body),'expires_in':300}
@app.put('/v1/uploads/document/{ticket}')
async def upload_document(ticket:str,req:Request):
    v=verify(ticket,'upload_document');uid,id=v['owner'],v['id'];content=await req.body()
    if len(content)>CONFIG['max_upload_bytes']:raise Fault('UPLOAD_TOO_LARGE','文件超过 25MB',413)
    # Metadata is validated again on upload. No file parsing or CV inference is fabricated.
    kind=req.headers.get('X-Document-Kind','reference');digest=hashlib.sha256(content).hexdigest()
    claimed=req.headers.get('X-Content-SHA256')
    if claimed and claimed!=digest:raise Fault('HASH_MISMATCH','文件校验失败',409)
    with store.transaction(uid):
        prior=memory_service.rows('documents',uid,sha256=digest)
        if prior:return prior[0]
        folder=store.root/uid;folder.mkdir(exist_ok=True);p=folder/(id+'.document');p.write_bytes(content)
        return memory_service.put('documents',uid,{'id':id,'kind':kind,'storage_path':uid+'/'+id+'.document','sha256':digest,'parsed_text':None},L1)
@app.post('/v1/demo/fixture')
def fixture(body:FixtureIn,uid=Depends(owner)):
    if MODE!='local':raise Fault('NOT_FOUND','示例入口仅用于本机模式',404)
    return store.fixture(uid,str(body.occasion_id))
@app.get('/v1/memory/export')
def export(uid=Depends(owner)):
    result={table:memory_service.rows(table,uid) for table in TABLES}
    for s in result['sessions']:
        if not s['audio_purged_at'] and memory_service.rows('session_media',uid,session_id=s['id']):s['audio_url']='/v1/audio/'+sign(uid,'audio',s['id'])
    return {'schema_version':'2.0.0','data':result,'exported_at':now(),'audio_links_expires_in':300}
@app.delete('/v1/memory')
def delete_memory(uid=Depends(owner)):return store.delete_memory(uid)


class MaterialIn(Input):
    workspace_id:UUID
    title:str=Field(default='补充资料',min_length=1,max_length=200)
    text:str=Field(default='',max_length=200000)
    url:str|None=Field(default=None,max_length=2000)

@app.post('/v1/materials')
def add_material(body:MaterialIn,uid=Depends(owner)):
    return agent.materials.save(uid,str(body.workspace_id),body.title,body.text,body.url)

@app.post('/v1/materials/pdf')
async def add_pdf(req:Request,workspace_id:UUID,title:str='PDF资料',uid=Depends(owner)):
    if len(title)>200:raise Fault('BAD_REQUEST','标题过长',422)
    raw=bytearray()
    async for chunk in req.stream():
        raw.extend(chunk)
        if len(raw)>20_000_000:raise Fault('PDF_TOO_LARGE','PDF超过20 MB',413)
    return await asyncio.to_thread(agent.materials.save,uid,str(workspace_id),title,raw=bytes(raw))

@app.get('/v1/materials/{id}')
def material_detail(id:str,uid=Depends(owner)):
    return memory_service.get('documents',uid,id)

@app.get('/v1/business-jobs')
def business_jobs(uid=Depends(owner)):
    return {'data':store.rows('business_jobs',uid),'next_cursor':None}

@app.get('/v1/business-jobs/{id}')
def business_job(id:str,uid=Depends(owner)):
    return store.get('business_jobs',uid,id)

@app.post('/v1/business-jobs/{id}/retry')
def retry_business(id:str,uid=Depends(owner)):
    return business.retry(uid,id)

@app.post('/v1/business-jobs/{id}/cancel')
def cancel_business(id:str,uid=Depends(owner)):
    return business.cancel(uid,id)

@app.get('/v1/personal-memories')
def personal_memories(uid=Depends(owner)):
    return {'data':store.rows('personal_memories',uid),'next_cursor':None}

class PersonalMemoryEdit(Input):
    text:str|None=Field(default=None,min_length=1,max_length=1200)
    title:str|None=Field(default=None,min_length=1,max_length=120)
    status:Literal['confirmed','withdrawn']|None=None
    expected_version:int=Field(ge=1)

@app.patch('/v1/personal-memories/{id}')
def edit_personal_memory(id:str,body:PersonalMemoryEdit,uid=Depends(owner)):
    with store.transaction(uid):
        row=store.get('personal_memories',uid,id)
        if row['version']!=body.expected_version:raise Fault('VERSION_CONFLICT','记忆已更新，请刷新',409)
        patch=body.model_dump(exclude_none=True,exclude={'expected_version'})
        return store.update('personal_memories',uid,id,{**patch,'version':row['version']+1,'edited_by':uid},actor=uid)

# New recordings are global library entries; project association only comes from tags.
from adapters.speech import Speech
from tasks.recordings import Recordings
from fastapi import WebSocket, WebSocketDisconnect
speech=Speech()
recordings=Recordings(store,business,speech)

class RecordingIn(Input):
    client_request_id:UUID
    recording_source:Literal['iphone','soundcore']='iphone'
    consent:Literal['yes']
    consent_ack_text_version:str=Field(default='recording-consent@1',min_length=1,max_length=80)
    scenario:Literal['interview','pitch','academic','sales']='sales'
    device_file_id:int|None=None
    device_id:str|None=None

@app.post('/v1/recordings')
def create_recording(body:RecordingIn,uid=Depends(owner)):
    payload=data(body)
    return memory_service.create_session(uid,{**payload,'kind':'live','occasion_id':None})

@app.get('/v1/recordings')
def recording_library(tag:str|None=None,uid=Depends(owner)):
    rows=[]
    for session in store.rows('sessions',uid):
        if session.get('fixture'):continue
        tags=[t for t in store.rows('recording_tags',uid,session_id=session['id']) if t.get('active')]
        if tag and not any(tag.lower() in t['label'].lower() for t in tags):continue
        rows.append({**session,'tags':tags,'jobs':store.rows('business_jobs',uid,object_id=session['id'])})
    return {'data':rows,'next_cursor':None}

@app.get('/v1/recordings/{id}')
def recording_detail(id:str,uid=Depends(owner)):
    row=store.get('sessions',uid,id)
    return {**row,'segments':recordings.segments(uid,id),'marks':store.rows('marks',uid,session_id=id),
        'tags':[t for t in store.rows('recording_tags',uid,session_id=id) if t.get('active')],
        'knowledge':[r for r in store.rows('recording_knowledge',uid,session_id=id) if str(r.get('revision'))==str(row.get('transcript_revision',1))],
        'jobs':store.rows('business_jobs',uid,object_id=id)}

@app.post('/v1/recordings/{id}/process')
def process_recording(id:str,uid=Depends(owner)):
    return recordings.queue(uid,id)

class TagIn(Input):
    label:str=Field(min_length=1,max_length=100)
    kind:Literal['client','project','topic']='topic'
    workspace_id:UUID|None=None

@app.post('/v1/recordings/{id}/tags')
def add_recording_tag(id:str,body:TagIn,uid=Depends(owner)):
    with store.transaction(uid):
        store.get('sessions',uid,id)
        if body.workspace_id:agent.workspaces.get(uid,str(body.workspace_id))
        result=store.put('recording_tags',uid,{**data(body),'label':body.label.strip(),'session_id':id,'active':True,'revision':1,'manual':True},L1)
        business.product.sync_recording(uid,id)
        return result

class TagEdit(TagIn):
    expected_revision:int=Field(ge=1)
    active:bool=True

@app.patch('/v1/recording-tags/{id}')
def change_recording_tag(id:str,body:TagEdit,uid=Depends(owner)):
    with store.transaction(uid):
        row=store.get('recording_tags',uid,id)
        if row['revision']!=body.expected_revision:raise Fault('VERSION_CONFLICT','标签已变化，请刷新',409)
        if body.workspace_id:agent.workspaces.get(uid,str(body.workspace_id))
        # Suppression survives reanalysis. Preserve original AI producer alongside the human edit.
        patch=data(body);patch.pop('expected_revision');patch['workspace_id']=str(body.workspace_id) if body.workspace_id else None
        result=store.update('recording_tags',uid,id,{**patch,'revision':row['revision']+1,'manual':True,'edited_by':uid,'original_label':row.get('original_label',row['label'])})
        business.product.sync_recording(uid,row['session_id'])
        return result

class SpeakerIn(Input):
    speaker_ids:list[str]=Field(min_length=1,max_length=100)
    expected_revision:int=Field(ge=1)

@app.put('/v1/recordings/{id}/self-speaker')
def choose_self_speaker(id:str,body:SpeakerIn,uid=Depends(owner)):
    with store.transaction(uid):
        row=store.get('sessions',uid,id)
        if row.get('transcript_revision',1)!=body.expected_revision:raise Fault('VERSION_CONFLICT','转写已更新，请刷新',409)
        segments=recordings.segments(uid,id)
        available={s.get('speaker_id') for s in segments if s.get('speaker_id')}
        if not set(body.speaker_ids)<=available:raise Fault('SPEAKER_INVALID','选择的说话人不存在',422)
        revision=body.expected_revision+1
        for s in segments:
            payload={k:v for k,v in s.items() if k not in {'id','owner_id','created_at','updated_at','source','trust','visibility'}}
            payload.update(transcript_revision=revision,speaker='self' if s.get('speaker_id') in body.speaker_ids else 'other',
                identity_confirmed_by=uid,previous_segment_id=s['id'])
            store.put('transcript_segments',uid,payload,L1,source='user')
        store.update('sessions',uid,id,{'transcript_revision':revision,'self_speaker_ids':body.speaker_ids,'speaker_identity_status':'user_selected'})
        business.submit(uid,'recording_knowledge',id,str(revision))
        return recording_detail(id,uid)

class RecordingSegmentIn(SegmentIn):
    speaker_id:str|None=Field(default=None,max_length=100)

class RecordingRevisionIn(Input):
    expected_revision:int=Field(ge=1)
    segments:list[RecordingSegmentIn]=Field(min_length=1,max_length=20000)

@app.put('/v1/recordings/{id}/transcript')
def revise_recording_transcript(id:str,body:RecordingRevisionIn,uid=Depends(owner)):
    with store.transaction(uid):
        row=store.get('sessions',uid,id)
        if row.get('transcript_revision',1)!=body.expected_revision:raise Fault('VERSION_CONFLICT','转写已变化，请刷新',409)
        revision=body.expected_revision+1
        for s in body.segments:
            if s.end_ms<=s.start_ms:raise Fault('BAD_REQUEST','时间范围无效',422)
            store.put('transcript_segments',uid,{**data(s),'session_id':id,'transcript_revision':revision,'asr_producer':'manual_user@2'},L1)
        store.update('sessions',uid,id,{'transcript_revision':revision,'pipeline_status':'transcribed'})
        business.submit(uid,'recording_knowledge',id,str(revision))
        return recording_detail(id,uid)

@app.post('/v1/chat/messages/{id}/speak')
def speak_message(id:str,uid=Depends(owner)):
    message=store.get('chat_messages',uid,id)
    speech.check()
    job=business.submit(uid,'tts',id,recordings.speech_version(message))
    return business.retry(uid,job['id']) if job['status'] in {'failed','interrupted','cancelled'} else job

@app.get('/v1/speech/{id}')
def speech_file(id:str,uid=Depends(owner)):
    row=store.get('speech_outputs',uid,id)
    return FileResponse(store.root/row['storage_path'],media_type='audio/wav')

@app.websocket('/v1/speech/live')
async def live_speech(ws:WebSocket):
    from voice.live_bridge import live_speech as relay
    await relay(ws,owner,store,speech)

from voice.routes import install as install_voice
install_voice(app,owner,store,agent,speech)

@app.get('/v1/speech-clips')
def speech_clips(job_id:str,uid=Depends(owner)):
    store.get('business_jobs',uid,job_id)
    return {'data':store.rows('speech_outputs',uid,job_id=job_id),'next_cursor':None}

@app.get('/v1/device-actions')
def device_actions(uid=Depends(owner)):
    return {'data':store.rows('device_actions',uid,status='queued'),'next_cursor':None}

@app.post('/v1/device-actions/{id}/claim')
def claim_device_action(id:str,uid=Depends(owner)):
    with store.transaction(uid):
        row=store.get('device_actions',uid,id)
        if row['status']!='queued':raise Fault('ACTION_ALREADY_CLAIMED','该动作已由手机处理',409)
        if (datetime.now(timezone.utc)-datetime.fromisoformat(row['requested_at'])).total_seconds()>60:
            return store.update('device_actions',uid,id,{'status':'expired'})
        return store.update('device_actions',uid,id,{'status':'running'})

class DeviceReceiptIn(Input):
    status:Literal['executed','failed','unavailable']
    recording_status:int|None=None
    note:str=Field(default='',max_length=300)

@app.post('/v1/device-actions/{id}/receipt')
def device_action_receipt(id:str,body:DeviceReceiptIn,uid=Depends(owner)):
    with store.transaction(uid):
        row=store.get('device_actions',uid,id)
        if row['status']!='running':return row
        return store.update('device_actions',uid,id,{'status':body.status,'receipt':data(body),'received_at':now()})

@app.get('/v1/sessions/{id}/upload-state')
def upload_state(id:str,uid=Depends(owner)):
    store.get('sessions',uid,id)
    media=store.rows('session_media',uid,session_id=id)
    partial=store.root/uid/(id+'.part')
    return {'offset':partial.stat().st_size if partial.exists() else 0,'media':media[0] if media else None}

# Product routes resolve the same authenticated store and durable business worker.
import sys
from product_routes import router as product_router
app.include_router(product_router(sys.modules[__name__]))

from onboarding import Onboarding, install as install_onboarding
# Resolve current services at request time so test stores and future adapters stay aligned.
def onboarding_service():
    service = getattr(business, 'onboarding_service', None)
    if service is None:
        service = Onboarding(store, business); business.onboarding_service = service
    return service
onboarding_service()
install_onboarding(app, owner, onboarding_service)

from companion_routes import router as companion_router
import sys as _sys
app.include_router(companion_router(_sys.modules[__name__]))
