import json
import math
import httpx
import pytest
from memory import Fault
from question_fallback import Qwen38QuestionJudge, hybrid_groups


def test_high_score_skips_llm_low_score_can_merge_or_start_group():
    calls = []
    def choose(text, candidates):
        calls.append((text, candidates))
        return '0' if text == 'c' else None
    vectors = [[1,0,0], [.99,.1,0], [.5,.86,0], [0,0,1]]
    groups, decisions = hybrid_groups(['a','b','c','d'], vectors, .85, choose)
    assert groups == [[0,1,2],[3]]
    assert [d['method'] for d in decisions] == ['new','embedding','llm','llm']
    assert len(calls) == 2
    assert calls[1][1][0]['questions'] == ['a','b','c'], 'Judge must see every distinct group member'
    assert decisions[2]['similarity'] < .85


def test_exact_duplicate_and_first_question_do_not_need_model():
    groups, decisions = hybrid_groups(['a','a'], [[1,0],[1,0]], .85,
        lambda *_: pytest.fail('No fallback for exact duplicates'))
    assert groups == [[0,1]]
    assert decisions[1]['method'] == 'exact'


def test_uses_group_mean_and_rejects_unknown_llm_choice():
    # a-b are close enough, but c only resembles b; average stays below gate.
    vectors = [[math.cos(a), math.sin(a)] for a in (0, .5, .9)]
    groups, decisions = hybrid_groups(['a','b','c'], vectors, .85, lambda *_: None)
    assert groups == [[0,1],[2]] and decisions[2]['method'] == 'llm'
    with pytest.raises(ValueError):
        hybrid_groups(['a','b'], [[1,0],[0,1]], .85, lambda *_: 'not-a-group')
    with pytest.raises(ValueError):
        hybrid_groups([], [], float('nan'), lambda *_: None)


def test_judge_payload_and_null_response(monkeypatch):
    monkeypatch.setenv('ANKER_AI_BASE_URL', 'https://ai-router-cn-pub.anker-in.com')
    monkeypatch.delenv('CANDID_QUESTION_FALLBACK_MODEL', raising=False)
    def handler(request):
        # Fallback rides the Anker OpenAI-compatible gateway, not DashScope directly.
        assert request.url.host == 'ai-router-cn-pub.anker-in.com'
        assert request.url.path == '/chat/completions'
        assert request.headers['authorization'] == 'Bearer test'
        payload = json.loads(request.content)
        assert payload['model'] == 'hackathon/v_model/qwen-max'
        assert payload['response_format'] == {'type':'json_object'}
        assert payload['enable_thinking'] is False
        assert '只输出 JSON' in payload['messages'][0]['content']
        return httpx.Response(200,json={'choices':[{'finish_reason':'stop','message':{'content':'{"group_id":null}'}}]})
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        assert Qwen38QuestionJudge(api_key='test',client=client).choose('价格？',[{'id':'0','questions':['交付？']}]) is None


@pytest.mark.parametrize('content,reason', [('{"group_id":"unknown"}','stop'),
    ('{"group_id":true}','stop'), ('{"group_id":"0"}','length'), ('not JSON','stop'),
    ('{"group_id":null,"extra":"untrusted"}','stop')])
def test_invalid_provider_decisions_are_not_accepted(content, reason):
    def handler(request):
        return httpx.Response(200,json={'choices':[{'finish_reason':reason,'message':{'content':content}}]})
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(Fault) as error:
            Qwen38QuestionJudge(api_key='test',client=client).choose('价格？',[{'id':'0','questions':['交付？']}])
    assert error.value.code == 'GROUPING_MODEL_FORMAT'
