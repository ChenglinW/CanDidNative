"""Authenticated voice turns reuse Agent tasks; transient playback is never replayed."""
import asyncio
import base64
import json
import time
from uuid import UUID
from fastapi import Request, WebSocket, WebSocketDisconnect, Depends
from pydantic import BaseModel, ConfigDict, Field
from memory import Fault, L1
from agent_runtime.cancellation import Cancellation


class VoiceTurnIn(BaseModel):
    model_config = ConfigDict(extra='forbid')
    thread_id: UUID
    content: str = Field(min_length=1, max_length=12000)
    client_request_id: UUID
    voice_session_id: UUID
    input_turn_id: UUID
    generation_id: UUID
    continuous: bool = False
    task_id: UUID | None = None
    input_id: UUID | None = None
    expected_attempt: int | None = Field(default=None, ge=1)


def install(app, owner, store, agent, speech):
    @app.post('/v1/voice/turns', status_code=202)
    def submit(body: VoiceTurnIn, uid=Depends(owner)):
        thread = str(body.thread_id)
        store.get('chat_threads', uid, thread)
        voice = {k: str(getattr(body, k)) for k in ('voice_session_id','input_turn_id','generation_id')}
        voice['continuous'] = body.continuous
        with agent._lock_guard:
            if body.input_id:
                if not body.task_id or not body.expected_attempt:
                    raise Fault('VOICE_INPUT_INVALID','等待补充问题的标识不完整',422)
                task = agent.tasks.get(uid, str(body.task_id))
                if task['thread_id'] != thread: raise Fault('VOICE_SCOPE_CHANGED','问题所属空间已变化',409)
                result=agent.answer_input(uid, task['id'], str(body.client_request_id), str(body.input_id),
                    body.content, body.expected_attempt, voice=voice)
            else:
                if any(t['status']=='waiting_input' for t in agent.tasks.list(uid,thread)):
                    raise Fault('VOICE_INPUT_CHANGED','Agent 正在等明确问题的回答，请核对后补充',409)
                result=agent.submit(uid, thread, body.content, str(body.client_request_id), voice=voice)
            with store.transaction(uid):
                store.db.execute("INSERT OR IGNORE INTO requests(owner_id,request_id,kind,object_id) VALUES(?,?,'voice_accept',?)",(uid,str(body.client_request_id),result['id']))
            return result

    @app.get('/v1/voice/threads/{thread}/requests/{request_id}')
    def receipt(thread: str, request_id: UUID, uid=Depends(owner)):
        store.get('chat_threads', uid, thread)
        tasks = agent.tasks.list(uid, thread)
        task = next((t for t in tasks if t.get('voice_context', {}).get('client_request_id') == str(request_id)), None)
        if not task:
            with store.lock: saved=store.db.execute("SELECT object_id FROM requests WHERE owner_id=? AND request_id=? AND kind='voice_accept'",(uid,str(request_id))).fetchone()
            if saved:
                candidate=agent.tasks.get(uid,saved['object_id'])
                if candidate['thread_id']==thread:task=candidate
        if task: return {'status':'accepted', 'task':agent.tasks.public(task)}
        with store.lock:
            tombstone = store.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='voice_cancel' AND object_id=?",(uid,str(request_id),thread)).fetchone()
        return {'status':'cancelled' if tombstone else 'unknown', 'task':None}

    @app.post('/v1/voice/threads/{thread}/requests/{request_id}/cancel')
    def cancel_request(thread: str, request_id: UUID, uid=Depends(owner)):
        store.get('chat_threads', uid, thread)
        with agent._lock_guard:
            with store.transaction(uid):
                store.db.execute("INSERT OR IGNORE INTO requests(owner_id,request_id,kind,object_id) VALUES(?,?,'voice_cancel',?)",(uid,str(request_id),thread))
            task = next((t for t in agent.tasks.list(uid,thread) if t.get('voice_context',{}).get('client_request_id') == str(request_id)), None)
            if task and task['status'] != 'waiting_input':
                agent.cancel(uid, task['id'], preserve_partial=True, expected_attempt=task['attempt'])
            return {'status':'cancelled','task_id':task['id'] if task else None}

    @app.websocket('/v1/voice/output/{task_id}')
    async def output(ws: WebSocket, task_id: str):
        await ws.accept()
        cancellation = Cancellation()
        consumer = None
        try:
            hello = await asyncio.wait_for(ws.receive_json(), 10)
            req = Request({'type':'http','headers':[(b'authorization',('Bearer '+str(hello.get('token',''))).encode())]})
            uid = owner(req)
            task = agent.tasks.get(uid,task_id)
            voice = task.get('voice_context',{})
            generation = str(UUID(hello.get('generation_id','')))
            if not voice.get('continuous') or voice.get('generation_id') != generation:
                raise Fault('VOICE_GENERATION_EXPIRED','语音生成代已结束',409)
            def check_cancelled():
                with store.lock:
                    cancelled=store.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='voice_cancel' AND object_id=?",
                        (uid,voice.get('client_request_id'),task['thread_id'])).fetchone()
                if cancelled:raise Fault('VOICE_OUTPUT_STOPPED','这一轮已停止，保留已有文字',409)
            check_cancelled()
            attempt = task['attempt']
            with store.transaction(uid):
                task=agent.tasks.get(uid,task_id)
                if task.get('voice_output_claim') == generation:
                    raise Fault('VOICE_OUTPUT_EXPIRED','自动播报通道不可重放，可手动播报文字',409)
                if task['status'] in {'cancelled','failed','interrupted'}:
                    raise Fault('VOICE_OUTPUT_STOPPED','该轮已停止',409)
                agent.tasks.update(uid,task_id,{'voice_output_claim':generation})
            speech.check()
            loop = asyncio.get_running_loop()
            cursor, audio_seq = 0, 0
            played_seq=0; outstanding={}; credit=asyncio.Event();credit.set()
            async def control():
                nonlocal played_seq
                try:
                    while True:
                        value = await ws.receive_json()
                        if value.get('type') in {'stop','cancel'}: cancellation.cancel();credit.set();return
                        if value.get('type')=='played' and type(value.get('seq')) is int and played_seq<value['seq']<=audio_seq:
                            played_seq=value['seq']
                            for number in list(outstanding):
                                if number<=played_seq:outstanding.pop(number,None)
                            credit.set()
                except Exception: cancellation.cancel()
            consumer = asyncio.create_task(control())
            async def send(value):
                cancellation.check()
                await asyncio.wait_for(ws.send_json({**value,'generation_id':generation,
                    'voice_session_id':voice.get('voice_session_id'),'task_id':task_id,'attempt':attempt}),5)
            await send({'type':'ready','sample_rate':24000,'format':'pcm16'})
            started = time.monotonic()
            while time.monotonic()-started < 600:
                cancellation.check()
                task = agent.tasks.get(uid,task_id)
                if task['attempt'] != attempt or task.get('voice_context',{}).get('generation_id') != generation:
                    raise Fault('VOICE_GENERATION_EXPIRED','语音生成代已变化',409)
                if task['status'] in {'cancelled','failed','interrupted'}:
                    raise Fault('VOICE_OUTPUT_STOPPED','这一轮已停止，保留已有文字',409)
                events = agent.tasks.events.after(uid,task_id,cursor)
                for event in events:
                    cursor = event['seq']
                    if event['attempt'] != attempt or event['kind'] != 'speech.segment': continue
                    data = event['data']
                    if data.get('generation_id') != generation: continue
                    if data.get('kind') == 'prompt' and (task.get('input_request') or {}).get('id') != data.get('input_id'): continue
                    chunks = asyncio.Queue(maxsize=32)
                    def guard():
                        cancellation.check()
                        check_cancelled()
                        if time.monotonic()-started>=600:raise Fault('VOICE_OUTPUT_TIMEOUT','语音等待超时，文字仍可查看',504)
                        current = agent.tasks.get(uid,task_id)
                        if current['attempt'] != attempt or current.get('voice_context',{}).get('generation_id') != generation or current['status'] in {'cancelled','failed','interrupted'}:
                            raise Fault('VOICE_OUTPUT_STOPPED','这一轮已停止',409)
                    def audio(chunk):
                        for start in range(0,len(chunk),4800):
                            guard()
                            future = asyncio.run_coroutine_threadsafe(chunks.put(chunk[start:start+4800]),loop)
                            try:future.result(timeout=6)
                            except Exception:
                                future.cancel();cancellation.cancel();return
                    await send({'type':'text','text':data['text'],'segment_seq':data['segment_seq'],'kind':data.get('kind'),'input_id':data.get('input_id')})
                    with store.transaction(uid):
                        run=store.put('provider_runs',uid,{'provider':'dashscope','kind':'voice_tts',
                            'model':speech.tts_model,'voice':speech.voice,'task_id':task_id,'attempt':attempt,
                            'generation_id':generation,'segment_seq':data['segment_seq'],'status':'running'},L1)
                    usage=None
                    work = asyncio.create_task(asyncio.to_thread(speech.stream_synthesize,data['text'],audio,guard,cancellation))
                    try:
                        while not work.done() or not chunks.empty():
                            guard()
                            try: chunk = await asyncio.wait_for(chunks.get(), .1)
                            except asyncio.TimeoutError: continue
                            while sum(outstanding.values())>=240000:
                                guard();credit.clear()
                                try:await asyncio.wait_for(credit.wait(),.5)
                                except asyncio.TimeoutError:pass
                            audio_seq += 1;outstanding[audio_seq]=len(chunk)
                            await send({'type':'audio','seq':audio_seq,'audio':base64.b64encode(chunk).decode(),
                                'segment_seq':data['segment_seq']})
                        usage = await work
                        while played_seq<audio_seq:
                            guard();credit.clear()
                            try:await asyncio.wait_for(credit.wait(),.5)
                            except asyncio.TimeoutError:pass
                        with store.transaction(uid):store.update('provider_runs',uid,run['id'],{'status':'completed','usage':usage})
                    finally:
                        if not work.done():cancellation.cancel();work.cancel()
                        with store.transaction(uid):
                            current_run=store.get('provider_runs',uid,run['id'])
                            if current_run['status']=='running':store.update('provider_runs',uid,run['id'],{'status':'interrupted','usage':usage,'provider_state':'unknown_after_disconnect'})
                if task['status'] == 'completed' or task['status'] == 'waiting_input':
                    # Check the latest event cursor to avoid missing a prompt appended immediately after pause.
                    current = agent.tasks.get(uid,task_id)
                    if cursor >= current.get('event_seq',0):
                        await send({'type':'finished','waiting_input':task['status']=='waiting_input'});return
                await asyncio.sleep(.08)
            raise Fault('VOICE_OUTPUT_TIMEOUT','语音等待超时，文字仍可查看',504)
        except WebSocketDisconnect: pass
        except Exception as exc:
            code = exc.code if isinstance(exc,Fault) else 'VOICE_OUTPUT_FAILED'
            try: await asyncio.wait_for(ws.send_json({'type':'error','code':code,'message':'播报已停止，文字仍可查看'}),2)
            except Exception: pass
        finally:
            cancellation.cancel()
            if consumer:
                consumer.cancel()
                await asyncio.gather(consumer,return_exceptions=True)
            try: await ws.close()
            except Exception: pass
