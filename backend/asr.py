"""Qwen Audio 3.0 ASR Flash native synchronous HTTP adapter (server-side only).

Evaluation inputs are local mono PCM16 WAV clips. No public upload URL is needed.
This model does not identify speakers. Do not infer `self` from a microphone channel.
"""
import base64
import io
import json
import os
import re
import wave
from pathlib import Path

import httpx
from llm import ModelError

MODEL = 'qwen-audio-3.0-asr-flash'
PATH = '/api/v1/services/aigc/multimodal-generation/generation'
MAX_ENCODED_BYTES = 10_000_000


def read_wav(path):
    path = Path(path)
    if path.stat().st_size > (MAX_ENCODED_BYTES - 100) * 3 // 4:
        raise ModelError('ASR_AUDIO_TOO_LARGE', 'Base64 编码后的音频不能超过 10 MB，请缩短片段')
    raw = path.read_bytes()
    try:
        with wave.open(io.BytesIO(raw), 'rb') as audio:
            rate, frames = audio.getframerate(), audio.getnframes()
            if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or rate != 16000:
                raise ValueError('mono 16k PCM16 required')
            if not 0 < frames <= 300 * rate:
                raise ValueError('duration')
            if len(audio.readframes(frames)) != frames * 2:
                raise ValueError('truncated')
    except (wave.Error, EOFError, ValueError):
        raise ModelError('ASR_AUDIO_INVALID', '测试音频必须是完整的 16 kHz 单声道 PCM16 WAV，时长不超过 5 分钟') from None
    return raw, round(frames * 1000 / rate)


class QwenASR:
    def __init__(self, api_key='', model=MODEL, region='cn-beijing', workspace_id='', transport=None):
        if model != MODEL:
            raise ValueError('This adapter implements qwen-audio-3.0-asr-flash only')
        if region not in {'cn-beijing', 'ap-southeast-1'}:
            raise ValueError('Qwen ASR region must be cn-beijing or ap-southeast-1')
        if workspace_id and not re.fullmatch(r'[a-zA-Z0-9-]+', workspace_id):
            raise ValueError('Invalid workspace_id')
        self._api_key, self.model, self.region = api_key, model, region
        self.transport = transport
        legacy = 'dashscope.aliyuncs.com' if region == 'cn-beijing' else 'dashscope-intl.aliyuncs.com'
        host = f'{workspace_id}.{region}.maas.aliyuncs.com' if workspace_id else legacy
        self.endpoint = 'https://' + host + PATH

    @classmethod
    def from_config(cls, root):
        path = Path(root) / 'asr-config.json'
        config = json.loads(path.read_text('utf8')) if path.exists() else {}
        return cls(api_key=os.environ.get('QWEN_ASR_API_KEY', os.environ.get('DASHSCOPE_API_KEY', config.get('api_key', ''))),
                   model=os.environ.get('QWEN_ASR_MODEL', config.get('model', MODEL)),
                   region=os.environ.get('QWEN_ASR_REGION', config.get('region', 'cn-beijing')),
                   workspace_id=os.environ.get('QWEN_ASR_WORKSPACE_ID', config.get('workspace_id', '')))

    @property
    def configured(self):
        return bool(self._api_key.strip())

    def transcribe(self, path):
        if not self.configured:
            raise ModelError('ASR_NOT_CONFIGURED', '请在后端 asr-config.json 填写 Qwen ASR API Key')
        raw, duration_ms = read_wav(path)
        data_uri = 'data:audio/wav;base64,' + base64.b64encode(raw).decode('ascii')
        if len(data_uri) > MAX_ENCODED_BYTES:
            raise ModelError('ASR_AUDIO_TOO_LARGE', 'Base64 音频超过 10 MB')
        # Deliberately no reference text, context, hotwords, or speaker labels in the request.
        payload = {'model': self.model, 'input': {'messages': [{'role': 'user', 'content': [
            {'type': 'input_audio', 'input_audio': {'data': data_uri}}]}]},
            'parameters': {'format': 'wav', 'sample_rate': '16000', 'language_hints': ['zh']}}
        try:
            with httpx.Client(timeout=httpx.Timeout(120, connect=10), transport=self.transport,
                              follow_redirects=False) as client:
                r = client.post(self.endpoint, json=payload, headers={
                    'Authorization': 'Bearer ' + self._api_key, 'X-DashScope-SSE': 'disable'})
        except httpx.TimeoutException:
            raise ModelError('ASR_TIMEOUT', 'Qwen ASR 响应超时') from None
        except httpx.HTTPError:
            raise ModelError('ASR_UNAVAILABLE', '暂时无法连接 Qwen ASR') from None
        if r.status_code != 200:
            # Observed on unlabelled AISHELL gaps. This is not proof of silence:
            # preserve a failed recognition so speech misses cannot disappear from metrics.
            if r.status_code == 400:
                try:
                    error = r.json()
                except ValueError:
                    error = None
                if (isinstance(error, dict) and error.get('code') == 'CLIENT_ERROR'
                        and error.get('message') == 'ASR_RESPONSE_HAVE_NO_WORDS'):
                    raise ModelError('ASR_NO_WORDS', 'Qwen ASR 未识别到文字，请检查片段是否包含可辨识语音')
            code, message = {
                400: ('ASR_REQUEST_REJECTED', 'Qwen ASR 拒绝请求，请检查模型和音频格式'),
                401: ('ASR_AUTH_FAILED', 'Qwen ASR 密钥无效，请检查密钥和地域'),
                402: ('ASR_BALANCE_REQUIRED', 'Qwen ASR 账户余额不足'),
                403: ('ASR_ACCESS_DENIED', 'Qwen ASR 未授权，请检查业务空间和地域'),
                429: ('ASR_RATE_LIMITED', 'Qwen ASR 请求频率受限'),
            }.get(r.status_code, ('ASR_UNAVAILABLE', 'Qwen ASR 服务暂时不可用'))
            raise ModelError(code, message)
        try:
            body = r.json()
            if body.get('code'): raise ValueError('provider error')
            text = body['output']['text']
            sentence = body['output'].get('sentence')
            if sentence is not None:
                if not isinstance(sentence, dict) or sentence.get('sentence_end') is False:
                    raise ValueError('non-final output')
            if not isinstance(text, str) or len(text) > 20000: raise ValueError('invalid text')
        except (ValueError, KeyError, TypeError):
            raise ModelError('ASR_INVALID_OUTPUT', 'Qwen ASR 返回格式异常，未将其保存为转写') from None
        return {'text': text.strip(), 'duration_ms': duration_ms,
                'producer': 'qwen/' + self.model, 'speaker': 'unknown',
                'timing_source': 'audio_clip_bounds', 'region': self.region}
