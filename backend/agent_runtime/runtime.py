"""Bounded text execution; preserves the current mobile chat HTTP contract."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, replace
import json
import threading
import time

from memory import Fault, L1, ident, now
from adapters.sqlite_memory import SQLiteMemoryAdapter
from tasks.store import TaskStore
from tasks.workspaces import WorkspaceStore
from tasks.sources import AgentSourceStore
from tools.memory_tools import memory_registry
from tools.skill_tools import register_skill_tool
from tools.input_tools import register_input_tool
from .config import Budget, RuntimeConfig, fingerprint, public_endpoint
from .context import RunContext
from .cancellation import Cancellation
from tasks.events import ACTIVE, TERMINAL
from .context_manager import ContextManager, reference_set
from .providers import Gateway, has_control_markup
from .rules import BASE_RULES, compose_prompt
from .skills import SkillCatalog, load_soul, skill_prompt
from .tools import ToolResult


class TextAgent:
    def __init__(self, memory, *, gateway=None, memory_adapter=None, registry=None, config=None):
        self.memory = memory
        self.config = config or RuntimeConfig()
        if memory_adapter is None and self.config.services.memory_backend != 'sqlite':
            raise Fault('MEMORY_ADAPTER_NOT_CONFIGURED', '远程记忆接口尚未接入，请继续使用 sqlite', 503)
        self.memory_adapter = memory_adapter or SQLiteMemoryAdapter(memory)
        if self.config.services.memory_backend != self.memory_adapter.name:
            raise Fault('MEMORY_ADAPTER_NOT_CONFIGURED', '记忆读写适配器与配置不一致，未切换数据源', 503)
        self.gateway = gateway or Gateway()
        self.registry = registry or memory_registry(self.memory_adapter)
        self.catalog = SkillCatalog()
        register_skill_tool(self.registry, self.catalog)
        register_input_tool(self.registry)
        from tasks.materials import Materials
        from tools.material_tools import register_material_tools,register_material_reader
        self.materials = Materials(memory, WorkspaceStore(memory))
        register_material_tools(self.registry, self.materials)
        register_material_reader(self.registry,self.memory_adapter)
        from adapters.monid import Monid
        from tools.research_tools import register_research_tools
        self.monid = Monid(memory)
        if self.monid.configured:
            register_research_tools(self.registry, self.monid)
        from tools.device_tools import register_device_tools
        register_device_tools(self.registry, memory)
        from tools.product_tools import register_product_tools,register_product_writes,register_progress_tool
        register_product_tools(self.registry,memory)
        register_product_writes(self.registry,memory)
        register_progress_tool(self.registry,memory)
        from tools.companion_tools import register_companion_tools
        register_companion_tools(self.registry, memory)
        self.catalog.index(self.registry.names)
        self.tasks = TaskStore(memory)
        self.workspaces = WorkspaceStore(memory)
        self.source_store = AgentSourceStore(memory)
        self.context_manager = ContextManager(memory, self.memory_adapter, self.gateway)
        self._locks = {}
        self._lock_guard = threading.RLock()
        self._pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix='candid-agent')
        self._capacity = threading.BoundedSemaphore(16)
        self._executions = {}
        self._reserved = set()
        self._closing = False

    def create(self, owner, occasion_id=None):
        self.memory.check_owner(owner)
        if occasion_id:
            self.memory_adapter.get_occasion(owner, occasion_id)
        space = self.workspaces.create(owner,'','',ident(),occasion_id)
        if occasion_id:
            prior = self.workspaces.scope(owner,'occasion:'+occasion_id)
            self.workspaces.set_scope(owner,'occasion:'+occasion_id,'spaces',
                [*(prior or {}).get('workspace_ids',[]),space['id']],(prior or {}).get('revision',0))
        return self.memory.get('chat_threads',owner,space['default_thread_id'])

    def _workspace(self, owner, thread_id):
        thread = self.memory.get('chat_threads',owner,thread_id)
        if not thread.get('workspace_id'):
            raise Fault('WORKSPACE_MISSING','历史对话尚未迁入项目空间，请刷新',409)
        space = self.workspaces.get(owner,thread['workspace_id'])
        if space.get('status')=='archived':
            raise Fault('WORKSPACE_ARCHIVED','空间已归档，请先恢复后继续对话',409)
        return space

    def _validate_workspace(self, owner, task):
        current = self._workspace(owner,task['thread_id'])
        prior = task['config_snapshot'].get('workspace_snapshot')
        if not prior or prior['id']!=current['id'] or prior['context_version']!=current['context_version']:
            raise Fault('WORKSPACE_CONTEXT_CHANGED','空间目标或关联已变化，请重新发送问题',409)
        return current

    def detail(self, owner, thread_id):
        self.memory.check_owner(owner)
        thread = self.memory.get('chat_threads', owner, thread_id)
        tasks = sorted(self.tasks.list(owner,thread_id),key=lambda t:t.get('queue_order',0))
        orders = {t['id']:t.get('queue_order',0) for t in tasks}
        messages = sorted(self.memory.rows('chat_messages',owner,thread_id=thread_id),
                          key=lambda m:(m['created_at'],m['id']))
        return {'thread':thread,'messages':[self.memory_adapter.decorate_message(owner,m,thread.get('workspace_id')) for m in messages],
                'tasks':[self.tasks.public(t) for t in tasks]}

    def dependency_snapshot(self):
        model = {'provider': 'anker', 'model': self.gateway.model,
                 'endpoint': public_endpoint(self.gateway.base), 'version': 'anker-chat@2'}
        return {'runtime_version': self.config.version, 'model': model, 'model_digest': fingerprint(model),
                'tools': self.registry.snapshot(), 'base_rules_digest': fingerprint(BASE_RULES),
                'memory_adapter': {'name': self.memory_adapter.name,
                                   'contract_version': self.memory_adapter.contract_version}}

    def snapshot(self, budget, owner, workspace):
        dependencies = self.dependency_snapshot()
        soul = load_soul()
        index = self.catalog.index(self.registry.names)
        profile = self.memory_adapter.profile(owner)
        preferences = dict(profile.get('agent_preferences', {}))
        if 'onboarding_profile' in profile:
            preferences.pop('display_name', None)
            if profile['onboarding_profile'].get('display_name'):
                preferences['display_name'] = profile['onboarding_profile']['display_name']
        preferences = {k: v for k, v in preferences.items()
                       if k in {'display_name', 'answer_style'} and isinstance(v, str)}
        preferences = {k: v[:1000] for k, v in preferences.items()}
        prompt = compose_prompt(soul, index, preferences)
        return {**dependencies, 'runtime_digest': self.config.digest, 'budget': asdict(budget),
                'budget_profiles': {name: asdict(value) for name, value in self.config.profiles.items()},
                'budget_ceiling': asdict(self.config.task_budget),
                'workspace_snapshot':{k:workspace[k] for k in ('id','name','goal','context_version')},
                'query_scope':workspace.get('query_scope',{'mode':'project','project_id':workspace['id']}), 'context_policy':dict(self.config.context_policy), 'base_rules_body':BASE_RULES,
                'soul': soul, 'skill_index': index, 'user_preferences': preferences,
                'personal_profile': self.memory_adapter.profile(owner).get('onboarding_profile', {}),
                'timezone': self.memory_adapter.profile(owner).get('timezone','Asia/Hong_Kong'),
                'prompt': {'version': 'candid-files@2', 'body': prompt, 'digest': fingerprint(prompt)}}

    def _validate_retry_dependencies(self, snapshot, current):
        if (snapshot.get('runtime_version') != current['runtime_version']
                or snapshot.get('model_digest') != current['model_digest']
                or snapshot.get('tools', {}).get('version') != current['tools']['version']
                or snapshot.get('memory_adapter') != current['memory_adapter']
                or snapshot.get('base_rules_digest') != current['base_rules_digest']):
            raise Fault('AGENT_DEPENDENCY_CHANGED', '原任务的运行依赖已变化，请新建一条消息', 409)

    def _skill_context(self, context, snapshot):
        allowed = set(snapshot['allowed_tools'])
        registered = set(self.registry.names)
        if not set(snapshot['required_tools']) <= registered or not allowed <= registered:
            raise Fault('AGENT_DEPENDENCY_CHANGED', '原沟通流程的工具依赖已不可用，请新建一条消息', 409)
        profiles = dict(context.budget_profiles)
        profile = profiles.get(snapshot['name'], profiles.get('chat', context.budget))
        ceiling = asdict(context.budget_ceiling or context.budget)
        budget = Budget(**{key: min(value, ceiling[key]) for key, value in asdict(profile).items()})
        if self.workspaces.get(context.owner_id,context.workspace_id).get('is_companion'):
            allowed-= {'read_project','update_action','arrange_meeting','update_participant','record_project_update'}
        return replace(context, task_kind=snapshot['name'], allowed_tools=frozenset(allowed), budget=budget)

    def _budget_usage(self, context, rounds, calls):
        # Reserve before a billed operation. A failed/uncertain call still consumes allowance.
        with self.memory.transaction(context.owner_id):
            context.remaining()
            self.tasks.require_running(context.owner_id, context.task_id, context.attempt)
            self.tasks.update(context.owner_id, context.task_id, {
                'budget_usage': {'model_rounds': rounds, 'tool_calls': calls},
                'effective_budget': asdict(context.budget)})

    def tool(self, owner, name, args, sources, occasion_id=None, workspace_id=None):
        """Compatibility seam for existing callers; the runtime uses the registry."""
        if not workspace_id:
            raise Fault('WORKSPACE_REQUIRED','Agent 查询必须指定服务端项目空间',409)
        self.workspaces.get(owner,workspace_id)
        return self.memory_adapter.query(owner, name, args, sources, occasion_id, workspace_id)

    def _activity(self, context, steps, sources=None):
        with self.memory.transaction(context.owner_id):
            context.remaining()
            self.tasks.require_running(context.owner_id,context.task_id,context.attempt)
            visible = [dict(s) for s in steps if self.registry.visible_to_user(s['name'])]
            self.memory.update('chat_threads',context.owner_id,context.thread_id,{'activity':visible})
            patch = {'tool_steps':steps,'visible_steps':visible}
            if sources is not None:
                patch['tool_source_refs'] = reference_set(sources)
            self.tasks.emit(context,'tools.updated',{'steps':visible},patch)

    def _run(self, context, messages, active_skill=None, initial_sources=None, input_references=None, checkpoint=None):
        if self.workspaces.get(context.owner_id,context.workspace_id).get('is_companion') and context.allowed_tools is None:
            context=replace(context,allowed_tools=frozenset(set(self.registry.names)-{'read_project','update_action','arrange_meeting','update_participant','record_project_update'}))
        sources, steps, total_calls = list(initial_sources or []), [], 0
        input_references = input_references or []
        if checkpoint:
            steps = checkpoint['steps']; total_calls = checkpoint['total_calls']
        if active_skill:
            context = self._skill_context(context, active_skill)
        task = self.tasks.require_running(context.owner_id, context.task_id, context.attempt)
        usage = task.get('budget_usage', {})
        total_calls = max(total_calls, usage.get('tool_calls', 0))
        voice_final = bool(checkpoint and checkpoint.get('voice_final'))
        if context.voice:
            import re
            voice_final = voice_final or bool(re.fullmatch(r'(你好|嗨|谢谢|早上好|晚上好|再见)[！!。 .]*', task.get('input',{}).get('content','')))
        from voice.committer import SpeechCommitter
        turn = max(checkpoint['round'] if checkpoint else 0, usage.get('model_rounds', 0))
        while turn < context.budget.max_rounds:
            budget = context.budget
            self.memory.check_owner(context.owner_id)
            self.context_manager.validate(context.owner_id, [*input_references,*reference_set(sources)], context.workspace_id)
            remaining = context.remaining()
            if len(json.dumps(messages, ensure_ascii=False)) > budget.max_context_chars:
                raise Fault('AGENT_CONTEXT_LIMIT', '这次任务资料较多，请缩小问题范围', 422)
            enabled = not voice_final and turn < budget.max_rounds - 1 and total_calls < budget.max_tool_calls
            schemas = [s.schema() for s in self.registry.available(context)]
            enabled=enabled and bool(schemas)
            self.tasks.emit(context,'text.reset',{'phase':'answer'}, {'partial_text':'','phase':'answer'})
            self._budget_usage(context, turn + 1, total_calls)
            committed = SpeechCommitter(self, context, sources, input_references) if context.voice and not enabled else None
            def delta(text):
                if not context.voice or committed:
                    self.tasks.text(context,text)
                if committed: committed.push(text)
            result = self.gateway.complete(messages, tools=enabled and bool(schemas), schemas=schemas,
                                           timeout_seconds=min(remaining, budget.model_timeout_seconds),
                                           cancellation=context.cancellation,
                                           on_delta=delta)
            context.remaining()
            calls = result.get('tool_calls', [])
            if has_control_markup(result.get('content') or ''):
                self.tasks.emit(context,'text.reset',{'phase':'tools'},{'partial_text':'','phase':'tools'})
                if not enabled:
                    raise Fault('AGENT_INVALID_OUTPUT','模型返回了未完成的工具请求，消息已保留，可以重试',502)
                # Do not execute strings from the content channel as tools. Reissue through
                # the normal schema-validated protocol and the existing bounded budget.
                messages.append({'role':'system','content':'上一轮输出包含内部 DSML 工具标记，客户端无法执行。需要工具时必须使用 API 的 tool_calls 字段，不能在 content 中输出工具语法；已有资料足够时直接用自然语言回答并引用来源。'})
                turn+=1
                continue
            if not calls:
                content = result['content'].strip()
                if not content:
                    raise Fault('AGENT_INVALID_OUTPUT', '模型没有返回回答，可以重试', 502)
                if self.workspaces.get(context.owner_id,context.workspace_id).get('is_companion') and self.preparation_requested(task['input']['content']):
                    saved=self.memory.rows('companion_preparations',context.owner_id,client_request_id='agent:'+context.task_id)
                    if not saved:
                        if not enabled:raise Fault('PREPARATION_NOT_SAVED','准备包尚未成功保存，原文保留；请重试继续整理',502)
                        messages.append(result)
                        messages.append({'role':'system','content':'本轮是明确的准备任务，尚无持久化准备包。不要仅以一段报告结束：信息已够时必须调用 save_preparation；对象或目标确实缺失才使用 request_input 集中补问，时间可留空。只引用实际已读来源。'})
                        turn+=1
                        continue
                if context.voice and enabled:
                    voice_final=True
                    turn+=1
                    saved={'messages':messages,'sources':sources,'references':input_references,'steps':steps,
                        'total_calls':total_calls,'round':turn,'voice_final':True,'effective_budget':asdict(context.budget),
                        'active_skill_digest':fingerprint(active_skill) if active_skill else None}
                    self.tasks.emit(context,'phase',{'phase':'answer'},{'checkpoint':saved})
                    continue
                if committed: committed.finish()
                return content, sources, steps
            if not isinstance(calls, list) or not enabled or len(calls) > budget.max_calls_per_round or total_calls + len(calls) > budget.max_tool_calls:
                raise Fault('AGENT_TOOL_LIMIT', '本次查询步骤过多，请缩小问题范围', 502)
            self.tasks.emit(context,'text.reset',{'phase':'tools'},{'partial_text':'','phase':'tools'})
            messages.append(result)
            pending_skill_prompt = None
            input_request = None
            for call in calls:
                if total_calls >= context.budget.max_tool_calls:
                    raise Fault('AGENT_TOOL_LIMIT', '本次查询步骤过多，请缩小问题范围', 502)
                total_calls += 1
                self._budget_usage(context, turn + 1, total_calls)
                if not isinstance(call, dict) or not isinstance(call.get('function'), dict) or not isinstance(call.get('id'), str):
                    raise Fault('AGENT_INVALID_OUTPUT', '模型工具调用不完整，可以重试', 502)
                name = call['function'].get('name', '')
                step = {'id': ident(), 'name': name, 'title': self.registry.title(name), 'status': 'running', 'count': 0}
                steps.append(step)
                self._activity(context, steps)
                self.tasks.emit(context,'tool.started',{'name':name,'step_id':step['id']})
                try:
                    args = json.loads(call['function']['arguments'])
                    if not isinstance(args, dict):
                        raise ValueError()
                except (ValueError, TypeError, KeyError):
                    output = ToolResult.failure('TOOL_ARGUMENTS_INVALID', '工具参数必须是 JSON 对象')
                else:
                    output = self.registry.execute(context, name, args, sources)
                if name == 'request_input' and output.status=='waiting_input':
                    if input_request:
                        output = ToolResult.failure('INPUT_ALREADY_REQUESTED','每轮只能等待一个用户问题')
                    else:
                        input_request = {'id':ident(),'question':output.data['question'],
                                         'options':output.data['options'],'tool_call_id':call['id']}
                if name == 'run_skill' and not output.error:
                    skill = output.data['skill_snapshot']
                    active_skill = skill
                    context = self._skill_context(context, skill)
                    budget = context.budget
                    with self.memory.transaction(context.owner_id):
                        context.remaining()
                        task = self.tasks.require_running(context.owner_id,context.task_id,context.attempt)
                        self.tasks.update(context.owner_id, context.task_id, {
                            'task_kind': skill['name'], 'active_skill_snapshot': skill,
                            'effective_budget': asdict(budget),
                            'active_skill_source_refs':reference_set([*sources,*input_references]),
                            'skill_load_history': [*task.get('skill_load_history', []), skill]})
                    self.tasks.emit(context,'skill.loaded',{'name':skill['name'],'version':skill['version']})
                    pending_skill_prompt = skill_prompt(skill)
                    if len(pending_skill_prompt) > budget.context_skill_chars:
                        raise Fault('AGENT_CONTEXT_LIMIT', '沟通流程超过上下文预算，请缩小任务', 422)
                    # Model-visible acknowledgement contains no body from untrusted tool data.
                    output = ToolResult('ok', {'state': 'ready', 'title': skill['title']})
                elif name == 'run_skill' and output.error and output.error['code'] == 'SKILL_VERSION_UNAVAILABLE':
                    raise Fault('SKILL_VERSION_UNAVAILABLE', output.error['message'], 409)
                context.remaining()
                self.memory.check_owner(context.owner_id)
                for source in output.sources:
                    prior = next((s for s in sources if s['ref']==source['ref']),None)
                    if prior:
                        sources[sources.index(prior)] = source
                    else:
                        sources.append(source)
                step.update(status='failed' if output.error else 'done', count=len(output.data.get('items', [])))
                if output.error:
                    step['error'] = output.error
                self.context_manager.validate(context.owner_id,reference_set(sources), context.workspace_id)
                self._activity(context, steps, sources)
                self.tasks.emit(context,'tool.finished',{'name':name,'step_id':step['id'],'status':step['status']})
                self.tasks.emit(context,'sources.updated',{'sources':sources})
                messages.append({'role': 'tool', 'tool_call_id': call['id'],
                                 'content': json.dumps(output.as_dict(), ensure_ascii=False)})
            if pending_skill_prompt:
                messages.append({'role': 'system', 'content': pending_skill_prompt})
            saved = {'messages':messages,'sources':sources,'references':input_references,'steps':steps,
                     'total_calls':total_calls,'round':turn+1,'effective_budget':asdict(context.budget),
                     'active_skill_digest':fingerprint(active_skill) if active_skill else None}
            if input_request:
                with self.memory.transaction(context.owner_id):
                    self.tasks.pause(context,input_request,saved)
                    if context.voice:
                        voice=self.tasks.get(context.owner_id,context.task_id).get('voice_context',{})
                        self.tasks.events.append(context.owner_id,context.task_id,'speech.segment',{'text':input_request['question'],
                            'segment_seq':1,'kind':'prompt','input_id':input_request['id'],
                            'generation_id':voice.get('generation_id'),'voice_session_id':voice.get('voice_session_id')},attempt=context.attempt)
                return None
            self.tasks.emit(context,'phase',{'phase':'answer'},{'checkpoint':saved})
            turn += 1
        raise Fault('AGENT_TOOL_LIMIT', '本次查询步骤过多，请缩小问题范围', 502)

    def _schedule(self, owner, task):
        key = (owner,task['id'],task['attempt'])
        cancellation = Cancellation()
        future = self._pool.submit(self._execute,owner,task['id'],task['attempt'],cancellation)
        self._executions[key] = (cancellation,future,task['thread_id'])
        def finished(done):
            with self._lock_guard:
                self._executions.pop(key,None)
                if key in self._reserved:
                    self._reserved.remove(key)
                    self._capacity.release()
                if not self._closing:
                    try:
                        self._kick(owner,task['thread_id'])
                    except Fault:
                        pass
        future.add_done_callback(finished)

    def _kick(self, owner, thread_id):
        if any(key[0]==owner and handle[2]==thread_id for key,handle in self._executions.items()):
            return
        tasks = self.tasks.list(owner,thread_id)
        if any(t['status'] in {'running','waiting_input'} for t in tasks):
            return
        queue = sorted((t for t in tasks if t['status']=='queued'),key=lambda t:t['queue_order'])
        if queue:
            self._schedule(owner,queue[0])

    @staticmethod
    def preparation_requested(text):
        import re
        if re.search(r'(帮我|为我|直接)准备|生成.{0,8}准备包',text):return True
        if re.search(r'如何|怎么|步骤|流程|能否|会不会',text):return False
        return bool(re.search(r'准备.{0,10}(下一场|客户|面试|会谈)',text))

    def submit(self, owner, thread_id, text, request_id, voice=None, live_source_id=None):
        self.memory.check_owner(owner)
        budget = self.config.budget('chat')
        if not isinstance(text,str) or not text.strip() or len(text)>budget.max_input_chars:
            raise Fault('AGENT_INPUT_LIMIT','消息为空或超过输入预算，请拆分消息',422)
        with self._lock_guard:
            if voice and self.memory.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='voice_cancel'",(owner,request_id)).fetchone():
                raise Fault('VOICE_TURN_CANCELLED','该语音轮已取消',409)
            previous = next((t for t in self.tasks.list(owner,thread_id) if t['client_request_id']==request_id),None)
            if previous:
                if voice and previous.get('voice_context') != {**voice,'client_request_id':request_id}:
                    raise Fault('REQUEST_CONFLICT','语音轮标识与原请求不一致',409)
                if previous.get('live_source_id')!=live_source_id:
                    raise Fault('REQUEST_CONFLICT','实时字幕快照与原请求不一致',409)
                if previous['input']['content']!=text:
                    raise Fault('REQUEST_CONFLICT','重试消息与原消息不一致',409)
                return self.tasks.public(previous)
            if not self.gateway.configured:
                raise Fault('AGENT_NOT_CONFIGURED','文本 Agent 尚未配置模型网关 Key',503)
            if self._closing or not self._capacity.acquire(blocking=False):
                raise Fault('AGENT_CAPACITY','后端任务较多，请稍后再发送',503)
            try:
                workspace = self._workspace(owner,thread_id)
                with self.memory.transaction(owner):
                    workspace = self.workspaces.seed_from_message(owner,workspace['id'],text)
                    task, fresh = self.tasks.enqueue(owner,thread_id,request_id,text,self.snapshot(budget,owner,workspace))
                    if fresh and workspace.get('is_companion') and self.preparation_requested(text):
                        skill=self.catalog.load('communication_prep',task['config_snapshot']['skill_index'],{})
                        task=self.tasks.update(owner,task['id'],{'active_skill_snapshot':skill,'task_kind':'communication_prep','skill_load_history':[skill]})
                    if fresh and live_source_id:
                        task=self.tasks.update(owner,task['id'],{'live_source_id':live_source_id})
                    if fresh and voice:
                        task=self.tasks.update(owner,task['id'],{'voice_context':{**voice,'client_request_id':request_id}})
            except Exception:
                self._capacity.release()
                raise
            if fresh:
                self._reserved.add((owner,task['id'],task['attempt']))
                self._kick(owner,task['thread_id'])
            else:
                self._capacity.release()
            return self.tasks.public(task)

    def resume(self, owner, task_id, request_id, expected_attempt=None):
        with self._lock_guard:
            task = self.tasks.get(owner,task_id)
            if request_id in task.get('resume_requests',[]):
                return self.tasks.public(task)
            if expected_attempt is not None and expected_attempt!=task['attempt']:
                raise Fault('AGENT_STATE_CONFLICT','任务执行版本已变化，请刷新后继续',409)
            if task['status']=='waiting_input' and task.get('input_request'):
                raise Fault('AGENT_INPUT_REQUIRED','请先回答当前问题',409)
            self._validate_retry_dependencies(task['config_snapshot'],self.dependency_snapshot())
            self._validate_workspace(owner,task)
            if task.get('checkpoint'):
                refs = [*task['checkpoint']['references'],*reference_set(task['checkpoint']['sources'])]
                if any(x['status']!='current' for x in self.memory_adapter.references_status(owner,refs,task.get('workspace_id'))):
                    with self.memory.transaction(owner):
                        self.tasks.update(owner,task_id,{'checkpoint':None,'active_skill_source_refs':[],
                            'active_skill_snapshot':{**task['active_skill_snapshot'],'inputs':{}} if task.get('active_skill_snapshot') else None})
                        task = self.tasks.get(owner,task_id)
            if not self.gateway.configured:
                raise Fault('AGENT_NOT_CONFIGURED','文本 Agent 尚未配置模型网关 Key',503)
            if self._closing or not self._capacity.acquire(blocking=False):
                raise Fault('AGENT_CAPACITY','后端任务较多，请稍后再继续',503)
            try:
                task, fresh = self.tasks.resume(owner,task_id,request_id)
            except Exception:
                self._capacity.release()
                raise
            if fresh:
                self._reserved.add((owner,task['id'],task['attempt']))
                self._kick(owner,task['thread_id'])
            else:
                self._capacity.release()
            return self.tasks.public(task)

    def answer_input(self, owner, task_id, request_id, input_id, text, expected_attempt, voice=None):
        text = text.strip()
        if not text or len(text)>self.config.budget('chat').max_input_chars:
            raise Fault('AGENT_INPUT_LIMIT','补充内容为空或过长',422)
        with self._lock_guard:
            if voice and self.memory.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='voice_cancel'",(owner,request_id)).fetchone():
                raise Fault('VOICE_TURN_CANCELLED','该语音轮已取消',409)
            task = self.tasks.get(owner,task_id)
            prior = next((r for r in task.get('input_responses',[]) if r['request_id']==request_id),None)
            if prior:
                if prior['input_id']!=input_id or prior['text']!=text:
                    raise Fault('REQUEST_CONFLICT','重试补充与原内容不一致',409)
                return self.tasks.public(task)
            if task['status']!='waiting_input' or task['attempt']!=expected_attempt or (task.get('input_request') or {}).get('id')!=input_id:
                raise Fault('AGENT_STATE_CONFLICT','等待的问题已变化，请刷新后补充',409)
            self._validate_retry_dependencies(task['config_snapshot'],self.dependency_snapshot())
            self._validate_workspace(owner,task)
            if self._closing or not self._capacity.acquire(blocking=False):
                raise Fault('AGENT_CAPACITY','后端任务较多，请稍后再补充',503)
            try:
                with self.memory.transaction(owner):
                    checkpoint = task['checkpoint']
                    self.context_manager.validate(owner,[*checkpoint['references'],*reference_set(checkpoint['sources'])],task.get('workspace_id'))
                    for message in checkpoint['messages']:
                        if message.get('role')=='tool' and message.get('tool_call_id')==task['input_request']['tool_call_id']:
                            message['content'] = json.dumps({'status':'ok','data':{'user_answer':text}},ensure_ascii=False)
                    self.memory.put('chat_messages',owner,{'thread_id':task['thread_id'],'role':'user','content':text,
                        'client_request_id':request_id,'task_id':task_id,'turn_id':task['turn_id'],
                        'sources':[],'tool_steps':[],'response_to':input_id},L1)
                    self.tasks.update(owner,task_id,{'checkpoint':checkpoint,'input_request':None,
                        'input_responses':[*task.get('input_responses',[]),{'request_id':request_id,'input_id':input_id,'text':text}],
                        **({'voice_context':{**voice,'client_request_id':request_id}} if voice else {})})
                    task,fresh = self.tasks.resume(owner,task_id,request_id)
            except Exception:
                self._capacity.release()
                raise
            if fresh:
                self._reserved.add((owner,task['id'],task['attempt']))
                self._kick(owner,task['thread_id'])
            else:
                self._capacity.release()
            return self.tasks.public(task)

    def cancel(self, owner, task_id, *, preserve_partial, expected_attempt=None):
        with self._lock_guard:
            with self.memory.transaction(owner):
                task = self.tasks.get(owner,task_id)
                if expected_attempt is not None and expected_attempt!=task['attempt']:
                    raise Fault('AGENT_STATE_CONFLICT','任务执行版本已变化，请刷新后停止',409)
                if task['status'] not in ACTIVE:
                    return self.tasks.public(task)
                execution = self._executions.get((owner,task_id,task['attempt']))
                if execution:
                    execution[0].cancel()
                refs = list(task.get('artifact_refs',[]))
                if preserve_partial and task.get('partial_text','').strip():
                    message = self.memory.put('chat_messages',owner,{
                        'thread_id':task['thread_id'],'role':'assistant','content':task['partial_text'],
                        'client_request_id':task['client_request_id'],'sources':[],
                        'tool_steps':task.get('visible_steps',[]),'task_id':task_id,'turn_id':task['turn_id'],
                        'attempt':task['attempt'],'producer':'anker:'+self.gateway.model,'model':self.gateway.model,
                        'incomplete':True,'excluded_from_summary':True},L1,source='ai')
                    refs.append({'kind':'incomplete_chat_message','id':message['id']})
                error = {'code':'AGENT_CANCELLED','message':'已停止生成','retryable':True}
                self.tasks.update(owner,task_id,{'status':'cancelled','finished_at':now(),'phase':'cancelled',
                    'artifact_refs':refs,'partial_text':'','error':error,
                    'provider_state':'unknown_after_disconnect' if task['status']=='running' else 'no_active_request',
                    'input_request':None})
                self.tasks.events.append(owner,task_id,'task.cancelled',{'status':'cancelled','error':error})
                self.tasks.end_thread(owner,task,'idle','AGENT_CANCELLED')
                key = (owner,task_id,task['attempt'])
                if not execution and key in self._reserved:
                    self._reserved.remove(key); self._capacity.release()
                self._kick(owner,task['thread_id'])
                return self.tasks.public(self.tasks.get(owner,task_id))

    def _execute(self, owner, task_id, attempt, cancellation):
        try:
            with self._lock_guard:
                lock = self._locks.setdefault((owner,self.tasks.get(owner,task_id)['thread_id']),threading.Lock())
        except Fault:
            return
        # A cancelled older attempt may still be closing its network connection.
        # Keep each conversation serial while allowing independent conversations to run.
        with lock:
            task = None
            try:
                cancellation.check()
                task = self.tasks.start(owner,task_id,attempt)
                snapshot = task['config_snapshot']
                self._validate_retry_dependencies(snapshot,self.dependency_snapshot())
                self._validate_workspace(owner,task)
                budget = Budget(**snapshot['budget'])
                ceiling = Budget(**snapshot.get('budget_ceiling', snapshot['budget']))
                profiles = tuple((name, Budget(**value)) for name, value in snapshot.get('budget_profiles', {}).items())
                thread_id = task['thread_id']
                occasion_id = task.get('occasion_id')
                if occasion_id and not self.workspaces.allowed(owner,'occasion',self.memory_adapter.get('occasions',owner,occasion_id),task['workspace_id']):
                    occasion_id = None
                context = RunContext(owner,thread_id,task_id,task['turn_id'],snapshot['model_digest'],
                    snapshot['runtime_version'],budget,occasion_id=occasion_id,
                    task_kind=task.get('task_kind','chat'),skill_index_snapshot=tuple(snapshot['skill_index']),
                    deadline=time.monotonic()+ceiling.timeout_seconds,cancellation=cancellation,attempt=attempt,workspace_id=task['workspace_id'],
                    allow_mutations=True,budget_profiles=profiles,budget_ceiling=ceiling,voice=bool(task.get('voice_context',{}).get('continuous')))
                active_skill = task.get('active_skill_snapshot')
                if active_skill:
                    context = self._skill_context(context, active_skill)
                bound_refs = task.get('active_skill_source_refs',[])
                if active_skill and bound_refs and any(s['status']!='current' for s in self.memory_adapter.references_status(owner,bound_refs,context.workspace_id)):
                    active_skill = {**active_skill,'inputs':{}}
                    self.tasks.emit(context,'phase',{'phase':'context'},{'active_skill_snapshot':active_skill,
                        'active_skill_source_refs':[],'active_skill_inputs_invalidated':True})
                checkpoint = task.get('checkpoint')
                if checkpoint:
                    messages,sources,references = list(checkpoint['messages']),checkpoint['sources'],checkpoint['references']
                    self.context_manager.validate(owner,[*references,*reference_set(sources)],context.workspace_id)
                    # A Skill may have loaded just before an interrupted round was checkpointed.
                    if active_skill and checkpoint.get('active_skill_digest')!=fingerprint(active_skill):
                        body=skill_prompt(active_skill)
                        if len(body)>context.budget.context_skill_chars:
                            raise Fault('AGENT_CONTEXT_LIMIT','沟通流程超过上下文预算，请缩小任务',422)
                        messages.append({'role':'system','content':body})
                else:
                    orders = {t['id']:t.get('queue_order',0) for t in self.tasks.list(owner,thread_id)}
                    history = [m for m in self.detail(owner,thread_id)['messages']
                               if orders.get(m.get('task_id'),0)<=task.get('queue_order',0)]
                    prepared = self.context_manager.prepare(context,snapshot,history,task['input']['content'],active_skill,live_source_id=task.get('live_source_id'))
                    messages,sources,references = prepared.messages,prepared.sources,prepared.references
                    checkpoint = {'messages':messages,'sources':sources,'references':references,'steps':[],
                                  'total_calls':0,'round':0,'active_skill_digest':fingerprint(active_skill) if active_skill else None}
                    self.tasks.emit(context,'phase',{'phase':'answer'},{'context_snapshot':prepared.metadata,
                        'checkpoint':checkpoint,'phase':'answer'})
                self.tasks.emit(context,'sources.updated',{'sources':sources})
                outcome = self._run(context,messages,active_skill,sources,references,checkpoint)
                if outcome is None:
                    return  # waiting_input is durable and consumes no worker while awaiting the user.
                content,sources,steps = outcome
                import re
                valid_citations={s.get('citation') for s in sources}
                cited={'['+number+']' for number in re.findall(r'\[(\d+)\]',content)}
                if cited-valid_citations:
                    raise Fault('SOURCE_CITATION_INVALID','报告引用编号不在已取得资料中，请继续修正',502)

                user_steps = [s for s in steps if self.registry.visible_to_user(s['name'])]
                with self.memory.transaction(owner):
                    context.remaining()
                    self.tasks.require_running(owner,task_id,attempt)
                    self.context_manager.validate(owner,[*references,*reference_set(sources)],context.workspace_id)
                    answer = self.memory.put('chat_messages',owner,{
                        'thread_id':thread_id,'role':'assistant','content':content,'client_request_id':task['client_request_id'],
                        'sources':sources,'tool_steps':user_steps,'task_id':task_id,'turn_id':task['turn_id'],'attempt':attempt,'workspace_id':context.workspace_id,
                        'producer':'anker:'+self.gateway.model,'model':self.gateway.model,'incomplete':False},L1,source='ai')
                    if any(s.get('material_kind')=='public_company' for s in sources):
                        self.memory.put('agent_sources',owner,{'title':'公司沟通资料 · '+self.workspaces.get(owner,context.workspace_id)['name'],
                            'text':content,'material_kind':'ai_suggestion','reading_range':'ai_report','status':'active',
                            'workspace_id':context.workspace_id,'task_id':task_id,'message_id':answer['id'],
                            'producer':'anker/'+self.gateway.model,'rubric_version':'research-report@1','acquired':True,
                            'evidence_refs':reference_set(sources)},'L2_inferred',source='ai')
                    self.tasks.finish(owner,task_id,answer)
                    self.tasks.update(owner,task_id,{'tool_steps':steps,'visible_steps':user_steps})
                    self.tasks.end_thread(owner,task,'idle')
            except Exception as error:
                fault = error if isinstance(error,Fault) else Fault('AGENT_EXECUTION_FAILED','Agent 处理失败，消息已保留，可以继续',500)
                if fault.code in {'MEMORY_DELETED','AGENT_CANCELLED'}:
                    return
                try:
                    with self.memory.transaction(owner):
                        current = self.tasks.get(owner,task_id)
                        if current['attempt']!=attempt or current['status'] not in ACTIVE:
                            return
                        self.tasks.fail(owner,task_id,fault)
                        self.tasks.end_thread(owner,current,'error',fault.code)
                except Fault:
                    pass  # The owner may have deleted all private data while the worker was running.

    def send(self, owner, thread_id, text, request_id):
        """Compatibility endpoint. The independently scheduled task outlives the HTTP connection."""
        receipt = self.submit(owner,thread_id,text,request_id)
        while True:
            task = self.tasks.get(owner,receipt['id'])
            if task['status']=='completed':
                message_id = task['artifact_refs'][0]['id']
                message = self.memory.get('chat_messages',owner,message_id)
                return {'message':self.memory_adapter.decorate_message(owner,message,task.get('workspace_id')),
                        'thread':self.memory.get('chat_threads',owner,thread_id),'task_id':task['id']}
            if task['status'] in TERMINAL:
                error = task.get('error') or {'code':'AGENT_CANCELLED','message':'任务已停止'}
                raise Fault(error['code'],error['message'],409)
            if task['status']=='waiting_input':
                raise Fault('AGENT_INPUT_REQUIRED','任务等待补充，请通过任务接口回答',409)
            time.sleep(.2)

    def close(self):
        with self._lock_guard:
            self._closing = True
            for cancellation,future,thread_id in list(self._executions.values()):
                cancellation.cancel()
            self._pool.shutdown(wait=False,cancel_futures=True)
        self.registry.close()
