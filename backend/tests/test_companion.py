"""V2 acceptance corpus: real domain/HTTP/storage, deterministic provider boundaries."""
import io,json,zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime,timedelta,timezone
from pathlib import Path
import sys
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory,L1,L2,ident,now,Fault
from companion import Companion
from tasks.materials import Materials
from tasks.workspaces import WorkspaceStore
from adapters.sqlite_memory import SQLiteMemoryAdapter
from adapters.sources import version

A='11111111-1111-4111-8111-111111111111'
B='22222222-2222-4222-8222-222222222222'
@pytest.fixture
def domain(tmp_path):
    store=Memory(tmp_path/'memory.sqlite3',tmp_path/'files')
    yield Companion(store)
    store.db.close()

def record(d,text,speaker='unknown'):
    s=d.store.create_session(A,{'client_request_id':ident(),'scenario':'sales','kind':'live','consent':'yes','consent_ack_text_version':'v1'})
    d.store.update('sessions',A,s['id'],{'transcript_revision':1,'llm_consent_at':now(),'pipeline_status':'done','title':text[:18]})
    line=d.store.put('transcript_segments',A,{'session_id':s['id'],'speaker':speaker,'speaker_id':'part0:0','start_ms':1000,'end_ms':3000,'text':text,'transcript_revision':1},L1)
    ref={'source_id':'transcript:'+line['id'],'source_version':version(line),'session_id':s['id'],'start_ms':1000,'end_ms':3000}
    d.store.put('recording_knowledge',A,{'session_id':s['id'],'revision':'1','part':0,'title':'沟通复盘','text':text,'evidence_refs':[ref],'status':'active','producer':'test','rubric_version':'test'},L2,source='ai')
    return s,line,ref

def pack(client='客户甲',when=None):
    return {'client':client,'goal':'确认实施范围','scenario':'sales','scheduled_at':when,'concerns':'时间待核实','sections':[{'title':'目标','text':'确认实施范围'},{'title':'关键问题','text':'请核对服务范围。'},{'title':'待核实','text':'报价尚未提供。'}]}

def test_one_thread_concurrent_and_owner_isolation(domain):
    with ThreadPoolExecutor(max_workers=8) as pool:
        ids=list(pool.map(lambda _:domain.thread(A)['id'],range(20)))
    assert len(set(ids))==1
    assert domain.thread(B)['id']!=ids[0]
    assert len(domain.store.rows('project_spaces',A))==1
    with pytest.raises(Fault):domain.store.get('chat_threads',B,ids[0])

def test_all_five_unlinked_recordings_and_customer_quotes_are_retrievable(domain):
    thread=domain.thread(A);wid=thread['workspace_id']
    records=[record(domain,t) for t in ['客户甲预算18万元','客户乙预算80万元','面试要求Python','采购确认服务范围','旧客户五承诺周四给接口清单']]
    materials=Materials(domain.store,domain.spaces)
    result=materials.search(A,wid,'旧客户五 接口清单',[])
    assert any('旧客户五承诺周四给接口清单' in i['text'] for i in result['items'])
    assert any(i.get('session_id')==records[-1][0]['id'] for i in result['items'])
    found=materials.search(A,wid,'预算',[])['items']
    assert any('客户甲预算18万元' in i['text'] for i in found)
    assert any('客户乙预算80万元' in i['text'] for i in found)
    # Unknown speakers remain meeting facts, never implicitly become self.
    assert all(i.get('personal_identity_confirmed') is False for i in found if i['source_id'].startswith('transcript:'))

def test_recording_publication_retry_revision_and_timeline(domain):
    t=domain.thread(A)
    user=domain.store.put('chat_messages',A,{'thread_id':t['id'],'role':'user','content':'先聊目标','sources':[],'tool_steps':[]},L1)
    s,line,ref=record(domain,'客户问包含什么培训')
    domain.publish_recording(A,s['id'],'1');domain.publish_recording(A,s['id'],'1')
    messages=domain.store.rows('chat_messages',A,thread_id=t['id'])
    assert len(messages)==2
    published=next(m for m in messages if m.get('recording_id'))
    assert published['recording_id']==s['id'] and published['created_at']>user['created_at']
    assert domain.store.get('chat_threads',A,t['id'])['message_count']==2
    domain.store.update('sessions',A,s['id'],{'transcript_revision':2})
    domain.store.put('recording_knowledge',A,{'session_id':s['id'],'revision':'2','part':0,'title':'校准复盘','text':'已校准的新结果','evidence_refs':[ref],'status':'active','producer':'test','rubric_version':'test'},L2,source='ai')
    domain.publish_recording(A,s['id'],'2')
    revised=domain.store.rows('chat_messages',A,recording_id=s['id'])
    assert len(revised)==1 and revised[0]['id']==published['id']
    assert revised[0]['recording_revision']=='2' and '已校准的新结果' in revised[0]['content']
    domain.store.update('sessions',A,s['id'],{'pipeline_status':'transcribed'})
    with pytest.raises(Fault):domain.publish_recording(A,s['id'],'1')

