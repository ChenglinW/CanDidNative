"""Isolated native acceptance; model boundary is synthetic, no provider calls."""
import os,sys,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
for key in ['DASHSCOPE_API_KEY','ANKER_AI_API_KEY','DEEPSEEK_API_KEY','MONID_API_KEY']:os.environ.pop(key,None)
os.environ.update(CANDID_DATA_DIR=str(ROOT/'.build/roleplay/http-data'),CANDID_AUTH_MODE='local',CANDID_LOCAL_TOKEN='candid-roleplay-acceptance',CANDID_DEVICE_AUTH='0',CANDID_SPEECH_ENABLED='0')
sys.path.insert(0,str(ROOT/'backend'))
import app
from memory import L1,now
from roleplay import COACH,HINT
p=app.store.profile(app.LOCAL_OWNER);app.store.update('profiles',app.LOCAL_OWNER,p['id'],{'product_use_consent_at':now(),'onboarding_completed_at':now(),'onboarding_profile':{'display_name':'演练验收','introduction':'需求分析与试点推进','scenarios':['sales','interview']}},actor=app.LOCAL_OWNER)
class Gateway:
 configured=True;model='roleplay-synthetic';base='https://test.invalid'
 def complete(self,messages,**kwargs):
  body=json.loads(messages[1]['content']);users=[t for t in body.get('conversation',[]) if t['role']=='user']
  if messages[0]['content']==COACH:
   u=users[0];value={'summary':'你先澄清了目标，下一步可以把试点范围问得更具体。','strengths':['先问需求再讨论方案。'],'improvements':[{'turn_id':u['id'],'quote':u['text'],'reason':'把试点范围说具体','suggested_text':'We should confirm the scope and the next step.'}]}
  elif messages[0]['content']==HINT:value={'hint':'先问清范围，再确认下一步由谁参与。'}
  else:value={'reply':'你提到先确认范围。你会先问清哪些条件？' if users else '你希望这次沟通先解决什么问题？','stage':'需求澄清'}
  return {'content':json.dumps(value,ensure_ascii=False)}
app.business.gateway=Gateway()
if not app.store.rows('documents',app.LOCAL_OWNER):
 doc=app.store.put('documents',app.LOCAL_OWNER,{'title':'试点说明','text':'先确认范围与参与人员。'},L1)
 app.agent.workspaces.set_scope(app.LOCAL_OWNER,'document:'+doc['id'],'personal',[],0)
if __name__=='__main__':
 import uvicorn;uvicorn.run(app.app,host='127.0.0.1',port=8898,access_log=False,ws='wsproto')
