from pydantic import BaseModel,ConfigDict,Field
from agent_runtime.tools import ToolSpec,ToolResult
from product import Product
from adapters.sources import source,collect
from memory import Fault

class Query(BaseModel):
    model_config=ConfigDict(extra='forbid')
    project_id:str|None=None
    meeting_id:str|None=None
class Update(BaseModel):
    model_config=ConfigDict(extra='forbid')
    item_id:str
    expected_version:int=Field(ge=1)
    status:str=Field(pattern='^(open|done)$')
    user_quote:str=Field(min_length=1,max_length=2000)

def register_product_tools(registry,store):
    domain=Product(store)
    def read(context,args,sources):
        pids=domain.scope_projects(context.owner_id,context.workspace_id)
        pid=args.get('project_id');mid=args.get('meeting_id')
        scope=domain.spaces.get(context.owner_id,context.workspace_id).get('query_scope',{})
        if pid and pid not in pids:raise Fault('SOURCE_SCOPE_DENIED','项目不在当前范围',403)
        if mid:
            meeting=domain.get_meeting(context.owner_id,mid)
            if meeting['project_id'] not in pids or scope.get('mode')=='meeting' and scope['meeting_id']!=mid:raise Fault('SOURCE_SCOPE_DENIED','场次不在当前范围',403)
        elif scope.get('mode')=='meeting':mid=scope['meeting_id']
        projects=[domain.project(context.owner_id,p) for p in pids if not pid or p==pid]
        records=[i for i in domain.items(context.owner_id) if i['project_id'] in {p['id'] for p in projects} and (not mid or i['meeting_id']==mid) and i['reference_status']=='current'][:24]
        items=[]
        from adapters.sqlite_memory import SQLiteMemoryAdapter
        adapter=SQLiteMemoryAdapter(store)
        for item in records:
            result=adapter.read_evidence(context.owner_id,item['evidence_refs'],sources=sources,workspace_id=context.workspace_id)
            if result.get('unavailable'):continue
            items.append({'id':item['id'],'version':item['version'],'kind':item['kind'],'text':item['text'],'owner':item['owner'],
                'due_at':item['due_at'],'status':item['status'],'meeting_id':item['meeting_id'],'sources':result['items']})
        return ToolResult('ok',{'projects':[{k:p.get(k) for k in ('id','name','goal','scenario','stage','participants')} for p in projects],
            'meetings':[m for m in store.rows('business_meetings',context.owner_id) if m['project_id'] in pids and (not mid or m['id']==mid)][:20],'items':items},sources)
    def update(context,args,sources):
        if domain.spaces.get(context.owner_id,context.workspace_id).get('is_practice'):raise Fault('PRACTICE_ONLY','练习不更新真实行动',409)
        row=store.get('project_items',context.owner_id,args['item_id'])
        if row['project_id'] not in domain.scope_projects(context.owner_id,context.workspace_id):raise Fault('SOURCE_SCOPE_DENIED','项目不在当前范围',403)
        task=store.get('agent_tasks',context.owner_id,context.task_id)
        if args['user_quote'] not in task['input']['content']:raise Fault('USER_UPDATE_REQUIRED','状态更新必须引用本轮用户原话',403)
        quote=args['user_quote'].lower()
        if args['status']=='done' and (not any(word in quote for word in ('已完成','完成了','做完','搞定','已发','发了','done','finished','sent')) or any(word in quote for word in ('未完成','没完成','not done','not sent'))):raise Fault('USER_UPDATE_REQUIRED','用户尚未明确表示完成',403)
        context.remaining()
        return ToolResult('ok',{'item':domain.patch_item(context.owner_id,row['id'],{'status':args['status'],'update_note':args['user_quote']},args['expected_version'])})
    tasks=frozenset({'chat','communication_prep','communication_review','memory_draft','company_research'})
    registry.register(ToolSpec('read_project','读取项目进展','读取当前范围的项目参与者、场次、问题回答、承诺与行动。事实必须附返回来源，未知结果不推断。',Query,read,tasks))
    registry.register(ToolSpec('update_action','更新行动','用户明确表示完成或重新打开行动时，根据本轮逐字原话更新状态。不得自行宣布完成。',Update,update,tasks,mutates_data=True))

class Arrange(BaseModel):
    model_config=ConfigDict(extra='forbid')
    project_id:str|None=None
    name:str=Field(min_length=1,max_length=200)
    scenario:str=Field(pattern='^(sales|interview)$')
    meeting_title:str|None=Field(default=None,max_length=200)
    scheduled_at:str|None=None
    date_quote:str=Field(default='',max_length=200)
    user_quote:str=Field(min_length=1,max_length=3000)

class Participants(BaseModel):
    model_config=ConfigDict(extra='forbid')
    project_id:str
    name:str=Field(min_length=1,max_length=100)
    role:str=Field(default='',max_length=100)
    side:str=Field(default='other',pattern='^(self|customer|interviewer|other)$')
    user_quote:str=Field(min_length=1,max_length=2000)

