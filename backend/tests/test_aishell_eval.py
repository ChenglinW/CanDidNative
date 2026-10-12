import json
from pathlib import Path
import sys

import httpx
import pytest

sf = pytest.importorskip('soundfile', reason='Install requirements-eval.txt for dataset tests')
pytest.importorskip('praatio')
import numpy as np
from praatio import textgrid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from aishell_eval import cer, prepare_suite, load_suite, run_suite, write_report, review_text
from asr import QwenASR
from llm import DeepSeek


@pytest.fixture
def suite(tmp_path):
    source = tmp_path/'source/test'
    (source/'wav').mkdir(parents=True); (source/'TextGrid').mkdir()
    signal = np.tile(np.arange(8, dtype='int16')*100, (16000*15, 1))
    sf.write(str(source/'wav/meeting.wav'), signal, 16000, subtype='PCM_16')
    grid = textgrid.Textgrid()
    grid.addTier(textgrid.IntervalTier('A', [(0, 4, '我负责这个项目的所有设计工作。'),
                 (6, 9, '我们一共访谈了二十家商店。'), (11, 13, '可能需要进一步核实项目结果。')], 0, 15))
    grid.addTier(textgrid.IntervalTier('B', [(2, 4, '我们一起讨论一下项目需求。')], 0, 15))
    grid.save(str(source/'TextGrid/meeting.TextGrid'), format='long_textgrid', includeBlankSpaces=True)
    output = tmp_path/'suite'
    prepare_suite(tmp_path/'source', output, limit=20, channel=3)
    return output/'manifest.json'


def test_prepare_uses_mic_channel_not_speaker_and_marks_overlap(suite):
    manifest = load_suite(suite)
    assert manifest['coverage']['overlap'] == 1
    assert manifest['coverage']['unlabelled_gap'] > 0
    for case in manifest['cases']:
        samples, rate = sf.read(str(suite.parent/case['audio']), dtype='int16')
        assert rate == 16000 and samples.ndim == 1 and np.all(samples == 300)
        if case['group'] in {'overlap', 'unlabelled_gap'}:
            assert not case['review_allowed'] and case['speaker'] is None
        if case['group'] == 'overlap': assert case['reference_text'] is None


def test_cer_normalization_and_empty_reference():
    assert cer('你好，世界！', '你好世界')['cer'] == 0
    assert cer('甲乙丙', '甲丁丙')['errors'] == 1
    assert cer('甲乙', '甲')['errors'] == 1
    assert cer('甲', '甲乙')['cer'] == 1
    assert cer('', '幻觉文本')['cer'] is None
    assert cer('十八万', '八十万')['cer'] > 0
    assert cer('１８万', '18万')['cer'] == 0


def test_dry_run_performs_no_network_and_has_no_fake_score(suite):
    def forbidden(r): raise AssertionError('Dry run must not call the provider')
    report = run_suite(suite, QwenASR('test', transport=httpx.MockTransport(forbidden)))
    assert report['summary']['transcribed'] == 0
    assert report['summary']['micro_cer_successful_clips'] is None
    assert not report['summary']['complete_asr_evaluation']


def test_live_mock_failures_are_counted_not_reported_as_zero_cer(suite):
    model = QwenASR('test', transport=httpx.MockTransport(lambda r: httpx.Response(401)))
    report = run_suite(suite, model, live=True)
    assert report['summary']['failed'] == len(report['cases'])
    assert report['summary']['micro_cer_successful_clips'] is None
    assert not report['summary']['complete_asr_evaluation']


def test_manifest_rejects_tampering_and_path_escape(suite, tmp_path):
    manifest = json.loads(suite.read_text())
    case = manifest['cases'][0]
    original = case['audio']
    case['audio'] = '../outside.wav'; suite.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match='escapes'): load_suite(suite)
    case['audio'] = original; suite.write_text(json.dumps(manifest))
    (suite.parent/original).write_bytes(b'changed')
    with pytest.raises(ValueError, match='checksum'): load_suite(suite)


def test_report_does_not_overwrite_previous_results(tmp_path):
    path = tmp_path/'report.json'
    write_report({'mode': 'dry_run'}, path)
    with pytest.raises(ValueError): write_report({'mode': 'live'}, path)
    assert json.loads(path.read_text())['mode'] == 'dry_run'


def review_response(request):
    body = json.loads(request.content)
    data = json.loads(body['messages'][1]['content'])
    assert len(data['segments']) == 1
    seg = data['segments'][0]
    citation = {'segment_id': seg['segment_id'], 'quote': seg['text']}
    result = {'diagnoses': [{'dimension': 'evidence', 'finding': '需要核实结果',
                           'suggestion': '保留原文限制并补充依据', 'citations': [citation]}],
              'asset_title': '待核实的原文', 'asset_citation': citation}
    return httpx.Response(200, json={'choices': [{'finish_reason': 'stop',
                          'message': {'content': json.dumps(result)}}]})


def test_asr_to_existing_review_pipeline_with_mock_providers(suite):
    asr = QwenASR('test', transport=httpx.MockTransport(lambda r: httpx.Response(200, json={
        'output': {'text': '我先核实需求，结果仍需验证。'}})))
    llm = DeepSeek('test', transport=httpx.MockTransport(review_response))
    report = run_suite(suite, asr, live=True, review_provider=llm)
    assert report['summary']['complete_asr_evaluation']
    for row in report['cases']:
        if row['group'] in {'overlap', 'unlabelled_gap'}:
            assert row['review']['status'] == 'not_requested_or_ineligible'
        else:
            review = row['review']
            assert review['status'] == 'evidence_checks_passed'
            assert all(a['status'] == 'draft' and a['trust'] == 'L2_inferred' for a in review['draft_assets'])


def test_five_scripted_cases_preserve_raw_quotes_and_require_human_confirmation():
    cases = json.loads((Path(__file__).resolve().parents[1]/'evaluation/scenarios.json').read_text())['cases']
    assert len(cases) == 5
    for case in cases:
        result = review_text(case['self_text'], DeepSeek('test', transport=httpx.MockTransport(review_response)), case['scenario'])
        assert result['draft_assets'][0]['body']['text'] == case['self_text']
        assert result['semantic_quality'] == 'requires_human_review'