def test_preparation_same_card_identity_order_and_completion(domain):
    t=domain.thread(A);future=(datetime.now(timezone.utc)+timedelta(days=1)).isoformat()
    past=(datetime.now(timezone.utc)-timedelta(days=1)).isoformat()
    undated=domain.save_preparation(A,t['id'],'unknown',pack(),[])
    upcoming=domain.save_preparation(A,t['id'],'future',pack('客户乙',future),[])
    old=domain.save_preparation(A,t['id'],'past',pack('客户丙',past),[])
    assert domain.snapshot(A)['next_preparation']['id']==upcoming['id']
    card=next(m for m in domain.store.rows('chat_messages',A) if m.get('preparation_package_id')==upcoming['id'])
    assert domain.save_preparation(A,t['id'],'future',pack('客户乙',future),[])['id']==card['preparation_package_id']
    domain.finish(A,upcoming['id'],upcoming['version'])
    assert domain.snapshot(A)['next_preparation']['id']==undated['id']
    assert old['id'] in {p['id'] for p in domain.snapshot(A)['preparations']}
    with pytest.raises(Fault):domain.finish(A,upcoming['id'],1)

def test_preparation_new_version_replaces_same_meeting_not_other_customer(domain):
    t=domain.thread(A)
    a=domain.save_preparation(A,t['id'],'one',pack(),[])
    other=domain.save_preparation(A,t['id'],'other',pack('另一客户'),[])
    b=domain.save_preparation(A,t['id'],'two',pack(),[])
    assert a['id']!=b['id'] and b['version']==2
    assert domain.store.get('companion_preparations',A,a['id'])['status']=='superseded'
    assert domain.store.get('companion_preparations',A,other['id'])['status']=='ready'
    with pytest.raises(Fault):domain.save_preparation(A,t['id'],'bad',pack(when='2026-10-18T12:00:00'),[])

def test_expression_user_revision_survives_and_stale_source_excluded(domain):
    s,line,ref=record(domain,'我们先核对三家门店的服务范围。','self')
    result={'expressions':[{'title':'确认范围','text':'先确认门店与服务内容，再讨论排期。','quote':'先核对三家门店','segment_id':line['id'],'kind':'值得复用'}]}
    domain.save_expressions(A,s['id'],'1',result,[line],0)
    e=domain.memory(A)['expressions'][0]
    domain.edit_expression(A,e['id'],'我想先了解服务范围。',1)
    domain.save_expressions(A,s['id'],'1',result,[line],0)
    assert domain.memory(A)['expressions'][0]['body']['text']=='我想先了解服务范围。'
    domain.store.update('sessions',A,s['id'],{'transcript_revision':2})
    assert domain.memory(A)['expressions'][0]['reference_status']=='superseded'
    assert Materials(domain.store,domain.spaces).search(A,domain.thread(A)['workspace_id'],'门店',[])['items']==[]

def test_deleted_document_not_resurrected_by_global_scope_or_old_id(domain):
    raw=domain.store.put('documents',A,{'title':'报价.txt','material_kind':'onboarding_original'},L1)
    parsed=domain.store.put('documents',A,{'title':'报价.txt','text':'服务费为测试价格K73','material_kind':'user_document','onboarding_original_id':raw['id'],'status':'active'},L1)
    wid=domain.thread(A)['workspace_id'];materials=Materials(domain.store,domain.spaces)
    assert materials.search(A,wid,'K73',[])['items']
    domain.store.db.execute("INSERT INTO requests VALUES(?,?,'onboarding_document_removed',?)",(A,raw['id'],raw['id']))
    assert materials.search(A,wid,'K73',[])['items']==[]
    with pytest.raises(Fault):domain.adapter.resolve(A,'document:'+parsed['id'],wid)

