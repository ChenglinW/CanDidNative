"""Review model calls stream their result, and a gateway failure names the step."""
import json
import sys
from pathlib import Path
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_runtime.providers import Gateway
from memory import Fault
from tasks.business import BusinessJobs, describe_failure


def test_upstream_timeout_keeps_status_code():
    with pytest.raises(Fault) as caught:
        Gateway._status(504)
    assert caught.value.code == 'AGENT_UPSTREAM_TIMEOUT'
    assert caught.value.details['upstream_status'] == 504
    assert '504' not in caught.value.message or '中断' in caught.value.message
    assert caught.value.message != '模型网关暂时不可用'


def test_other_upstream_errors_include_http_status():
    with pytest.raises(Fault) as caught:
        Gateway._status(503)
    assert caught.value.details['upstream_status'] == 503
    assert '503' in caught.value.message


def test_structured_review_uses_streaming_then_parses():
    class Fake:
        def complete(self, messages, tools=True, *, on_delta=None, **kwargs):
            assert on_delta is not None
            on_delta('{"summary":"已整理"}')
            return {'role': 'assistant', 'content': '{"summary":"已整理"}'}
    jobs = BusinessJobs.__new__(BusinessJobs)
    jobs.gateway = Fake()
    assert jobs.structured('整理', {'segments': []})['summary'] == '已整理'


def test_failure_record_names_the_review_step():
    error = Fault('AGENT_UPSTREAM_TIMEOUT', '上游在返回完整结果前中断了这次请求，已有内容会保留，可以重试这一步', 502, {'upstream_status': 504})
    row = describe_failure({'kind': 'recording_knowledge'}, error, '2026-10-17T00:00:00+00:00')
    assert row['status'] == 'failed'
    assert row['error'].startswith('复盘整理失败（上游 HTTP 504）')
    assert row['error_code'] == 'AGENT_UPSTREAM_TIMEOUT'
    assert row['upstream_status'] == 504
    assert row['elapsed_ms'] >= 0
    faq = describe_failure({'kind': 'library_extract'}, error, None)
    assert faq['error'].startswith('问答提取失败（上游 HTTP 504）')
    assert faq['elapsed_ms'] is None
    assert 'summary' not in json.dumps(row)
