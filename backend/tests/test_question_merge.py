import json
import math
import httpx
import numpy as np
import pytest
from memory import Fault
from question_grouping import average_groups
from question_merge import candidate_average_groups, Qwen38MergeJudge


def test_zero_width_exactly_matches_baseline():
    rng = np.random.default_rng(712)
    for n in [0,1,3,20,80]:
        vectors = rng.normal(size=(n,8)).tolist()
        got,_ = candidate_average_groups(list(map(str,range(n))),vectors)
        assert got == average_groups(vectors)


def test_group_judge_can_merge_two_existing_groups_and_sees_all_members():
    angles = [0,.02,.78,.80]
    vectors = [[math.cos(a),math.sin(a)] for a in angles]
    calls = []
    def judge(a,b):
        calls.append((a,b))
        return True
    groups, _ = candidate_average_groups(['a','b','c','d'],vectors,threshold=.75,width=.08,judge=judge)
    assert groups == [[0,1,2,3]]
    assert calls == [(['a','b'],['c','d'])]


def test_rejection_is_reused_and_invalid_decisions_fail():
    vectors = [[math.cos(a),math.sin(a)] for a in [0,.02,.78,.80]]
    calls = []
    groups,_ = candidate_average_groups(['a','b','c','d'],vectors,threshold=.75,width=.08,
        judge=lambda a,b:calls.append((a,b)) or False)
    assert groups == [[0,1],[2,3]] and len(calls)==1
    with pytest.raises(ValueError):
        candidate_average_groups(['a','b'],[[1,0],[.7,.714]],width=.08,judge=lambda *_:'true')


@pytest.mark.parametrize('content,valid', [('{"merge":true}',True),('{"merge":false}',True),
    ('{"merge":"true"}',False),('{"merge":1}',False),('{"merge":null}',False),
    ('{"merge":true,"reason":"x"}',False)])
def test_merge_api_strict_schema_and_complete_groups(content,valid):
    def handler(request):
        payload=json.loads(request.content)
        assert json.loads(payload['messages'][1]['content']) == {'group_a':['a','b'],'group_b':['c','d']}
        return httpx.Response(200,json={'choices':[{'finish_reason':'stop','message':{'content':content}}]})
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        judge=Qwen38MergeJudge(api_key='test',client=client)
        if valid:
            assert judge.merge(['a','b'],['c','d']) is json.loads(content)['merge']
        else:
            with pytest.raises(Fault):judge.merge(['a','b'],['c','d'])