def test_pptx_actual_upload_parse_and_slide_sources(tmp_path,monkeypatch,bind_app_store):
    import app
    from fastapi.testclient import TestClient
    store=Memory(tmp_path/'test.sqlite',tmp_path/'files');bind_app_store(app,store)
    data=io.BytesIO()
    with zipfile.ZipFile(data,'w') as z:
        for n,text in [(1,'门店系统包含培训'),(2,'验收代号 PPT-K73')]:
            z.writestr(f'ppt/slides/slide{n}.xml',f'<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>{text}</a:t></a:r></a:p></p:sld>')
    client=TestClient(app.app);headers={'Authorization':'Bearer test-token'}
    res=client.post('/v1/onboarding/documents?filename=产品.pptx',headers=headers,content=data.getvalue())
    assert res.status_code==200
    job=store.get('business_jobs',A,res.json()['job_id']);job=store.update('business_jobs',A,job['id'],{'status':'running'})
    result=app.onboarding_service().extract(A,job) if hasattr(app,'onboarding_service') else None
    if result is None:
        from onboarding import Onboarding
        result=Onboarding(store,app.business).extract(A,job)
    parsed=store.get('documents',A,result['document_id'])
    assert 'PPT-K73' in parsed['text'] and parsed['pages'][1]['page']==2
    state=client.get('/v1/companion',headers=headers).json()
    found=Materials(store,WorkspaceStore(store)).search(A,state['thread']['workspace_id'],'PPT-K73',[])['items']
    assert found and 'PPT-K73' in found[0]['text']

def test_deleted_document_invalidates_two_levels_of_derived_assets(domain):
    raw=domain.store.put('documents',A,{'title':'原件','material_kind':'onboarding_original'},L1)
    doc=domain.store.put('documents',A,{'text':'DELETE-CANARY-733','status':'active','onboarding_original_id':raw['id']},L1)
    parent=domain.store.put('assets',A,{'body':{'text':'DELETE-CANARY-733'},'status':'draft','evidence_refs':[{'source_id':'document:'+doc['id'],'source_version':version(doc)}],'producer':'test','rubric_version':'test'},L2,source='ai')
    child=domain.store.put('assets',A,{'body':{'text':'DELETE-CANARY-733 derived'},'status':'draft','evidence_refs':[{'source_id':'asset:'+parent['id'],'source_version':version(parent)}],'producer':'test','rubric_version':'test'},L2,source='ai')
    wid=domain.thread(A)['workspace_id']
    assert Materials(domain.store,domain.spaces).search(A,wid,'DELETE-CANARY',[])['items']
    domain.store.db.execute("INSERT INTO requests VALUES(?,?,'onboarding_document_removed',?)",(A,raw['id'],raw['id']))
    assert not Materials(domain.store,domain.spaces).search(A,wid,'DELETE-CANARY',[])['items']
    for row in [parent,child]:
        with pytest.raises(Fault):domain.adapter.resolve(A,'asset:'+row['id'],wid)

def test_current_queued_user_input_is_last_model_turn(domain):
    from types import SimpleNamespace
    from agent import TextAgent
    agent=TextAgent(domain.store)
    try:
        t=domain.thread(A);space=domain.spaces.get(A,t['workspace_id']);budget=agent.config.budget('chat')
        history=[{'id':'a','role':'user','content':'客户甲问题','task_id':'old','sources':[]},
            {'id':'b','role':'user','content':'客户乙当前问题','task_id':'current','sources':[]},
            {'id':'answer-a','role':'assistant','content':'客户甲回答','task_id':'old','sources':[]},
            {'id':'proactive','role':'assistant','content':'一场录音已经整理','sources':[]}]
        context=SimpleNamespace(owner_id=A,workspace_id=space['id'],thread_id=t['id'],task_id='current',budget=budget,
            occasion_id=None,task_kind='chat',session_id=None,remaining=lambda:90,cancellation=None)
        result=agent.context_manager.prepare(context,agent.snapshot(budget,A,space),history,'客户乙当前问题')
        assert result.messages[-1]=={'role':'user','content':'客户乙当前问题'}
        assert sum(m['content']=='客户乙当前问题' for m in result.messages)==1
        assert any(m['content']=='客户甲回答' for m in result.messages)
    finally:agent.close()

