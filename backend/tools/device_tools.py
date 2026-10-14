"""Phone-executed device requests. Only actual callback/state receipts imply execution."""
from typing import Literal
from pydantic import BaseModel,ConfigDict,Field
from agent_runtime.tools import ToolSpec
from memory import Fault,L1,now

class DeviceAction(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    action:Literal['pause','resume','status']
class DeviceResult(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    action_id:str=Field(min_length=1,max_length=80)

def register_device_tools(registry,store):
    def request(context,args,sources):
        with store.transaction(context.owner_id):
            store.check_owner(context.owner_id)
            prior=next((r for r in store.rows('device_actions',context.owner_id,task_id=context.task_id) if r['action']==args['action']),None)
            row=prior or store.put('device_actions',context.owner_id,{'workspace_id':context.workspace_id,'task_id':context.task_id,
                'action':args['action'],'status':'queued','requested_at':now()},L1)
            return {'status':'pending' if row['status'] in {'queued','running'} else 'ok','action_id':row['id'],
                'device_status':row['status'],'note':'等待手机校验设备状态和执行回执；尚不能声称成功。'}
    def result(context,args,sources):
        row=store.get('device_actions',context.owner_id,args['action_id'])
        if row['workspace_id']!=context.workspace_id:raise Fault('SOURCE_OUTSIDE_WORKSPACE','设备动作属于其他空间',403)
        return {'status':'pending' if row['status'] in {'queued','running'} else 'ok','action':row['action'],'device_status':row['status'],
            'receipt':row.get('receipt'), 'note':'只有device_status=executed才表示手机校验并取得实际状态回执；pending不代表成功。'}
    allowed=frozenset({'chat','communication_prep','communication_review'})
    registry.register(ToolSpec('request_device_action','操作录音设备','仅当用户明确请求时，向手机请求已支持的暂停、继续或状态。开始/结束请用设备按钮。',DeviceAction,request,allowed))
    registry.register(ToolSpec('read_device_action','查看设备回执','读取手机校验后的真实设备动作结果，不推断尚未发生的执行。',DeviceResult,result,allowed))
