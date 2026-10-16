from typing import Literal
from pydantic import BaseModel,ConfigDict,Field
from agent_runtime.tools import ToolSpec
from memory import Fault

class Args(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    force_refresh:bool=Field(default=False,description='用户要求刷新或最新动态时设为true，跳过缓存；同任务相同请求仍不会重复付费提交')
class Search(Args):
    query:str=Field(min_length=1,max_length=500)
    platform:Literal['google','bing','baidu','reddit','youtube','wechat','bilibili']|None=None
    time_range:Literal['day','week','month','year']|None=None
class Read(Args):url:str=Field(min_length=8,max_length=2000)
class Video(Read):
    language:Literal['zh','en']|None=None
class Company(Args):
    name:str=Field(min_length=1,max_length=200)
    website:str|None=Field(default=None,max_length=2000)

def register_research_tools(registry, monid):
    for name,title,kind,args in [('search_company','搜索公司资料','search',Search),('read_source','读取公开正文','read',Read),('enrich_company','补全公司档案','company',Company),('get_video_transcript','读取视频字幕','youtube',Video)]:
        def handle(context,arguments,sources,kind=kind):
            if not context.workspace_id:raise Fault('WORKSPACE_REQUIRED','缺少当前空间',409)
            return monid.tool(context,kind,arguments,sources)
        description={'search':'搜索公开公司资料或指定平台摘要。最新动态设置time_range及force_refresh；摘要不是正文、完整评论或字幕。',
            'read':'读取指定公开网页正文。当前供应商不支持Reddit正文，遇到拒绝不要反复改同站网址重试；应说明只拿到搜索摘要。',
            'company':'仅在确实需要规模、行业、成立时间等公司档案字段且已确定公司身份时补充；普通官网概括、产品反馈、准备包不必调用。',
            'youtube':'读取YouTube单视频真实字幕；没有字幕就说明，不能从标题推测。'}[kind]
        registry.register(ToolSpec(name,title,description,
            args,handle,frozenset({'chat','company_research','communication_prep'}),timeout_seconds=120))