def test_long_summary_batches_keep_first_goal_last_todo_and_checkpoint(domain):
    from dataclasses import replace
    from agent_runtime.config import RuntimeConfig
    from agent_runtime.summary import SummaryStore
    class Gateway:
        model='summary-fixture'
        def __init__(self):self.calls=[]
        def complete(self,messages,**kw):
            body=messages[-1]['content'];self.calls.append(len(body));assert len(body)<=2200
            data=json.loads(body);previous=data['previous_summary'];rows=data['new_messages']
            first=(previous or {}).get('goals') or [{'text':'客户甲目标保持','support':[{'message_id':rows[0]['id'],'quote':rows[0]['content'][:60]}]}]
            return {'content':json.dumps({'goals':first,'constraints':[],'completed_steps':[],
                'pending_questions':[{'text':rows[-1]['content'][:80],'support':[{'message_id':rows[-1]['id'],'quote':rows[-1]['content'][:60]}]}],'uncertainties':[]})}
    gateway=Gateway();summary=SummaryStore(domain.store,domain.adapter,gateway)
    t=domain.thread(A);budget=replace(RuntimeConfig().budget('chat'),summary_input_chars=2200)
    rows=[{'id':str(i),'role':'user','content':('客户甲目标保持' if i==0 else '最后要确认接口' if i==19 else '中间进度')+' 测试填充'*60,'sources':[]} for i in range(20)]
    result=summary.extend(A,t['id'],rows,None,budget,lambda:90,workspace_id=t['workspace_id'])
    assert len(gateway.calls)>=3 and max(gateway.calls)<=2200
    assert result['covered_message_ids']==[str(i) for i in range(20)]
    assert result['structured']['goals'][0]['text']=='客户甲目标保持'
    assert '最后要确认接口' in result['structured']['pending_questions'][0]['text']
    assert len(domain.store.rows('agent_summaries',A,status='valid'))==1
    count=len(gateway.calls)
    assert summary.extend(A,t['id'],rows,result,budget,lambda:90,workspace_id=t['workspace_id'])['id']==result['id']
    assert len(gateway.calls)==count

def test_real_recording_knowledge_job_publishes_expression_and_one_message(domain):
    from types import SimpleNamespace
    from tasks.business import BusinessJobs
    from tasks.recordings import Recordings
    s,line,ref=record(domain,'我们先确认接口，再安排三家门店试点。','self')
    domain.store.db.execute('DELETE FROM recording_knowledge WHERE owner_id=?',(A,))
    class Gateway:
        model='knowledge-fixture';configured=True;base='https://test.invalid'
        calls=0
        def complete(self,messages,**kw):
            self.calls+=1
            return {'content':json.dumps({'title':'确认试点','summary':'先确认接口再排期。','tags':[],
                'expressions':[{'title':'范围确认','text':'先核对接口和服务范围。','quote':'先确认接口','segment_id':line['id'],'kind':'值得复用'}]})}
    gateway=Gateway();jobs=BusinessJobs(domain.store,gateway,domain.spaces);recordings=Recordings(domain.store,jobs,SimpleNamespace())
    try:
        job=jobs.submit(A,'recording_knowledge',s['id'],'1');jobs.run(A,job)
        assert domain.store.get('business_jobs',A,job['id'])['status']=='completed'
        assert domain.store.get('sessions',A,s['id'])['pipeline_status']=='done'
        assert len(domain.memory(A)['expressions'])==1
        assert len(domain.store.rows('chat_messages',A,recording_id=s['id']))==1
        # Simulate retry after publication, with the original successful chunk checkpoint.
        job=domain.store.update('business_jobs',A,job['id'],{'status':'queued','attempt':2});jobs.run(A,job)
        assert gateway.calls==1 and len(domain.memory(A)['expressions'])==1
        assert len(domain.store.rows('chat_messages',A,recording_id=s['id']))==1
    finally:jobs.close()

