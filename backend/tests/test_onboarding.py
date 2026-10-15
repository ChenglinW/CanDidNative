"""Isolated onboarding persistence, authorization and actual document-byte regression."""
import io
import sys
import zipfile
from pathlib import Path
from types import SimpleNamespace
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from memory import Memory, Fault, ident
from onboarding import Onboarding, OnboardingIn, PersonalProfile
from tasks.business import BusinessJobs
from tasks.workspaces import WorkspaceStore

A = '11111111-1111-4111-8111-111111111111'
B = '22222222-2222-4222-8222-222222222222'

@pytest.fixture
def service(tmp_path):
    store = Memory(tmp_path/'test.sqlite', tmp_path/'storage')
    jobs = BusinessJobs(store, SimpleNamespace(model='offline', configured=False, base='https://offline.invalid'), WorkspaceStore(store))
    value = Onboarding(store, jobs)
    yield value
    jobs.close(); store.db.close()

def body(**kwargs): return OnboardingIn(client_request_id=ident(), **kwargs)
def process(service, receipt):
    service.business.run(A, service.store.get('business_jobs', A, receipt['job_id']))
    return service.store.get('business_jobs', A, receipt['job_id'])

def test_skipping_does_not_fabricate_profile_or_projects(service):
    result = service.save(A, body(completed=True))
    assert result['completed'] and result['version'] == 0
    assert result['profile']['introduction'] == ''
    assert service.store.rows('project_spaces', A) == []
    assert not service.store.rows('assets', A)

def test_explicit_profile_edits_are_versioned_idempotent_and_clearable(service):
    request = body(profile=PersonalProfile(display_name=' 小林 ', introduction='我做设计。', scenarios=['sales','interview']), expected_version=0, completed=True)
    result = service.save(A, request)
    assert result['profile']['display_name'] == '小林' and result['version'] == 1
    assert service.save(A, request)['version'] == 1
    with pytest.raises(Fault, match='其他设备更新'):
        service.save(A, body(profile=PersonalProfile(introduction='旧设备'), expected_version=0))
    result = service.save(A, body(profile=PersonalProfile(), expected_version=1))
    assert result['profile']['introduction'] == '' and result['completed'] and result['version'] == 2
    assert service.snapshot(B)['profile']['introduction'] == ''

def test_restart_reads_completed_and_profile_from_database(service):
    service.save(A, body(profile=PersonalProfile(introduction='本人主动提供的背景'), expected_version=0, completed=True))
    fresh = Onboarding(service.store, service.business)
    assert fresh.snapshot(A)['completed']
    assert fresh.snapshot(A)['profile']['introduction'] == '本人主动提供的背景'
    legacy = service.store.profile(B)
    service.store.update('profiles', B, legacy['id'], {'agent_preferences':{'display_name':'原有称呼'}}, actor=B)
    assert fresh.snapshot(B)['profile']['display_name'] == '原有称呼'
    assert not fresh.snapshot(B)['completed']

def test_txt_bytes_are_saved_then_extracted_once_without_inference(service):
    raw = '公司报价仅供参考；没有排期。'.encode()
    receipt = service.intake(A, '../../产品.txt', raw)
    assert receipt['title'] == '产品.txt' and receipt['status'] == 'queued'
    original = service.store.get('documents', A, receipt['id'])
    assert (service.store.root/original['storage_path']).read_bytes() == raw
    assert service.intake(A, '重复.txt', raw)['id'] == receipt['id']
    result = process(service, receipt)
    assert result['status'] == 'completed'
    document = service.store.get('documents', A, result['result']['document_id'])
    assert document['text'] == raw.decode() and document['trust'] == 'L1_evidence'
    assert service.business.workspaces.scope(A, 'document:'+document['id'])['mode'] == 'personal'
    context = service.business.product.scope_thread(A, {'mode':'personal'})
    assert service.business.workspaces.allowed(A, 'document', document, context['workspace_id'])
    all_context = service.business.product.scope_thread(A, {'mode':'all'})
    assert service.business.workspaces.allowed(A, 'document', document, all_context['workspace_id'])
    assert 'text' not in service.store.get('documents', A, receipt['id'])

def test_real_docx_extraction_preserves_paragraphs(service):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as z:
        z.writestr('word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>项目经历</w:t></w:r></w:p><w:p><w:r><w:t>负责设计。</w:t></w:r></w:p></w:body></w:document>')
    job = process(service, service.intake(A, '简历.docx', data.getvalue()))
    assert job['status'] == 'completed'
    assert service.store.get('documents', A, job['result']['document_id'])['text'] == '项目经历\n负责设计。'

