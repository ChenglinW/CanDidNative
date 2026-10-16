"""Internal skill activation; never appears as a Skill selector or user-facing tool step."""
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field
from memory import Fault
from agent_runtime.tools import ToolResult, ToolSpec


class SkillArgs(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    name: Literal['communication_prep', 'communication_review', 'memory_draft', 'company_research']
    inputs: dict[str, str] = Field(default_factory=dict, max_length=12)


def register_skill_tool(registry, catalog):
    def load(context, args, sources):
        try:
            skill = catalog.load(args['name'], context.skill_index_snapshot, args.get('inputs', {}))
        except Fault as error:
            return ToolResult.failure(error.code, error.message, error.code=='SKILL_INPUT_INVALID')
        return ToolResult('ok', {'skill_snapshot': skill})
    registry.register(ToolSpec(
        'run_skill', '准备沟通流程', '根据服务端固定索引按需加载一个沟通流程。只选索引中 available=true 的流程；加载后执行其规则。',
        SkillArgs, load, frozenset({'chat', 'communication_prep', 'communication_review', 'memory_draft','company_research'}),
        visible_to_user=False))
