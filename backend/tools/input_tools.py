"""A bounded request for missing user input; no provider or memory mutation."""
from pydantic import BaseModel, ConfigDict, Field
from agent_runtime.tools import ToolResult, ToolSpec


class InputArgs(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    question: str = Field(min_length=1, max_length=1000)
    options: list[str] = Field(default_factory=list, max_length=4)


def register_input_tool(registry):
    def request(context, args, sources):
        if any(not value.strip() or len(value)>120 for value in args['options']):
            return ToolResult.failure('TOOL_ARGUMENTS_INVALID','选项为空或过长')
        return ToolResult('waiting_input', {'question':args['question'], 'options':args['options']})
    registry.register(ToolSpec('request_input','等待你的补充',
        '只有缺少会改变任务方向的用户信息、无法继续时使用。提出一个清晰问题和至多四个建议答案；任务暂停等待真实用户答复，不自行选择。普通聊天追问可直接回答。',
        InputArgs,request,frozenset({'chat','communication_prep','communication_review','memory_draft','company_research'}),
        visible_to_user=False))