def test_live_ask_retries_bind_recording_and_include_latest_unverified_tail(tmp_path,bind_app_store):
    import app,time
    from fastapi.testclient import TestClient
    store=Memory(tmp_path/'live.sqlite',tmp_path/'files');bind_app_store(app,store);d=Companion(store)
    s,_,_=record(d,'当前沟通','self');other,_,_=record(d,'另一场沟通','self')
    class Gateway:
        model='live-fixture';configured=True;base='https://test.invalid'
        seen=[]
        def complete(self,messages,**kw):
            self.seen=messages
            return {'role':'assistant','content':'请先核对范围。'}
    gateway=Gateway();app.agent.gateway=gateway
    client=TestClient(app.app);headers={'Authorization':'Bearer test-token'}
    sentences=[{'text':'前文测试'*350,'start_ms':i*1000} for i in range(8)]+[{'text':'客户最新问题 TAIL-739 服务范围','start_ms':9000}]
    body={'client_request_id':ident(),'recording_id':s['id'],'question':'客户刚才最关注什么？','sentences':sentences}
    response=client.post('/v1/companion/live-ask',headers=headers,json=body);assert response.status_code==200,response.text
    tid=response.json()['id']
    for _ in range(100):
        task=client.get('/v1/agent/tasks/'+tid,headers=headers).json()
        if task['status'] not in {'running','queued'}:break
        time.sleep(.02)
    assert task['status']=='completed',task
    serialized=json.dumps(gateway.seen,ensure_ascii=False)
    assert 'TAIL-739' in serialized and '未经校准' in serialized
    assert client.post('/v1/companion/live-ask',headers=headers,json=body).json()['id']==tid
    for changed in [{**body,'question':'不同问题'},{**body,'recording_id':other['id']},{**body,'sentences':[{'text':'不同字幕','start_ms':0}]}]:
        assert client.post('/v1/companion/live-ask',headers=headers,json=changed).status_code==409
    assert Materials(store,d.spaces).search(A,d.thread(A)['workspace_id'],'TAIL-739',[])['items']==[]

def test_preparation_cannot_finish_with_only_unsaved_model_prose(domain):
    import time
    from agent import TextAgent
    text='帮我准备客户甲沟通，目标是确认接口，时间待定。'
    class Gateway:
        model='prepare-fixture';configured=True;base='https://test.invalid'
        calls=0
        def complete(self,messages,**kw):
            self.calls+=1
            if any(m['role']=='tool' and 'preparation_package_id' in m.get('content','') for m in messages):
                return {'role':'assistant','content':'准备包已保存。'}
            if any('尚无持久化准备包' in m.get('content','') for m in messages):
                data={**pack(),'user_quote':text,'sections':pack()['sections'],'source_ids':[]}
                return {'role':'assistant','content':'','tool_calls':[{'id':'save','type':'function','function':{'name':'save_preparation','arguments':json.dumps(data,ensure_ascii=False)}}]}
            return {'role':'assistant','content':'这里是完整的会前准备报告，但尚未真正保存。'}
    gateway=Gateway();agent=TextAgent(domain.store,gateway=gateway)
    try:
        thread=domain.thread(A);task=agent.submit(A,thread['id'],text,ident())
        for _ in range(150):
            state=agent.tasks.get(A,task['id'])
            if state['status'] not in {'queued','running'}:break
            time.sleep(.02)
        assert state['status']=='completed',state.get('error')
        assert gateway.calls>=3 and domain.snapshot(A)['next_preparation']
        assert len(domain.store.rows('chat_messages',A,preparation_package_id=domain.snapshot(A)['next_preparation']['id']))==1
    finally:agent.close()

def test_provider_control_markup_is_reissued_without_becoming_a_chat_answer(domain):
    import time
    from agent import TextAgent
    class Gateway:
        model='wire-fixture';configured=True;base='https://test.invalid';calls=0
        def complete(self,messages,**kw):
            self.calls+=1
            if self.calls==1:return {'role':'assistant','content':'<｜｜DSML｜｜tool_calls><｜｜DSML｜｜invoke name="read_source">'}
            assert '必须使用 API 的 tool_calls' in messages[-1]['content']
            return {'role':'assistant','content':'资料已查阅，请先核对服务范围。'}
    gateway=Gateway();agent=TextAgent(domain.store,gateway=gateway)
    try:
        task=agent.submit(A,domain.thread(A)['id'],'请概括资料',ident())
        for _ in range(150):
            state=agent.tasks.get(A,task['id'])
            if state['status'] not in {'queued','running'}:break
            time.sleep(.02)
        assert state['status']=='completed' and gateway.calls==2
        assert all('DSML' not in m.get('content','') for m in domain.store.rows('chat_messages',A))
    finally:agent.close()

