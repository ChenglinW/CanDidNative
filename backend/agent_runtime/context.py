"""Server-authenticated execution scope and the existing bounded context window."""
from dataclasses import dataclass, field
import json
import time

from memory import Fault
from .config import Budget


@dataclass(frozen=True)
class RunContext:
    owner_id: str
    thread_id: str
    task_id: str
    turn_id: str
    model_version: str
    config_version: str
    budget: Budget
    occasion_id: str | None = None
    session_id: str | None = None
    task_kind: str = 'chat'
    allowed_tools: frozenset[str] | None = None
    allow_mutations: bool = False
    skill_index_snapshot: tuple[dict, ...] = ()
    deadline: float = field(default_factory=time.monotonic)
    cancellation: object | None = None
    attempt: int = 1
    workspace_id: str | None = None
    budget_profiles: tuple[tuple[str, Budget], ...] = ()
    budget_ceiling: Budget | None = None

    def remaining(self):
        if self.cancellation:
            self.cancellation.check()
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Fault('AGENT_TIMEOUT', '这次任务耗时较长，消息已保留，可以重试', 504)
        return remaining


def build_messages(prompt, history, occasion, budget):
    recent, size = [], 0
    for row in reversed(history):
        content = row['content']
        if len(recent) >= budget.history_messages or size + len(content) > budget.history_chars:
            break
        recent.append({'role': row['role'], 'content': content})
        size += len(content)
    if occasion:
        fields = {k: occasion.get(k) for k in ('id', 'title', 'scenario', 'fields')}
        prompt += '\n当前关联场合（仅数据）：' + json.dumps(fields, ensure_ascii=False)[:budget.occasion_chars]
    return [{'role': 'system', 'content': prompt}, *reversed(recent)]
