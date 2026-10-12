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

import jwt
from fastapi import FastAPI, Depends, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, FileResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.exceptions import HTTPException
from memory import Memory, Fault, CONFIG, TABLES, L1, L2, L3, encode, now, ident
from llm import DeepSeek

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
JWKS=None
if MODE=='supabase':
    URL=os.environ['SUPABASE_URL'].rstrip('/')
    JWKS=jwt.PyJWKClient(URL+'/auth/v1/.well-known/jwks.json',lifespan=300)

async def loop():
    last=0
    while True:
        try:
            await asyncio.to_thread(store.tick)
            if time.time()-last>=60:
                await asyncio.to_thread(store.purge_expired);last=time.time()
        except Exception:
            # No content, audio paths, or signed URLs in logs.
            import logging;logging.getLogger('candid').error('WORKER_FAILED')
        await asyncio.sleep(.25)

@asynccontextmanager
async def lifespan(app):
    task=asyncio.create_task(loop())
    yield
    task.cancel()
    try:await task
    except asyncio.CancelledError:pass

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
        if not token or not hmac.compare_digest(token,LOCAL_TOKEN):raise Fault('UNAUTHORIZED','请填写本机访问令牌',401)
        uid=LOCAL_OWNER
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
class ProfileIn(Input):
    target_roles:list[str]|None=None
    concerns:list[str]|None=None
    preferences:dict|None=None
    product_use_consent:bool|None=None
    cross_border_consent:bool|None=None
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
def health():return {'status':'ok','schema_version':'2.0.0','storage':'sqlite_prototype','auth_mode':MODE,'ai_provider':'not_configured'}
@app.get('/v1/profile')
def profile(uid=Depends(owner)):return store.profile(uid)
@app.patch('/v1/profile')
def patch_profile(body:ProfileIn,uid=Depends(owner)):
    patch=data(body);preferences=patch.pop('preferences',None)
    if preferences is not None:
        if set(preferences)-{'audio_retention_days'}:raise Fault('BAD_REQUEST','该原型只支持音频保留设置')
        if 'audio_retention_days' in preferences:store.change_retention(uid,preferences['audio_retention_days'])
    if patch.pop('cross_border_consent',None):patch['cross_border_consent_at']=now()
    elif body.cross_border_consent is False:patch['cross_border_consent_at']=None
    if patch.pop('product_use_consent',None):patch['product_use_consent_at']=now();patch['terms_version']='prototype@1'
    elif body.product_use_consent is False:patch['product_use_consent_at']=None
    with store.transaction(uid):return store.update('profiles',uid,store.profile(uid)['id'],patch,actor=uid)

@app.post('/v1/occasions')
def create_occasion(body:OccasionIn,uid=Depends(owner)):
    with store.transaction(uid):
        key=str(body.client_request_id)
        r=store.db.execute("SELECT object_id FROM requests WHERE owner_id=? AND request_id=? AND kind='occasion'",(uid,key)).fetchone()
        if r:return store.get('occasions',uid,r[0])
        row=store.put('occasions',uid,{**data(body),'status':'active','template_version':body.scenario+'@1'},L3,actor=uid)
        store.db.execute('INSERT INTO requests VALUES(?,?,?,?)',(uid,key,'occasion',row['id']));return row
@app.get('/v1/occasions')
def occasions(cursor:str|None=None,limit:int=50,uid=Depends(owner)):return list_page(store.rows('occasions',uid),cursor,limit)
@app.get('/v1/occasions/{id}')
def occasion(id:str,uid=Depends(owner)):
    row=store.get('occasions',uid,id)
    return {**row,'artifacts':store.rows('occasion_artifacts',uid,occasion_id=id),'audiences':store.rows('audiences',uid,occasion_id=id)}
@app.post('/v1/occasions/{id}/audiences')
def audiences(id:str,body:AudienceIn,uid=Depends(owner)):
    store.get('occasions',uid,id)
    with store.transaction(uid):
        existing=store.rows('audiences',uid,occasion_id=id,role_key=body.role_key)
        return existing[0] if existing else store.put('audiences',uid,{**data(body),'occasion_id':id,'agent_config_version':body.role_key+'@1'},L3,actor=uid)
