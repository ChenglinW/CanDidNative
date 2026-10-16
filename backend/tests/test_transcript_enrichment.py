"""Semantic preparation acceptance; downstream prompts and evidence stay unchanged."""
from pathlib import Path
import sys,ast,hashlib,json,time,threading
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from types import SimpleNamespace
import pytest
from memory import Memory,L1,ident
from adapters.sources import version
from transcript_enrichment import enhance_transcript,PREFIX
OWNER='11111111-1111-4111-8111-111111111111'

@pytest.fixture
def context(tmp_path,bind_app_store):
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
def mark(app,sid,t=5000):return app.store.put('marks',OWNER,{'session_id':sid,'t_ms':t},L1)
def prepared(app,sid,rows=None):
 return enhance_transcript(app.store,OWNER,sid,rows if rows is not None else app.recordings.segments(OWNER,sid),processor=app.recordings.marks)
def answer(raw,text='本轮讨论客户预算与待核对的报价，预算不等于已确认报价。',**extra):
 return {'title':'预算与报价','summary':'讨论了预算和报价，仍需确认。','annotations':[{'anchor_segment_id':raw['id'],'text':text,'evidence':[{'segment_id':raw['id'],'quote':raw['text']}]}],**extra}

def test_semantic_context_one_note_keeps_original_and_filler(context,monkeypatch):
 app,sid=context
 ack=line(app,sid,'嗯。',0,500);raw=line(app,sid,'预算100万，起售价91万8。',1000,10000)
 other=line(app,sid,'远处还有其他安排。',150000,160000);mark(app,sid);mark(app,sid,7000)
 calls=[]
 def model(prompt,payload,**kw):
  calls.append(payload);assert payload['segments'][0]['text']=='嗯。'
  return answer(raw,'100万是客户预算，“91万8”是起售价原表达，落地费用仍待确认。')
 monkeypatch.setattr(app.business,'structured',model)
 out=prepared(app,sid,[ack,raw,other])
 assert out[0]['text']=='嗯。' and out[2]==other
 assert out[1]['text'].startswith(raw['text']+'\n'+PREFIX) and out[1]['text'].count(PREFIX)==1
 assert '91万8' in out[1]['text'] and '注意这个数字' not in out[1]['text']
 assert app.store.get('transcript_segments',OWNER,raw['id'])['text']==raw['text']
 assert version(app.store.get('transcript_segments',OWNER,raw['id']))==version(raw)
 prepared(app,sid);app.recordings.marks.snapshot(OWNER,sid)
 assert len(calls)==1 and not app.store.rows('personal_memories',OWNER)

def test_hidden_and_revised_source_invalidates_only_derived_cache(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'预算20万元。');m=mark(app,sid)
 calls=[]
 def model(prompt,payload,**kw):
  rows=app.recordings.segments(OWNER,sid);calls.append(rows[0]['text']);return answer(rows[0])
 monkeypatch.setattr(app.business,'structured',model)
 assert PREFIX in prepared(app,sid)[0]['text']
 app.recordings.marks.edit(OWNER,sid,m['id'],title='我的标题')
 app.store.update('sessions',OWNER,sid,{'hidden_mark_ids':[m['id']]})
 assert prepared(app,sid)==[raw]
 app.store.update('sessions',OWNER,sid,{'hidden_mark_ids':[],'transcript_revision':2})
 revised=line(app,sid,'预算改为30万元。',revision=2)
 assert PREFIX in prepared(app,sid)[0]['text'] and calls==[raw['text'],revised['text']]
 assert app.recordings.marks.snapshot(OWNER,sid)['items'][0]['title']=='我的标题'
 app.business.gateway.model='new-model';prepared(app,sid);assert len(calls)==3

def test_failed_preparation_falls_back_once_and_manual_retry_works(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'预算20万元。');mark(app,sid);calls=[]
 def fail(*a,**kw):calls.append(1);raise RuntimeError('provider timeout')
 monkeypatch.setattr(app.business,'structured',fail)
 assert prepared(app,sid)==[raw] and prepared(app,sid)==[raw] and len(calls)==1
 state=app.recordings.marks.snapshot(OWNER,sid);assert state['status']=='failed'
 monkeypatch.setattr(app.business,'structured',lambda *a,**kw:answer(raw))
 app.business.retry(OWNER,state['job_id']);assert PREFIX in prepared(app,sid)[0]['text']

