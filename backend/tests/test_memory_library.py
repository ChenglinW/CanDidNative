from pathlib import Path
import sys,hashlib,io
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import pytest
from fastapi.testclient import TestClient
from memory import Memory,L1,L2,ident
from memory_library import Library,union_ms,Edit
from adapters.sources import version
from companion import Companion
A='11111111-1111-4111-8111-111111111111'
H={'Authorization':'Bearer test-token'}
@pytest.fixture
def lib(tmp_path,bind_app_store):
 import app
 store=Memory(tmp_path/'memory.sqlite3',tmp_path/'files');bind_app_store(app,store)
 library=app.library_service()
 return library,TestClient(app.app),app

def asset(lib,**patch):
 row=lib.store.put('assets',A,{'title':'客户常问什么','body':{'text':'先确认需求'},'companion_expression':True,'tags':['需要改善'],'version':1,'status':'draft','evidence_refs':[],'producer':'test','rubric_version':'test',**patch},L2,source='ai')
 lib.migrate(A);return row['id']
def run(lib,kind,obj,revision='1',payload=None):
 job=lib.business.submit(A,kind,obj,revision,payload)
 lib.business.run(A,job)
 return lib.store.get('business_jobs',A,job['id'])

def test_migration_idempotent_and_versions(lib):
 l,c,app=lib;id=asset(l)
 l.migrate(A);assert len(l.store.rows('library_items',A))==1
 edited=c.patch('/v1/library/items/'+id,headers=H,json={'expected_version':1,'text':'我的新说法'}).json()
 assert edited['expression_state']=='reusable' and edited['evidence_state']=='missing' and edited['effect_state']=='untried'
 assert edited['history'][0]['text']=='先确认需求'
 assert c.patch('/v1/library/items/'+id,headers=H,json={'expected_version':1,'text':'覆盖'}).status_code==409
 assert c.get('/v1/library/items/'+ident(),headers=H).status_code==404

def test_mock_real_model_boundary_and_idempotency(lib,monkeypatch):
 l,c,app=lib;id=asset(l)
 monkeypatch.setattr(l.business,'structured',lambda *a,**k:{'feedback':'先说结论','next_question':'依据是什么？','suggested_text':'先确认范围'})
 req=ident();body={'client_request_id':req,'answer':'我先解释一下背景'}
 p=c.post('/v1/library/items/'+id+'/practice',headers=H,json=body).json()
 job=l.store.get('business_jobs',A,p['job_id']);l.business.run(A,job)
 p2=c.post('/v1/library/items/'+id+'/practice',headers=H,json=body).json()
 assert p2['id']==p['id']
 stored=l.store.get('library_practices',A,p['id']);assert len(stored['turns'])==1
 assert l.item(A,id)['effect_state']=='untried' and not l.store.rows('library_uses',A)
 assert not l.metrics(A)['sessions']

def test_ocr_hash_pages_resume_and_partial(lib):
 l,c,app=lib
 r=l.onboarding.intake(A,'scan.png',b'fake-image',True)
 body={'sha256':hashlib.sha256(b'fake-image').hexdigest(),'pages':[{'page':1,'text':'交付周期三周','review_required':True}]}
 assert c.post('/v1/library/documents/'+r['id']+'/ocr',headers=H,json={**body,'sha256':'wrong'}).status_code==409
 reply=c.post('/v1/library/documents/'+r['id']+'/ocr',headers=H,json=body).json()
 l.business.run(A,l.store.get('business_jobs',A,reply['job_id']))
 docs=l.documents(A);assert docs[0]['text'].endswith('交付周期三周') and docs[0]['pages'][0]['review_required']
 c.post('/v1/library/documents/'+r['id']+'/ocr',headers=H,json=body)
 assert len(l.store.rows('document_ocr',A))==1
 assert len(l.store.rows('documents',A,onboarding_original_id=r['id']))==1

def test_mixed_pdf_requires_every_page(lib):
 from pypdf import PdfWriter
 l,c,app=lib;w=PdfWriter();w.add_blank_page(100,100);w.add_blank_page(100,100);b=io.BytesIO();w.write(b);raw=b.getvalue()
 r=l.onboarding.intake(A,'mixed.pdf',raw,True)
 body={'sha256':hashlib.sha256(raw).hexdigest(),'pages':[{'page':1,'text':'第一页'}]}
 assert c.post('/v1/library/documents/'+r['id']+'/ocr',headers=H,json=body).status_code==422
 body['pages'].append({'page':2,'text':'','review_required':True})
 assert c.post('/v1/library/documents/'+r['id']+'/ocr',headers=H,json=body).status_code==200