@app.post('/v1/occasions/{id}/outcome')
def outcome(id:str,body:OutcomeIn,uid=Depends(owner)):
    store.get('occasions',uid,id)
    if body.session_id and store.get('sessions',uid,str(body.session_id)).get('occasion_id')!=id:raise Fault('BAD_REQUEST','场次不属于该场合')
    with store.transaction(uid):
        old=[o for o in store.rows('outcomes',uid,occasion_id=id) if o.get('session_id')==(str(body.session_id) if body.session_id else None)]
        payload={**data(body),'occasion_id':id,'reported_at':now()}
        row=store.update('outcomes',uid,old[0]['id'],payload,actor=uid) if old else store.put('outcomes',uid,payload,L3,actor=uid)
        store.update('occasions',uid,id,{'status':'completed'},actor=uid);return row

@app.post('/v1/sessions')
def create_session(body:SessionIn,uid=Depends(owner)):return store.create_session(uid,data(body))
@app.get('/v1/capabilities')
def capabilities(uid=Depends(owner)):
    return {'llm_configured':store.llm.configured,'llm_provider':'DeepSeek',
            'llm_model':store.llm.model,'asr_configured':False}
@app.get('/v1/sessions')
def sessions(cursor:str|None=None,limit:int=50,uid=Depends(owner)):return list_page(store.rows('sessions',uid),cursor,limit)
@app.get('/v1/sessions/{id}')
def session(id:str,uid=Depends(owner)):
    row=store.get('sessions',uid,id)
    # Other speech can be read only within its own session and only with consent.
    segments=store.rows('transcript_segments',uid,session_id=id)
    if row['consent']!='yes':segments=[s for s in segments if s['speaker']=='self']
    return {**row,'transcript_segments':sorted(segments,key=lambda s:s['start_ms']),'marks':store.rows('marks',uid,session_id=id)}
@app.get('/v1/sessions/{id}/review')
def review(id:str,uid=Depends(owner)):
    row=store.get('sessions',uid,id)
    current=CONFIG['rubrics'][row['scenario']]
    return {'session':row,'diagnoses':store.rows('diagnoses',uid,session_id=id),'metrics':store.rows('metrics',uid,session_id=id),
            'draft_assets':store.rows('assets',uid,source_session_id=id,status='draft'),
            'comparison_status':'current' if row['rubric_version']==current else 'old_rubric',
            'audio_note':'原音频已删除，用户原文与复盘仍保留' if row['audio_purged_at'] else None}
@app.post('/v1/sessions/{id}/marks')
def marks(id:str,body:MarksIn,uid=Depends(owner)):
    s=store.get('sessions',uid,id)
    with store.transaction(uid):
        for m in body.marks:
            if s['duration_ms'] and m.t_ms>s['duration_ms']:raise Fault('BAD_REQUEST','标记超出场次范围')
            if not store.rows('marks',uid,session_id=id,t_ms=m.t_ms):store.put('marks',uid,{**data(m),'session_id':id},source='device')
    return {'data':store.rows('marks',uid,session_id=id)}
@app.post('/v1/sessions/{id}/transcript')
def transcript(id:str,body:TranscriptIn,uid=Depends(owner)):
    s=store.get('sessions',uid,id)
    if s['kind']=='live' and s['consent']=='no':raise Fault('CONSENT_REQUIRED','请使用口述复盘',403)
    with store.transaction(uid):
        added=False
        for x in body.segments:
            if x.end_ms<=x.start_ms:raise Fault('BAD_REQUEST','原文时间范围无效')
            if s['consent']!='yes' and x.speaker!='self':raise Fault('CONSENT_REQUIRED','无法确认同意时只保存本人片段',403)
            prior=store.rows('transcript_segments',uid,session_id=id,start_ms=x.start_ms,end_ms=x.end_ms,speaker=x.speaker)
            if prior:
                if prior[0]['text']!=x.text:raise Fault('L1_IMMUTABLE','相同证据范围的原文不可覆盖',409)
            else:
                store.put('transcript_segments',uid,{**data(x),'session_id':id,'asr_producer':'manual_user@1'},source='user')
                added=True
        if added:
            # Invalidate an in-flight result when its evidence snapshot changes.
            store.db.execute('DELETE FROM jobs WHERE owner_id=? AND session_id=?',(uid,id))
            for table in ['qa_units','metrics','diagnoses','assets']:
                for row in store.rows(table,uid):
                    if row['trust']==L2 and (row.get('session_id')==id or row.get('source_session_id')==id):
                        store.remove(table,uid,row['id'])
            s=store.update('sessions',uid,id,{'pipeline_status':'awaiting_model','llm_consent_at':None,
                'pipeline_error':None,'pipeline_error_message':None,
                'duration_ms':max(s['duration_ms'],max(x.end_ms for x in body.segments))})
        if body.analyze:return queue_analysis(uid,id)
        return s

