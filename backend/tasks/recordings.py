"""Global recordings, true final transcript revisions, tags and recording-bound knowledge."""
import hashlib
import csv
import json
import subprocess
import time
from pathlib import Path
import httpx
from memory import Fault,L1,L2,ident,now
from adapters.sources import version


class Recordings:
    def __init__(self,store,business,speech):
        self.store,self.business,self.speech=store,business,speech
        business.handlers.update(transcribe=self.transcribe,recording_knowledge=self.knowledge,tts=self.tts)

    def queue(self,owner,sid):
        session=self.store.get('sessions',owner,sid)
        if session.get('consent')!='yes':raise Fault('RECORDING_CONSENT_REQUIRED','尚未取得录音告知同意',403)
        media=self.store.rows('session_media',owner,session_id=sid)
        if not media:raise Fault('AUDIO_MISSING','请先完成音频上传',409)
        return self.business.submit(owner,'transcribe',sid,media[0]['sha256'])

    def segments(self,owner,sid):
        session=self.store.get('sessions',owner,sid);revision=session.get('transcript_revision',1)
        return sorted([r for r in self.store.rows('transcript_segments',owner,session_id=sid)
            if r.get('transcript_revision',1)==revision],key=lambda r:r['start_ms'])

    def transcribe(self,owner,job):
        sid=job['object_id'];session=self.store.get('sessions',owner,sid)
        if session.get('consent')!='yes':raise Fault('RECORDING_CONSENT_REQUIRED','没有录音授权',403)
        media=self.store.rows('session_media',owner,session_id=sid)[0]
        if session.get('audio_purged_at'):raise Fault('ALREADY_PURGED','原音频已删除',410)
        input_file=self.store.root/media['storage_path']
        folder=self.store.root/owner/'asr'/sid;folder.mkdir(parents=True,exist_ok=True)
        # Mono, 90-minute blocks retain timestamps. Speaker IDs are local to each block, never guessed across blocks.
        marker=folder/'conversion.complete.json'
        chunks=sorted(folder.glob('part-*.m4a'))
        if not marker.exists() or not chunks:
            for partial in chunks:partial.unlink()
            try:
                subprocess.run(['ffmpeg','-nostdin','-v','error','-i',str(input_file),'-map','0:a:0','-ac','1','-ar','16000',
                    '-c:a','aac','-b:a','64k','-f','segment','-segment_time','5400','-reset_timestamps','1',
                    '-segment_list',str(folder/'parts.csv'),'-segment_list_type','csv',str(folder/'part-%04d.m4a')],
                    check=True,capture_output=True,timeout=900)
            except Exception:raise Fault('AUDIO_DECODE_FAILED','无法解码音频；请检查ffmpeg及原文件',422) from None
            chunks=sorted(folder.glob('part-*.m4a'))
            if not chunks:raise Fault('AUDIO_EMPTY','音频没有可处理的声音轨',422)
            marker.write_text(json.dumps({'media_sha256':media['sha256']}))
        with (folder/'parts.csv').open(newline='') as manifest:
            offsets={Path(r[0]).name:round(float(r[1])*1000) for r in csv.reader(manifest)}
        transcript=[];all_usage=[]
        for number,path in enumerate(chunks):
            self.business.guard(owner,job)
            key='asr:'+sid+':'+job['revision']+':'+str(number)
            with self.store.transaction():
                prior=next((r for r in self.store.rows('provider_runs',owner) if r.get('key')==key),None)
                if prior and prior['status']=='submitting' and not prior.get('external_id'):
                    raise Fault('ASR_SUBMIT_UNCERTAIN','精转写提交结果不明，需先核对供应商运行记录',409)
                row=prior or self.store.put('provider_runs',owner,{'key':key,'provider':'dashscope','kind':'filetrans',
                    'session_id':sid,'job_id':job['id'],'model':self.speech.file_model,'status':'uploading','part':number},L1)
            if not row.get('external_id'):
                url=self.speech.upload(path)
                with self.store.transaction():self.store.update('provider_runs',owner,row['id'],{'status':'submitting','temporary_url':url})
                external=self.speech.submit_file(url)
                with self.store.transaction():row=self.store.update('provider_runs',owner,row['id'],{'external_id':external,'status':'PENDING'})
            result=row.get('response',{})
            for _ in range(7200):
                self.business.guard(owner,job)
                if result.get('output',{}).get('task_status') in {'SUCCEEDED','FAILED','CANCELED'}:break
                result=self.speech.fetch_file(row['external_id'])
                with self.store.transaction():
                    self.store.update('provider_runs',owner,row['id'],{'response':result,'status':result.get('output',{}).get('task_status'),
                        'usage':result.get('usage',{})})
                    self.store.update('business_jobs',owner,job['id'],{'progress':f'精转写第{number+1}/{len(chunks)}段'})
                time.sleep(1)
            if result.get('output',{}).get('task_status')!='SUCCEEDED':raise Fault('ASR_FAILED','精转写失败，音频和外部任务ID已保留',502)
            all_usage.append(result.get('usage',{}))
            for item in result['output'].get('results',[]):
                if item.get('subtask_status')!='SUCCEEDED':raise Fault('ASR_FAILED','部分精转写失败，未当作完整结果',502)
                cache=folder/('result-'+str(number)+'.json')
                if cache.exists():data=json.loads(cache.read_text('utf8'))
                else:
                    with httpx.Client(timeout=60,follow_redirects=False) as client:
                        response=client.get(item['transcription_url'])
                        if response.status_code!=200 or len(response.content)>30_000_000:raise Fault('ASR_RESULT_INVALID','无法下载转写结果',502)
                        data=response.json();cache.write_text(json.dumps(data,ensure_ascii=False));cache.chmod(0o600)
                for track in data.get('transcripts',[]):
                    for sentence in track.get('sentences',[]):
                        start,end=sentence.get('begin_time'),sentence.get('end_time');text=sentence.get('text')
                        if not isinstance(start,int) or not isinstance(end,int) or end<=start or not isinstance(text,str) or not text.strip():continue
                        speaker=sentence.get('speaker_id')
                        transcript.append({'start_ms':offsets[path.name]+start,'end_ms':offsets[path.name]+end,'text':text,
                            'speaker':'unknown','speaker_id':('part'+str(number)+':'+str(speaker)) if speaker is not None else None,
                            'speaker_scope':'chunk','part':number,'asr_producer':'dashscope/'+self.speech.file_model})
        if not transcript:raise Fault('ASR_EMPTY','模型没有返回有效逐句转写',502)
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            current=self.store.get('sessions',owner,sid)
            if current.get('transcription_job_id')==job['id']:
                revision=current['transcript_revision']
            else:
                revision=current.get('transcript_revision',0)+1
                for segment in transcript:self.store.put('transcript_segments',owner,{**segment,'session_id':sid,'transcript_revision':revision},L1,source='device')
                self.store.update('sessions',owner,sid,{'transcript_revision':revision,'transcription_job_id':job['id'],
                    'pipeline_status':'transcribed','asr_model':self.speech.file_model,'llm_consent_at':now(),
                    'speaker_identity_status':'awaiting_self_selection','speaker_continuity':'chunk_local' if len(chunks)>1 else 'single_chunk'})
            self.business.submit(owner,'recording_knowledge',sid,str(revision))
        return {'session_id':sid,'revision':revision,'sentence_count':len(transcript),'usage':all_usage,'parts':len(chunks)}

    def knowledge(self,owner,job):
        sid=job['object_id'];session=self.store.get('sessions',owner,sid)
        if str(session.get('transcript_revision',1))!=job['revision']:raise Fault('TRANSCRIPT_CHANGED','转写已修订，请使用最新任务',409)
        with self.store.transaction(owner):
            if session.get('tag_generation_revision')!=job['revision']:
                for tag in self.store.rows('recording_tags',owner,session_id=sid):
                    if tag.get('source')=='ai' and not tag.get('manual'):
                        self.store.update('recording_tags',owner,tag['id'],{'active':False,'revision':tag['revision']+1})
                self.store.update('sessions',owner,sid,{'tag_generation_revision':job['revision']})
        segments=self.segments(owner,sid); groups=[];group=[];size=0
        for segment in segments:
            if size+len(segment['text'])>24000 and group:groups.append(group);group=[];size=0
            group.append(segment);size+=len(segment['text'])
        if group:groups.append(group)
        saved=[]; spaces=[{'id':s['id'],'name':s['name'],'goal':s['goal']} for s in self.business.workspaces.list(owner) if s['status']=='active']
        for number,group in enumerate(groups):
            self.business.guard(owner,job)
            prior=next((k for k in self.store.rows('recording_knowledge',owner,session_id=sid) if k.get('revision')==job['revision'] and k.get('part')==number),None)
            if prior:saved.append(prior);continue
            result=self.business.structured('整理全场沟通，不猜谁是用户。保留粤语原文引用，复盘可用普通话。输出 {"summary":"总结与要点","strengths":[],"improvements":[],"open_questions":[],"tags":[{"label":"名称","kind":"client或project或topic","workspace_id":null}]}。只有明确匹配提供的空间方向才填其workspace_id，不确定时为null。不要凭空补事实，不把全场内容当用户经历。',
                {'segments':[{'id':s['id'],'start_ms':s['start_ms'],'end_ms':s['end_ms'],'speaker':s.get('speaker_id'),'text':s['text']} for s in group],
                 'project_spaces':spaces,'part':number+1,'parts':len(groups)})
            summary=result.get('summary','')
            if not isinstance(summary,str) or not summary.strip():raise Fault('KNOWLEDGE_FORMAT_INVALID','录音整理格式无效',502)
            refs=[{'source_id':'transcript:'+s['id'],'source_version':version(s),'start_ms':s['start_ms'],'end_ms':s['end_ms']} for s in group]
            with self.store.transaction(owner):
                self.business.guard(owner,job)
                if str(self.store.get('sessions',owner,sid).get('transcript_revision',1))!=job['revision']:raise Fault('TRANSCRIPT_CHANGED','转写已修订',409)
                knowledge=self.store.put('recording_knowledge',owner,{'session_id':sid,'revision':job['revision'],'part':number,
                    'title':'录音资料 · '+str(number+1),'text':summary[:12000],'review':{k:result.get(k,[]) for k in ['strengths','improvements','open_questions']},
                    'evidence_refs':refs,'producer':'anker/'+self.business.gateway.model,'rubric_version':'recording-knowledge@1',
                    'status':'active','personal_identity_confirmed':False},L2,source='ai')
                valid_spaces={s['id'] for s in spaces}
                for tag in result.get('tags',[])[:12]:
                    if not isinstance(tag,dict) or not isinstance(tag.get('label'),str) or not 1<=len(tag['label'])<=100:continue
                    label=tag['label'].strip();kind=tag.get('kind','topic')
                    if kind not in {'client','project','topic'}:continue
                    existing=self.store.rows('recording_tags',owner,session_id=sid)
                    matching=[t for t in existing if t.get('label')==label or t.get('original_label')==label]
                    if any(t.get('manual') for t in matching):continue # Human edits and suppression always win.
                    if matching:
                        prior=matching[0]
                        self.store.update('recording_tags',owner,prior['id'],{'active':True,'revision':prior['revision']+1,
                            'transcript_revision':job['revision'],'workspace_id':tag.get('workspace_id') if tag.get('workspace_id') in valid_spaces else None})
                        continue
                    self.store.put('recording_tags',owner,{'session_id':sid,'label':label,'kind':kind,'active':True,'revision':1,
                        'workspace_id':tag.get('workspace_id') if tag.get('workspace_id') in valid_spaces else None,
                        'transcript_revision':job['revision'],'producer':'anker/'+self.business.gateway.model,'rubric_version':'recording-tag@1'},L2,source='ai')
                saved.append(knowledge)
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            self.store.update('sessions',owner,sid,{'pipeline_status':'done','knowledge_revision':job['revision']})
        return {'knowledge_ids':[k['id'] for k in saved],'session_id':sid}

    def tts(self,owner,job):
        message=self.store.get('chat_messages',owner,job['object_id'])
        if message['role']!='assistant' or message.get('incomplete') or message.get('status') in {'incomplete','cancelled'}:
            raise Fault('TTS_INCOMPLETE','未完成的回复不能自动播报',409)
        # Each bounded sentence group is cached; user starts playback explicitly.
        import re
        sentences=re.split(r'(?<=[。！？.!?])\s*',message['content']);groups=[];current=''
        for sentence in sentences:
            for start in range(0,len(sentence),800):
                part=sentence[start:start+800]
                if len(current)+len(part)>800:groups.append(current);current=''
                current+=part
        if current:groups.append(current)
        clips=[]
        folder=self.store.root/owner/'tts';folder.mkdir(parents=True,exist_ok=True)
        for number,text in enumerate(groups):
            prior=next((s for s in self.store.rows('speech_outputs',owner,message_id=message['id']) if s.get('part')==number),None)
            if prior:clips.append(prior['id']);continue
            raw,usage=self.speech.synthesize(text,lambda:self.business.guard(owner,job))
            with self.store.transaction(owner):
                self.business.guard(owner,job)
                identifier=ident();path=folder/(identifier+'.wav');path.write_bytes(raw);path.chmod(0o600)
                row=self.store.put('speech_outputs',owner,{'id':identifier,'message_id':message['id'],'job_id':job['id'],'part':number,
                    'storage_path':str(path.relative_to(self.store.root)),'model':self.speech.tts_model,'voice':self.speech.voice,'usage':usage},L1,source='device')
                clips.append(row['id'])
        return {'clip_ids':clips,'model':self.speech.tts_model,'voice':self.speech.voice}
