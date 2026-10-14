"""Bounded live ASR relay; final results and terminal acknowledgements are ordered."""
import asyncio
import base64
import time
from collections import deque
from uuid import UUID
from fastapi import Request, WebSocket, WebSocketDisconnect
from dashscope.audio.asr import RecognitionCallback
from memory import Fault, L1


async def live_speech(ws, owner, store, speech):
    await ws.accept()
    recognition = None; receipt = None; uid = None; last_seq = -1
    loop = asyncio.get_running_loop(); alive = True; partial_gap = False; failed = False
    events = deque(); wake = asyncio.Event(); drained = asyncio.Event(); drained.set()
    provider_done = loop.create_future(); sender = None; binding = {}; seen = {}; audio_bytes = 0
    metrics = {'started': time.monotonic(), 'queue_peak': 0, 'events_sent': 0, 'callback_to_send_max_ms': 0}
    def enqueue(event):
        nonlocal partial_gap, failed
        if not alive: return
        final = event.get('type') != 'transcript' or event.get('sentence', {}).get('sentence_end') is True
        if len(events) >= 128:
            replace = next((i for i,e in enumerate(events) if e.get('type') == 'transcript' and e.get('sentence',{}).get('sentence_end') is not True),None)
            if replace is not None: del events[replace];partial_gap=True
            elif not final: partial_gap=True;return
            else:
                failed = True
                events.clear()
                events.append({'type':'error','code':'ASR_BACKPRESSURE','retryable':False,'message':'最终字幕交付中断，输入已保留'})
                if recognition: recognition.abort()
                if not provider_done.done(): provider_done.set_result(False)
                wake.set();drained.clear();return
        events.append(event);metrics['queue_peak']=max(metrics['queue_peak'],len(events));drained.clear();wake.set()
        if event.get('type') == 'complete' and not provider_done.done(): provider_done.set_result(True)
        if event.get('type') == 'error':
            failed=True
            if not provider_done.done():provider_done.set_result(False)
    def publish(event):loop.call_soon_threadsafe(enqueue,{**event,'_callback_at':time.monotonic()})
    class Callback(RecognitionCallback):
        def on_ready(self):publish({'type':'ready','upstream_ready':True})
        def on_event(self,result):
            sentence=result.get_sentence()
            if isinstance(sentence,dict):publish({'type':'transcript','sentence':sentence,'usage':result.get_usage(sentence)})
        def on_error(self,result):
            code=getattr(result,'code',None) or 'ASR_CONNECTION_FAILED'
            publish({'type':'error','code':code,'retryable':code=='ASR_CONNECTION_FAILED','message':'实时转写中断，输入已保留'})
        def on_complete(self):publish({'type':'complete'})
    async def transmit():
        while True:
            await wake.wait()
            while events:
                store.check_owner(uid)
                event=events.popleft()
                callback_at=event.pop('_callback_at',None)
                if event.get('type')=='transcript':
                    s=event['sentence'];key=str(s.get('sentence_id',s.get('begin_time',0)))
                    if s.get('text'):seen[key]=s.get('sentence_end') is True
                await asyncio.wait_for(ws.send_json({**event,**binding}),5)
                metrics['events_sent']+=1
                if callback_at is not None:metrics['callback_to_send_max_ms']=max(metrics['callback_to_send_max_ms'],(time.monotonic()-callback_at)*1000)
                if event.get('type')=='transcript':metrics.setdefault('first_caption_sent',time.monotonic())
            wake.clear();drained.set()
    try:
        hello=await asyncio.wait_for(ws.receive_json(),10)
        req=Request({'type':'http','headers':[(b'authorization',('Bearer '+str(hello.get('token',''))).encode())]})
        uid=owner(req)
        for key in ('voice_session_id','input_turn_id','segment_id','epoch'):
            if hello.get(key):binding[key]=str(UUID(hello[key]))
        sid=hello.get('session_id')
        if sid:
            session=store.get('sessions',uid,sid)
            if session.get('consent')!='yes':raise Fault('RECORDING_CONSENT_REQUIRED','没有录音授权',403)
        speech.check()
        with store.transaction(uid):
            receipt=store.put('provider_runs',uid,{'provider':'dashscope','kind':'realtime_asr','session_id':sid,
                'model':speech.realtime_model,'status':'running','offset_ms':hello.get('offset_ms',0),'last_seq':-1,**binding},L1)
        binding['stream_id']=receipt['id']
        sender=asyncio.create_task(transmit())
        recognition=await asyncio.to_thread(speech.live,Callback())
        while True:
            # A provider error also terminates input collection without waiting for another frame.
            receive=asyncio.create_task(ws.receive_json())
            done,_=await asyncio.wait([receive,provider_done,sender],return_when=asyncio.FIRST_COMPLETED)
            if sender in done:
                receive.cancel();await asyncio.gather(receive,return_exceptions=True);await sender;raise Fault('ASR_SEND_FAILED','字幕交付中断',502)
            if provider_done in done:
                receive.cancel()
                await asyncio.gather(receive,return_exceptions=True)
                if failed:raise Fault('ASR_PROVIDER_FAILED','语音转写中断，输入已保留',502)
                break
            packet=await receive
            store.check_owner(uid)
            if packet.get('type')=='abort':recognition.abort();return
            if packet.get('type')=='finish':
                if packet.get('last_seq',last_seq)!=last_seq:raise Fault('AUDIO_SEQUENCE_INVALID','音频段未完整传输',422)
                break
            seq=packet.get('seq');raw=packet.get('audio')
            if type(seq) is not int or seq!=last_seq+1 or not isinstance(raw,str) or len(raw)>100000:
                raise Fault('AUDIO_SEQUENCE_INVALID','音频顺序中断，输入已保留',422)
            pcm=base64.b64decode(raw,validate=True)
            if not pcm or len(pcm)%2 or len(pcm)>64000:raise Fault('AUDIO_FORMAT_INVALID','需要16kHz单声道PCM16',422)
            await asyncio.to_thread(recognition.send_audio_frame,pcm);last_seq=seq;audio_bytes+=len(pcm)
        await asyncio.to_thread(recognition.stop)
        complete=await asyncio.wait_for(asyncio.shield(provider_done),2)
        await asyncio.wait_for(drained.wait(),5)
        if sender.done():await sender
        await asyncio.wait_for(ws.send_json({'type':'finished',**binding,'last_seq':last_seq,
            'audio_bytes':audio_bytes,'complete':complete and not failed and all(seen.values()),
            'display_gap':partial_gap,'audio_gap':False}),5)
    except WebSocketDisconnect:pass
    except Exception as exc:
        if sender and not sender.done():
            # Cancel the only sender before sending the terminal error ourselves.
            sender.cancel();await asyncio.gather(sender,return_exceptions=True)
        code=exc.code if isinstance(exc,Fault) else 'ASR_CONNECTION_FAILED'
        retryable=code in {'ASR_CONNECTION_FAILED','ASR_READY_TIMEOUT'}
        try:await asyncio.wait_for(ws.send_json({'type':'error',**binding,'code':code,'retryable':retryable,'message':'实时字幕暂不可用，输入已保留'}),2)
        except Exception:pass
        failed=True
    finally:
        alive=False
        if sender:sender.cancel();await asyncio.gather(sender,return_exceptions=True)
        if recognition:recognition.abort()
        if receipt:
            try:
                with store.transaction(uid):
                    store.update('provider_runs',uid,receipt['id'],{'status':'failed' if failed else 'ended',
                    'last_seq':last_seq,'audio_bytes':audio_bytes,'display_gap':partial_gap,
                        'timings':getattr(recognition,'metrics',{}),'relay_timings':metrics})
            except Fault:pass
        try:await ws.close()
        except Exception:pass