def queue_analysis(uid,id):
    # Caller owns the transaction. Repeated submits do not cause duplicate billable work.
    s=store.get('sessions',uid,id)
    if s.get('fixture'):raise Fault('BAD_REQUEST','示例场次不会发送至模型')
    if not store.rows('transcript_segments',uid,session_id=id,speaker='self'):
        raise Fault('EVIDENCE_MISSING','请先保存本人原文',422)
    if s['pipeline_status']=='done' or (s.get('llm_consent_at') and store.db.execute("SELECT 1 FROM jobs WHERE owner_id=? AND session_id=? AND status IN ('queued','running')",(uid,id)).fetchone()):
        return s
    store.db.execute('DELETE FROM jobs WHERE owner_id=? AND session_id=?',(uid,id))
    store.db.execute('INSERT INTO jobs(id,owner_id,session_id,stage,available_at) VALUES(?,?,?,?,?)',(ident(),uid,id,'diagnosing',now()))
    return store.update('sessions',uid,id,{'pipeline_status':'queued','llm_consent_at':now(),
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
    if not store.profile(s['owner_id']).get('product_use_consent_at'):raise Fault('PROCESSING_CONSENT_REQUIRED','请先同意在此后端保存与处理音频',403)

@app.post('/v1/sessions/{id}/upload-url')
def upload_url(id:str,uid=Depends(owner)):
    s=store.get('sessions',uid,id);consent(s)
    if s.get('fixture'):raise Fault('BAD_REQUEST','示例场次不可上传真实音频')
    return {'upload_url':'/v1/uploads/audio/'+sign(uid,'upload_audio',id),'expires_in':300}
@app.put('/v1/uploads/audio/{ticket}')
async def upload_audio(ticket:str,req:Request,offset:int=0):
    value=verify(ticket,'upload_audio');uid,id=value['owner'],value['id']
    s=store.get('sessions',uid,id);consent(s)
    folder=store.root/uid;folder.mkdir(exist_ok=True)
    partial=folder/(id+'.part');path=folder/(id+'.audio')
    if store.rows('session_media',uid,session_id=id):raise Fault('L1_IMMUTABLE','已入库音频不可覆盖',409)
    if path.exists():raise Fault('L1_IMMUTABLE','上传已完成，请提交校验回调',409)
    if offset<0 or (partial.stat().st_size if partial.exists() else 0)!=offset:raise Fault('OFFSET_CONFLICT','上传位置不一致',409)
    # Stream to disk; final endpoint verifies hash before acknowledging synchronization.
    size=offset
    with partial.open('ab') as f:
        async for chunk in req.stream():
            size+=len(chunk)
            if size>CONFIG['max_upload_bytes']:raise Fault('UPLOAD_TOO_LARGE','原型单文件上限 25MB',413)
            f.write(chunk)
    return {'storage_path':uid+'/'+id+'.part','bytes':size,'sha256':hashlib.sha256(partial.read_bytes()).hexdigest(),'mime':req.headers.get('Content-Type','audio/mp4')}
@app.post('/v1/sessions/{id}/media')
def media(id:str,body:MediaIn,uid=Depends(owner)):
    with store.transaction(uid):
        s=store.get('sessions',uid,id);consent(s)
        if s.get('fixture'):raise Fault('BAD_REQUEST','示例不接受真实音频')
        old=store.rows('session_media',uid,session_id=id)
        if old:
            if old[0]['sha256']==body.sha256:return old[0]
            raise Fault('L1_IMMUTABLE','该场次已有不可变音频',409)
        expected=uid+'/'+id+'.part'
        if body.storage_path!=expected:raise Fault('NOT_FOUND','文件不存在',404)
        path=store.root/expected
        if not path.exists():raise Fault('NOT_FOUND','上传尚未完成',404)
        content=path.read_bytes()
        if len(content)!=body.bytes or hashlib.sha256(content).hexdigest()!=body.sha256:raise Fault('HASH_MISMATCH','音频校验失败，保留本地文件',409)
        final=uid+'/'+id+'.audio';path.replace(store.root/final)
        row=store.put('session_media',uid,{**data(body),'storage_path':final,'session_id':id},source='device')
        store.update('sessions',uid,id,{'pipeline_status':'queued','duration_ms':body.duration_ms or s['duration_ms']})
        store.db.execute('INSERT INTO jobs(id,owner_id,session_id,stage,available_at) VALUES(?,?,?,?,?)',(ident(),uid,id,'transcribing',now()))
        return row
@app.get('/v1/sessions/{id}/audio')
def audio(id:str,start_ms:int=0,end_ms:int|None=None,uid=Depends(owner)):
    s=store.get('sessions',uid,id)
    if s['audio_purged_at']:raise Fault('ALREADY_PURGED','原音频已删除',409)
    media=store.rows('session_media',uid,session_id=id)
    if not media:raise Fault('NOT_FOUND','该场次没有可播放音频',404)
    if start_ms<0 or end_ms is not None and end_ms<=start_ms:raise Fault('BAD_REQUEST','回听范围无效')
    return {'url':'/v1/audio/'+sign(uid,'audio',id),'expires_in':300,'start_ms':start_ms,'end_ms':end_ms,'range_mode':'client_seek'}
@app.get('/v1/audio/{ticket}')
def audio_file(ticket:str):
    v=verify(ticket,'audio');s=store.get('sessions',v['owner'],v['id'])
    if s['audio_purged_at']:raise Fault('ALREADY_PURGED','音频已删除',409)
    items=store.rows('session_media',v['owner'],session_id=v['id'])
    if not items or not (store.root/items[0]['storage_path']).exists():raise Fault('NOT_FOUND','音频不存在',404)
    return FileResponse(store.root/items[0]['storage_path'],media_type=items[0]['mime'])
@app.delete('/v1/sessions/{id}/audio')
def delete_audio(id:str,uid=Depends(owner)):return store.purge_audio(uid,id)
@app.patch('/v1/sessions/{id}/retention')
def retention(id:str,body:RetentionIn,uid=Depends(owner)):return store.change_retention(uid,body.retention_days,id)

@app.get('/v1/assets')
def assets(scenario:str|None=None,kind:str|None=None,status:str|None=None,tag:str|None=None,cursor:str|None=None,limit:int=50,uid=Depends(owner)):
    rows=store.rows('assets',uid,scenario=scenario,kind=kind,status=status)
    if tag:rows=[a for a in rows if tag in a.get('tags',[])]
    return list_page(rows,cursor,limit)
@app.post('/v1/assets')
def asset(body:AssetIn,uid=Depends(owner)):
    with store.transaction(uid):return store.put('assets',uid,{**data(body),'status':'confirmed','version':1},L3,actor=uid)
@app.patch('/v1/assets/{id}')
def patch_asset(id:str,body:ConfirmIn,uid=Depends(owner)):return store.mutate_asset(uid,id,**data(body))
@app.post('/v1/assets/{id}/confirm')
def confirm(id:str,body:ConfirmIn,uid=Depends(owner)):return store.mutate_asset(uid,id,status='confirmed',**data(body))
@app.post('/v1/assets/{id}/archive')
def archive(id:str,body:ConfirmIn,uid=Depends(owner)):return store.mutate_asset(uid,id,status='archived',**data(body))
@app.get('/v1/assets/{id}/revisions')
def revisions(id:str,uid=Depends(owner)):
    store.get('assets',uid,id);return {'data':store.rows('asset_revisions',uid,asset_id=id)}
@app.get('/stories')
def stories(uid=Depends(owner)):return list_page(store.rows('assets',uid,kind='story'))
@app.get('/v1/experiences')
def experiences(status:str|None=None,uid=Depends(owner)):return list_page(store.rows('experiences',uid,status=status))
@app.post('/v1/experiences')
def experience(body:AssetIn,uid=Depends(owner)):
    with store.transaction(uid):return store.put('experiences',uid,{**data(body),'status':'confirmed','version':1},L3,actor=uid)
@app.post('/v1/experiences/{id}/confirm')
def confirm_experience(id:str,body:ConfirmIn,uid=Depends(owner)):return store.mutate_asset(uid,id,status='confirmed',table='experiences',**data(body))
@app.post('/v1/diagnoses/{id}/feedback')
def feedback(id:str,body:FeedbackIn,uid=Depends(owner)):
    d=store.get('diagnoses',uid,id)
    with store.transaction(uid):
        old=store.rows('diagnosis_feedback',uid,diagnosis_id=id)
        row=store.update('diagnosis_feedback',uid,old[0]['id'],data(body),actor=uid) if old else store.put('diagnosis_feedback',uid,{**data(body),'diagnosis_id':id},L3,actor=uid)
        if body.verdict=='disagree':
            s=store.get('sessions',uid,d['session_id'])
            for w in store.rows('weaknesses',uid,scenario=s['scenario'],dimension=d['dimension']):store.update('weaknesses',uid,w['id'],{'state':'disputed','user_disagrees':True,'dispute_hits':0})
        return row
@app.get('/v1/progress')
def progress(scenario:Literal['interview','pitch','academic','sales']='interview',uid=Depends(owner)):
    version=CONFIG['rubrics'][scenario]
    sessions=[s for s in store.rows('sessions',uid,scenario=scenario) if s['rubric_version']==version and s['pipeline_status']=='done']
    return {'rubric_version':version,'status':'ready' if len(sessions)>=3 else 'insufficient_data',
        'baselines':[b for b in store.rows('baselines',uid) if b['rubric_version']==version],
        'weaknesses':[w for w in store.rows('weaknesses',uid,scenario=scenario) if w['rubric_version']==version and w['state']!='observed'],
        'n_sessions':len(sessions)}
@app.post('/v1/context-preview')
def context(body:ContextIn,uid=Depends(owner)):return store.context(uid,**data(body))

@app.post('/v1/documents')
def document(body:DocumentIn,uid=Depends(owner)):
    if body.occasion_id:store.get('occasions',uid,str(body.occasion_id))
    existing=store.rows('documents',uid,sha256=body.sha256)
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
        prior=store.rows('documents',uid,sha256=digest)
        if prior:return prior[0]
        folder=store.root/uid;folder.mkdir(exist_ok=True);p=folder/(id+'.document');p.write_bytes(content)
        return store.put('documents',uid,{'id':id,'kind':kind,'storage_path':uid+'/'+id+'.document','sha256':digest,'parsed_text':None},L1)
@app.post('/v1/demo/fixture')
def fixture(body:FixtureIn,uid=Depends(owner)):
    if MODE!='local':raise Fault('NOT_FOUND','示例入口仅用于本机模式',404)
    return store.fixture(uid,str(body.occasion_id))
@app.get('/v1/memory/export')
def export(uid=Depends(owner)):
    result={table:store.rows(table,uid) for table in TABLES}
    for s in result['sessions']:
        if not s['audio_purged_at'] and store.rows('session_media',uid,session_id=s['id']):s['audio_url']='/v1/audio/'+sign(uid,'audio',s['id'])
    return {'schema_version':'2.0.0','data':result,'exported_at':now(),'audio_links_expires_in':300}
@app.delete('/v1/memory')
def delete_memory(uid=Depends(owner)):return store.delete_memory(uid)
