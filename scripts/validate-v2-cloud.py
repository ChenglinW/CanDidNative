"""Real HTTPS + configured model acceptance with a disposable synthetic-data owner.
No provider key is read or printed. Saves only synthetic results, never the access token.
Requires httpx and websocket-client; run after generate-v2-fixtures.py and deployment.
"""
import argparse,base64,json,re,threading,time,uuid,wave
from pathlib import Path
import httpx,websocket

p=argparse.ArgumentParser();p.add_argument('--base',default='https://47.129.137.212');p.add_argument('--fixtures',default='.build/v2-fixtures');p.add_argument('--checks',default='all');p.add_argument('--output',default='.build/product-audit-20261016/cloud-v2.json');a=p.parse_args()
out=Path(a.output);out.parent.mkdir(parents=True,exist_ok=True);fixtures=Path(a.fixtures)
client=httpx.Client(base_url=a.base,timeout=90,follow_redirects=False)
token='';report={'base':a.base,'synthetic_data_only':True,'checks':{},'errors':[]}
def save():out.write_text(json.dumps(report,ensure_ascii=False,indent=2))
def uid():return str(uuid.uuid4())
def api(method,path,**kwargs):
    r=client.request(method,path,headers={'Authorization':'Bearer '+token},**kwargs)
    r.raise_for_status();return r.json()
def wait_task(task,timeout=150):
    start=time.monotonic()
    while time.monotonic()-start<timeout:
        state=api('GET','/v1/agent/tasks/'+task['id'])
        if state['status'] not in {'queued','running'}:return state
        time.sleep(.5)
    raise RuntimeError('agent task timeout')
def turn(thread,text):
    started=time.monotonic();task=api('POST','/v1/chat/threads/'+thread+'/tasks',json={'content':text,'client_request_id':uid()})
    state=wait_task(task)
    detail=api('GET','/v1/chat/threads/'+thread)
    answer=next((m for m in reversed(detail['messages']) if m.get('task_id')==task['id'] and m['role']=='assistant'),{})
    return {'status':state['status'],'seconds':round(time.monotonic()-started,3),'content':answer.get('content'),'sources':answer.get('sources',[]),'steps':state.get('tool_steps',[]),'error':state.get('error')}
def guarded(name,fn):
    try:report['checks'][name]=fn();assert report['checks'][name].get('status') in {'passed','completed'}, report['checks'][name];print(name,report['checks'][name]['status'],flush=True)
    except Exception as e:report['errors'].append({'check':name,'type':type(e).__name__,'message':str(e)[:400]});print(name,type(e).__name__,flush=True)
    save()