@pytest.mark.parametrize('case',['empty','bad_quote','unknown_source','filler','out_of_focus','duplicate'])
def test_unusable_annotations_are_omitted_not_mechanically_replaced(context,monkeypatch,case):
 app,sid=context;raw=line(app,sid,'预算20万元。');ack=line(app,sid,'没问题。',11000,12000)
 far=line(app,sid,'邻近的其他主题。',50000,60000);mark(app,sid)
 result=answer(raw);note=result['annotations'][0]
 if case=='empty':result['annotations']=[]
 if case=='bad_quote':note['evidence'][0]['quote']='并不存在的原文'
 if case=='unknown_source':note['anchor_segment_id']='missing'
 if case=='filler':note['anchor_segment_id']=ack['id']
 if case=='out_of_focus':note['anchor_segment_id']=far['id']
 if case=='duplicate':result['annotations']=[note,dict(note)]
 monkeypatch.setattr(app.business,'structured',lambda *a,**kw:result)
 out=prepared(app,sid)
 assert sum(s['text'].count(PREFIX) for s in out)==(1 if case=='duplicate' else 0)
 assert next(s for s in out if s['id']==ack['id'])['text']==ack['text']

def test_parallel_readers_and_cards_share_one_model_job(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'预算20万元。');mark(app,sid)
 entered=threading.Event();release=threading.Event();calls=[]
 def model(*a,**kw):calls.append(1);entered.set();assert release.wait(3);return answer(raw)
 monkeypatch.setattr(app.business,'structured',model)
 with ThreadPoolExecutor(max_workers=2) as pool:
  a=pool.submit(prepared,app,sid);assert entered.wait(3)
  b=pool.submit(prepared,app,sid);release.set()
  assert PREFIX in a.result(timeout=4)[0]['text'] and PREFIX in b.result(timeout=4)[0]['text']
 assert len(calls)==1 and app.recordings.marks.snapshot(OWNER,sid)['items'][0]['status']=='ready'

def test_no_mark_or_missing_consent_does_not_call_model(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'预算20万元。')
 monkeypatch.setattr(app.business,'structured',lambda *a,**kw:pytest.fail('Unexpected model call'))
 assert prepared(app,sid)==[raw]
 mark(app,sid);app.store.update('sessions',OWNER,sid,{'llm_consent_at':None})
 assert prepared(app,sid)==[raw]

def test_review_faq_and_discovery_use_front_step_without_reinterpreting_mark(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'客户问：预算20万元够吗？');mark(app,sid);calls=[]
 def model(prompt,payload,**kw):
  if 'annotations' in prompt:
   calls.append('prepare');return answer(raw)
  assert '标记' not in prompt and 'user_marks_ms' not in payload
  if 'evidence' in payload:
   assert PREFIX in next(r for r in payload['evidence'] if r['session_id']==sid)['text']
   calls.append('discovery');return {'items':[]}
  assert PREFIX in payload['segments'][0]['text']
  if 'summary' in prompt:
   calls.append('review');return {'title':'预算沟通','summary':'询问预算是否足够。','expressions':[{'title':'确认范围','text':'先核对范围','quote':raw['text'],'segment_id':raw['id'],'kind':'值得复用'}]}
  calls.append('faq');return {'items':[{'question':'20万元预算够吗？','answer':'先核对范围。','topic':'需求与场景','segment_ids':[raw['id']],'used_text':raw['text']}]}
 monkeypatch.setattr(app.business,'structured',model)
 def run(kind,obj=sid):
  job=app.business.submit(OWNER,kind,obj,'1');app.business.run(OWNER,job)
  assert app.store.get('business_jobs',OWNER,job['id'])['status']=='completed'
 run('recording_knowledge');run('library_extract')
 other=app.store.create_session(OWNER,{'client_request_id':ident(),'kind':'live','consent':'yes','consent_ack_text_version':'v1'})
 line(app,other['id'],'我会先核对范围。')
 run('companion_discovery')
 assert calls==['prepare','review','faq','discovery']
 for record in app.store.rows('recording_knowledge',OWNER)+app.store.rows('library_items',OWNER):
  for ref in record.get('evidence_refs',[]):
   if ref['source_id']=='transcript:'+raw['id']:assert ref['source_version']==version(raw)
 assert app.store.rows('library_uses',OWNER)[0]['text']==raw['text']
 assert not app.store.rows('personal_memories',OWNER)


