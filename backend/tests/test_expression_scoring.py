import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audio_metrics import compute_pvq, classify_pauses, analyze_wav, RATE
from expression_scoring import (
    RULE_VERSION, score_pace, score_filler, score_pause, score_pitch_pvq, score_duration,
    score_session, aggregate_axis_scores, detect_language, count_fillers, overall_grade,
)


def test_language_and_pace_endpoints():
    assert detect_language('中文面试自我介绍项目经验') == 'zh'
    assert detect_language('Tell me about a conflict at work') == 'en'
    assert detect_language('我负责 Python backend') == 'mixed'
    for value, expect in [(200, 4), (220, 4), (190, 3), (230, 3), (150, 2), (260, 2), (149, 1), (261, 1)]:
        assert score_pace(value, 'zh')['score'] == expect
    for value, expect in [(130, 4), (150, 4), (125, 3), (165, 3), (100, 2), (190, 2), (99, 1), (191, 1)]:
        assert score_pace(value, 'en')['score'] == expect
    assert score_pace(210, 'mixed')['status'] == 'unscored'
    assert score_pace(210, 'unknown')['status'] == 'unscored'


def test_filler_gaps_conflicts_and_semantic_skip():
    assert score_filler(2, 1)['score'] == 4
    assert score_filler(5, 3)['score'] == 3
    assert score_filler(5.5, 1)['score'] == 2  # product gap 5-6
    assert score_filler(10, 1)['score'] == 2   # product gap 9-12
    assert score_filler(12, 1)['score'] == 1
    assert score_filler(4, 7)['score'] == 1    # pct conflict → conservative
    assert 'product' in score_filler(5.5, 1)['rule_id'] or score_filler(5.5, 1)['score'] == 2
    assert score_filler(0, 0, transcript_zero=True)['measurement_quality'] == 'limited'
    assert count_fillers('然后我们推进方案落地', 'zh')[0] == 0
    assert count_fillers('嗯，呃，那个', 'zh')[0] >= 3


def test_pause_requires_boundary_samples_and_subscores():
    assert score_pause(0.6, 0.01, 0.2, boundary_samples=2)['status'] == 'unscored'
    assert score_pause(0.6, 0.01, 0.2, boundary_samples=3)['score'] == 4
    assert score_pause(0.3, 0.15, 2.5, boundary_samples=4)['score'] == 2
    assert score_pause(0.1, 0.25, 4, boundary_samples=4)['score'] == 1


def test_pvq_scale_must_be_verified_before_scoring():
    for value in (None, 0, 145, 175, 220, 260):
        cell=score_pitch_pvq(value, pitch_range_st=4)
        assert cell['score'] is None and cell['measurement_quality']=='uncalibrated'
        assert cell['raw']['pitch_range_st']==4
    assert compute_pvq([150, 170]*100) is None


def test_duration_targets_sales_inapplicable_and_followup_exempt():
    assert score_duration(30000, 30000, profile='interview_general')['score'] == 4
    assert score_duration(33000, 30000, profile='interview_general')['score'] == 3  # 10%
    assert score_duration(40000, 30000, profile='interview_general')['score'] == 1
    assert score_duration(30000, 30000, profile='sales_reference')['status'] == 'unscored'
    assert score_duration(90000, 30000, profile='interview_general', exempt=True)['status'] == 'unscored'


def test_unscored_is_not_zero_and_window_avoids_canceling_extremes():
    slow = score_session({
        'id': 's', 'scenario': 'interview', 'language': 'zh', 'text': '偏慢', 'words': 100,
        'self_ms': 60000, 'pace': 100, 'articulation_rate': 100, 'acoustic_ms': 50000, 'voiced_ms': 45000,
        'boundary_pause_samples': 4, 'boundary_pause_median_s': 0.6, 'non_boundary_pause_ratio': 0.02,
        'long_pause_rate': 0.2, 'pvq': 160, 'answer_ms': 30000, 'target_answer_ms': 30000,
    })
    fast = score_session({
        'id': 'f', 'scenario': 'interview', 'language': 'zh', 'text': '偏快', 'words': 100,
        'self_ms': 60000, 'pace': 280, 'articulation_rate': 280, 'acoustic_ms': 50000, 'voiced_ms': 45000,
        'boundary_pause_samples': 4, 'boundary_pause_median_s': 0.6, 'non_boundary_pause_ratio': 0.02,
        'long_pause_rate': 0.2, 'pvq': 160, 'answer_ms': 30000, 'target_answer_ms': 30000,
    })
    assert slow['axes']['pace']['score'] == 1 and fast['axes']['pace']['score'] == 1
    window = aggregate_axis_scores([slow, fast])
    assert window['axes']['pace']['score'] == 1
    assert score_pitch_pvq(None)['score'] is None
    assert RULE_VERSION.startswith('expression-scoring@')


