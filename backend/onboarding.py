"""User-authored profile and durable, local-only document extraction for first use."""
import hashlib
import io
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from uuid import UUID

from fastapi import Depends, Request
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal
from memory import Fault, L1, now, ident


class PersonalProfile(BaseModel):
    model_config = ConfigDict(extra='forbid')
    display_name: str = Field(default='', max_length=40)
    introduction: str = Field(default='', max_length=2000)
    scenarios: list[Literal['sales', 'interview']] = Field(default_factory=list, max_length=2)


class OnboardingIn(BaseModel):
    model_config = ConfigDict(extra='forbid')
    client_request_id: UUID
    profile: PersonalProfile | None = None
    expected_version: int | None = Field(default=None, ge=0)
    completed: bool = False


class Onboarding:
    def __init__(self, store, business):
        self.store, self.business = store, business
        business.handlers['onboarding_document'] = self.extract

    def snapshot(self, owner):
        self.store.check_owner(owner)
        p = self.store.profile(owner)
        legacy_name = p.get('agent_preferences', {}).get('display_name', '')
        fallback = PersonalProfile(display_name=legacy_name[:40] if isinstance(legacy_name, str) else '').model_dump()
        return {'profile': p.get('onboarding_profile', fallback),
                'version': p.get('onboarding_profile_version', 0),
                'completed': bool(p.get('onboarding_completed_at')),
                'documents': self.documents(owner)}

    def save(self, owner, body):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            key = str(body.client_request_id)
            prior = self.store.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='onboarding_profile'", (owner, key)).fetchone()
            if prior: return self.snapshot(owner)
            p = self.store.profile(owner)
            patch = {}
            if body.profile is not None:
                if body.expected_version != p.get('onboarding_profile_version', 0):
                    raise Fault('PROFILE_VERSION_CONFLICT', '个人介绍已在其他设备更新；本机输入已保留，可先读取最新资料再修改', 409)
                value = body.profile.model_dump()
                value.update(display_name=value['display_name'].strip(), introduction=value['introduction'].strip(), scenarios=sorted(set(value['scenarios'])))
                patch.update(onboarding_profile=value, onboarding_profile_version=p.get('onboarding_profile_version', 0)+1)
            if body.completed and not p.get('onboarding_completed_at'): patch['onboarding_completed_at'] = now()
            if patch: self.store.update('profiles', owner, p['id'], patch, actor=owner)
            self.store.db.execute("INSERT INTO requests VALUES(?,?,'onboarding_profile',?)", (owner, key, p['id']))
            return self.snapshot(owner)

    def removed(self, owner, id):
        return self.store.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='onboarding_document_removed'", (owner, id)).fetchone() is not None

    def documents(self, owner):
        rows = []
        for d in self.store.rows('documents', owner, material_kind='onboarding_original'):
            if self.removed(owner, d['id']): continue
            job = next(iter(self.store.rows('business_jobs', owner, kind='onboarding_document', object_id=d['id'])), {})
            rows.append({'id': d['id'], 'title': d['title'], 'status': job.get('status', 'queued'),
                         'error': job.get('error'), 'job_id': job.get('id')})
        return rows

    def intake(self, owner, filename, raw):
        self.store.check_owner(owner)
        name = Path(filename).name[:180]
        extension = Path(name).suffix.lower()
        if extension not in {'.pdf', '.docx', '.pptx', '.txt', '.md'}: raise Fault('FILE_TYPE_UNSUPPORTED', '请选择 PDF、DOCX、PPTX、TXT 或 Markdown 文件', 422)
        if not raw: raise Fault('FILE_EMPTY', '文件为空，请重新选择', 422)
        if len(raw) > 25_000_000: raise Fault('UPLOAD_TOO_LARGE', '单份文件最多 25 MB', 413)
        digest = hashlib.sha256(raw).hexdigest()
        with self.store.transaction(owner):
            prior = next((d for d in self.store.rows('documents', owner, material_kind='onboarding_original') if d['sha256'] == digest and not self.removed(owner, d['id'])), None)
            if prior: return next(x for x in self.documents(owner) if x['id'] == prior['id'])
            id = ident()
            folder = self.store.root/owner/'onboarding'; folder.mkdir(parents=True, exist_ok=True)
            target = folder/(id+extension); target.write_bytes(raw); target.chmod(0o600)
            self.store.put('documents', owner, {'id': id, 'title': name, 'sha256': digest, 'extension': extension,
                'storage_path': str(target.relative_to(self.store.root)), 'material_kind': 'onboarding_original',
                'status': 'active', 'acquired': False}, L1)
            self.business.submit(owner, 'onboarding_document', id)
            return next(x for x in self.documents(owner) if x['id'] == id)

    def extract(self, owner, job):
        with self.store.transaction(owner):
            self.business.guard(owner, job)
            original = self.store.get('documents', owner, job['object_id'])
            if self.removed(owner, original['id']): raise Fault('DOCUMENT_REMOVED', '这份资料已移除', 409)
        raw = (self.store.root/original['storage_path']).read_bytes()
        pages = []
        try:
            if original['extension'] == '.pdf':
                from document_text import pdf_text
                text, pages = pdf_text(raw)
                meaningful = True
            elif original['extension'] == '.pptx':
                with zipfile.ZipFile(io.BytesIO(raw)) as z:
                    if sum(i.file_size for i in z.infolist())>40_000_000:raise ValueError()
                    import re
                    slides=sorted((i for i in z.infolist() if re.fullmatch(r'ppt/slides/slide[0-9]+.xml',i.filename)),key=lambda i:int(re.search(r'slide([0-9]+)',i.filename).group(1)))
                    if len(slides)>300:raise ValueError()
                    for number,part in enumerate(slides,1):
                        xml=z.read(part)
                        if b'<!DOCTYPE' in xml or b'<!ENTITY' in xml:raise ValueError()
                        root=ET.fromstring(xml)
                        text='\n'.join(t.text or '' for t in root.iter('{http://schemas.openxmlformats.org/drawingml/2006/main}t'))
                        pages.append({'page':number,'text':text})
                    text='\n\n'.join(p['text'] for p in pages);meaningful=bool(text.strip())
            elif original['extension'] == '.docx':
                with zipfile.ZipFile(io.BytesIO(raw)) as z:
                    part = z.getinfo('word/document.xml')
                    if part.file_size > 8_000_000 or sum(i.file_size for i in z.infolist()) > 40_000_000: raise ValueError()
                    xml = z.read(part)
                    if b'<!DOCTYPE' in xml or b'<!ENTITY' in xml: raise ValueError()
                    root = ET.fromstring(xml)
                    ns = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
                    text = '\n'.join(''.join(p.itertext()) if not list(p.iter(ns+'t')) else ''.join(t.text or '' for t in p.iter(ns+'t')) for p in root.iter(ns+'p'))
                    meaningful = bool(text.strip())
            else:
                text = raw.decode('utf-8-sig'); meaningful = bool(text.strip())
            if not meaningful: raise Fault('DOCUMENT_NO_TEXT', '未找到可提取文字，扫描件请换文字版 PDF 或粘贴文字后重试', 422)
            if len(text) > 205000: raise ValueError()
        except Fault: raise
        except Exception: raise Fault('DOCUMENT_PARSE_FAILED', '文件无法解析或超出文本上限；TXT 请使用 UTF-8，扫描 PDF 请换文字版', 422) from None
        with self.store.transaction(owner):
            self.business.guard(owner, job)
            if self.removed(owner, original['id']): raise Fault('DOCUMENT_REMOVED', '这份资料已移除', 409)
            prior = self.store.rows('documents', owner, onboarding_original_id=original['id'])
            parsed = prior[0] if prior else self.store.put('documents', owner, {'title': original['title'], 'text': text, 'pages': pages,
                'sha256': original['sha256'], 'status': 'active', 'acquired': True, 'version': 1,
                'onboarding_original_id': original['id'], 'material_kind': 'user_document', 'reading_range': 'user_document'}, L1)
            # Original bytes remain immutable; only extracted user evidence gets personal scope.
            scope = self.business.workspaces.scope(owner, 'document:'+parsed['id'])
            if not scope: self.business.workspaces.set_scope(owner, 'document:'+parsed['id'], 'personal', [], 0)
            return {'document_id': parsed['id'], 'characters': len(text), 'processing': 'local_text_extraction'}

    def remove(self, owner, id):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            row = self.store.get('documents', owner, id)
            if row.get('material_kind') != 'onboarding_original': raise Fault('NOT_FOUND', '资料不存在', 404)
            self.store.db.execute("INSERT OR IGNORE INTO requests VALUES(?,?,'onboarding_document_removed',?)", (owner, id, id))
            for d in self.store.rows('documents', owner, onboarding_original_id=id):
                scope = self.business.workspaces.scope(owner, 'document:'+d['id'])
                self.business.workspaces.set_scope(owner, 'document:'+d['id'], 'unassigned', [], scope['revision'] if scope else 0)
            for job in self.store.rows('business_jobs', owner, kind='onboarding_document', object_id=id):
                self.business.cancel(owner, job['id'])
            return {'status': 'removed'}


