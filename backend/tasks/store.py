"""Durable task state. Submission is idempotent; retries require an explicit action."""
from memory import Fault, L1, ident, now
from .events import EventStore, ACTIVE, TERMINAL


class TaskStore:
    def __init__(self, store):
        self.store = store
        self.events = EventStore(store)

    def get(self, owner, task_id):
        self.store.check_owner(owner)
        return self.store.get('agent_tasks', owner, task_id)

    def list(self, owner, thread_id=None):
        self.store.check_owner(owner)
        if thread_id:
            self.store.get('chat_threads', owner, thread_id)
        return self.store.rows('agent_tasks', owner, thread_id=thread_id)

    @staticmethod
    def public(task):
        # Runtime instructions and hidden Skill bodies do not travel to the mobile UI.
        return {k:task[k] for k in ('id','thread_id','turn_id','client_request_id','status','attempt',
            'event_seq','partial_text','visible_steps','error','artifact_refs','created_at','updated_at',
            'started_at','finished_at','phase','workspace_id','input','input_request','provider_state','queue_order','voice_context') if k in task} | {'tool_steps':task.get('visible_steps',[]),'accepted_action_ids':task.get('resume_requests',[])}

    def require_running(self, owner, task_id, attempt):
        task = self.get(owner, task_id)
        thread = self.store.get('chat_threads', owner, task['thread_id'])
        if task['status'] != 'running' or task['attempt'] != attempt or thread.get('active_task_id') != task_id:
            raise Fault('AGENT_CANCELLED', '任务已停止或执行版本已变化', 409)
        return task

    def enqueue(self, owner, thread_id, request_id, text, snapshot):
        with self.store.transaction(owner):
            thread = self.store.get('chat_threads', owner, thread_id)
            if thread.get('workspace_id') and self.store.get('project_spaces',owner,thread['workspace_id']).get('status')=='archived':
                raise Fault('WORKSPACE_ARCHIVED','空间已归档，请先恢复后继续对话',409)
            prior = next((t for t in self.list(owner, thread_id) if t['client_request_id']==request_id), None)
            if prior:
                if prior['input']['content'] != text:
                    raise Fault('REQUEST_CONFLICT', '重试消息与原消息不一致', 409)
                return prior, False
            queue_order = thread.get('task_queue_seq',0)+1
            active = any(t['status'] in ACTIVE for t in self.list(owner,thread_id))
            task = self.store.put('agent_tasks', owner, {
                'thread_id':thread_id,'workspace_id':thread.get('workspace_id'),'turn_id':ident(),'client_request_id':request_id,
                'occasion_id':thread.get('occasion_id'),'session_id':None,'task_kind':'chat',
                'input':{'content':text},'status':'queued','attempt':1,'event_seq':0,
                'started_at':None,'finished_at':None,'active_skill_snapshot':None,
                'config_snapshot':snapshot,'attempt_config_snapshot':snapshot,'skill_load_history':[],
                'artifact_refs':[],'tool_steps':[],'visible_steps':[],'partial_text':'','phase':'queued','error':None,
                'resume_requests':[],'queue_order':queue_order}, L1)
            self.store.put('chat_messages', owner, {
                'thread_id':thread_id,'role':'user','content':text,'client_request_id':request_id,
                'sources':[],'tool_steps':[],'task_id':task['id'],'turn_id':task['turn_id']}, L1)
            self.store.update('chat_threads', owner, thread_id, {
                'title':self.store.get('project_spaces',owner,thread['workspace_id'])['name'] if thread.get('workspace_id') else text[:28] if thread['message_count']==0 else thread['title'],
                'task_queue_seq':queue_order,
                **({} if active else {'status':'thinking','activity':[],'error_code':None,'active_task_id':task['id']})})
            self.events.append(owner, task['id'], 'task.queued', {'status':'queued'})
            return self.get(owner, task['id']), True

    def resume(self, owner, task_id, request_id):
        with self.store.transaction(owner):
            task = self.get(owner, task_id)
            if request_id in task.get('resume_requests', []):
                return task, False
            if task['status'] not in {'failed','cancelled','interrupted','waiting_input'}:
                raise Fault('AGENT_STATE_CONFLICT', '当前任务不需要继续执行', 409)
            if len(task.get('resume_requests', [])) >= 128:
                raise Fault('AGENT_STATE_CONFLICT', '此任务重试次数过多，请开始新的对话', 409)
            if any(t['id']!=task_id and t['status'] in {'running','waiting_input'} for t in self.list(owner,task['thread_id'])):
                raise Fault('CHAT_BUSY', '这段对话还在回复，请先停止当前任务', 409)
            # Resuming an old turn after subsequent user input changes its meaning.
            later = [m for m in self.store.rows('chat_messages', owner, thread_id=task['thread_id'])
                     if m['role']=='user' and m.get('task_id')!=task_id and m['created_at']>task['created_at']
                     and not (self.get(owner,m['task_id'])['status']=='queued' or
                              (self.get(owner,m['task_id'])['status']=='interrupted' and not self.get(owner,m['task_id']).get('started_at')))]
            if later:
                raise Fault('AGENT_STATE_CONFLICT', '后面已有新消息，请将需要补充的内容重新发送', 409)
            self.store.update('agent_tasks', owner, task_id, {
                'status':'queued','attempt':task['attempt']+1,'started_at':None,'finished_at':None,'error':None,
                'attempt_config_snapshot':task['config_snapshot'],
                'tool_steps':(task.get('checkpoint') or {}).get('steps',[]),
                'visible_steps':task.get('visible_steps',[]) if task.get('checkpoint') else [],
                'partial_text':'','phase':'queued','resume_requests':[*task.get('resume_requests',[]),request_id]})
            self.store.update('chat_threads', owner, task['thread_id'], {
                'status':'thinking','activity':[],'error_code':None,'active_task_id':task_id})
            self.events.append(owner, task_id, 'task.queued', {'status':'queued'})
            return self.get(owner,task_id), True

    def start(self, owner, task_id, attempt):
        with self.store.transaction(owner):
            task = self.get(owner,task_id)
            if task['status']!='queued' or task['attempt']!=attempt:
                raise Fault('AGENT_CANCELLED','任务已停止或执行版本已变化',409)
            self.store.update('chat_threads',owner,task['thread_id'],{'active_task_id':task_id,'status':'thinking','activity':[],'error_code':None})
            self.update(owner,task_id,{'status':'running','started_at':now(),'phase':'context'})
            self.events.append(owner,task_id,'task.running',{'status':'running','phase':'context'},attempt=attempt)
            return self.get(owner,task_id)

    def update(self, owner, task_id, patch):
        self.store.check_owner(owner)
        return self.store.update('agent_tasks',owner,task_id,patch)

    def emit(self, context, kind, data=None, patch=None):
        with self.store.transaction(context.owner_id):
            context.remaining()
            self.require_running(context.owner_id,context.task_id,context.attempt)
            if patch:
                self.update(context.owner_id,context.task_id,patch)
            return self.events.append(context.owner_id,context.task_id,kind,data,attempt=context.attempt)

    def text(self, context, text):
        with self.store.transaction(context.owner_id):
            task = self.require_running(context.owner_id,context.task_id,context.attempt)
            self.emit(context,'text.delta',{'text':text},{'partial_text':task.get('partial_text','')+text})

    def pause(self, context, request, checkpoint):
        with self.store.transaction(context.owner_id):
            context.remaining()
            self.require_running(context.owner_id,context.task_id,context.attempt)
            self.update(context.owner_id,context.task_id,{'status':'waiting_input','phase':'waiting_input',
                'input_request':request,'checkpoint':checkpoint,'partial_text':''})
            self.events.append(context.owner_id,context.task_id,'input.requested',
                {'status':'waiting_input','input_request':request})
            self.store.update('chat_threads',context.owner_id,context.thread_id,{'status':'waiting_input','activity':[]})

    def finish(self, owner, task_id, message):
        task = self.update(owner,task_id,{'status':'completed','finished_at':now(),'phase':'completed',
            'artifact_refs':[{'kind':'chat_message','id':message['id']}],'partial_text':'',
            'tool_steps':message['tool_steps'],'error':None})
        self.events.append(owner,task_id,'task.completed',{'status':'completed','message_id':message['id']})
        return task

    def fail(self, owner, task_id, error):
        task = self.get(owner,task_id)
        interrupted = error.code in {'AGENT_DEPENDENCY_CHANGED','SKILL_VERSION_UNAVAILABLE'}
        state = 'interrupted' if interrupted else 'failed'
        fault = {'code':error.code,'message':error.message,'retryable':error.code not in
                 {'AGENT_DEPENDENCY_CHANGED','SKILL_VERSION_UNAVAILABLE','AGENT_AUTH_FAILED','AGENT_FORBIDDEN',
                  'AGENT_CONTEXT_LIMIT','AGENT_TOOL_LIMIT','AGENT_COMPACTION_LIMIT','WORKSPACE_CONTEXT_CHANGED','WORKSPACE_ARCHIVED'}}
        self.update(owner,task_id,{'status':state,'finished_at':now(),'phase':state,'error':fault})
        self.events.append(owner,task_id,'task.'+state,{'status':state,'error':fault})

    def end_thread(self, owner, task, status, error_code=None):
        thread = self.store.get('chat_threads',owner,task['thread_id'])
        if thread.get('active_task_id')==task['id']:
            self.store.update('chat_threads',owner,task['thread_id'],{
                'status':status,'activity':[],'active_task_id':None,'last_task_id':task['id'],'error_code':error_code,
                'message_count':len(self.store.rows('chat_messages',owner,thread_id=task['thread_id']))})

    def interrupt_running(self):
        # A process restart never replays a potentially billed request automatically.
        with self.store.transaction():
            owners = self.store.db.execute('SELECT DISTINCT owner_id FROM agent_tasks').fetchall()
            for row in owners:
                owner = row['owner_id']
                self.store.check_owner(owner)
                for task in self.list(owner):
                    if task['status'] not in {'running','queued'}:
                        continue
                    error = {'code':'AGENT_INTERRUPTED','message':'后端重启中断了任务，可以手动继续','retryable':True}
                    self.update(owner,task['id'],{'status':'interrupted','finished_at':now(),'phase':'interrupted','error':error})
                    self.events.append(owner,task['id'],'task.interrupted',{'status':'interrupted','error':error})
                    self.end_thread(owner,task,'error','AGENT_INTERRUPTED')