def test_partial_reader_does_not_receive_context_without_evidence(context,monkeypatch):
 app,sid=context;a=line(app,sid,'客户的预算是20万元。');b=line(app,sid,'交期还需要核对。',12000,20000);mark(app,sid)
 result=answer(a);result['annotations'][0]['evidence'].append({'segment_id':b['id'],'quote':b['text']})
 monkeypatch.setattr(app.business,'structured',lambda *a,**kw:result)
 assert prepared(app,sid,[a])==[a]
 assert PREFIX in prepared(app,sid,[a,b])[0]['text']


def test_downstream_prompt_literals_unchanged():
 expected={'backend/tasks/recordings.py': '98c76093a614fbd8eab0b4361e3e829e3d6b5a90abd126e31c1d690b2461018b', 'backend/memory_library.py': 'b3309c995f7e7540a3b06f8881b6922077c3e799e852ea2ac6e7e949fb4c3762'}
 for filename,digest in expected.items():
  path=Path(__file__).resolve().parents[2]/filename
  tree=ast.parse(path.read_text())
  prompts=[n.args[0].value for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and n.func.attr=='structured' and n.args and isinstance(n.args[0],ast.Constant)]
  assert hashlib.sha256(json.dumps(prompts,ensure_ascii=False).encode()).hexdigest()==digest


def test_nearby_marks_with_shared_context_are_analyzed_together(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'预算20万元，报价还需要确认。',0,35000)
 mark(app,sid,10000);mark(app,sid,60000);calls=[]
 def model(prompt,payload,**kw):calls.append(payload);return answer(raw)
 monkeypatch.setattr(app.business,'structured',model)
 assert PREFIX in prepared(app,sid)[0]['text']
 assert len(calls)==1 and calls[0]['times_ms']==[10000,60000]
 assert len(app.recordings.marks.snapshot(OWNER,sid)['items'])==1


def test_non_numeric_concern_gets_contextual_note_without_number_rules(context,monkeypatch):
 app,sid=context;raw=line(app,sid,'客户更关心上线后有没有现场培训。');mark(app,sid)
 note='本轮关注上线后的现场培训安排，原文只是客户需求，尚无服务承诺。'
 monkeypatch.setattr(app.business,'structured',lambda *a,**kw:answer(raw,note))
 result=prepared(app,sid)[0]['text']
 assert result==raw['text']+'\n'+PREFIX+note+'】'
 assert '数字' not in result


@pytest.mark.parametrize('status',['cancelled','interrupted'])
def test_cancelled_preparation_does_not_auto_resubmit_model(context,monkeypatch,status):
 app,sid=context;raw=line(app,sid,'交期还需要核对。');mark(app,sid)
 job=app.recordings.marks.queue(OWNER,sid)
 app.store.update('business_jobs',OWNER,job['id'],{'status':status})
 monkeypatch.setattr(app.business,'structured',lambda *a,**kw:pytest.fail('Should not retry a stopped paid call'))
 assert prepared(app,sid)==[raw]
 assert len(app.store.rows('business_jobs',OWNER,kind='recording_marks'))==1


def test_chunk_reader_omits_notes_whose_support_is_in_another_chunk(context,monkeypatch):
 app,sid=context
 a=line(app,sid,'讨论预算。'*4500,0,5000)
 b=line(app,sid,'后续交期仍待确认。'*200,6000,10000);mark(app,sid)
 result=answer(a);result['annotations'][0]['evidence'].append({'segment_id':b['id'],'quote':'后续交期仍待确认。'})
 reviewed=[]
 def model(prompt,payload,**kw):
  if 'annotations' in prompt:return result
  reviewed.append(payload['segments'])
  assert all(PREFIX not in r['text'] for r in payload['segments'])
  return {'summary':'讨论片段。'}
 monkeypatch.setattr(app.business,'structured',model)
 job=app.business.submit(OWNER,'recording_knowledge',sid,'1');app.business.run(OWNER,job)
 assert app.store.get('business_jobs',OWNER,job['id'])['status']=='completed'
 assert len(reviewed)==2 and all(len(rows)==1 for rows in reviewed)
