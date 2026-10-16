"""Probe the recording review gateway with synthetic text; never access user data.

Run: backend/.venv/bin/python scripts/check-model-gateway.py
Use --stream for a separate streaming probe, or --env-file on the server.
Each invocation sends one small model request, with no automatic retries.
"""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import time
from urllib.parse import urlsplit

import httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))


def probe(base, key, model, *, streaming=False, timeout=150):
    result = {'mode': 'stream' if streaming else 'non-stream', 'ok': False}
    payload = {'model': model, 'messages': [{'role': 'user', 'content': 'Reply exactly OK.'}],
               'max_tokens': 32, 'thinking': {'type': 'disabled'}, 'stream': streaming}
    started = time.monotonic()
    try:
        with httpx.Client(timeout=httpx.Timeout(timeout, connect=min(10, timeout)),
                          follow_redirects=False) as client:
            with client.stream('POST', base.rstrip('/') + '/chat/completions', json=payload,
                               headers={'Authorization': 'Bearer ' + key}) as response:
                result['http_status'] = response.status_code
                if response.status_code != 200:
                    result['error'] = {
                        400: '请求参数被拒绝', 401: '密钥无效', 403: '没有模型使用权限',
                        404: '地址或模型不存在', 429: '请求限流或额度受限',
                        500: '上游内部错误', 502: '上游网关错误',
                        503: '上游服务不可用', 504: '上游网关超时',
                    }.get(response.status_code, 'HTTP 请求未成功')
                else:
                    content, finish = '', None
                    if streaming:
                        if not response.headers.get('content-type', '').startswith('text/event-stream'):
                            raise ValueError('not SSE')
                        for line in response.iter_lines():
                            if time.monotonic() - started > timeout:
                                raise TimeoutError()
                            if not line.startswith('data:'):
                                continue
                            raw = line[5:].strip()
                            if raw == '[DONE]':
                                break
                            chunk = json.loads(raw)
                            if chunk.get('error'):
                                raise ValueError('provider error')
                            for choice in chunk.get('choices', []):
                                if choice.get('index', 0) != 0:
                                    continue
                                delta = choice.get('delta', {}).get('content') or ''
                                if delta and 'first_text_seconds' not in result:
                                    result['first_text_seconds'] = round(time.monotonic() - started, 3)
                                content += delta
                                finish = choice.get('finish_reason') or finish
                    else:
                        choice = json.loads(response.read())['choices'][0]
                        content = choice['message'].get('content') or ''
                        finish = choice.get('finish_reason')
                    result.update(ok=bool(content.strip()) and finish == 'stop', finish_reason=finish)
                    if not result['ok']:
                        result['error'] = '模型未返回完整文字回答'
    except (httpx.TimeoutException, TimeoutError):
        result['error'] = '客户端等待超时'
    except httpx.ConnectError:
        result['error'] = '连接失败（可能为 DNS、TLS 或网络问题）'
    except httpx.HTTPError:
        result['error'] = 'HTTP 传输失败'
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        result['error'] = '模型响应格式无效或流式响应不完整'
    result['elapsed_seconds'] = round(time.monotonic() - started, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, action='append', default=[],
                        help='后端配置文件，可重复指定；已有环境变量优先')
    parser.add_argument('--stream', action='store_true', help='检测流式请求（默认检测复盘使用的非流式请求）')
    parser.add_argument('--timeout', type=float, default=150, help='等待超时秒数，默认 150')
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout 必须为有限正数')
    from run import load_service_environment
    try:
        load_service_environment([*args.env_file, *[p for p in (ROOT / '.env.team.local',
                                                             ROOT / '.env.soundcore.local') if p.exists()]])
    except (OSError, UnicodeError):
        print('无法读取配置文件；请检查文件路径和读取权限。', file=sys.stderr)
        return 2
    key = os.getenv('ANKER_AI_API_KEY', '').strip()
    base = os.getenv('ANKER_AI_BASE_URL', 'https://ai-router-cn-pub.anker-in.com').rstrip('/')
    model = os.getenv('ANKER_AI_MODEL', 'hackathon/v_model/deepseek-v4-pro')
    if not key:
        print('缺少 ANKER_AI_API_KEY；请使用后端环境变量或 --env-file 指定配置。', file=sys.stderr)
        return 2
    try:
        parts = urlsplit(base)
        if parts.scheme not in {'http', 'https'} or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
            raise ValueError()
        parts.port
    except ValueError:
        print('ANKER_AI_BASE_URL 格式无效，应为不含凭证、查询或片段的 HTTP(S) 地址。', file=sys.stderr)
        return 2
    print('检测模型网关：发送一次最小请求，不读取录音、不修改应用数据。', flush=True)
    result = probe(base, key, model, streaming=args.stream, timeout=args.timeout)
    # Do not print raw provider responses, exceptions, headers or configuration secrets.
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
