"""Offline regression cases for QA. No provider calls or real microphones.

Run with the repository venv; all providers are local doubles.
"""
import asyncio
import base64
from contextlib import contextmanager
from pathlib import Path
import sys
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from voice.live_bridge import live_speech
from voice.committer import SpeechCommitter
from memory import Fault

class Store:
    def check_owner(self,*a):pass
    @contextmanager
    def transaction(self,*a):yield
    def put(self,*a):return {'id':str(uuid.uuid4())}
    def update(self,*a):pass

class Socket:
    def __init__(self,packets):self.packets=asyncio.Queue();self.sent=[];self.closed=False
    async def accept(self):pass
    async def receive_json(self):return await self.packets.get()
    async def send_json(self,value):self.sent.append(value)
    async def close(self):self.closed=True

class Result:
    def __init__(self,sentence):self.sentence=sentence
    def get_sentence(self):return self.sentence
    def get_usage(self,*a):return None

class Speech:
    realtime_model='offline-test';metrics={}
    def check(self):pass
    def live(self,callback):self.callback=callback;callback.on_ready();return self
    def send_audio_frame(self,pcm):
        # More than the partial buffer size: partials may coalesce, the final must survive.
        for n in range(140):self.callback.on_event(Result({'sentence_id':1,'text':str(n),'sentence_end':False}))
        self.callback.on_event(Result({'sentence_id':1,'text':'完整文字。','sentence_end':True}))
    def stop(self):self.callback.on_complete()
    def abort(self):pass

async def relay(packets):
    sock=Socket(packets)
    for p in packets:await sock.packets.put(p)
    await asyncio.wait_for(live_speech(sock,lambda req:'owner',Store(),Speech()),3)
    return sock

def test_final_delivered_before_finished_even_after_partial_burst():
    pcm=b'\0\0'*160
    sock=asyncio.run(relay([{'token':'local-test'}, {'seq':0,'audio':base64.b64encode(pcm).decode()}, {'type':'finish','last_seq':0}]))
    finals=[i for i,e in enumerate(sock.sent) if e.get('sentence',{}).get('sentence_end')]
    finished=[i for i,e in enumerate(sock.sent) if e['type']=='finished']
    assert len(finals)==1 and finished[0]>finals[0]
    assert sock.sent[finished[0]]['complete'] is True
    assert sock.sent[finished[0]]['audio_bytes']==len(pcm)
    assert sock.closed

def test_out_of_order_audio_cannot_return_success():
    sock=asyncio.run(relay([{'token':'local-test'},{'seq':2,'audio':'AAA='}]))
    assert any(e.get('code')=='AUDIO_SEQUENCE_INVALID' and e['retryable'] is False for e in sock.sent)
    assert not any(e['type']=='finished' for e in sock.sent)

class Context:
    owner_id='owner';task_id='task';workspace_id='space'
    def remaining(self):return 10
class Tasks:
    def __init__(self):self.events=[]
    def get(self,*a):return {'voice_context':{'generation_id':'generation','voice_session_id':'session'}}
    def emit(self,context,kind,data):self.events.append((kind,data))
class Validation:
    def validate(self,*a):pass
class Runtime:
    def __init__(self):self.tasks=Tasks();self.context_manager=Validation()

def test_speech_commit_validates_citations_before_tts():
    runtime=Runtime();commit=SpeechCommitter(runtime,Context(),[])
    try:commit.push('这是未经取得的来源[7]。')
    except Fault as exc:assert exc.code=='SOURCE_CITATION_INVALID'
    else:raise AssertionError('Invalid source was committed')
    assert runtime.tasks.events==[]

def test_code_and_urls_do_not_become_spoken_content():
    runtime=Runtime();commit=SpeechCommitter(runtime,Context(),[])
    commit.push('```json\n');commit.push('{"hidden":true}\n');commit.push('```\n');commit.push('看正文 https://example.com/path。\n');commit.finish()
    spoken=''.join(data['text'] for _,data in runtime.tasks.events)
    assert 'hidden' not in spoken and 'https' not in spoken and '正文' in spoken
