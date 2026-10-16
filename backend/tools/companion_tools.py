"""Prepare directly inside the enduring Chat, with durable report cards."""
from pydantic import BaseModel,ConfigDict,Field
from companion import Companion
from agent_runtime.tools import ToolSpec,ToolResult
from memory import Fault

class Section(BaseModel):
    model_config=ConfigDict(extra='forbid')
    title:str=Field(min_length=1,max_length=100)
    text:str=Field(min_length=1,max_length=5000)
class Preparation(BaseModel):
    model_config=ConfigDict(extra='forbid')
    client:str=Field(min_length=1,max_length=200)
    goal:str=Field(min_length=1,max_length=1500)
    scenario:str=Field(pattern='^(sales|interview)$')
    scheduled_at:str|None=None
    time_quote:str=Field(default='',max_length=200)
    concerns:str=Field(default='',max_length=1500)
    participants:list[str]=Field(default_factory=list,max_length=30,description='用户已明确提供的参会人及角色，未知时留空，不猜测姓名')
    user_quote:str=Field(min_length=1,max_length=3000)
    sections:list[Section]=Field(min_length=3,max_length=12)
    source_ids:list[str]=Field(default_factory=list,max_length=30)

def register_companion_tools(registry,store):
    def prepare(context,args,sources):
        domain=Companion(store)
        messages=store.rows('chat_messages',context.owner_id,thread_id=context.thread_id)
        user='\n'.join(m['content'] for m in messages if m['role']=='user')
        if args['user_quote'] not in user: raise Fault('USER_INTENT_REQUIRED','请先在对话中说明准备意图',403)
        known={s['source_id']:s for s in sources}
        if any(s not in known for s in args['source_ids']): raise Fault('SOURCE_UNAVAILABLE','准备依据尚未读取',409)
        refs=[{'source_id':s,'source_version':known[s]['source_version']} for s in args['source_ids']]
        data={k:v for k,v in args.items() if k not in {'source_ids','user_quote','time_quote'}}
        if not args['time_quote'] or args['time_quote'] not in user: data['scheduled_at']=None
        # Only names explicitly present in this user's conversation become meeting metadata.
        data['participants']=[name for name in args.get('participants',[]) if name and name in user]
        context.remaining()
        pack=domain.save_preparation(context.owner_id,context.thread_id,'agent:'+context.task_id,data,refs)
        return ToolResult('ok',{'preparation_package_id':pack['id'],'version':pack['version'],'saved':True,'note':'Chat卡片与首页已同步，不再重复生成准备包。'})
    registry.register(ToolSpec('save_preparation','保存会前准备包',
        '用户准备销售沟通或面试时，先检索资料；从对话补齐对象和目标。时间、顾虑可未知，不强制追问。生成至少目标、对象背景、提纲、关键问题、表达建议和待核实事项等章节；有实际来源的事实需引用已读取source_ids，建议和未知项需明确区分。保存后会自动发布Chat卡片及首页同一准备包。user_quote取用户原话，日期含时区且time_quote为实际用户时间原话。',
        Preparation,prepare,frozenset({'chat','communication_prep'}),mutates_data=True))
