"""Acceptance for transient annotation and unchanged downstream contracts."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from types import SimpleNamespace
import pytest
from memory import Memory, L1, ident
from adapters.sources import version
from transcript_enrichment import enhance_transcript, NUMBER_NOTE, GENERAL_NOTE

OWNER='11111111-1111-4111-8111-111111111111'

@pytest.fixture
def context(tmp_path,bind_app_store,monkeypatch):
 import app
 store=Memory(tmp_path/'db.sqlite',tmp_path/'files');bind_app_store(app,store)
 app.business.gateway=SimpleNamespace(configured=True,model='test')
 app.library_service()
 session=store.create_session(OWNER,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'v1'})
 store.update('sessions',OWNER,session['id'],{'transcript_revision':1,'llm_consent_at':'2026-10-16T00:00:00Z'})
 yield app,session['id']
 store.db.close()

def line(app,sid,text,start=0,end=10000,revision=1):
 return app.store.put('transcript_segments',OWNER,{'session_id':sid,'transcript_revision':revision,'speaker':'self','speaker_id':'self','start_ms':start,'end_ms':end,'text':text},L1)

def mark(app,sid,t):
 return app.store.put('marks',OWNER,{'session_id':sid,'t_ms':t},L1)

def test_numeric_attention_does_not_rewrite_evidence_or_unmarked_text(context):
 app,sid=context
 raw=line(app,sid,'预算二十万元，先订300台，折扣3.5%，比例百分之三十，下个月十五号再确认。')
 other=line(app,sid,'远处的预算是99万元。',150000,160000)
 mark(app,sid,10000);mark(app,sid,11000)
 original_version=version(raw)
 prepared=enhance_transcript(app.store,OWNER,sid,[raw,other])
 assert prepared[0]['text'].replace(NUMBER_NOTE,'')==raw['text']
 for token in ['二十万元','300台','3.5%','百分之三十','十五号']:
  assert token+NUMBER_NOTE in prepared[0]['text']
 assert prepared[0]['text'].count(NUMBER_NOTE)==5
 assert prepared[1]==other and prepared[1] is not other
 assert app.store.get('transcript_segments',OWNER,raw['id'])['text']==raw['text']
 assert version(app.store.get('transcript_segments',OWNER,raw['id']))==original_version
 assert prepared[0]['id']==raw['id'] and prepared[0]['start_ms']==raw['start_ms']

def test_generic_attention_hidden_and_revised_sources_are_read_fresh(context):
 app,sid=context
 raw=line(app,sid,'我们先统一一下，再一起沟通。')
 m=mark(app,sid,5000)
 assert enhance_transcript(app.store,OWNER,sid,[raw])[0]['text']==raw['text']+GENERAL_NOTE
 app.store.update('sessions',OWNER,sid,{'hidden_mark_ids':[m['id']]})
 assert enhance_transcript(app.store,OWNER,sid,[raw])==[raw]
 app.store.update('sessions',OWNER,sid,{'hidden_mark_ids':[],'transcript_revision':2})
 revised=line(app,sid,'预算改为30万元。',revision=2)
 prepared=enhance_transcript(app.store,OWNER,sid,app.recordings.segments(OWNER,sid))
 assert len(prepared)==1 and '30万元'+NUMBER_NOTE in prepared[0]['text']
 assert prepared[0]['id']==revised['id'] and raw['text'] not in prepared[0]['text']
 # Foreign marks cannot annotate this session, and annotations are never persisted.
 foreign=app.store.create_session(OWNER,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'v1'})
 f=line(app,foreign['id'],'预算50万元。')
 assert enhance_transcript(app.store,OWNER,foreign['id'],[f])==[f]
 assert not app.store.rows('personal_memories',OWNER)

def test_existing_review_and_faq_receive_prepared_text_but_cite_original(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'客户问：预算20万元够吗？');mark(app,sid,5000)
 calls=[]
 def model(prompt,payload,**kwargs):
  calls.append((prompt,payload))
  assert 'user_marks_ms' not in payload and 'user_marks_ms' not in prompt
  assert '标记' not in prompt
  assert '20万元'+NUMBER_NOTE in payload['segments'][0]['text']
  if 'summary' in prompt:
   return {'title':'预算沟通','summary':'客户询问二十万元预算是否足够。','expressions':[{'title':'确认范围','text':'先核对范围','quote':raw['text'],'segment_id':raw['id'],'kind':'值得复用'}]}
  return {'items':[{'question':'20万元预算够吗？','answer':'先核对范围。','topic':'需求与场景','segment_ids':[raw['id']],'used_text':raw['text']}]}
 monkeypatch.setattr(app.business,'structured',model)
 j=app.business.submit(OWNER,'recording_knowledge',sid,'1');app.business.run(OWNER,j)
 assert app.store.get('business_jobs',OWNER,j['id'])['status']=='completed'
 job=next(j for j in app.store.rows('business_jobs',OWNER) if j['kind']=='library_extract')
 app.business.run(OWNER,job)
 assert app.store.get('business_jobs',OWNER,job['id'])['status']=='completed'
 assert len(calls)==2
 for record in app.store.rows('recording_knowledge',OWNER)+app.store.rows('library_items',OWNER):
  for ref in record.get('evidence_refs',[]):
   if ref['source_id']=='transcript:'+raw['id']:assert ref['source_version']==version(raw)
 assert app.store.get('transcript_segments',OWNER,raw['id'])['text']==raw['text']
 assert app.store.rows('library_uses',OWNER)[0]['text']==raw['text']
 assert app.store.rows('personal_memories',OWNER)==[]


def test_cross_session_discovery_uses_same_front_step_without_changing_identity(context,monkeypatch):
 app,sid=context
 first=line(app,sid,'我先确认20万元的范围。');mark(app,sid,5000)
 second=app.store.create_session(OWNER,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'v1'})
 other=line(app,second['id'],'我先确认对方关心什么。')
 captured=[]
 def model(prompt,payload,**kwargs):
  captured.append(payload)
  assert '标记' not in prompt
  evidence=payload['evidence']
  assert any(NUMBER_NOTE in r['text'] for r in evidence)
  assert next(r['text'] for r in evidence if r['session_id']==second['id'])==other['text']
  return {'items':[]}
 monkeypatch.setattr(app.business,'structured',model)
 job=app.business.submit(OWNER,'companion_discovery',sid,'1');app.business.run(OWNER,job)
 assert app.store.get('business_jobs',OWNER,job['id'])['status']=='completed' and captured
 assert app.store.get('transcript_segments',OWNER,first['id'])['text']==first['text']
 assert not app.store.rows('personal_memories',OWNER)