def install(app, owner, get_service):
    @app.get('/v1/onboarding')
    def get(uid=Depends(owner)): return get_service().snapshot(uid)

    @app.patch('/v1/onboarding')
    def save(body: OnboardingIn, uid=Depends(owner)): return get_service().save(uid, body)

    @app.post('/v1/onboarding/documents')
    async def upload(req: Request, filename: str, uid=Depends(owner)):
        raw = bytearray()
        async for chunk in req.stream():
            raw.extend(chunk)
            if len(raw) > 25_000_000: raise Fault('UPLOAD_TOO_LARGE', '单份文件最多 25 MB', 413)
        import asyncio
        return await asyncio.to_thread(get_service().intake, uid, filename, bytes(raw))

    @app.post('/v1/onboarding/documents/{id}/retry')
    def retry(id: UUID, uid=Depends(owner)):
        service = get_service()
        row = next((x for x in service.documents(uid) if x['id'] == str(id)), None)
        if not row: raise Fault('NOT_FOUND', '资料不存在', 404)
        service.business.retry(uid, row['job_id'])
        return next(x for x in service.documents(uid) if x['id'] == str(id))

    @app.delete('/v1/onboarding/documents/{id}')
    def remove(id: UUID, uid=Depends(owner)): return get_service().remove(uid, str(id))
