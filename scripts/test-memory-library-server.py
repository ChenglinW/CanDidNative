"""Loopback-only native memory acceptance server with isolated synthetic data.

Run with backend/.venv/bin/python scripts/test-memory-library-server.py.
No vendor model/embedding or production database is used.
"""
import os,sys,json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
for key in ('DEEPSEEK_API_KEY','ANKER_AI_API_KEY','DASHSCOPE_API_KEY','MONID_API_KEY'):os.environ.pop(key,None)
os.environ.update(CANDID_DATA_DIR=os.getenv('CANDID_LIBRARY_TEST_DATA_DIR',str(root/'.build/memory-merge/http-data')),CANDID_AUTH_MODE='local',CANDID_DEVICE_AUTH='0',CANDID_LOCAL_TOKEN='candid-v2-local-acceptance',CANDID_SPEECH_ENABLED='0')
sys.path.insert(0,str(root/'backend'))
import app
from types import SimpleNamespace
from memory import L1,L2,ident,now
from adapters.sources import version
owner=app.LOCAL_OWNER
lib=app.library_service()
def complete(messages,**kwargs):
 text='请先核对这段原文，再确认适用范围与下一步。'
 if kwargs.get('on_delta'):kwargs['on_delta'](text)
 return {'role':'assistant','content':text}
gateway=SimpleNamespace(configured=True,model='synthetic-memory-acceptance',base='https://test.invalid',complete=complete)
app.agent.gateway=gateway
app.agent.context_manager.gateway=gateway
app.agent.context_manager.summaries.gateway=gateway
app.business.gateway=gateway
# Network model boundaries are deterministic; no vendor credentials are loaded.
app.business.structured=lambda *a,**k:{'feedback':'先确认需求这个方向很好；下一次请补上明确的下一步。','next_question':'接下来你会怎么做？','suggested_text':'先确认需求，再明确下一步。','changes':['交期更新为四周'],'answers':[],'items':[],'title':'预算与交期','summary':'这一段讨论了预算和交期，需要核对范围。','topics':['需求','待核实'],'suggestion':'请核对原文与适用范围。'}
lib.grouping.encoder_factory=lambda:type('E',(),{'encode':lambda self,texts:[[1,0] if '价格' in t else [0,1] for t in texts]})()
p=app.store.profile(owner)
app.store.update('profiles',owner,p['id'],{'product_use_consent_at':now(),'onboarding_completed_at':now(),'timezone':'Asia/Shanghai','onboarding_profile':{'display_name':'隔离测试','introduction':'合成资料','scenarios':['sales','interview']}},actor=owner)
if not app.store.rows('library_items',owner):
 doc=lib.onboarding.intake(owner,'门店交付说明.txt','当前交付三周。价格以门店书面报价为准。'.encode())
 app.business.run(owner,app.store.get('business_jobs',owner,doc['job_id']))
 parsed=app.store.rows('documents',owner,onboarding_original_id=doc['id'])[0]
 for scenario,title,text in [('sales','价格怎么解释？','先确认配置与适用范围。'),('interview','请介绍你的项目经历','先说明我的职责，再讲行动。')]:
  row=app.store.put('library_items',owner,{'title':title,'text':text,'topic':'价格与政策' if scenario=='sales' else '经历与故事','scenario':scenario,'item_type':'faq','version':1,'status':'active','expression_state':'improve','user_edited':False,'evidence_refs':[{'source_id':'document:'+parsed['id'],'source_version':version(parsed)}],'producer':'acceptance/synthetic','rubric_version':'acceptance@1'},L2,source='ai')
  lib.spaces.set_scope(owner,'faq:'+row['id'],'personal',[],0)
 for i in range(6):
  sid=app.store.create_session(owner,{'client_request_id':ident(),'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'synthetic'})['id']
  app.store.put('session_media',owner,{'session_id':sid,'sha256':'synthetic-'+str(i)},L1)
  app.store.put('transcript_segments',owner,{'session_id':sid,'speaker':'self','speaker_id':'0','text':'先确认需求嗯','start_ms':0,'end_ms':10000,'transcript_revision':1},L1)
  app.store.put('transcript_segments',owner,{'session_id':sid,'speaker':'other','speaker_id':'1','text':'谢谢','start_ms':10000,'end_ms':20000,'transcript_revision':1},L1)
if not app.store.rows('sessions',owner,title='逐句回听验收录音'):
 import wave
 sid=app.store.create_session(owner,{'client_request_id':ident(),'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'synthetic'})['id']
 app.store.update('sessions',owner,sid,{'title':'逐句回听验收录音','duration_ms':60000,'transcript_revision':1,'pipeline_status':'done','llm_consent_at':now()})
 for start,end,text in [(0,12000,'预算是二十万元，什么时候交付？'),(13000,35000,'我先核对交付资料，下次再确认。')]:
  app.store.put('transcript_segments',owner,{'session_id':sid,'speaker':'unknown','speaker_id':'0','text':text,'start_ms':start,'end_ms':end,'transcript_revision':1},L1)
 folder=app.store.root/owner;folder.mkdir(parents=True,exist_ok=True)
 audio=folder/(sid+'.wav')
 with wave.open(str(audio),'wb') as sound:
  sound.setnchannels(1);sound.setsampwidth(2);sound.setframerate(8000);sound.writeframes(b'\0\0'*8000*60)
 app.store.put('session_media',owner,{'session_id':sid,'storage_path':owner+'/'+audio.name,'mime':'audio/wav','sha256':'synthetic-silence'},L1)
 app.store.put('marks',owner,{'session_id':sid,'t_ms':10000,'user_label':'unlabeled'},L1)
 job=app.recordings.marks.queue(owner,sid)
 if job:app.business.run(owner,job)
# A stale citation must still lead to the current family and its original-file history.
if not app.store.rows('library_items',owner,title='历史依据如何核对？'):
 originals=[]
 for title,text in [('历史依据旧版.txt','旧资料交期两周。'),('历史依据新版.txt','新资料交期四周。')]:
  receipt=lib.onboarding.intake(owner,title,text.encode())
  app.business.run(owner,app.store.get('business_jobs',owner,receipt['job_id']))
  originals.append((receipt,app.store.rows('documents',owner,onboarding_original_id=receipt['id'])[0]))
 job=lib.replace(owner,originals[0][0]['id'],originals[1][0]['id']);app.business.run(owner,job)
 row=app.store.put('library_items',owner,{'title':'历史依据如何核对？','text':'先核对最新交期。','topic':'交付与服务','scenario':'sales','item_type':'faq','version':1,'status':'active','expression_state':'improve','evidence_refs':[{'source_id':'document:'+originals[0][1]['id'],'source_version':version(originals[0][1])}],'producer':'acceptance/synthetic','rubric_version':'acceptance@1'},L2,source='ai')
 lib.spaces.set_scope(owner,'faq:'+row['id'],'personal',[],0)
if __name__=='__main__':
 import uvicorn
 uvicorn.run(app.app,host='127.0.0.1',port=8897,log_level='warning')