def document(l,name,text):
 r=l.onboarding.intake(A,name,text.encode());job=l.store.rows('business_jobs',A,kind='onboarding_document',object_id=r['id'])[0];l.business.run(A,job)
 return r['id'],l.store.rows('documents',A,onboarding_original_id=r['id'])[0]

def test_document_sync_preserves_user_and_scope(lib,monkeypatch):
 l,c,app=lib;old,doc=document(l,'old.txt','交付约两周');new,newdoc=document(l,'new.txt','交付约三周')
 id=asset(l,evidence_refs=[{'source_id':'document:'+doc['id'],'source_version':version(doc)}],user_edited=True)
 monkeypatch.setattr(l.business,'structured',lambda *a,**k:{'changes':['两周改三周'],'answers':[{'id':id,'text':'交付约三周','quote':'交付约三周','conflict':False}]})
 job=l.replace(A,old,new);l.business.run(A,job)
 assert l.store.get('business_jobs',A,job['id'])['status']=='completed'
 item=l.item(A,id);assert item['text']=='先确认需求' and item['suggested_text']=='交付约三周' and item['evidence_state']=='changed'
 assert l.adapter.references_status(A,[{'source_id':'document:'+doc['id'],'source_version':version(doc)}])[0]['status']!='current'
 assert len(l.documents(A))==1 and l.documents(A)[0]['version']==2
 assert l.spaces.scope(A,'document:'+newdoc['id'])['mode']=='personal'

def test_metrics_weighted_nonoverlap_revision_dedupe(lib):
 l,c,app=lib
 for i in range(7):
  sid=l.store.create_session(A,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'test','scenario':'sales'})['id']
  l.store.put('session_media',A,{'session_id':sid,'sha256':str(i if i<6 else 0)},L1)
  l.store.put('transcript_segments',A,{'session_id':sid,'speaker':'self','speaker_id':'part0:0','start_ms':0,'end_ms':60000,'text':'中文测试嗯','transcript_revision':1},L1)
  l.store.put('transcript_segments',A,{'session_id':sid,'speaker':'other','speaker_id':'part1:0','start_ms':60000,'end_ms':120000,'text':'不应计入本人','transcript_revision':1},L1)
 m=l.metrics(A);assert len(m['sessions'])==6 and m['baseline']['count']==3 and m['recent']['count']==3
 assert m['recent']['share']==50 and m['recent']['pace']==5 and m['recent']['filler_rate']==1
 assert union_ms([{'start_ms':0,'end_ms':100},{'start_ms':50,'end_ms':150}])==150

def test_private_faq_not_visible_in_other_customer(lib):
 l,c,app=lib;a=l.spaces.create(A,'A','',ident());b=l.spaces.create(A,'B','',ident());id=asset(l,workspace_id=a['id'])
 assert l.spaces.allowed(A,'faq',l.item(A,id),a['id'])
 assert not l.spaces.allowed(A,'faq',l.item(A,id),b['id'])

def test_user_edit_during_sync_not_overwritten(lib,monkeypatch):
 l,c,app=lib;old,doc=document(l,'a.txt','旧事实');new,nd=document(l,'b.txt','新事实');id=asset(l,evidence_refs=[{'source_id':'document:'+doc['id'],'source_version':version(doc)}])
 def model(*args,**kwargs):
  l.edit(A,id,Edit(expected_version=1,text='用户刚修改的'))
  return {'changes':['事实变化'],'answers':[{'id':id,'text':'新事实','quote':'新事实'}]}
 monkeypatch.setattr(l.business,'structured',model);job=l.replace(A,old,new);l.business.run(A,job)
 assert l.item(A,id)['text']=='用户刚修改的'

