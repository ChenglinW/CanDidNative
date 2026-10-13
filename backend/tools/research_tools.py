from typing import Literal
from pydantic import BaseModel,ConfigDict,Field
from agent_runtime.tools import ToolSpec
from memory import Fault

class Args(BaseModel):model_config=ConfigDict(extra='forbid',strict=True)
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
        registry.register(ToolSpec(name,title,'通过受控Monid接口取得真实资料并保存来源；可读取公司动态、公开岗位及产品反馈。',
            args,handle,frozenset({'chat','company_research','communication_prep'}),timeout_seconds=120))
