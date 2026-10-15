"""HTTP boundary for the product domain; dependencies resolve the current app database."""
from typing import Literal
from uuid import UUID
from io import BytesIO
import zipfile
from xml.sax.saxutils import escape
from fastapi import APIRouter, Depends
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict, Field
from product import Product
from memory import Fault, now

class Input(BaseModel):model_config=ConfigDict(extra='forbid')
class Participant(Input):
    name:str=Field(min_length=1,max_length=100)
    role:str=Field(default='',max_length=100)
    side:Literal['self','customer','interviewer','other']='other'
class ProjectIn(Input):
    client_request_id:UUID
    name:str=Field(min_length=1,max_length=200)
    goal:str=Field(default='',max_length=1200)
    scenario:Literal['sales','interview']
    organization:str=Field(default='',max_length=200)
    opportunity:str=Field(default='',max_length=200)
    participants:list[Participant]=Field(default_factory=list,max_length=50)
class ProjectEdit(Input):
    expected_version:int=Field(ge=1)
    name:str|None=Field(default=None,min_length=1,max_length=200)
    goal:str|None=Field(default=None,max_length=1200)
    scenario:Literal['sales','interview']|None=None
    organization:str|None=Field(default=None,max_length=200)
    opportunity:str|None=Field(default=None,max_length=200)
    stage:str|None=Field(default=None,max_length=50)
    result:str|None=Field(default=None,max_length=1000)
    participants:list[Participant]|None=Field(default=None,max_length=50)
class MeetingIn(Input):
    client_request_id:UUID
    title:str=Field(min_length=1,max_length=200)
    goal:str=Field(default='',max_length=1200)
    scheduled_at:str|None=None
    timezone:str='Asia/Hong_Kong'
    actual_at:str|None=None
    kind:str=Field(default='communication',max_length=100)
    is_practice:bool=False
    participants:list[Participant]=Field(default_factory=list,max_length=50)
class MeetingEdit(Input):
    expected_version:int=Field(ge=1)
    title:str|None=Field(default=None,min_length=1,max_length=200)
    goal:str|None=Field(default=None,max_length=1200)
    scheduled_at:str|None=None
    actual_at:str|None=None
    status:Literal['planned','recorded','completed','cancelled']|None=None
class LinkIn(Input):session_id:UUID;active:bool=True
class ScopeIn(Input):
    mode:Literal['personal','all','scenario','project','meeting']
    project_id:UUID|None=None
    meeting_id:UUID|None=None
    scenario:Literal['sales','interview']|None=None
    practice:bool=False
class ItemEdit(Input):
    expected_version:int=Field(ge=1)
    text:str|None=Field(default=None,min_length=1,max_length=2000)
    owner:str|None=Field(default=None,max_length=100)
    due_at:str|None=None
    status:Literal['open','done','withdrawn']|None=None
    update_note:str|None=Field(default=None,max_length=2000)
class DraftIn(Input):channel:Literal['email','wechat','whatsapp']='email';internal:bool=False
class DraftEdit(Input):
    expected_version:int=Field(ge=1)
    text:str|None=Field(default=None,min_length=1,max_length=12000)
    title:str|None=Field(default=None,min_length=1,max_length=200)
    recipient:str|None=Field(default=None,max_length=500)
class ReceiptIn(Input):
    result:Literal['sent','cancelled','saved','failed']
    manual:bool=False
    sent_version:int|None=Field(default=None,ge=1)
class RewriteIn(Input):
    instruction:str=Field(min_length=1,max_length=2000)
    client_request_id:UUID
class DiscoveryDecision(Input):
    id:UUID
    expected_version:int=Field(ge=1)
    status:Literal['confirmed','withdrawn','pending']
    text:str|None=Field(default=None,min_length=1,max_length=1200)
class DiscoveryBatch(Input):items:list[DiscoveryDecision]=Field(max_length=100)
class SpeakerName(Input):speaker_id:str=Field(min_length=1,max_length=100);name:str=Field(max_length=100);is_self:bool=False
class SpeakersIn(Input):expected_revision:int=Field(ge=1);speakers:list[SpeakerName]=Field(max_length=100)
class NaturalIn(Input):
    text:str=Field(min_length=1,max_length=3000)
    client_request_id:UUID
    project_id:UUID|None=None
    scenario:Literal['sales','interview']='sales'
    timezone:str='Asia/Hong_Kong'

def word_document(title,text):
    doc='''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'''
    for line in [title,*text.splitlines()]:doc+='<w:p><w:r><w:t xml:space="preserve">'+escape(line)+'</w:t></w:r></w:p>'
    doc+='<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:bottom="1134" w:left="1134" w:right="1134"/></w:sectPr></w:body></w:document>'
    out=BytesIO()
    with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr('word/document.xml',doc)
    return out.getvalue()

