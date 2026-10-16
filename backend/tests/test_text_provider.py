import json
import sys
from pathlib import Path
import httpx
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_runtime.providers import Gateway
from memory import Fault


@pytest.mark.parametrize('provider', ['anker', 'dashscope'])
@pytest.mark.parametrize('stream', [False, True])
def test_provider_wire_keeps_messages_and_tool_schema(monkeypatch, provider, stream):
    monkeypatch.setenv('CANDID_TEXT_PROVIDER', provider)
    monkeypatch.setenv('ANKER_AI_API_KEY', 'anker-test')
    monkeypatch.setenv('DASHSCOPE_API_KEY', 'dashscope-test')
    monkeypatch.setenv('DASHSCOPE_TEXT_MODEL', 'deepseek-v4-pro')
    monkeypatch.delenv('DASHSCOPE_TEXT_BASE_URL', raising=False)
    gateway = Gateway()
    messages = [{'role':'system','content':'Existing prompt'}, {'role':'user','content':'Existing data'}]
    schemas = [{'type':'function','function':{'name':'lookup','parameters':{'type':'object','properties':{}}}}]
    def handle(request):
        payload = json.loads(request.content)
        assert request.headers['authorization'] == 'Bearer '+provider+'-test'
        assert payload['messages'] == messages and payload['tools'] == schemas
        assert payload['tool_choice'] == 'auto' and payload['max_tokens'] == 4096
        if provider == 'dashscope':
            assert request.url == 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions'
            assert payload['model'] == 'deepseek-v4-pro' and payload['enable_thinking'] is False
            assert 'thinking' not in payload
        else:
            assert payload['thinking'] == {'type':'disabled'} and 'enable_thinking' not in payload
        if stream:
            assert payload['stream'] is True
            chunk = {'choices':[{'index':0,'delta':{'content':'OK'},'finish_reason':'stop'}]}
            return httpx.Response(200, headers={'content-type':'text/event-stream'},
                                  text='data: '+json.dumps(chunk)+'\n\ndata: [DONE]\n\n')
        return httpx.Response(200,json={'choices':[{'finish_reason':'stop','message':{'content':'OK'}}]})
    original = httpx.Client
    monkeypatch.setattr('agent_runtime.providers.httpx.Client',
                        lambda **kw: original(transport=httpx.MockTransport(handle), **kw))
    chunks = []
    result = gateway.complete(messages, schemas=schemas, on_delta=chunks.append if stream else None)
    assert result['content'] == 'OK'
    if stream: assert ''.join(chunks) == 'OK'


def test_dashscope_does_not_fall_back_to_anker_key(monkeypatch):
    monkeypatch.setenv('CANDID_TEXT_PROVIDER', 'dashscope')
    monkeypatch.setenv('ANKER_AI_API_KEY', 'anker-test')
    monkeypatch.delenv('DASHSCOPE_API_KEY', raising=False)
    gateway = Gateway()
    assert not gateway.configured
    with pytest.raises(Fault) as error:
        gateway.complete([], tools=False)
    assert error.value.code == 'AGENT_NOT_CONFIGURED'


def test_dashscope_defaults_to_confirmed_deepseek_model(monkeypatch):
    monkeypatch.setenv('CANDID_TEXT_PROVIDER', 'dashscope')
    monkeypatch.delenv('DASHSCOPE_TEXT_MODEL', raising=False)
    assert Gateway().model == 'deepseek-v4-pro'


def test_unknown_provider_fails_at_startup(monkeypatch):
    monkeypatch.setenv('CANDID_TEXT_PROVIDER', 'typo')
    with pytest.raises(ValueError): Gateway()
