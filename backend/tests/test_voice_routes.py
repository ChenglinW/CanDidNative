"""Exercise the real Agent, SQLite, HTTP and audio-event routes without cloud calls."""
import json
import time
import threading
from pathlib import Path
import sys
import uuid
import pytest
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from agent import TextAgent
from memory import Memory,Fault
from voice.routes import install

OWNER='11111111-1111-4111-8111-111111111111'
HEADERS={'Authorization':'Bearer offline-token'}
class Gateway:
    configured=True;base='https://offline.invalid';model='offline-model'
    def __init__(self):self.calls=[];self.block=False;self.ask=False;self.entered=threading.Event();self.release=threading.Event()
    def complete(self,messages,tools=True,*,on_delta=None,cancellation=None,**kwargs):
        self.calls.append(tools);self.last_messages=messages
        if self.ask:
            self.ask=False
            return {'role':'assistant','content':'','tool_calls':[{'id':'question-1','function':{'name':'request_input','arguments':json.dumps({'question':'目标是什么？','options':[]})}}]}
        if on_delta:on_delta('收到。')
        self.entered.set()
        if self.block:
            deadline=time.monotonic()+3
            while not self.release.wait(.01) and time.monotonic()<deadline:cancellation.check()
            cancellation.check()
        return {'role':'assistant','content':'收到。'}
class Speech:
    tts_model='offline-tts';voice='offline-voice'
    def __init__(self):self.spoken=[]
    def check(self):pass
    def stream_synthesize(self,text,on_audio,guard,cancellation):
        guard();self.spoken.append(text);on_audio(b'\0\0'*3000);return [{'fixture':True}]

@pytest.fixture
def system(tmp_path):
    store=Memory(tmp_path/'memory.sqlite',tmp_path/'files')
    gateway=Gateway();agent=TextAgent(store,gateway=gateway);speech=Speech();app=FastAPI()
    @app.exception_handler(Fault)
    async def error(request,exc):return JSONResponse({'error':{'code':exc.code}},status_code=exc.status)
    def owner(request:Request):
        if request.headers.get('authorization')!='Bearer offline-token':raise Fault('UNAUTHORIZED','No auth',401)
        return OWNER
    install(app,owner,store,agent,speech)
    client=TestClient(app);thread=agent.create(OWNER)['id']
    yield client,agent,store,gateway,speech,thread
    gateway.release.set();agent.close()
    agent._pool.shutdown(wait=True,cancel_futures=True)
    store.db.close()

def body(thread,text='你好'):
    return {'thread_id':thread,'content':text,'client_request_id':str(uuid.uuid4()),
            'voice_session_id':str(uuid.uuid4()),'input_turn_id':str(uuid.uuid4()),
            'generation_id':str(uuid.uuid4()),'continuous':True}
def wait(agent,task,status):
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        value=agent.tasks.get(OWNER,task)
        if value['status']==status:return value
        if value['status']=='failed':raise AssertionError(value['error'])
        time.sleep(.01)
    raise AssertionError('Task did not reach '+status)
def post(client,value):return client.post('/v1/voice/turns',json=value,headers=HEADERS)
def request_path(thread,value):return '/v1/voice/threads/'+thread+'/requests/'+value['client_request_id']

def test_voice_request_is_idempotent_and_conflicting_retry_rejected(system):
    client,agent,store,gateway,speech,thread=system;value=body(thread)
    first=post(client,value);assert first.status_code==202
    task=wait(agent,first.json()['id'],'completed')
    assert post(client,value).json()['id']==task['id']
    assert len(agent.tasks.list(OWNER,thread))==1
    assert client.get(request_path(thread,value),headers=HEADERS).json()['status']=='accepted'
    assert post(client,{**value,'content':'不同正文'}).json()['error']['code']=='REQUEST_CONFLICT'
    assert gateway.calls==[False]

def test_cancel_before_acceptance_leaves_tombstone_and_no_model_call(system):
    client,agent,store,gateway,speech,thread=system;value=body(thread)
    assert client.post(request_path(thread,value)+'/cancel',headers=HEADERS).status_code==200
    assert post(client,value).json()['error']['code']=='VOICE_TURN_CANCELLED'
    assert client.get(request_path(thread,value),headers=HEADERS).json()['status']=='cancelled'
    assert gateway.calls==[]

def test_barge_cancel_preserves_partial_and_unrelated_thread(system):
    client,agent,store,gateway,speech,thread=system;gateway.block=True;value=body(thread)
    first=post(client,value).json();assert gateway.entered.wait(2)
    client.post(request_path(thread,value)+'/cancel',headers=HEADERS)
    task=wait(agent,first['id'],'cancelled')
    messages=store.rows('chat_messages',OWNER,thread_id=thread)
    assert any(m.get('incomplete') and m['content']=='收到。' for m in messages)
    other=agent.create(OWNER)['id'];gateway.block=False;gateway.release.set()
    second=post(client,body(other)).json();wait(agent,second['id'],'completed')
    assert agent.tasks.get(OWNER,task['id'])['status']=='cancelled'

def test_only_final_answer_commits_speech_not_planner_deltas(system):
    client,agent,store,gateway,speech,thread=system;value=body(thread,'帮我复盘沟通')
    task=post(client,value).json();wait(agent,task['id'],'completed')
    events=agent.tasks.events.after(OWNER,task['id'],0)
    assert gateway.calls==[True,False]
    assert ''.join(e['data']['text'] for e in events if e['kind']=='speech.segment')=='收到。'
    assert ''.join(e['data']['text'] for e in events if e['kind']=='text.delta')=='收到。'

