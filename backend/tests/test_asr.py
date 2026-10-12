import base64
import json
from pathlib import Path
import sys
import wave

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from asr import QwenASR, MODEL, read_wav
from llm import ModelError


@pytest.fixture
def wav(tmp_path):
    path = tmp_path/'clip.wav'
    with wave.open(str(path), 'wb') as f:
        f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        f.writeframes(b'\0\0'*16000)
    return path


def test_native_payload_contains_audio_only(wav):
    def handler(request):
        assert request.url.path == '/api/v1/services/aigc/multimodal-generation/generation'
        assert request.headers['X-DashScope-SSE'] == 'disable'
        body = json.loads(request.content)
        assert body['model'] == MODEL
        assert body['parameters'] == {'format': 'wav', 'sample_rate': '16000', 'language_hints': ['zh']}
        messages = body['input']['messages']
        assert len(messages) == 1 and len(messages[0]['content']) == 1
        data = messages[0]['content'][0]['input_audio']['data']
        assert base64.b64decode(data.split(',', 1)[1]) == wav.read_bytes()
        assert 'context' not in body['input'] and 'vocabulary' not in body['parameters']
        return httpx.Response(200, json={'output': {'text': '本人原文。', 'sentence': {'sentence_end': True}}})
    model = QwenASR('test-secret', transport=httpx.MockTransport(handler))
    result = model.transcribe(wav)
    assert result['text'] == '本人原文。' and result['duration_ms'] == 1000
    assert result['speaker'] == 'unknown' and result['timing_source'] == 'audio_clip_bounds'


def test_missing_key_never_calls_provider(wav):
    def forbidden(r): raise AssertionError('Network called without a key')
    with pytest.raises(ModelError) as e:
        QwenASR(transport=httpx.MockTransport(forbidden)).transcribe(wav)
    assert e.value.code == 'ASR_NOT_CONFIGURED'


@pytest.mark.parametrize(('status', 'code'), [(401, 'ASR_AUTH_FAILED'), (402, 'ASR_BALANCE_REQUIRED'),
    (403, 'ASR_ACCESS_DENIED'), (429, 'ASR_RATE_LIMITED'), (500, 'ASR_UNAVAILABLE')])
def test_errors_are_redacted(wav, status, code):
    model = QwenASR('test-secret', transport=httpx.MockTransport(lambda r: httpx.Response(status, text='private key and audio')))
    with pytest.raises(ModelError) as e: model.transcribe(wav)
    assert e.value.code == code and 'private' not in e.value.message and 'secret' not in e.value.message


@pytest.mark.parametrize('body', [{}, {'output': {'text': None}}, {'output': {'text': 'partial', 'sentence': {'sentence_end': False}}},
                               {'code': 'ProviderFailure', 'output': {'text': 'untrusted'}}])
def test_malformed_or_partial_results_rejected(wav, body):
    model = QwenASR('test-secret', transport=httpx.MockTransport(lambda r: httpx.Response(200, json=body)))
    with pytest.raises(ModelError) as e: model.transcribe(wav)
    assert e.value.code == 'ASR_INVALID_OUTPUT'


def test_empty_silence_result_and_timeout(wav):
    model = QwenASR('test-secret', transport=httpx.MockTransport(lambda r: httpx.Response(200, json={'output': {'text': '', 'sentence': None}})))
    assert model.transcribe(wav)['text'] == ''
    def timeout(r): raise httpx.ReadTimeout('private details')
    model.transport = httpx.MockTransport(timeout)
    with pytest.raises(ModelError) as e: model.transcribe(wav)
    assert e.value.code == 'ASR_TIMEOUT'


@pytest.mark.parametrize(('body', 'expected'), [
    ({'code': 'CLIENT_ERROR', 'message': 'ASR_RESPONSE_HAVE_NO_WORDS'}, 'ASR_NO_WORDS'),
    ({'code': 'CLIENT_ERROR', 'message': 'private error'}, 'ASR_REQUEST_REJECTED'),
    ({'code': 'OTHER_ERROR', 'message': 'ASR_RESPONSE_HAVE_NO_WORDS'}, 'ASR_REQUEST_REJECTED'),
    ([], 'ASR_REQUEST_REJECTED'),
])
def test_no_words_is_a_distinct_failure_not_silent_success(wav, body, expected):
    model = QwenASR('test-secret', transport=httpx.MockTransport(
        lambda r: httpx.Response(400, json=body)))
    with pytest.raises(ModelError) as e:
        model.transcribe(wav)
    assert e.value.code == expected
    assert 'private' not in e.value.message and 'test-secret' not in e.value.message


def test_audio_validation(wav, tmp_path):
    raw, duration = read_wav(wav)
    assert duration == 1000
    wav.write_bytes(raw[:-10])
    with pytest.raises(ModelError) as e: read_wav(wav)
    assert e.value.code == 'ASR_AUDIO_INVALID'
    wav.write_bytes(b'x'*7_500_000)
    with pytest.raises(ModelError) as e: read_wav(wav)
    assert e.value.code == 'ASR_AUDIO_TOO_LARGE'
    with wave.open(str(wav), 'wb') as f:
        f.setparams((8, 2, 16000, 0, 'NONE', 'not compressed')); f.writeframes(b'\0'*16*100)
    with pytest.raises(ModelError): read_wav(wav)


def test_config_precedence_and_regional_endpoint(tmp_path, monkeypatch):
    (tmp_path/'asr-config.json').write_text(json.dumps({'api_key': 'file-secret', 'region': 'cn-beijing'}))
    monkeypatch.setenv('QWEN_ASR_API_KEY', '')
    monkeypatch.setenv('QWEN_ASR_REGION', 'ap-southeast-1')
    monkeypatch.setenv('QWEN_ASR_WORKSPACE_ID', 'workspace-123')
    provider = QwenASR.from_config(tmp_path)
    assert not provider.configured
    assert provider.endpoint.startswith('https://workspace-123.ap-southeast-1.maas.aliyuncs.com/')
    with pytest.raises(ValueError): QwenASR(model='qwen3-asr-flash')
    with pytest.raises(ValueError): QwenASR(workspace_id='evil.com/path')
    with pytest.raises(ValueError): QwenASR(region='unknown')
