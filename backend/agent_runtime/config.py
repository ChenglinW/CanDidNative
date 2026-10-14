"""Runtime budgets and independent server-only service configuration."""
from dataclasses import asdict, dataclass, field
import hashlib
import json
import os
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from memory import Fault


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def public_endpoint(url):
    parts = urlsplit(url)
    host = parts.hostname or ''
    if ':' in host:
        host = '[' + host + ']'
    if parts.port:
        host += ':' + str(parts.port)
    return urlunsplit((parts.scheme, host, parts.path, '', ''))


@dataclass(frozen=True)
class Budget:
    max_rounds: int
    max_calls_per_round: int
    max_tool_calls: int
    max_input_chars: int
    history_messages: int
    history_chars: int
    occasion_chars: int
    max_context_chars: int
    max_tool_result_chars: int
    timeout_seconds: int
    model_timeout_seconds: int
    tool_timeout_seconds: int
    context_rules_chars: int = 6000
    context_soul_chars: int = 6000
    context_index_chars: int = 4000
    context_preferences_chars: int = 2000
    context_task_chars: int = 2000
    context_skill_chars: int = 24000
    context_memory_chars: int = 12000
    context_summary_chars: int = 8000
    summary_input_chars: int = 40000
    summary_max_tokens: int = 4096

    def __post_init__(self):
        if any(type(v) is not int or v < 1 for v in asdict(self).values()):
            raise Fault('AGENT_CONFIG_INVALID', 'Agent 预算必须是正整数', 503)


@dataclass(frozen=True)
class ServiceSettings:
    dashscope_region: str
    asr_realtime_model: str
    asr_file_model: str
    memory_backend: str
    memory_url: str
    monid_url: str
    monid_budget_yuan: str
    dashscope_key: str = field(repr=False)
    memory_key: str = field(repr=False)
    monid_key: str = field(repr=False)

    @classmethod
    def from_environment(cls):
        return cls(
            os.getenv('DASHSCOPE_REGION', 'cn-beijing'),
            os.getenv('DASHSCOPE_ASR_REALTIME_MODEL', 'qwen-audio-3.1-asr-flash-streaming'),
            os.getenv('DASHSCOPE_ASR_FILE_MODEL', 'qwen-audio-3.1-asr-flash-filetrans'),
            os.getenv('CANDID_MEMORY_BACKEND', 'sqlite'),
            os.getenv('CANDID_MEMORY_SERVICE_URL', ''),
            os.getenv('MONID_BASE_URL', 'https://api.monid.ai'), os.getenv('MONID_BUDGET_YUAN', ''),
            os.getenv('DASHSCOPE_API_KEY', ''), os.getenv('CANDID_MEMORY_SERVICE_KEY', ''),
            os.getenv('MONID_API_KEY', ''))

    def public_status(self):
        return {
            'dashscope': {'configured': bool(self.dashscope_key), 'region': self.dashscope_region,
                         'realtime_model': self.asr_realtime_model, 'file_model': self.asr_file_model,
                         'pipeline_enabled': bool(self.dashscope_key)},
            'memory': {'backend': self.memory_backend, 'contract_version': 'candid-memory@2-draft'},
            'monid': {'configured': bool(self.monid_key and self.monid_url),
                      'key_configured': bool(self.monid_key), 'budget_configured': True, 'spending_policy':'demo_unlimited',
                      'integration_enabled': bool(self.monid_key)}}


class RuntimeConfig:
    def __init__(self, path=None):
        self.path = Path(path or Path(__file__).resolve().parents[1] / 'agent_config/runtime.json')
        try:
            raw = json.loads(self.path.read_text('utf8'))
            self.version = raw['version']
            self.profiles = {name: Budget(**value) for name, value in raw['profiles'].items()}
            self.digest = fingerprint(raw)
            self.context_policy = raw.get('context_policy', {})
            if self.context_policy.get('summary_mode') not in {'current_text_model'}:
                raise ValueError('Unsupported summary model policy')
            limit = self.context_policy.get('automatic_memory_limit', 4)
            if type(limit) is not int or not 1 <= limit <= 6:
                raise ValueError('Invalid automatic memory limit')
            if type(self.context_policy.get('automatic_memory')) is not bool:
                raise ValueError('Invalid automatic memory policy')
        except (OSError, KeyError, ValueError, TypeError):
            raise Fault('AGENT_CONFIG_INVALID', 'Agent 运行配置无法读取', 503) from None
        self.services = ServiceSettings.from_environment()

    def budget(self, kind='chat'):
        if kind not in self.profiles:
            raise Fault('AGENT_TASK_UNSUPPORTED', '该任务类型尚未配置', 422)
        return self.profiles[kind]
