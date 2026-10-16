from uuid import UUID
from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field
from companion import Companion

class Edit(BaseModel):
    model_config = ConfigDict(extra='forbid')
    expected_version: int = Field(ge=1)
class ExpressionEdit(Edit):
    text: str = Field(min_length=1,max_length=4000)
class FAQEdit(Edit):
    text: str | None = Field(default=None, min_length=1, max_length=4000)
    topic: str | None = Field(default=None, max_length=40)
    period: str | None = Field(default=None, max_length=120)
    expires_on: str | None = Field(default=None, max_length=10)

class LiveSentence(BaseModel):
    text:str=Field(min_length=1,max_length=3000)
    start_ms:int=Field(ge=0)
class LiveAsk(BaseModel):
    client_request_id:UUID
    recording_id:UUID
    question:str=Field(min_length=1,max_length=3000)
    sentences:list[LiveSentence]=Field(max_length=100)

def router(module):
    r=APIRouter(prefix='/v1/companion'); auth=Depends(module.owner)
    def domain(): return Companion(module.store)
    @r.get('')
    def snapshot(uid=auth): return domain().snapshot(uid)
    @r.get('/memory')
    def memory(uid=auth):
        with module.store.transaction(uid):
            lib=module.library_service();lib.migrate(uid)
            result = domain().memory(uid)
            library = module.library_service()
            library.migrate(uid)
            result['expressions'] = [library.compat_expression(uid,row['id']) for row in module.store.rows('library_items',uid)
                                     if row.get('status') == 'active']
            result['question_grouping'] = library.grouping.snapshot(uid)
            return result
    @r.post('/live-ask')
    def live_ask(body:LiveAsk,uid=auth):
        from memory import L1,Fault
        session=module.store.get('sessions',uid,str(body.recording_id))
        if session.get('consent')!='yes':raise Fault('RECORDING_CONSENT_REQUIRED','请先开启本场转写',403)
        text='实时字幕快照，未经最终转写校准，未认领说话人；不能当作本人经历。\n'+'\n'.join(f'[{s.start_ms}ms] {s.text}' for s in body.sentences)
        if len(text)>20000:raise Fault('LIVE_CONTEXT_TOO_LONG','实时原文过长，请缩小到最近片段',422)
        with module.store.transaction(uid):
            request='live:'+str(body.client_request_id)
            prior=module.store.rows('documents',uid,live_request_id=request)
            doc=prior[0] if prior else module.store.put('documents',uid,{'title':'本场实时字幕（未校准）','text':text,'session_id':str(body.recording_id),'material_kind':'live_caption_snapshot','live_request_id':request,'status':'active','acquired':True},L1)
            if doc['text']!=text or doc.get('session_id')!=str(body.recording_id):raise Fault('REQUEST_CONFLICT','重试时的字幕范围已改变，请沿用原快照',409)
        return module.agent.submit(uid,domain().thread(uid)['id'],body.question,str(body.client_request_id),live_source_id='document:'+doc['id'])
    @r.get('/documents/{id}')
    def document(id:UUID,uid=auth):
        from memory import Fault
        original=module.store.get('documents',uid,str(id))
        if module.store.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='onboarding_document_removed'",(uid,str(id))).fetchone():
            raise Fault('NOT_FOUND','资料已移除',404)
        rows=module.store.rows('documents',uid,onboarding_original_id=str(id))
        if not rows: raise Fault('DOCUMENT_PROCESSING','资料尚未解析完成，请稍后重试',409)
        row=rows[0]
        return {'id':row['id'],'title':original['title'],'text':row['text'],'pages':row.get('pages',[]),'original_id':str(id)}
    @r.get('/preparations/{id}')
    def preparation(id:UUID,uid=auth):
        row=module.store.get('companion_preparations',uid,str(id))
        return {**row,'reference_status':'current' if domain().current(uid,row['evidence_refs']) else 'superseded'}
    @r.post('/preparations/{id}/complete')
    def complete(id:UUID,body:Edit,uid=auth): return domain().finish(uid,str(id),body.expected_version)
    @r.patch('/faq/{id}')
    def faq(id:UUID,body:FAQEdit,uid=auth):
        return module.library_service().compat_edit(uid,str(id),body.model_dump(exclude_unset=True))
    @r.patch('/expressions/{id}')
    def expression(id:UUID,body:ExpressionEdit,uid=auth):
        return module.library_service().compat_edit(uid,str(id),body.model_dump())
    return r