def register_product_writes(registry,store):
    domain=Product(store)
    tasks=frozenset({'chat','communication_prep','communication_review'})
    def arrange(context,args,sources):
        task=store.get('agent_tasks',context.owner_id,context.task_id);text=task['input']['content']
        if args['user_quote'] not in text:raise Fault('USER_UPDATE_REQUIRED','创建必须引用本轮用户原话',403)
        scope=domain.spaces.get(context.owner_id,context.workspace_id)
        if scope.get('is_practice'):raise Fault('PRACTICE_ONLY','练习不自动建立真实项目',409)
        with store.transaction(context.owner_id):
            context.remaining()
            pid=args.get('project_id')
            if pid:
                if pid not in domain.scope_projects(context.owner_id,context.workspace_id):raise Fault('SOURCE_SCOPE_DENIED','项目不在范围',403)
                project=domain.project(context.owner_id,pid)
            else:
                if not scope.get('is_scope_context') or scope.get('query_scope',{}).get('mode') not in {'all','scenario'}:raise Fault('PROJECT_REQUIRED','在当前项目安排，或切到全部后新建',409)
                same=[p for p in domain.projects(context.owner_id) if p['name']==args['name']]
                if same:raise Fault('PROJECT_AMBIGUOUS','已有同名项目，请先核对是否为同一机会',409)
                project=domain.create(context.owner_id,{'name':args['name'],'goal':args['user_quote'],'scenario':args['scenario']},'agent:'+task['id'])
            meeting=None
            if args.get('meeting_title'):
                date=args.get('scheduled_at')
                if not args['date_quote'] or args['date_quote'] not in args['user_quote']:date=None
                meeting=domain.meeting(context.owner_id,project['id'],{'title':args['meeting_title'],'goal':args['user_quote'],
                    'scheduled_at':date,'timezone':'Asia/Hong_Kong','created_from_text':args['user_quote']},'agent:'+task['id'])
            return ToolResult('ok',{'project':{k:project.get(k) for k in ('id','name','scenario','goal')},'meeting':meeting})
    def participant(context,args,sources):
        if domain.spaces.get(context.owner_id,context.workspace_id).get('is_practice'):raise Fault('PRACTICE_ONLY','练习不修改项目参与方',409)
        task=store.get('agent_tasks',context.owner_id,context.task_id)
        if args['user_quote'] not in task['input']['content'] or args['name'] not in args['user_quote'] or args['role'] and args['role'] not in args['user_quote']:raise Fault('USER_UPDATE_REQUIRED','参与方必须来自用户原话',403)
        if args['project_id'] not in domain.scope_projects(context.owner_id,context.workspace_id):raise Fault('SOURCE_SCOPE_DENIED','项目不在范围',403)
        row=domain.project(context.owner_id,args['project_id']);person={k:args[k] for k in ('name','role','side')}
        participants=[p for p in row.get('participants',[]) if p['name']!=person['name']]+[person]
        context.remaining()
        return ToolResult('ok',{'project':domain.update_project(context.owner_id,row['id'],{'participants':participants},row['version'])})
    registry.register(ToolSpec('arrange_meeting','安排项目与场次','用户明确要新建或安排时从本轮原话创建销售/面试项目或场次。已有同名机会先核对。时间不明留空。不得在练习中使用。',Arrange,arrange,tasks,mutates_data=True))
    registry.register(ToolSpec('update_participant','更新参与方','用户明确提供姓名角色时补充当前项目参与方。原话未说明阵营则other。',Participants,participant,tasks,mutates_data=True))

class ProgressUpdate(BaseModel):
    model_config=ConfigDict(extra='forbid')
    project_id:str
    user_quote:str=Field(min_length=1,max_length=2000)

def register_progress_tool(registry,store):
    domain=Product(store)
    def update(context,args,sources):
        if domain.spaces.get(context.owner_id,context.workspace_id).get('is_practice'):raise Fault('PRACTICE_ONLY','练习不更新真实项目',409)
        if args['project_id'] not in domain.scope_projects(context.owner_id,context.workspace_id):raise Fault('SOURCE_SCOPE_DENIED','项目不在范围',403)
        task=store.get('agent_tasks',context.owner_id,context.task_id);quote=args['user_quote']
        if quote not in task['input']['content']:raise Fault('USER_UPDATE_REQUIRED','进展必须引用本轮原话',403)
        if any(word in quote for word in ('是否','有没有','回复了吗','没回复','尚未回复')):raise Fault('UPDATE_UNCERTAIN','疑问或缺少回复不记为客户已回复',409)
        message=next((m for m in store.rows('chat_messages',context.owner_id,thread_id=context.thread_id) if m.get('task_id')==task['id'] and m.get('role')=='user'),None)
        if not message:raise Fault('SOURCE_UNAVAILABLE','缺少用户原话证据',409)
        from adapters.sources import version
        with store.transaction(context.owner_id):
            context.remaining()
            previous=next((i for i in store.rows('project_items',context.owner_id) if i.get('user_update_task')==task['id']),None)
            if previous:return ToolResult('ok',{'item':previous})
            prior=domain.spaces.scope(context.owner_id,'message:'+message['id'])
            domain.spaces.set_scope(context.owner_id,'message:'+message['id'],'spaces',list(set([args['project_id'],*(prior or {}).get('workspace_ids',[])])),(prior or {}).get('revision',0))
            row=store.put('project_items',context.owner_id,{'project_id':args['project_id'],'meeting_id':None,'workspace_id':args['project_id'],
                'kind':'internal','text':quote,'owner':'','due_at':None,'status':'open','version':1,'external_safe':False,'user_update_task':task['id'],
                'evidence_refs':[{'source_id':'message:'+message['id'],'source_version':version(message),'quote':quote,'thread_id':context.thread_id}],
                'update_source':'user','is_practice':False,'is_example':False})
        return ToolResult('ok',{'item':row})
    registry.register(ToolSpec('record_project_update','记录项目进展','用户明确陈述客户回复或项目进展时保存原话与来源，不记录疑问为事实。未接收消息不能断言客户没有回复。',ProgressUpdate,update,frozenset({'chat','communication_prep','communication_review'}),mutates_data=True))
