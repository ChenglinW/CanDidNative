"""Wire-level duplex readiness, PCM and final/error lifecycle with a local socket double."""
import json
import queue
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from pathlib import Path
import sys
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from adapters.live_asr import LiveRecognition
from memory import Fault

class Callback:
    def __init__(self):self.events=[]
    def on_ready(self):self.events.append('ready')
    def on_event(self,result):self.events.append(result.get_sentence())
    def on_complete(self):self.events.append('complete')
    def on_error(self,result):self.events.append(result.code)
class Socket:
    def __init__(self):self.incoming=queue.Queue();self.commands=[];self.frames=[];self.run_sent=threading.Event();self.closed=False;self.sock=self
    def getpeername(self):return ('127.0.0.1',443)
    def send(self,value):
        event=json.loads(value);self.commands.append(event)
        if event['header']['action']=='run-task':self.run_sent.set()
        if event['header']['action']=='finish-task':self.publish('task-finished',event['header']['task_id'])
    def publish(self,kind,task_id,**header):self.incoming.put(json.dumps({'header':{'event':kind,'task_id':task_id,**header}}))
    def recv(self):return self.incoming.get(timeout=2)
    def settimeout(self,value):pass
    def send_binary(self,frame):self.frames.append(frame)
    def shutdown(self):self.incoming.put('')
    def close(self,**kwargs):self.closed=True

@pytest.fixture
def wire(monkeypatch):
    sock=Socket();callback=Callback()
    def connect(url,**kwargs):
        assert url=='wss://dashscope.aliyuncs.com/api-ws/v1/inference'
        assert kwargs['header']['Authorization']=='Bearer offline-key'
        return sock
    monkeypatch.setattr('adapters.live_asr.websocket.create_connection',connect)
    spec=SimpleNamespace(international=False,key='offline-key',realtime_model='offline-model')
    recognition=LiveRecognition(spec,callback)
    yield recognition,sock,callback
    recognition.abort()
    if recognition.worker.ident is not None:recognition.worker.join(timeout=2)

def test_ready_waits_for_matching_provider_task_started(wire):
    recognition,sock,callback=wire
    with ThreadPoolExecutor(max_workers=1) as pool:
        start=pool.submit(recognition.start)
        assert sock.run_sent.wait(1)
        assert not start.done() and callback.events==[]
        sock.publish('task-started','unrelated-task')
        assert not recognition.ready.is_set()
        sock.publish('task-started',recognition.task_id)
        assert start.result(timeout=2) is recognition
    assert callback.events==['ready']
    payload=sock.commands[0]['payload']
    assert payload['parameters']['keep_dialect'] is True
    assert payload['parameters']['sample_rate']==16000

def test_pcm_and_final_are_ordered_and_finish_waits_for_complete(wire):
    recognition,sock,callback=wire
    sock.publish('task-started',recognition.task_id);recognition.start()
    recognition.send_audio_frame(b'\0\0'*160)
    sentence={'text':'粤语原话。','sentence_end':True}
    sock.incoming.put(json.dumps({'header':{'event':'result-generated','task_id':recognition.task_id},'payload':{'output':{'sentence':sentence}}}))
    recognition.stop()
    assert callback.events==['ready',sentence,'complete']
    assert sock.frames==[b'\0\0'*160]
    assert recognition.metrics['bytes']==320
    assert sock.commands[-1]['header']['action']=='finish-task'
    assert sock.closed

def test_provider_auth_failure_is_terminal_and_blocks_pcm(wire):
    recognition,sock,callback=wire
    sock.publish('task-failed',recognition.task_id,error_code='InvalidApiKey')
    with pytest.raises(Fault,match='实时转写服务'):recognition.start()
    assert callback.events==['ASR_AUTH_FAILED']
    with pytest.raises(Fault) as error:recognition.send_audio_frame(b'\0\0')
    assert error.value.code=='ASR_STREAM_CLOSED'
    assert sock.frames==[]