def test_extraction_revision_dedup_and_generic_method_scope(lib,monkeypatch):
 l,c,app=lib;space=l.spaces.create(A,'客户私名','',ident());other=l.spaces.create(A,'另一个客户','',ident())
 s=l.store.create_session(A,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'v1'})
 l.store.update('sessions',A,s['id'],{'customer_confirmed_at':'2026-10-16T00:00:00+00:00','customer_workspace_id':space['id'],'transcript_revision':1})
 r=l.store.put('transcript_segments',A,{'session_id':s['id'],'speaker':'self','start_ms':0,'end_ms':3000,'text':'您关心价格还是交付？','transcript_revision':1},L1)
 monkeypatch.setattr(l.business,'structured',lambda *a,**k:{'items':[{'question':'价格怎么说？','answer':'先确认需求','topic':'价格与政策','segment_ids':[r['id']],'general_method':True}]})
 j=run(l,'library_extract',s['id']);assert j['status']=='completed'
 l.snapshot(A);rows=l.store.rows('library_items',A);assert len(rows)==2
 generic=next(x for x in rows if x.get('general_key'));specific=next(x for x in rows if x.get('faq_key'))
 assert l.spaces.allowed(A,'faq',generic,other['id']) and not l.spaces.allowed(A,'faq',specific,other['id'])
 assert generic['evidence_refs']==[] and '客户私名' not in generic['text']
 run(l,'library_extract',s['id']);assert len(l.store.rows('library_items',A))==2

def test_ocr_revision_supersedes_only_previous_extraction(lib):
 l,c,app=lib;r=l.onboarding.intake(A,'scan.png',b'img',True);digest=hashlib.sha256(b'img').hexdigest()
 for text in ['部分内容','修复后的完整内容']:
  reply=c.post('/v1/library/documents/'+r['id']+'/ocr',headers=H,json={'sha256':digest,'pages':[{'page':1,'text':text}]}).json()
  l.business.run(A,l.store.get('business_jobs',A,reply['job_id']))
 docs=l.store.rows('documents',A,onboarding_original_id=r['id']);assert len(docs)==2
 assert l.documents(A)[0]['text'].endswith('修复后的完整内容')
 assert l.adapter.resolve(A,'document:'+docs[-1]['id'])[1]['status']=='superseded'

def test_expired_saying_is_historical_not_agent_fact(lib):
 l,c,app=lib;id=asset(l)
 l.edit(A,id,Edit(expected_version=1,text='活动价只适用于过去',valid_until='2020-01-01T00:00:00+00:00'))
 assert l.item(A,id)['evidence_state']=='expired'
 assert l.adapter.resolve(A,'faq:'+id)[1]['text']=='活动价只适用于过去'
 result=l.adapter.search(A,'活动价',workspace_id=Companion(l.store).thread(A)['workspace_id'])
 assert not any(x['source_id']=='faq:'+id for x in result['items'])

def test_mock_binds_submitted_version_even_if_user_edits(lib,monkeypatch):
 l,c,app=lib;id=asset(l);p=l.practice(A,id,ident(),'我的回答')
 l.edit(A,id,Edit(expected_version=1,text='第二版说法'))
 monkeypatch.setattr(l.business,'structured',lambda *a,**k:{'feedback':'练习反馈','next_question':'下一问','suggested_text':'可以改成这样'})
 l.business.run(A,l.store.get('business_jobs',A,p['job_id']))
 assert l.store.get('library_practices',A,p['id'])['turns'][0]['answer_version']==1

def test_removed_document_invalidates_derived_answer(lib):
 l,c,app=lib;original,doc=document(l,'policy.txt','价格依书面报价')
 id=asset(l,evidence_refs=[{'source_id':'document:'+doc['id'],'source_version':version(doc)}])
 assert l.item(A,id)['evidence_state']=='ready';l.onboarding.remove(A,original)
 assert l.item(A,id)['evidence_state']=='changed'
 assert c.get('/v1/library/documents/'+original+'/file',headers=H).status_code==404

def test_library_backfill_leaves_capacity_for_new_recording(lib,monkeypatch):
 l,c,app=lib;captured=[]
 monkeypatch.setattr(l.business.pools['background'],'submit',lambda fn,owner,job:captured.append(job['kind']))
 l.business.submit(A,'library_extract',ident());l.business.submit(A,'library_extract',ident())
 l.business.handlers['recording_priority']=lambda owner,job:{}
 l.business.submit(A,'recording_priority',ident())
 l.business.tick()
 assert captured==['recording_priority','library_extract']
 assert len(l.business.running)==2