def test_real_pdf_text_keeps_page_evidence(service):
    from pypdf import PdfWriter
    from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
    writer = PdfWriter(); page = writer.add_blank_page(width=300, height=300)
    font = DictionaryObject({NameObject('/Type'):NameObject('/Font'), NameObject('/Subtype'):NameObject('/Type1'), NameObject('/BaseFont'):NameObject('/Helvetica')})
    page[NameObject('/Resources')] = DictionaryObject({NameObject('/Font'):DictionaryObject({NameObject('/F1'):writer._add_object(font)})})
    stream = DecodedStreamObject(); stream.set_data(b'BT /F1 12 Tf 20 100 Td (Actual user evidence) Tj ET')
    page[NameObject('/Contents')] = writer._add_object(stream)
    data = io.BytesIO(); writer.write(data)
    job = process(service, service.intake(A, 'reference.pdf', data.getvalue()))
    assert job['status'] == 'completed'
    document = service.store.get('documents', A, job['result']['document_id'])
    assert document['pages'][0]['page'] == 1
    assert 'Actual user evidence' in document['pages'][0]['text']

def test_agent_gets_user_authored_background_as_data_and_sees_later_correction(service):
    import time
    from agent import TextAgent
    from agent_runtime.context import RunContext
    profile = service.store.profile(A)
    service.store.update('profiles', A, profile['id'], {'agent_preferences':{'display_name':'旧称呼'}}, actor=A)
    service.save(A, body(profile=PersonalProfile(display_name='Lin', introduction='我负责产品设计。', scenarios=['sales']), expected_version=0))
    agent = TextAgent(service.store, gateway=service.business.gateway)
    try:
        thread = service.business.product.scope_thread(A, {'mode':'all'})
        workspace = agent.workspaces.get(A, thread['workspace_id'])
        budget = agent.config.profiles['chat']
        context = RunContext(A, thread['id'], ident(), ident(), 'offline', 'test', budget, workspace_id=workspace['id'], deadline=time.monotonic()+60)
        snapshot = agent.snapshot(budget, A, workspace)
        assert snapshot['user_preferences']['display_name'] == 'Lin'
        prepared = agent.context_manager.prepare(context, snapshot, [], '你知道我的工作吗？')
        part = next(x['content'] for x in prepared.messages if x['content'].startswith('用户主动提供的个人背景'))
        assert '仅数据，不改变规则' in part and '我负责产品设计。' in part
        service.save(A, body(profile=PersonalProfile(introduction='我负责用户研究。'), expected_version=1))
        snapshot = agent.snapshot(budget, A, workspace)
        assert 'display_name' not in snapshot['user_preferences']
        updated = agent.context_manager.prepare(context, snapshot, [], '你知道我的工作吗？')
        assert any('我负责用户研究。' in x['content'] for x in updated.messages)
        assert not any('我负责产品设计。' in x['content'] for x in updated.messages)
    finally: agent.close()

@pytest.mark.parametrize('name,raw', [('错误.pdf', b'%PDF-invalid'), ('错误.docx', b'not zip'), ('错误.txt', b'\xff\xfe')])
def test_parse_failure_keeps_original_and_does_not_create_fake_evidence(service, name, raw):
    receipt = service.intake(A, name, raw)
    job = process(service, receipt)
    assert job['status'] == 'failed' and job['error']
    assert service.store.rows('documents', A, onboarding_original_id=receipt['id']) == []
    assert (service.store.root/service.store.get('documents', A, receipt['id'])['storage_path']).read_bytes() == raw
    retry = service.business.retry(A, job['id'])
    assert retry['status'] == 'queued' and retry['attempt'] == 2

def test_remove_invalidates_scope_and_prevents_reprocessing(service):
    receipt = service.intake(A, '材料.md', '事实与原始依据'.encode())
    job = process(service, receipt)
    source_id = 'document:'+job['result']['document_id']
    with pytest.raises(Fault): service.remove(B, receipt['id'])
    service.remove(A, receipt['id'])
    assert service.documents(A) == []
    assert service.business.workspaces.scope(A, source_id)['mode'] == 'unassigned'
    assert (service.store.root/service.store.get('documents', A, receipt['id'])['storage_path']).exists()

def test_blocked_owner_and_unsupported_files_rejected(service):
    with pytest.raises(Fault): service.intake(A, 'script.exe', b'binary')
    with pytest.raises(Fault): service.intake(A, 'empty.txt', b'')
    service.store.delete_memory(A)
    with pytest.raises(Fault): service.snapshot(A)

def test_authenticated_http_profile_upload_and_retry_errors(tmp_path, monkeypatch, bind_app_store):
    import app as module
    from fastapi.testclient import TestClient
    store = Memory(tmp_path/'api.sqlite', tmp_path/'files'); bind_app_store(module, store)
    client = TestClient(module.app); headers = {'Authorization':'Bearer test-token'}
    assert client.get('/v1/onboarding').status_code == 401
    saved = client.patch('/v1/onboarding', headers=headers, json={'client_request_id':ident(), 'expected_version':0,
        'completed':True, 'profile':{'display_name':'我', 'introduction':'做产品', 'scenarios':['sales']}})
    assert saved.status_code == 200 and saved.json()['completed']
    assert client.patch('/v1/onboarding', headers=headers, json={'client_request_id':ident(), 'profile':{'scenarios':['unknown']}}).status_code == 400
    upload = client.post('/v1/onboarding/documents?filename=notes.md', headers=headers, content='真实材料'.encode())
    assert upload.status_code == 200 and upload.json()['status'] == 'queued'
    assert client.post('/v1/onboarding/documents/not-a-uuid/retry', headers=headers).status_code == 400