def router(module):
    r=APIRouter(prefix='/v1');auth=Depends(module.owner)
    def domain():return Product(module.store,module.business)
    @r.get('/projects')
    def projects(uid=auth):return {'data':domain().projects(uid),'next_cursor':None}
    @r.post('/projects')
    def create(body:ProjectIn,uid=auth):return domain().create(uid,body.model_dump(exclude={'client_request_id'}),str(body.client_request_id))
    @r.get('/projects/{id}')
    def detail(id:str,uid=auth):return domain().detail(uid,id)
    @r.patch('/projects/{id}')
    def edit(id:str,body:ProjectEdit,uid=auth):return domain().update_project(uid,id,body.model_dump(exclude_none=True,exclude={'expected_version'}),body.expected_version)
    @r.post('/projects/{id}/meetings')
    def meeting(id:str,body:MeetingIn,uid=auth):return domain().meeting(uid,id,body.model_dump(exclude={'client_request_id'}),str(body.client_request_id))
    @r.patch('/meetings/{id}')
    def meeting_edit(id:str,body:MeetingEdit,uid=auth):return domain().patch_meeting(uid,id,body.model_dump(exclude_unset=True,exclude={'expected_version'}),body.expected_version)
    @r.post('/meetings/{id}/recordings')
    def link(id:str,body:LinkIn,uid=auth):return domain().link(uid,id,str(body.session_id),body.active)
    @r.post('/meetings/{id}/analyze')
    def analyze(id:str,uid=auth):return domain().queue_analysis(uid,id)
    @r.post('/meetings/{id}/prepare')
    def prepare(id:str,uid=auth):return domain().queue_preparation(uid,id)
    @r.post('/chat/scopes')
    def scope(body:ScopeIn,uid=auth):
        if body.practice and body.mode!='project':raise Fault('SCOPE_INVALID','练习需要明确的项目范围',422)
        required={'project':'project_id','meeting':'meeting_id','scenario':'scenario'}
        if body.mode in required and not getattr(body,required[body.mode]):raise Fault('SCOPE_REQUIRED','请选择问答范围',422)
        data={k:str(v) if k!='practice' else v for k,v in body.model_dump(exclude_none=True).items() if k!='practice' or v}
        if any(k not in {'mode','practice'} and k!=required.get(body.mode) for k in data):raise Fault('SCOPE_INVALID','范围字段不一致',422)
        return domain().scope_thread(uid,data)
    @r.get('/project-items')
    def items(uid=auth):return {'data':domain().items(uid),'next_cursor':None}
    @r.patch('/project-items/{id}')
    def item_edit(id:str,body:ItemEdit,uid=auth):return domain().patch_item(uid,id,body.model_dump(exclude_unset=True,exclude={'expected_version'}),body.expected_version)
    @r.post('/project-items/{id}/faq')
    def faq(id:str,uid=auth):return domain().faq(uid,id)
    @r.post('/meetings/{id}/followups')
    def draft(id:str,body:DraftIn,uid=auth):return domain().draft(uid,id,body.channel,body.internal)
    @r.patch('/followups/{id}')
    def draft_edit(id:str,body:DraftEdit,uid=auth):return domain().patch_draft(uid,id,body.model_dump(exclude_none=True,exclude={'expected_version'}),body.expected_version)
    @r.post('/followups/{id}/receipt')
    def receipt(id:str,body:ReceiptIn,uid=auth):return domain().sent(uid,id,body.result,body.manual,body.sent_version)
    @r.post('/followups/{id}/rewrite')
    def rewrite(id:str,body:RewriteIn,uid=auth):
        draft=module.store.get('followup_drafts',uid,id)
        return module.business.submit(uid,'followup_rewrite',id,str(draft['version'])+':'+str(body.client_request_id),{'instruction':body.instruction,'request_id':str(body.client_request_id),'draft_version':draft['version']})
    @r.get('/preparations/{id}/export')
    def preparation_export(id:str,format:Literal['text','word']='text',uid=auth):
        pack=module.store.get('preparation_packs',uid,id)
        # Sources can include documents, so use the adapter's version/state validation.
        refs=pack.get('evidence_refs',[])
        if any(s['status']!='current' for s in module.memory_service.references_status(uid,refs,pack['project_id'])):raise Fault('SOURCE_SUPERSEDED','准备资料已修订，请重新整理',409)
        text='\n\n'.join(section['title']+'\n'+section['text'] for section in pack['sections'])
        if format=='word':return Response(word_document('会前准备包',text),media_type='application/vnd.openxmlformats-officedocument.wordprocessingml.document')
        return {'title':'会前准备包','text':text,'internal':True}
    @r.get('/followups/{id}/export')
    def export(id:str,format:Literal['text','word']='text',include_transcript:bool=False,uid=auth):
        d=module.store.get('followup_drafts',uid,id);text=d['text']
        if not domain().current(uid,d):raise Fault('SOURCE_SUPERSEDED','稿件依据已修订，请重新生成',409)
        if include_transcript:text+='\n\n原文（用户主动包含）\n'+'\n'.join(f"[{e['start_ms']/1000:.1f}s] {e['text']}" for e in domain().evidence(uid,d['meeting_id']))
        if format=='word':return Response(word_document(d['title'],text),media_type='application/vnd.openxmlformats-officedocument.wordprocessingml.document',headers={'Content-Disposition':'attachment; filename="Candid.docx"'})
        return {'title':d['title'],'text':text,'internal':d['internal']}
    @r.get('/discoveries')
    def discoveries(uid=auth):return {'data':[{**d,'reference_status':'current' if domain().current(uid,d) else 'superseded'} for d in module.store.rows('discoveries',uid)],'next_cursor':None}
    @r.post('/discoveries/decisions')
    def decisions(body:DiscoveryBatch,uid=auth):return {'data':domain().confirm_discoveries(uid,[{**i.model_dump(exclude_none=True),'id':str(i.id)} for i in body.items])}
    @r.post('/projects/{id}/discoveries')
    def discover(id:str,uid=auth):
        domain().project(uid,id)
        evidence=[e for m in module.store.rows('business_meetings',uid,project_id=id) for e in domain().evidence(uid,m['id'])]
        import hashlib,json
        return module.business.submit(uid,'discovery',id,hashlib.sha256(json.dumps(evidence,sort_keys=True).encode()).hexdigest())
    @r.get('/personal-progress')
    def progress(uid=auth):return domain().stats(uid)
    @r.patch('/recordings/{id}/speakers')
    def names(id:str,body:SpeakersIn,uid=auth):
        from memory import L1
        with module.store.transaction(uid):
            session=module.store.get('sessions',uid,id)
            if session.get('transcript_revision',1)!=body.expected_revision:raise Fault('VERSION_CONFLICT','转写已更新，请刷新',409)
            lines=module.recordings.segments(uid,id);valid={line.get('speaker_id') for line in lines}
            if any(s.speaker_id not in valid for s in body.speakers):raise Fault('SPEAKER_INVALID','未知说话人',422)
            mappings={s.speaker_id:s for s in body.speakers}
            if len(mappings)!=len(body.speakers):raise Fault('SPEAKER_INVALID','说话人编号不能重复',422)
            for speaker in mappings.values():speaker.name=speaker.name.strip()
            if not any(s.speaker_id==line.get('speaker_id') and (s.name!=(line.get('speaker_name') or '') or s.is_self!=(line.get('speaker')=='self')) for s in body.speakers for line in lines):
                return {'revision':body.expected_revision}
            revision=body.expected_revision+1
            updated=[]
            for line in lines:
                speaker=mappings.get(line.get('speaker_id'));copy={k:v for k,v in line.items() if k not in {'id','created_at','updated_at'}}
                copy.update(transcript_revision=revision,speaker_name=speaker.name if speaker else line.get('speaker_name'),
                    speaker='self' if speaker and speaker.is_self else 'other' if speaker else line.get('speaker','unknown'))
                module.store.put('transcript_segments',uid,copy,L1,source='device')
                updated.append(copy)
            module.store.update('sessions',uid,id,{'transcript_revision':revision,
                'speaker_names':{line['speaker_id']:line['speaker_name'] for line in updated if line.get('speaker_id') and line.get('speaker_name')},
                'self_speaker_ids':sorted({line['speaker_id'] for line in updated if line.get('speaker_id') and line.get('speaker')=='self'}),
                'speaker_identity_status':'user_selected'})
            module.business.submit(uid,'recording_knowledge',id,str(revision))
            return {'revision':revision}
    @r.post('/projects/natural/create')
    def natural(body:NaturalIn,uid=auth):
        product=domain();text=body.text
        prior=next((p for p in product.spaces.list(uid) if p.get('client_request_id')==str(body.client_request_id)),None)
        if prior:
            if prior.get('goal')!=text:raise Fault('REQUEST_CONFLICT','重试原话与原请求不同',409)
            prior_meeting=next((m for m in module.store.rows('business_meetings',uid,project_id=prior['id']) if m.get('request_id')==str(body.client_request_id)),None)
            return {'project':product.spaces.view(uid,prior),'meeting':prior_meeting}
        if body.project_id:project=product.project(uid,str(body.project_id))
        result=module.business.structured('解析用户创建项目或安排场次的原话。返回 {"name":"简短标题","goal":"用户目标","organization":"原话中的公司或空","opportunity":"原话中的岗位机会或空","meeting_title":"场次名称或空","scheduled_at":null,"date_quote":"原话日期或空"}。时间只根据当前时间和原话解析，未知为null。不补人名。',{'text':text,'now':now(),'timezone':body.timezone})
        with module.store.transaction(uid):
            if not body.project_id:
                project=product.create(uid,{'name':str(result.get('name') or text[:50])[:200],'goal':text,'scenario':body.scenario,
                    'organization':result.get('organization') if isinstance(result.get('organization'),str) and result['organization'] in text else '',
                    'opportunity':result.get('opportunity') if isinstance(result.get('opportunity'),str) and result['opportunity'] in text else '', 'participants':[]},str(body.client_request_id))
            meeting=None;date=result.get('scheduled_at');quote=result.get('date_quote')
            if not isinstance(quote,str) or not quote.strip() or quote not in text:date=None
            if result.get('meeting_title'):
                meeting=product.meeting(uid,project['id'],{'title':str(result['meeting_title'])[:200],'goal':text,'scheduled_at':date,
                    'timezone':body.timezone,'created_from_text':text},str(body.client_request_id))
        return {'project':project,'meeting':meeting}
    return r
