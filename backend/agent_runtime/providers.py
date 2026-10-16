"""Server-only OpenAI-compatible text providers; no cross-provider fallback."""
import os
import json
import time
import httpx
from memory import Fault

def has_control_markup(text):
    return '<｜' in text or '<|DSML|' in text or '<|tool_calls' in text

def visible_prefix(text):
    """Hold incomplete control tokens across SSE fragments; never display model wire syntax."""
    stop=len(text)
    for marker in ('<｜','<|DSML|','<|tool_calls'):
        at=text.find(marker)
        if at>=0:stop=min(stop,at)
    # A chunk can finish halfway through the opening marker.
    if stop==len(text):
        for marker in ('<｜','<|DSML|','<|tool_calls'):
            for n in range(1,len(marker)):
                if text.endswith(marker[:n]):stop=min(stop,len(text)-n)
    return text[:stop]

class Gateway:
    def __init__(self):
        self.provider = os.environ.get('CANDID_TEXT_PROVIDER', 'anker').strip().lower()
        if self.provider == 'dashscope':
            self._key = os.environ.get('DASHSCOPE_API_KEY', '')
            self.base = os.environ.get('DASHSCOPE_TEXT_BASE_URL', 'https://dashscope.aliyuncs.com/compatible-mode/v1').rstrip('/')
            self.model = os.environ.get('DASHSCOPE_TEXT_MODEL', 'qwen3.8-max')
        elif self.provider == 'anker':
            self._key = os.environ.get('ANKER_AI_API_KEY', '')
            self.base = os.environ.get('ANKER_AI_BASE_URL', 'https://ai-router-cn-pub.anker-in.com').rstrip('/')
            self.model = os.environ.get('ANKER_AI_MODEL', 'hackathon/v_model/deepseek-v4-pro')
        else:
            raise ValueError('Unsupported CANDID_TEXT_PROVIDER')

    @property
    def configured(self):
        return bool(self._key.strip())

    def complete(self, messages, tools=True, *, schemas=None, timeout_seconds=90, max_tokens=4096, cancellation=None, on_delta=None):
        if not self.configured:
            raise Fault('AGENT_NOT_CONFIGURED', '文本 Agent 尚未配置模型网关 Key', 503)
        payload = {'model': self.model, 'messages': messages, 'max_tokens': max_tokens}
        if self.provider == 'dashscope':
            payload['enable_thinking'] = False
        else:
            payload['thinking'] = {'type': 'disabled'}
        if tools:
            if schemas is None:
                from tools.memory_tools import DEFINITIONS
                schemas = [{'type': 'function', 'function': {
                    'name': name, 'description': description, 'parameters': args.model_json_schema()}}
                    for name, _, description, args in DEFINITIONS]
            payload.update(tools=schemas or [], tool_choice='auto')
        if cancellation:
            cancellation.check()
        client = httpx.Client(timeout=httpx.Timeout(timeout_seconds, connect=min(10, timeout_seconds)), follow_redirects=False)
        try:
            if cancellation:
                cancellation.register(client.close)
            if on_delta is not None:
                payload['stream'] = True
                return self._stream(client, payload, on_delta, cancellation)
            response = client.post(self.base + '/chat/completions', json=payload,
                                   headers={'Authorization': 'Bearer ' + self._key})
            if cancellation:
                cancellation.check()
        except httpx.TimeoutException:
            if cancellation:
                cancellation.check()
            raise Fault('AGENT_TIMEOUT', '模型响应超时，消息已保留，可以重试', 504) from None
        except (httpx.HTTPError, OSError, RuntimeError):
            if cancellation:
                cancellation.check()
            raise Fault('AGENT_UNAVAILABLE', '暂时无法连接模型网关，请稍后重试', 502) from None
        finally:
            if cancellation:
                cancellation.unregister(client.close)
            try:
                client.close()
            except Exception:
                pass
        self._status(response.status_code)
        try:
            choice = response.json()['choices'][0]
            message = choice['message']
            if choice.get('finish_reason') not in {'stop', 'tool_calls'}:
                raise ValueError('incomplete output')
            if not message.get('content') and not message.get('tool_calls'):
                raise ValueError('empty output')
            # Never return or persist reasoning_content from the provider.
            result = {'role': 'assistant', 'content': message.get('content') or ''}
            if message.get('tool_calls'):
                result['tool_calls'] = message['tool_calls']
            return result
        except (ValueError, KeyError, IndexError, TypeError):
            raise Fault('AGENT_INVALID_OUTPUT', '模型没有返回完整回答，消息已保留，可以重试', 502) from None

    @staticmethod
    def _status(status_code):
        if status_code != 200:
            code, message = {
                401: ('AGENT_AUTH_FAILED', '模型网关 Key 无效，请检查后端配置'),
                403: ('AGENT_FORBIDDEN', '当前 Key 没有此模型的使用权限'),
                429: ('AGENT_RATE_LIMITED', '模型请求过于频繁，请稍后重试'),
                400: ('AGENT_REQUEST_REJECTED', '模型请求被拒绝，请检查模型或工具参数'),
                404: ('AGENT_MODEL_UNAVAILABLE', '模型不可用，请检查后端模型配置'),
            }.get(status_code, ('AGENT_UNAVAILABLE', '模型网关暂时不可用'))
            raise Fault(code, message, 502)

    def _stream(self, client, payload, on_delta, cancellation):
        content, calls, finish, buffer = '', {}, None, ''
        delivered=0
        last_flush = time.monotonic()
        with client.stream('POST', self.base + '/chat/completions', json=payload,
                           headers={'Authorization': 'Bearer ' + self._key}) as response:
            self._status(response.status_code)
            if not response.headers.get('content-type', '').startswith('text/event-stream'):
                raise Fault('AGENT_STREAM_UNAVAILABLE', '模型网关未返回流式响应，请检查当前模型的流式支持', 502)
            if cancellation:cancellation.register(response.close)
            try:
                for line in response.iter_lines():
                    if cancellation:
                        cancellation.check()
                    if not line.startswith('data:'):
                        continue
                    raw = line[5:].strip()
                    if raw == '[DONE]':
                        break
                    chunk = json.loads(raw)
                    if chunk.get('error'):
                        raise ValueError('provider stream error')
                    for choice in chunk.get('choices', []):
                        if choice.get('index', 0) != 0:
                            continue
                        delta = choice.get('delta') or {}
                        # reasoning_content is deliberately ignored, including during streaming.
                        text = delta.get('content') or ''
                        if not isinstance(text, str):
                            raise ValueError('invalid content')
                        content += text
                        safe=visible_prefix(content)
                        buffer=safe[delivered:]
                        if len(content) > 64000:
                            raise ValueError('oversized content')
                        if buffer and (len(buffer) >= 80 or time.monotonic() - last_flush >= .1):
                            on_delta(buffer); delivered=len(safe); buffer = ''; last_flush = time.monotonic()
                        for fragment in delta.get('tool_calls') or []:
                            index = fragment['index']
                            if not isinstance(index, int) or not 0 <= index < 12:
                                raise ValueError('invalid tool index')
                            call = calls.setdefault(index, {'id':'', 'type':'function', 'function':{'name':'','arguments':''}})
                            if fragment.get('id'):
                                call['id'] += fragment['id']
                            for key in ('name', 'arguments'):
                                call['function'][key] += (fragment.get('function') or {}).get(key) or ''
                            if len(call['function']['arguments']) > 64000:
                                raise ValueError('oversized tool arguments')
                        finish = choice.get('finish_reason') or finish
                if buffer:
                    on_delta(buffer)
                if finish not in {'stop', 'tool_calls'} or (not content and not calls):
                    raise ValueError('incomplete stream')
                result = {'role':'assistant', 'content':content}
                if calls:
                    result['tool_calls'] = [calls[i] for i in sorted(calls)]
                return result
            except (ValueError, KeyError, IndexError, TypeError):
                raise Fault('AGENT_INVALID_OUTPUT', '模型没有返回完整流式回答，消息已保留，可以重试', 502) from None

            finally:
                if cancellation:cancellation.unregister(response.close)