def test_audio_has_ordered_pcm_and_cannot_replay_generation(system):
    client,agent,store,gateway,speech,thread=system;value=body(thread)
    task=post(client,value).json();wait(agent,task['id'],'completed')
    path='/v1/voice/output/'+task['id']
    with client.websocket_connect(path) as ws:
        ws.send_json({'token':'offline-token','generation_id':value['generation_id']})
        events=[]
        while True:
            event=ws.receive_json();events.append(event)
            if event['type']=='audio':ws.send_json({'type':'played','seq':event['seq']})
            if event['type']=='finished':break
        assert [e['seq'] for e in events if e['type']=='audio']==[1,2]
        assert all(e['generation_id']==value['generation_id'] for e in events)
    with client.websocket_connect(path) as ws:
        ws.send_json({'token':'offline-token','generation_id':value['generation_id']})
        assert ws.receive_json()['code']=='VOICE_OUTPUT_EXPIRED'
    assert speech.spoken==['收到。']
    assert store.rows('provider_runs',OWNER)[0]['status']=='completed'

def test_question_response_reuses_task_and_cancel_does_not_destroy_question(system):
    client,agent,store,gateway,speech,thread=system;gateway.ask=True;value=body(thread,'需要先问我目标')
    first=post(client,value).json();task=wait(agent,first['id'],'waiting_input')
    client.post(request_path(thread,value)+'/cancel',headers=HEADERS)
    assert agent.tasks.get(OWNER,task['id'])['status']=='waiting_input'
    assert post(client,body(thread)).json()['error']['code']=='VOICE_INPUT_CHANGED'
    answer=body(thread,'明确需求');answer.update(task_id=task['id'],input_id=task['input_request']['id'],expected_attempt=task['attempt'])
    resumed=post(client,answer);assert resumed.status_code==202 and resumed.json()['id']==task['id']
    wait(agent,task['id'],'completed')
    assert len(agent.tasks.list(OWNER,thread))==1
    assert client.get(request_path(thread,value),headers=HEADERS).json()['status']=='accepted'
    assert client.get(request_path(thread,answer),headers=HEADERS).json()['status']=='accepted'

def test_auth_and_foreign_thread_are_rejected_without_provider_work(system):
    client,agent,store,gateway,speech,thread=system
    assert client.post('/v1/voice/turns',json=body(thread)).status_code==401
    assert post(client,body(str(uuid.uuid4()))).status_code==404
    assert gateway.calls==[]

def test_http_cancel_stops_output_even_when_agent_has_already_completed(system):
    client,agent,store,gateway,speech,thread=system;value=body(thread)
    task=post(client,value).json();wait(agent,task['id'],'completed')
    path='/v1/voice/output/'+task['id']
    with client.websocket_connect(path) as ws:
        ws.send_json({'token':'offline-token','generation_id':value['generation_id']})
        while ws.receive_json()['type']!='audio':pass
        assert client.post(request_path(thread,value)+'/cancel',headers=HEADERS).status_code==200
        while True:
            event=ws.receive_json()
            if event['type']=='error':
                assert event['code']=='VOICE_OUTPUT_STOPPED';break
            assert event['type']!='finished'
    with client.websocket_connect(path) as ws:
        ws.send_json({'token':'offline-token','generation_id':value['generation_id']})
        assert ws.receive_json()['code']=='VOICE_OUTPUT_STOPPED'


def test_spoken_answer_uses_same_grounded_task_with_short_reply_instruction(system):
    client,agent,store,gateway,speech,thread=system
    task=post(client,body(thread)).json();wait(agent,task['id'],'completed')
    assert '连续语音对话的最终回答' in gateway.last_messages[-1]['content']
    assert '姓名、数字' in gateway.last_messages[-1]['content']
    assert any(m['content']=='收到。' for m in store.rows('chat_messages',OWNER,thread_id=thread))


def test_voice_preparation_saves_report_before_committing_final_speech(system):
    client,agent,store,gateway,speech,thread=system
    def complete(messages,tools=True,*,on_delta=None,**kw):
        gateway.calls.append(tools)
        if not store.rows('companion_preparations',OWNER):
            args={'client':'客户甲','goal':'确认试点范围','scenario':'sales','sections':[{'title':'目标','text':'确认范围'},{'title':'问题','text':'有哪些需求？'},{'title':'待核实','text':'时间未知'}]}
            return {'role':'assistant','content':'','tool_calls':[{'id':'prepare','function':{'name':'save_preparation','arguments':json.dumps(args)}}]}
        if on_delta:on_delta('准备包已保存。')
        return {'role':'assistant','content':'准备包已保存。'}
    gateway.complete=complete
    task=post(client,body(thread,'帮我准备客户甲沟通，目标确认试点范围。')).json()
    wait(agent,task['id'],'completed')
    assert len(store.rows('companion_preparations',OWNER))==1
    events=agent.tasks.events.after(OWNER,task['id'],0)
    assert gateway.calls==[True]
    assert ''.join(e['data']['text'] for e in events if e['kind']=='speech.segment')=='准备包已保存，可以打开查看。'