def test_overall_deterministic_priority():
    def pack(scores):
        axes = ['pace', 'pause', 'filler', 'pitch', 'duration']
        return {axis: {'status': 'scored', 'score': scores[i]} for i, axis in enumerate(axes) if i < len(scores)}
    assert overall_grade(pack([4, 4, 4, 4, 3]))['score'] == 4
    assert overall_grade(pack([3, 3, 3, 2, 2]))['score'] == 3  # 3 green + 2 yellow
    assert overall_grade(pack([4, 4, 2, 2, 2]))['score'] == 2  # ≥2 yellow, not the 3+2 pattern
    assert overall_grade(pack([3, 3, 1, 3, 3]))['score'] == 1  # filler red
    assert overall_grade(pack([4, 4, 4, 4])) is None  # missing axis


def test_classify_pauses_boundary_vs_mid_clause(tmp_path):
    lines = [
        {'id': '1', 'speaker': 'other', 'start_ms': 0, 'end_ms': 1000, 'text': '请介绍？'},
        {'id': '2', 'speaker': 'self', 'start_ms': 2500, 'end_ms': 5000, 'text': '我负责交付。'},
        {'id': '3', 'speaker': 'self', 'start_ms': 5200, 'end_ms': 8000, 'text': '然后推进。'},
    ]
    # thinking pause 1s after question — exempt
    events = [
        {'start_ms': 1200, 'end_ms': 2400, 'duration_ms': 1200},
        {'start_ms': 5000, 'end_ms': 5200, 'duration_ms': 200},  # boundary-ish short
        {'start_ms': 6000, 'end_ms': 6400, 'duration_ms': 400},  # mid
        {'start_ms': 7000, 'end_ms': 8600, 'duration_ms': 1600},  # long
    ]
    metrics = classify_pauses(events, lines, acoustic_ms=60000)
    assert metrics['boundary_pause_samples'] >= 1 or metrics['non_boundary_pause_ratio'] is not None
    assert metrics['long_pause_rate'] is not None


def test_empty_transcript_and_missing_components_cannot_earn_scores():
    result=score_session({'id':'empty','text':'','self_ms':60000,'pace':210})
    assert result['axes']['filler']['score'] is None
    assert result['axes']['pace']['score'] is None
    assert score_pace(None,'zh',pace=210)['score'] is None
    assert score_filler(0,None)['score'] is None
    assert score_pause(.6,None,0,boundary_samples=3)['score'] is None
    assert count_fillers('I like this design and actually delivered it', 'en')[0]==0
    assert count_fillers('那个 backend', 'mixed')[0]==0


def test_thinking_exemption_never_hides_a_pause_after_answer_started():
    lines=[{'speaker':'other','start_ms':0,'end_ms':1000,'text':'问题？'},
           {'speaker':'self','start_ms':2500,'end_ms':7000,'text':'回答。'},
           {'speaker':'self','start_ms':7600,'end_ms':9000,'text':'继续。'}]
    events=[{'start_ms':1200,'end_ms':2400,'duration_ms':1200},
            {'start_ms':3000,'end_ms':3400,'duration_ms':400},
            {'start_ms':7000,'end_ms':7600,'duration_ms':600}]
    result=classify_pauses(events,lines,60000)
    assert result['boundary_pause_samples']==1
    assert result['boundary_pause_median_s']==.6
    assert result['non_boundary_pause_ratio']==.5


def test_answer_duration_does_not_combine_answers_or_guess_prefixes():
    from memory_library import Library
    lib=Library.__new__(Library)
    lines=[{'id':'a','speaker':'self','start_ms':1000,'end_ms':3000},
           {'id':'b','speaker':'self','start_ms':4000,'end_ms':6000}]
    qa={'status':'answered','segment_ids':['a','b']}
    session={'transcript_revision':2,'session_qa_revision':2,'target_answer_ms':5000,'session_qa':[qa]}
    assert lib._answer_duration(session,lines)==(5000,5000,False)
    assert lib._answer_duration({**session,'session_qa':[qa,qa] },lines)[0] is None
    assert lib._answer_duration({**session,'session_qa_revision':1},lines)[0] is None
    assert lib._answer_duration({**session,'session_qa':[dict(qa,segment_ids=[''])]},lines)[0] is None
    interrupted=lines+[{'id':'o','speaker':'other','start_ms':3200,'end_ms':3800}]
    assert lib._answer_duration(session,interrupted)[0] is None


def test_aggregate_lower_median_matches_client_and_excludes_old_rules():
    def session(score,version=RULE_VERSION):
        return {'rule_version':version,'axes':{'pace':{'score':score,'status':'scored'}}}
    assert aggregate_axis_scores([session(1),session(3)])['axes']['pace']['score']==1
    assert aggregate_axis_scores([session(2),session(4)])['axes']['pace']['score']==2
    assert aggregate_axis_scores([session(4,'old')])['axes']['pace']['score'] is None
