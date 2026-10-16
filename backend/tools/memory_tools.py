"""Business tool definitions independent of the memory storage implementation."""
from pydantic import BaseModel, ConfigDict, Field
from memory import Fault
from agent_runtime.tools import ToolRegistry, ToolSpec


class EmptyArgs(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class SearchArgs(EmptyArgs):
    query: str = Field(min_length=1, max_length=500, description='使用用户提供的公司、主题或经历')
    occasion_id: str | None = Field(default=None, min_length=1, max_length=80)
    session_id: str | None = Field(default=None, min_length=1, max_length=80)
    include_evidence: bool = False


class SourceReference(EmptyArgs):
    source_id: str = Field(min_length=3, max_length=200)
    source_version: str | None = Field(default=None, max_length=100)


class ReadEvidenceArgs(EmptyArgs):
    references: list[SourceReference] = Field(min_length=1, max_length=24)


class SessionsArgs(EmptyArgs):
    occasion_id: str | None = Field(default=None, min_length=1, max_length=80)


class ReadSessionArgs(EmptyArgs):
    session_id: str = Field(min_length=1, max_length=80)


DEFINITIONS = (
    ('search_memory', '查找相关记忆', '查询相关条目的摘要片段，默认仅已确认 L3；可按场合、场次过滤。详细原文通过 read_evidence 读取。', SearchArgs),
    ('read_evidence', '读取资料依据', '用 source_id 与可选 source_version 读取实际资料原文及位置；版本失效时不返回旧内容。', ReadEvidenceArgs),
    ('list_occasions', '查看最近场合', '列出最近的真实沟通场合及其目标，用于定位上次沟通。', EmptyArgs),
    ('list_sessions', '查看最近录音', '列出最近真实录音或复述场次及标记数量，获得 session_id 后可读取原文和关注位置；不包含示例。', SessionsArgs),
    ('read_session', '读取录音原文', '读取指定场次获授权的原文及用户标记点；有标记时优先返回附近原文，标记只表示关注，不代表确认或本人身份。', ReadSessionArgs),
)


def memory_registry(adapter):
    registry = ToolRegistry()
    for name, title, description, args_model in DEFINITIONS:
        def handle(context, args, sources, tool_name=name):
            if not context.workspace_id:
                raise Fault('WORKSPACE_REQUIRED','Agent 查询缺少项目空间',409)
            return adapter.query(context.owner_id, tool_name, args, sources, context.occasion_id, context.workspace_id)
        registry.register(ToolSpec(name, title, description, args_model, handle,
                                  frozenset({'chat', 'company_research', 'communication_prep',
                                             'communication_review', 'memory_draft'})))
    return registry
