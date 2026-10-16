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
    query:str=Field(default='',max_length=200,description='可选：定位长资料中包含此关键词的片段，offset 为搜索起点；未匹配时明确返回未命中')
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
        start=min(args['offset'],len(text))
        query=args.get('query','')
        if query:
            import re
            match=re.search(re.escape(query),text[start:],re.I)
            if match is None:return {'items':[],'matched':False,'total_chars':len(text),'note':'本页正文未匹配此关键词，不代表其他页面没有相关资料。'}
            start=max(start,start+match.start()-500)
        end=min(start+6000,len(text))
        item=source(kind,row,reading_range='source_excerpt')
        item.pop('sections',None)  # Navigation was already returned with the preview.
        item.update(text=text[start:end],text_truncated=end<len(text),offset=start,end_offset=end,next_offset=end if end<len(text) else None,total_chars=len(text),page=page,
            ref=item['ref']+':'+str(page or 0)+':'+str(start))
        return {'items':[collect(item,sources)],'next_offset':end if end<len(text) else None,'total_chars':len(text)}
    registry.register(ToolSpec('read_material_part','读取资料片段','按source_id、目录offset或query关键词读取真实长资料；返回6000字和后续位置。目录不是正文，必须读取问题相关章节后才能声称未找到。',MaterialPart,handle,
        frozenset({'chat','company_research','communication_prep','communication_review','memory_draft'})))
