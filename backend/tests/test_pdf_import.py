"""Real PDF bytes through both intake paths; isolated database and no provider calls."""
import io,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from types import SimpleNamespace
import pytest
from pypdf import PdfWriter
from pypdf.generic import DictionaryObject,NameObject,DecodedStreamObject
from memory import Memory,Fault,ident
from tasks.business import BusinessJobs
from tasks.workspaces import WorkspaceStore
from tasks.materials import Materials
from onboarding import Onboarding

OWNER='11111111-1111-4111-8111-111111111111'

def pdf_bytes(password=None,prefix=b'',blank=False):
    writer=PdfWriter();page=writer.add_blank_page(width=300,height=300)
    if not blank:
        font=DictionaryObject({NameObject('/Type'):NameObject('/Font'),NameObject('/Subtype'):NameObject('/Type1'),NameObject('/BaseFont'):NameObject('/Helvetica')})
        page[NameObject('/Resources')]=DictionaryObject({NameObject('/Font'):DictionaryObject({NameObject('/F1'):writer._add_object(font)})})
        stream=DecodedStreamObject();stream.set_data(b'BT /F1 12 Tf 20 100 Td (PDF upload regression evidence) Tj ET')
        page[NameObject('/Contents')]=writer._add_object(stream)
    if password is not None:writer.encrypt(password,owner_password='owner-only-test-password')
    raw=io.BytesIO();writer.write(raw);return prefix+raw.getvalue()

@pytest.fixture
def intake(tmp_path):
    store=Memory(tmp_path/'db.sqlite',tmp_path/'files');spaces=WorkspaceStore(store)
    jobs=BusinessJobs(store,SimpleNamespace(model='offline',configured=False,base='https://offline.invalid'),spaces)
    onboarding=Onboarding(store,jobs);materials=Materials(store,spaces)
    workspace=spaces.create(OWNER,'PDF regression','',ident())
    yield store,jobs,onboarding,materials,workspace
    jobs.close();store.db.close()

@pytest.mark.parametrize('path',['personal','project'])
def test_openable_permission_encrypted_pdf_is_readable(intake,path):
    store,jobs,onboarding,materials,space=intake;raw=pdf_bytes(password='')
    if path=='personal':
        receipt=onboarding.intake(OWNER,'readable.pdf',raw)
        jobs.run(OWNER,store.get('business_jobs',OWNER,receipt['job_id']))
        job=store.get('business_jobs',OWNER,receipt['job_id'])
        assert job['status']=='completed',job.get('error')
        document=store.get('documents',OWNER,job['result']['document_id'])
    else:document=materials.save(OWNER,space['id'],'readable',raw=raw)
    assert 'PDF upload regression evidence' in document['text']
    assert document['pages'][0]['page']==1

@pytest.mark.parametrize('path',['personal','project'])
def test_pdf_with_bom_prefix_keeps_evidence(intake,path):
    store,jobs,onboarding,materials,space=intake;raw=pdf_bytes(prefix=b'\xef\xbb\xbf\n')
    if path=='personal':
        receipt=onboarding.intake(OWNER,'bom.pdf',raw);jobs.run(OWNER,store.get('business_jobs',OWNER,receipt['job_id']))
        job=store.get('business_jobs',OWNER,receipt['job_id']);assert job['status']=='completed'
        document=store.get('documents',OWNER,job['result']['document_id'])
    else:document=materials.save(OWNER,space['id'],'bom',raw=raw)
    assert 'PDF upload regression evidence' in document['text']

@pytest.mark.parametrize('path',['personal','project'])
@pytest.mark.parametrize('raw,code,word',[(pdf_bytes(password='open-secret'),'PDF_PASSWORD_REQUIRED','打开密码'),(pdf_bytes(blank=True),'PDF_NO_TEXT','扫描件'),(b'%PDF-broken','PDF_INVALID','PDF')])
def test_unreadable_pdf_has_actionable_error_without_fake_evidence(intake,path,raw,code,word):
    store,jobs,onboarding,materials,space=intake
    if path=='personal':
        receipt=onboarding.intake(OWNER,'needs-help.pdf',raw);jobs.run(OWNER,store.get('business_jobs',OWNER,receipt['job_id']))
        job=store.get('business_jobs',OWNER,receipt['job_id']);assert job['status']=='failed' and word in job['error']
        assert not store.rows('documents',OWNER,onboarding_original_id=receipt['id'])
        original=store.get('documents',OWNER,receipt['id']);assert (store.root/original['storage_path']).read_bytes()==raw
    else:
        with pytest.raises(Fault) as e:materials.save(OWNER,space['id'],'needs-help',raw=raw)
        assert e.value.code==code and word in e.value.message
        assert store.rows('documents',OWNER)==[]

def test_project_pdf_http_upload_stores_page_text_and_respects_scope(tmp_path,bind_app_store):
    import app
    from fastapi.testclient import TestClient
    store=Memory(tmp_path/'http.sqlite',tmp_path/'files');bind_app_store(app,store)
    client=TestClient(app.app);headers={'Authorization':'Bearer test-token'}
    project=app.business.product.create(OWNER,{'name':'PDF upload test','scenario':'interview'},ident())
    other=app.business.product.create(OWNER,{'name':'Other project','scenario':'sales'},ident())
    raw=pdf_bytes(password='')
    path='/v1/materials/pdf?workspace_id='+project['id']+'&title=resume'
    response=client.post(path,headers={**headers,'Content-Type':'application/pdf'},content=raw)
    assert response.status_code==200,response.text
    document=response.json();assert 'PDF upload regression evidence' in document['pages'][0]['text']
    materials=app.agent.materials
    assert materials.search(OWNER,project['id'],'regression',[])['items']
    assert materials.search(OWNER,other['id'],'regression',[])['items']==[]
    assert client.post(path,headers=headers,content=raw).json()['id']==document['id']
    denied=client.post(path,headers=headers,content=pdf_bytes(password='secret'))
    assert denied.status_code==422 and denied.json()['error']['code']=='PDF_PASSWORD_REQUIRED'
    assert client.post(path,content=raw).status_code==401
