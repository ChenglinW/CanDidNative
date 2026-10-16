"""Loopback-only actual FastAPI/SQLite/Agent server with a deterministic model boundary.
Used by native HTTP acceptance; never reads the demo database or private provider keys.
"""
import json,os,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
for key in ('ANKER_AI_API_KEY','DEEPSEEK_API_KEY','DASHSCOPE_API_KEY','MONID_API_KEY'):os.environ.pop(key,None)
os.environ.update(CANDID_DATA_DIR=os.getenv('CANDID_HTTP_TEST_DATA_DIR',str(root/'.build/v2-http-data')),CANDID_AUTH_MODE='local',CANDID_LOCAL_TOKEN='candid-v2-local-acceptance',CANDID_SPEECH_ENABLED='0')
sys.path.insert(0,str(root/'backend'))
import app
from memory import L1,ident,now
from companion import Companion
owner=app.LOCAL_OWNER

class Gateway:
    configured=True;model='deterministic-native-acceptance';base='https://test.invalid'
    def complete(self,messages,tools=True,**kw):
        last=next((m['content'] for m in reversed(messages) if m['role']=='user'),'')
        if tools and '准备' in last and not any(m['role']=='tool' and 'preparation_package_id' in m.get('content','') for m in messages):
            data={'client':'客户甲 · 试点沟通','goal':'确认三家门店的服务范围','scenario':'sales','concerns':'排期尚未核实','user_quote':last,
                'sections':[{'title':'本次目标','text':'确认三家门店的服务范围。'},{'title':'关键问题','text':'请问接口清单何时可以提供？'},{'title':'待核实','text':'不承诺两周上线。'}],'source_ids':[]}
            return {'role':'assistant','content':'','tool_calls':[{'id':'prepare-native','type':'function','function':{'name':'save_preparation','arguments':json.dumps(data,ensure_ascii=False)}}]}
        if '产品代号' in last:
            assert any('CANDID-A73' in m.get('content','') and 'document:' in m.get('content','') for m in messages if m['role']=='system'), 'Material did not reach actual model context'
        text='准备包已保存，可以在首页和对话中打开。' if '准备' in last else '资料中的产品代号为 CANDID-A73。[1]'
        if kw.get('on_delta'):
            for word in text:kw['on_delta'](word);time.sleep(.008)
        return {'role':'assistant','content':text}

gateway=Gateway();app.agent.gateway=gateway;app.agent.context_manager.gateway=gateway;app.agent.context_manager.summaries.gateway=gateway;app.business.gateway=gateway
profile=app.store.profile(owner)
app.store.update('profiles',owner,profile['id'],{'product_use_consent_at':now(),'onboarding_completed_at':now(),'onboarding_profile':{'display_name':'测试用户','introduction':'销售与面试测试','scenarios':['sales','interview']}},actor=owner)
if not app.store.rows('documents',owner):
    app.store.put('documents',owner,{'title':'产品与服务范围.txt','text':'客户甲产品代号为 CANDID-A73，预算18万元。基础服务包含一次培训，排期尚未核实。','status':'active','acquired':True,'material_kind':'user_document'},L1)
Companion(app.store).thread(owner)
# Actual local audio for native sentence playback; no provider or microphone required.
import wave, math, struct
if not app.store.rows('sessions',owner,title='逐句回听验收录音'):
    session=app.store.create_session(owner,{'client_request_id':ident(),'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'v1'})
    sid=session['id']
    audio_path=app.store.root/'native-playback.wav'
    with wave.open(str(audio_path),'wb') as out:
        out.setnchannels(1);out.setsampwidth(2);out.setframerate(16000)
        out.writeframes(b''.join(struct.pack('<h',int(2500*math.sin(i*2*math.pi*440/16000))) for i in range(144000)))
    app.store.put('session_media',owner,{'session_id':sid,'storage_path':audio_path.name,'mime':'audio/wav'},L1)
    app.store.update('sessions',owner,sid,{'title':'逐句回听验收录音','duration_ms':9000,'pipeline_status':'done','transcript_revision':1})
    for key,start,end,text,speaker in [('one',500,3500,'为什么价格不同？','unknown'),('two',4000,7500,'请先确认服务范围。','self')]:
        app.store.put('transcript_segments',owner,{'session_id':sid,'start_ms':start,'end_ms':end,'text':text,'speaker':speaker,'speaker_id':'part0:'+key,'transcript_revision':1},L1)
    app.store.put('recording_knowledge',owner,{'session_id':sid,'revision':'1','part':0,'title':'逐句回听验收','text':'测试录音，仅用于验证音频定位。','evidence_refs':[]},L1)
@app.app.middleware('http')
async def observe_playback(request,call_next):
    if request.url.path.startswith('/v1/sessions/') and request.url.path.endswith('/audio'):
        with (root/'.build/fidelity-http-playback.jsonl').open('a') as output:
            output.write(json.dumps({'path':request.url.path,'range':dict(request.query_params)})+'\n')
    return await call_next(request)

if __name__=='__main__':
    import uvicorn
    uvicorn.run(app.app,host='127.0.0.1',port=8879,ws='wsproto',log_level='warning')
