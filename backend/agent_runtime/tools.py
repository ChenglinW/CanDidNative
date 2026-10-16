"""Validated tool registration, task permissions, deadlines and safe result envelopes."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass, field, replace
import json
import time
from typing import Callable

from pydantic import BaseModel, ValidationError
from memory import Fault
from .config import fingerprint


@dataclass
class ToolResult:
    status: str
    data: dict = field(default_factory=dict)
    sources: list = field(default_factory=list)
    error: dict | None = None

    def as_dict(self):
        return {'status': self.status, 'data': self.data, 'sources': self.sources, 'error': self.error}

    @classmethod
    def failure(cls, code, message, retryable=False):
        return cls('error', error={'code': code, 'message': message, 'retryable': retryable})


@dataclass(frozen=True)
class ToolSpec:
    name: str
    title: str
    description: str
    input_model: type[BaseModel]
    handler: Callable
    allowed_tasks: frozenset[str]
    timeout_seconds: int = 10
    mutates_data: bool = False
    version: str = '1'
    visible_to_user: bool = True

    def schema(self):
        return {'type': 'function', 'function': {
            'name': self.name, 'description': self.description,
            'parameters': self.input_model.model_json_schema()}}

    def snapshot(self):
        return {**self.schema(), 'version': self.version, 'mutates_data': self.mutates_data,
                'allowed_tasks': sorted(self.allowed_tasks), 'timeout_seconds': self.timeout_seconds,
                'result_format': 'candid-tool-result@1', 'visible_to_user': self.visible_to_user}


class ToolRegistry:
    def __init__(self):
        self._tools = {}
        self._pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix='candid-memory-tool')

    def register(self, spec):
        if spec.name in self._tools:
            raise ValueError('Duplicate tool registration: ' + spec.name)
        self._tools[spec.name] = spec

    def available(self, context):
        return [s for s in self._tools.values() if context.task_kind in s.allowed_tasks
                and (context.allowed_tools is None or s.name in context.allowed_tools)
                and (not s.mutates_data or context.allow_mutations)]

    @property
    def names(self):
        return list(self._tools)

    def title(self, name):
        spec = self._tools.get(name)
        return spec.title if spec else '查询资料'

    def visible_to_user(self, name):
        spec = self._tools.get(name)
        return spec is None or spec.visible_to_user

    def snapshot(self):
        definitions = [s.snapshot() for s in self._tools.values()]
        return {'version': fingerprint(definitions), 'definitions': definitions}

    def execute(self, context, name, arguments, sources):
        spec = self._tools.get(name)
        if not spec or spec not in self.available(context):
            return ToolResult.failure('TOOL_FORBIDDEN', '当前任务不能使用这个工具')
        try:
            args = spec.input_model.model_validate(arguments).model_dump(exclude_none=True)
        except ValidationError as exc:
            fields=', '.join('.'.join(map(str,e['loc']))+':'+e['type'] for e in exc.errors(include_input=False,include_url=False))
            return ToolResult.failure('TOOL_ARGUMENTS_INVALID', '工具参数需要修正：'+fields[:1000], True)
        timeout = min(spec.timeout_seconds, context.budget.tool_timeout_seconds, context.remaining())
        # The worker receives its own source list. Timed-out calls cannot change the answer's sources.
        collected = json.loads(json.dumps(sources, ensure_ascii=False))
        worker_context=replace(context,deadline=min(context.deadline,time.monotonic()+timeout))
        future = self._pool.submit(spec.handler, worker_context, args, collected)
        try:
            deadline = time.monotonic() + timeout
            while True:
                context.remaining()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise FutureTimeout()
                try:
                    data = future.result(timeout=min(.1, remaining))
                    context.remaining()
                    break
                except FutureTimeout:
                    if time.monotonic() >= deadline:
                        raise
            if isinstance(data, ToolResult):
                if len(json.dumps(data.as_dict(), ensure_ascii=False)) > context.budget.max_tool_result_chars:
                    return ToolResult.failure('TOOL_OUTPUT_TOO_LARGE', '资料过多，请缩小查询范围')
                return data
            if not isinstance(data, dict):
                return ToolResult.failure('TOOL_INVALID_OUTPUT', '工具未返回结构化资料')
            if data.get('error'):
                return ToolResult.failure('TOOL_UNAVAILABLE', '未找到可访问的资料或工具参数不正确')
            if len(json.dumps(data, ensure_ascii=False)) > context.budget.max_tool_result_chars:
                return ToolResult.failure('TOOL_OUTPUT_TOO_LARGE', '资料过多，请缩小查询范围')
            items = data.get('items')
            status = data.get('status') or ('empty' if items == [] else 'ok')
            referenced = {item.get('ref') for item in (items or []) if isinstance(item, dict)}
            result_sources = [s for s in collected if s.get('ref') in referenced]
            return ToolResult(status, data, result_sources)
        except FutureTimeout:
            future.cancel()
            return ToolResult.failure('TOOL_TIMEOUT', '资料查询超时，可以重试', True)
        except Fault as exc:
            if exc.code in {'MEMORY_DELETED', 'AGENT_CANCELLED', 'AGENT_TIMEOUT'}:
                future.cancel()
                raise
            if exc.code in {'RESEARCH_REQUIRED','RESEARCH_NOT_ALLOWED','SOURCE_UNSUPPORTED','SOURCE_UNREADABLE','RESEARCH_RESULT_INVALID','MONID_NOT_CONFIGURED','MONID_REQUEST_REJECTED','MONID_UNAVAILABLE','MONID_FORMAT_INVALID','PROVIDER_SUBMIT_UNCERTAIN','RESEARCH_SOURCE_FAILED','RESEARCH_RATE_LIMITED','URL_INVALID','USER_INTENT_REQUIRED','SOURCE_UNAVAILABLE','SOURCE_SUPERSEDED','DATE_INVALID','WORKSPACE_ARCHIVED','VERSION_CONFLICT'}:
                return ToolResult.failure(exc.code,exc.message,exc.details.get('retryable',exc.status>=500 or exc.code in {'RESEARCH_REQUIRED','USER_INTENT_REQUIRED','SOURCE_UNAVAILABLE','SOURCE_SUPERSEDED','DATE_INVALID','WORKSPACE_ARCHIVED','VERSION_CONFLICT'}))
            return ToolResult.failure('TOOL_DATA_UNAVAILABLE', '未找到可访问的资料', exc.status >= 500)
        except Exception:
            # Provider responses, user content and exception repr never enter model-visible errors.
            return ToolResult.failure('TOOL_FAILED', '资料查询暂时失败，可以重试', True)

    def close(self):
        self._pool.shutdown(wait=False, cancel_futures=True)