def test_split_control_markup_is_never_streamed_to_user():
    import httpx
    from agent_runtime.providers import Gateway
    wire='正常前文。<｜｜DSML｜｜tool_calls><｜｜DSML｜｜invoke name="read_source">'
    chunks=[{'choices':[{'index':0,'delta':{'content':c},'finish_reason':None}]} for c in wire]
    chunks.append({'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]})
    stream=''.join('data: '+json.dumps(c,ensure_ascii=False)+'\n\n' for c in chunks)+'data: [DONE]\n\n'
    gateway=Gateway();gateway._key='test-not-a-real-key';seen=[]
    with httpx.Client(transport=httpx.MockTransport(lambda r:httpx.Response(200,headers={'content-type':'text/event-stream'},text=stream))) as client:
        result=gateway._stream(client,{},seen.append,None)
    assert ''.join(seen)=='正常前文。' and result['content']==wire

def test_device_timezone_is_validated_and_frozen_in_agent_context(tmp_path,bind_app_store):
    import app,time
    from fastapi.testclient import TestClient
    store=Memory(tmp_path/'zone.sqlite',tmp_path/'files');bind_app_store(app,store)
    client=TestClient(app.app);headers={'Authorization':'Bearer test-token'}
    assert client.patch('/v1/profile',headers=headers,json={'timezone':'Mars/Fake'}).status_code==422
    assert client.patch('/v1/profile',headers=headers,json={'timezone':'America/Los_Angeles'}).status_code==200
    class Gateway:
        model='timezone-fixture';configured=True;base='https://test.invalid';seen=[]
        def complete(self,messages,**kw):self.seen=messages;return {'role':'assistant','content':'按你所在地时间准备。'}
    gateway=Gateway();app.agent.gateway=gateway
    thread=Companion(store).thread(A)
    task=app.agent.submit(A,thread['id'],'明天下午三点见客户，先聊聊注意事项。',ident())
    for _ in range(150):
        state=app.agent.tasks.get(A,task['id'])
        if state['status'] not in {'queued','running'}:break
        time.sleep(.02)
    assert state['status']=='completed'
    assert app.agent.tasks.get(A,task['id'])['config_snapshot']['timezone']=='America/Los_Angeles'
    assert any('America/Los_Angeles' in m['content'] and 'request_time' in m['content'] for m in gateway.seen)

def test_single_chat_queue_cancel_and_cursor_recovery(domain):
    import threading,time
    from agent import TextAgent
    class Gateway:
        model='queue-fixture';configured=True;base='https://test.invalid'
        entered=threading.Event();release=threading.Event();seen=[]
        def complete(self,messages,on_delta=None,cancellation=None,**kw):
            last=next(m['content'] for m in reversed(messages) if m['role']=='user');self.seen.append(last)
            if last=='第一轮':
                if on_delta:on_delta('已生成的片段')
                self.entered.set()
                while not self.release.wait(.01):cancellation.check()
                cancellation.check()
            return {'role':'assistant','content':'第二轮已完成'}
    gateway=Gateway();agent=TextAgent(domain.store,gateway=gateway)
    try:
        thread=domain.thread(A);first=agent.submit(A,thread['id'],'第一轮',ident())
        assert gateway.entered.wait(3)
        second=agent.submit(A,thread['id'],'第二轮',ident())
        assert agent.tasks.get(A,second['id'])['status']=='queued'
        agent.cancel(A,first['id'],preserve_partial=True);gateway.release.set()
        for _ in range(200):
            state=agent.tasks.get(A,second['id'])
            if state['status'] not in {'queued','running'}:break
            time.sleep(.02)
        assert state['status']=='completed' and gateway.seen==['第一轮','第二轮']
        assert any(m.get('incomplete') and m['content']=='已生成的片段' for m in domain.store.rows('chat_messages',A))
        events=agent.tasks.events.after(A,second['id'],0);cut=events[len(events)//2]['seq']
        tail=agent.tasks.events.after(A,second['id'],cut)
        assert tail==[e for e in events if e['seq']>cut]
        assert [e['seq'] for e in events]==list(range(1,len(events)+1))
        assert events[-1]['kind']=='task.completed'
    finally:gateway.release.set();agent.close()

def test_restart_interrupts_without_automatic_model_replay_and_keeps_queue(domain):
    from tasks.store import TaskStore
    tasks=TaskStore(domain.store);thread=domain.thread(A)
    first,_=tasks.enqueue(A,thread['id'],ident(),'正在回答的消息',{})
    tasks.start(A,first['id'],1)
    second,_=tasks.enqueue(A,thread['id'],ident(),'排队的消息',{})
    tasks.interrupt_running()
    assert [tasks.get(A,t['id'])['status'] for t in (first,second)]==['interrupted','interrupted']
    assert len(domain.store.rows('chat_messages',A))==2
    resumed,fresh=tasks.resume(A,first['id'],ident())
    assert fresh and resumed['attempt']==2 and resumed['status']=='queued'
    assert tasks.get(A,second['id'])['status']=='interrupted'


def test_preparation_participants_only_use_explicit_user_names(domain):
    from tools.companion_tools import register_companion_tools, Preparation
    from types import SimpleNamespace
    class Registry:
        def register(self, spec): self.spec=spec
    registry=Registry();register_companion_tools(registry,domain.store)
    thread=domain.thread(A)
    user='帮我准备王总（采购）和李工（IT）的沟通，目标确认服务范围。'
    domain.store.put('chat_messages',A,{'thread_id':thread['id'],'role':'user','content':user,'sources':[],'tool_steps':[]},L1)
    ctx=SimpleNamespace(owner_id=A,thread_id=thread['id'],task_id='participants-test',remaining=lambda:10)
    args=Preparation(**{**pack(),'user_quote':user,'participants':['王总（采购）','李工（IT）','虚构联系人']}).model_dump()
    result=registry.spec.handler(ctx,args,[])
    saved=domain.store.get('companion_preparations',A,result.data['preparation_package_id'])
    assert saved['participants']==['王总（采购）','李工（IT）']
    assert Preparation(**{**pack(),'user_quote':user}).participants==[]


def test_workspace_preparations_publish_to_own_thread_without_superseding_other_spaces(domain):
    general=domain.thread(A)
    one=domain.spaces.create(A,'客户甲','试点','one')
    two=domain.spaces.create(A,'客户乙','报价','two')
    a=domain.save_preparation(A,one['default_thread_id'],'a',pack(),[])
    b=domain.save_preparation(A,two['default_thread_id'],'b',pack(),[])
    c=domain.save_preparation(A,one['default_thread_id'],'c',pack(),[])
    assert b['version']==1 and c['version']==2
    assert domain.store.get('companion_preparations',A,a['id'])['status']=='superseded'
    assert domain.store.get('companion_preparations',A,b['id'])['status']=='ready'
    assert len(domain.store.rows('chat_messages',A,thread_id=one['default_thread_id']))==2
    assert len(domain.store.rows('chat_messages',A,thread_id=two['default_thread_id']))==1
    assert domain.store.rows('chat_messages',A,thread_id=general['id'])==[]
    assert domain.snapshot(A)['preparations']
    domain.spaces.archive(A,one['id'],one['version'])
    with pytest.raises(Fault):domain.save_preparation(A,one['default_thread_id'],'archived',pack(),[])
    with pytest.raises(Fault):domain.save_preparation(B,two['default_thread_id'],'foreign',pack(),[])


def test_workspace_preparation_rejects_cross_space_evidence_until_explicitly_linked(domain):
    from adapters.sources import version
    general=domain.thread(A)
    one=domain.spaces.create(A,'甲','目标甲','one')
    two=domain.spaces.create(A,'乙','目标乙','two')
    doc=Materials(domain.store,domain.spaces).save(A,one['id'],'甲的预算','预算为18万元')
    refs=[{'source_id':'document:'+doc['id'],'source_version':version(doc)}]
    with pytest.raises(Fault):domain.save_preparation(A,two['default_thread_id'],'blocked',pack(),refs)
    assert Materials(domain.store,domain.spaces).search(A,two['id'],'预算',[])['items']==[]
    assert Materials(domain.store,domain.spaces).search(A,general['workspace_id'],'预算',[])['items']
    domain.spaces.set_scope(A,'document:'+doc['id'],'spaces',[one['id'],two['id']],0)
    assert domain.save_preparation(A,two['default_thread_id'],'linked',pack(),refs)['workspace_id']==two['id']