try:
    auth=client.post('/v1/auth/device',json={'installation_secret':(uuid.uuid4().hex+uuid.uuid4().hex)});auth.raise_for_status();token=auth.json()['access_token']
    api('PATCH','/v1/profile',json={'product_use_consent':True})
    state=api('GET','/v1/companion');thread=state['thread']['id']
    assert api('GET','/v1/companion')['thread']['id']==thread
    report['checks']['single_chat']={'status':'passed','thread_id':thread}
    def documents():
        records=[]
        for name in ['客户甲-服务范围.txt','客户乙-需求.md','面试-JD.txt','报价与服务范围.pdf','产品介绍.docx','试点方案.pptx','扫描件无文字.pdf','损坏.pdf']:
            receipt=api('POST','/v1/onboarding/documents',params={'filename':name},content=(fixtures/name).read_bytes())
            records.append({'file':name,'id':receipt['id']})
        for _ in range(120):
            current=api('GET','/v1/onboarding')['documents'];byid={d['id']:d for d in current}
            if all(byid[d['id']]['status'] in {'completed','failed','interrupted','cancelled'} for d in records):break
            time.sleep(.5)
        for d in records:d.update(status=byid[d['id']]['status'],error=byid[d['id']].get('error'))
        assert all(d['status']=='completed' for d in records[:6]),records
        assert all(d['status']=='failed' for d in records[6:]),records
        return {'status':'passed','documents':records}
    guarded('documents',documents)
    def grounding():
        result=turn(thread,'请分别列出客户甲和客户乙的预算、产品或验收代号，以及面试岗位要求和岗位代号。分别引用资料来源，不要混在一起。')
        assert result['status']=='completed',result
        text=result.get('content') or ''
        assert 'CANDID-A73' in text and 'CANDID-B29' in text and 'INTERVIEW-K51' in text,text
        assert result['sources'],result
        return result
    if a.checks in {'all','text'}:guarded('grounded_material_answer',grounding)
    def preparation():
        result=turn(thread,'帮我准备客户甲华味餐饮的下一场销售沟通。对象是采购王总，目标是确认三家门店试点的接口和服务范围，时间还没定，顾虑是对方要求两周上线但我们的资料没有承诺。直接准备完整报告并保存准备包。')
        report.setdefault('diagnostics',{})['preparation']=result;save()
        assert result['status']=='completed',result
        snapshot=api('GET','/v1/companion');pack=snapshot['next_preparation'];assert pack and len(pack['sections'])>=3,snapshot
        detail=api('GET','/v1/chat/threads/'+thread)
        assert any(m.get('preparation_package_id')==pack['id'] for m in detail['messages'])
        return {**result,'package_id':pack['id'],'version':pack['version'],'sections':pack['sections'],'same_chat_and_home_id':True}
    if a.checks in {'all','text','preparation'}:guarded('preparation',preparation)
    def recording():
        raw=(fixtures/'mixed-turns.wav').read_bytes();record=api('POST','/v1/recordings',json={'client_request_id':uid(),'recording_source':'iphone','consent':'yes','scenario':'sales'})
        sid=record['id'];url=api('POST','/v1/sessions/'+sid+'/upload-url')['upload_url'];receipt=api('PUT',url,content=raw)
        with wave.open(str(fixtures/'mixed-turns.wav'),'rb') as w:duration=round(w.getnframes()/w.getframerate()*1000)
        api('POST','/v1/sessions/'+sid+'/media',json={**receipt,'duration_ms':duration})
        started=time.monotonic();detail=None
        for _ in range(240):
            detail=api('GET','/v1/recordings/'+sid)
            if detail['pipeline_status']=='done':break
            if any(j['status']=='failed' for j in detail['jobs']):raise RuntimeError(json.dumps([{'kind':j['kind'],'error':j.get('error')} for j in detail['jobs'] if j['status']=='failed'],ensure_ascii=False))
            time.sleep(1)
        assert detail['pipeline_status']=='done',detail['pipeline_status']
        detail_chat=api('GET','/v1/chat/threads/'+thread)
        messages=[m for m in detail_chat['messages'] if m.get('recording_id')==sid];assert len(messages)==1
        api('POST','/v1/recordings/'+sid+'/process')
        assert len([m for m in api('GET','/v1/chat/threads/'+thread)['messages'] if m.get('recording_id')==sid])==1
        segments=detail['segments'];assert segments and all(s['end_ms']>s['start_ms'] for s in segments)
        ids={s.get('speaker_id') for s in segments};assert None not in ids
        return {'status':'passed','recording_id':sid,'processing_seconds':round(time.monotonic()-started,3),'segments':segments,'speaker_ids':sorted(ids),'review':detail['knowledge'],'expressions':api('GET','/v1/companion/memory')['expressions'],'one_proactive_message':True}
    if a.checks in {'all','audio'}:guarded('recording_pipeline',recording)
    def stream(name):
        with wave.open(str(fixtures/name),'rb') as f:pcm=f.readframes(f.getnframes())
        sock=websocket.create_connection(a.base.replace('https:','wss:')+'/v1/speech/live',timeout=50)
        start=time.monotonic();sock.send(json.dumps({'token':token,**{k:uid() for k in ('voice_session_id','input_turn_id','segment_id','epoch')}}))
        while True:
            event=json.loads(sock.recv())
            if event['type']=='error':raise RuntimeError(event.get('message',event.get('code')))
            if event['type']=='ready':break
        ready=time.monotonic();sentences={};first=None;send_errors=[]
        def sender():
            try:
                chunks=[pcm[i:i+1600] for i in range(0,len(pcm),1600)]
                for seq,chunk in enumerate(chunks):sock.send(json.dumps({'seq':seq,'audio':base64.b64encode(chunk).decode()}));time.sleep(.05)
                sock.send(json.dumps({'type':'finish','last_seq':len(chunks)-1}))
            except Exception as e:send_errors.append(type(e).__name__)
        work=threading.Thread(target=sender);work.start()
        while True:
            event=json.loads(sock.recv())
            if event['type']=='error':raise RuntimeError(event.get('message',event.get('code')))
            if event['type']=='transcript':
                sentence=event['sentence'];sentences[str(sentence.get('sentence_id',sentence.get('begin_time',0)))]=sentence
                if sentence.get('text') and first is None:first=time.monotonic()
            if event['type']=='finished':receipt=event;break
        work.join(10);sock.close();assert receipt['complete'] and not receipt['audio_gap'] and receipt['audio_bytes']==len(pcm) and not send_errors
        text=''.join(s.get('text','') for s in sentences.values());assert text
        manifest=json.loads((fixtures/'manifest.json').read_text());reference=next((i.get('reference') for i in manifest['audio'] if i['file']==name),None)
        metrics={}
        if reference:
            def normalize(s):return re.sub(r'[^a-z0-9\u4e00-\u9fff]','',s.lower())
            expected,actual=normalize(reference),normalize(text)
            previous=list(range(len(actual)+1))
            for i,char in enumerate(expected,1):
                current=[i]
                for j,other in enumerate(actual,1):current.append(min(current[-1]+1,previous[j]+1,previous[j-1]+(char!=other)))
                previous=current
            metrics={'reference':reference,'character_error_rate':previous[-1]/max(1,len(expected)),'metric_note':'normalized synthetic speech sample, not human benchmark'}
        return {'status':'passed','file':name,'text':text,'ready_seconds':round(ready-start,3),'first_caption_after_ready_seconds':round(first-ready,3),'complete':True,'audio_bytes':len(pcm),**metrics}
    if a.checks in {'all','audio'}:
        for name in ['mandarin.wav','english.wav','cantonese.wav','mixed-noise.wav','overlap.wav']:guarded('stream_'+name,lambda name=name:stream(name))
    def voice_tts():
        ids={k:uid() for k in ('voice_session_id','input_turn_id','generation_id')}
        started=time.monotonic();task=api('POST','/v1/voice/turns',json={'thread_id':thread,'content':'请用一句话说你好。','client_request_id':uid(),'continuous':True,**ids})
        sock=websocket.create_connection(a.base.replace('https:','wss:')+'/v1/voice/output/'+task['id'],timeout=60);sock.send(json.dumps({'token':token,'generation_id':ids['generation_id']}))
        first_text=first_audio=None;size=0;seq=0;text=[]
        while True:
            event=json.loads(sock.recv());kind=event['type']
            if kind=='error':raise RuntimeError(event.get('message',event.get('code')))
            if kind=='text':
                text.append(event['text'])
                if first_text is None:first_text=time.monotonic()-started
            if kind=='audio':
                assert event['seq']==seq+1;seq=event['seq'];size+=len(base64.b64decode(event['audio']))
                if first_audio is None:first_audio=time.monotonic()-started
                sock.send(json.dumps({'type':'played','seq':seq}))
            if kind=='finished':break
        sock.close();assert size>0
        body={'thread_id':thread,'content':'请详细说明沟通准备的步骤。','client_request_id':uid(),'continuous':True,**{k:uid() for k in ids}}
        cancel=api('POST','/v1/voice/turns',json=body)
        receipt=api('POST','/v1/voice/threads/'+thread+'/requests/'+body['client_request_id']+'/cancel',json={})
        assert receipt['status']=='cancelled' and api('GET','/v1/agent/tasks/'+cancel['id'])['status']=='cancelled'
        return {'status':'passed','text':' '.join(text),'first_text_seconds':first_text,'first_audio_seconds':first_audio,'audio_bytes':size,'cancel':'passed','physical_playback':False}
    if a.checks in {'all','voice'}:guarded('voice_agent_tts_cancel',voice_tts)
    def research():
        result=turn(thread,'请使用公司调研 Skill 和 Monid 联网调研 Anker Innovations（安克创新）的主要业务与最新可查公开资料，列出来源 URL，缺口如实说明。')
        assert result['status']=='completed',result
        assert not any(marker in result.get('content','') for marker in ('DSML','<｜','<|tool_calls')),result
        assert len(result.get('content','').strip())>40,result
        assert any('research' in step.get('name','') or 'search' in step.get('name','') for step in result['steps']),result['steps']
        assert any(s.get('url') for s in result['sources']),result
        return result
    if a.checks in {'all','research'}:guarded('monid_research',research)
finally:
    if token:
        try:
            api('DELETE','/v1/memory');r=client.get('/v1/profile',headers={'Authorization':'Bearer '+token});report['cleanup']={'owner_deleted':True,'access_status':r.status_code};assert r.status_code==410
        except Exception as e:
            report['cleanup']={'owner_deleted':False,'error':type(e).__name__}
            report['errors'].append({'check':'cleanup','type':type(e).__name__})
    report['status']='passed' if not report['errors'] else 'failed';save();client.close()
print(json.dumps({'status':report['status'],'checks':len(report['checks']),'errors':report['errors']},ensure_ascii=False))
if report['errors']:raise SystemExit(1)
