from pydantic import BaseModel, ConfigDict, Field
from agent_runtime.tools import ToolSpec
from memory import Fault

class MaterialQuery(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    query:str=Field(default='',max_length=500)

def register_material_tools(registry, materials):
    def handle(context,args,sources):
        if not context.workspace_id:raise Fault('WORKSPACE_REQUIRED','缺少当前空间',409)
        return materials.search(context.owner_id,context.workspace_id,args['query'],sources)
    registry.register(ToolSpec('search_materials','读取相关资料','搜索当前空间真实文本、PDF、公司调研和录音知识；保留来源。可用空查询查看最近资料。',
        MaterialQuery,handle,frozenset({'chat','company_research','communication_prep','communication_review','memory_draft'})))

class MaterialPart(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    source_id:str=Field(min_length=3,max_length=200)
    offset:int=Field(default=0,ge=0,le=200000)
    page:int|None=Field(default=None,ge=1,le=300)

def register_material_reader(registry, adapter):
    from adapters.sources import source,collect,text_of,state_of
    def handle(context,args,sources):
        kind,row=adapter.resolve(context.owner_id,args['source_id'],context.workspace_id)
        if state_of(row)!='current':raise Fault('SOURCE_SUPERSEDED','依据已变化，请重新核对',409)
        text=text_of(kind,row)
        page=args.get('page')
        if page is not None:
            pages=row.get('pages',[])
            selected=next((p for p in pages if p.get('page')==page),None)
            if selected is None:raise Fault('PAGE_UNAVAILABLE','资料没有该页',404)
            text=selected['text']
        start=args['offset'];end=min(start+6000,len(text))
        item=source(kind,row,reading_range='source_excerpt')
        item.update(text=text[start:end],text_truncated=end<len(text),offset=start,end_offset=end,page=page,
            ref=item['ref']+':'+str(page or 0)+':'+str(start))
        return {'items':[collect(item,sources)],'next_offset':end if end<len(text) else None,'total_chars':len(text)}
    registry.register(ToolSpec('read_material_part','读取资料片段','按source_id、字符位置及可选PDF页码读取真实长资料，返回后续位置。',MaterialPart,handle,
        frozenset({'chat','company_research','communication_prep','communication_review','memory_draft'})))
