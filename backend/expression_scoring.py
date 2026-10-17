"""Versioned delivery reference scoring. Rules from docs/EXPRESSION_SCORING_RULES_v1.md."""
from __future__ import annotations

import math
import re
from statistics import median

RULE_VERSION = 'expression-scoring@1.0.1'
AXES = ('pace', 'pause', 'filler', 'pitch', 'duration')
AXIS_LABELS = {'pace': '语速', 'pause': '停顿', 'filler': '口头禅', 'pitch': '起伏', 'duration': '时长控制'}
LABELS = {4: '强', 3: '有效', 2: '待改进', 1: '需优先改进'}
COLORS = {4: 'green', 3: 'green', 2: 'yellow', 1: 'red'}

STRICT_FILLERS = [r'嗯+', r'呃+', r'\bum+\b', r'\buh+\b']
WEAK_FILLERS_ZH = ['那个', '就是', '然后', '所以说', '你知道', '就是说']
WEAK_FILLERS_EN = [r'\blike\b', r'\byou know\b', r'\bbasically\b', r'\bactually\b']


def _finite(value, lo=None, hi=None):
    if value is None or isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    if not math.isfinite(value):
        return None
    if lo is not None and value < lo:
        return None
    if hi is not None and value > hi:
        return None
    return value


def detect_language(text: str) -> str:
    if not text or not text.strip():
        return 'unknown'
    zh = len(re.findall(r'[\u3400-\u9fff]', text))
    en = len(re.findall(r'[A-Za-z]+', text))
    total = zh + en
    if total == 0:
        return 'unknown'
    if zh / total >= 0.85:
        return 'zh'
    if en / total >= 0.85:
        return 'en'
    if zh and en:
        return 'mixed'
    return 'zh' if zh else 'en'


def tokenize_units(text: str) -> list[str]:
    return re.findall(r'[\u3400-\u9fff]|[A-Za-z]+(?:\'[A-Za-z]+)?|\d+', text or '')


def count_fillers(text: str, language: str) -> tuple[int, dict]:
    """Return scored filler count and debug breakdown. Semantic connectors are conservatively filtered."""
    text = text or ''
    strict = 0
    for pattern in STRICT_FILLERS:
        strict += len(re.findall(pattern, text, re.I))
    weak = 0
    notes = []
    # Weak Chinese: count only when repeated or appearing as isolated hesitation (surrounded by punctuation/space/start).
    if language == 'zh':
        for word in WEAK_FILLERS_ZH:
            for match in re.finditer(re.escape(word), text):
                start, end = match.span()
                left = text[max(0, start - 1):start]
                right = text[end:end + 2]
                isolated = (start == 0 or left in '，。！？、；,.!?; \n\t') and (
                    end == len(text) or right[:1] in '，。！？、；,.!?; \n\t嗯呃')
                repeated = text[end:end + len(word)] == word
                # Skip if followed by a content character (noun-like continuation).
                content_follow = bool(re.match(r'[\u3400-\u9fffA-Za-z]', right[:1] or ''))
                if isolated or repeated:
                    if word in {'然后', '就是'} and content_follow and not repeated:
                        notes.append(f'skip_semantic:{word}')
                        continue
                    weak += 1
                elif not content_follow:
                    weak += 1
    if language in {'en', 'mixed', 'unknown'}:
        # "I like this" / "actually delivered" are not verified hesitations.
        # Weak English markers need semantic disambiguation before scoring.
        notes.append('english_semantic_markers_not_scored')
    return strict + weak, {'strict': strict, 'weak': weak, 'notes': notes[:8]}


def unscored(axis, reason, *, evidence_grade, measurement_quality, raw=None, target=None, suggestion=None, sources=None):
    return {
        'score': None, 'status': 'unscored', 'label': reason, 'color': 'neutral',
        'raw': raw, 'target': target, 'rule_id': f'{axis}.unscored',
        'explanation': reason, 'suggestion': suggestion or '先补齐可测量数据后再看参考评分。',
        'evidence_grade': evidence_grade, 'measurement_quality': measurement_quality,
        'sources': sources or [], 'rule_version': RULE_VERSION,
    }


def scored(axis, score, *, raw, target, rule_id, explanation, suggestion, evidence_grade, measurement_quality, sources=None):
    score = int(score)
    return {
        'score': score, 'status': 'scored', 'label': LABELS[score], 'color': COLORS[score],
        'raw': raw, 'target': target, 'rule_id': rule_id, 'explanation': explanation,
        'suggestion': suggestion, 'evidence_grade': evidence_grade,
        'measurement_quality': measurement_quality, 'sources': sources or [],
        'rule_version': RULE_VERSION,
    }


def score_pace(articulation_rate, language, *, pace=None, content_type='unknown', sources=None):
    rate = _finite(articulation_rate, lo=0) 
    quality = 'ready'
    metric = 'articulation_rate'
    if rate is None:
        rate = _finite(pace, lo=0)
        return unscored('pace', '发音速率尚未可靠测量，整体语速仅供参考',
                        evidence_grade='C', measurement_quality='insufficient',
                        raw={'value': rate, 'unit': '字词/分钟', 'metric': 'pace'}, sources=sources)
    if rate is None:
        return unscored('pace', '无法计算语速', evidence_grade='C', measurement_quality='insufficient', sources=sources)
    if language in {'mixed', 'unknown'}:
        return unscored('pace', '语言不明确或中英混说，不能套用单一语速阈值', evidence_grade='C',
                        measurement_quality='inapplicable',
                        raw={'value': rate, 'unit': '字词/分钟', 'metric': metric},
                        target='请先区分中文或英文后再评分', sources=sources)
    unit = '字/分钟' if language == 'zh' else 'WPM'
    if language == 'zh':
        bands = [
            (4, lambda x: 200 <= x <= 220, 'pace.zh.4', '200–220 字/分钟（中文参考中心）'),
            (3, lambda x: 190 <= x < 200 or 220 < x <= 230, 'pace.zh.3', '190–230 字/分钟（绿区边缘）'),
            (2, lambda x: 150 <= x < 190 or 230 < x <= 260, 'pace.zh.2', '150–190 或 230–260'),
            (1, lambda x: x < 150 or x > 260, 'pace.zh.1', '<150 或 >260'),
        ]
        target = '200–220 字/分钟（中文参考）'
    else:
        bands = [
            (4, lambda x: 130 <= x <= 150, 'pace.en.4', '130–150 WPM（英文专业目标）'),
            (3, lambda x: 125 <= x < 130 or 150 < x <= 165, 'pace.en.3', '125–165 WPM'),
            (2, lambda x: 100 <= x < 125 or 165 < x <= 190, 'pace.en.2', '100–125 或 165–190 WPM'),
            (1, lambda x: x < 100 or x > 190, 'pace.en.1', '<100 或 >190 WPM'),
        ]
        target = '130–150 WPM（英文参考）'
    for score, pred, rule_id, band in bands:
        if pred(rate):
            tip = {
                4: '当前发音语速落在参考中心，可保持为个人模板。',
                3: '接近参考区间边缘，可按内容类型微调快慢。',
                2: '本次发音语速偏离参考区间，建议在核心观点处放慢或减少拖沓。' if rate < 200 else '本次发音语速高于参考区间，建议在核心观点处放慢。',
                1: '语速明显过慢或过快，建议先按题型设定目标区间并分段练习。',
            }[score]
            note = '' if content_type != 'unknown' else '；内容类型未识别，未做题型加减分'
            return scored('pace', score, raw={'value': round(rate, 1), 'unit': unit, 'metric': metric},
                          target=target, rule_id=rule_id,
                          explanation=f'发音速率约 {rate:.1f} {unit}，命中{band}{note}',
                          suggestion=tip, evidence_grade='C', measurement_quality=quality, sources=sources)
    return unscored('pace', '语速未落入已定义区间', evidence_grade='C', measurement_quality=quality, sources=sources)


def score_filler(rate_per_min, pct, *, transcript_zero=False, sources=None):
    rate = _finite(rate_per_min, lo=0)
    pct = _finite(pct, lo=0, hi=100)
    if rate is None or pct is None:
        return unscored('filler', '无法测量口头禅', evidence_grade='A', measurement_quality='insufficient', sources=sources)

    def one(metric_name, value, kind):
        if value is None:
            return None
        if kind == 'rate':
            if value <= 2:
                return 4, 'filler.rate.4'
            if value <= 5:
                return 3, 'filler.rate.3'
            if value < 12:  # product continuous gap (5,12)
                return 2, 'filler.rate.2_product'
            return 1, 'filler.rate.1'
        if value <= 1:
            return 4, 'filler.pct.4'
        if value <= 3:
            return 3, 'filler.pct.3'
        if value <= 6:  # includes product treatment of 3–6
            return 2, 'filler.pct.2'
        return 1, 'filler.pct.1'

    parts = [one('rate', rate, 'rate'), one('pct', pct, 'pct')]
    parts = [p for p in parts if p]
    score = min(p[0] for p in parts)
    rule_id = '+'.join(p[1] for p in parts)
    quality = 'limited' if transcript_zero else 'ready'
    zero_note = '转写未检出填充词，但不能证明录音中没有口头禅。' if transcript_zero else ''
    tip = {
        4: '填充词很少，保持自然即可。',
        3: '填充词仍在可接受软阈值内，可留意句首犹豫。',
        2: '填充词已可察觉，建议把“嗯/呃”换成短停顿，并减少无实义的“那个/就是”。',
        1: '填充词偏多，优先在回答开头用 0.5 秒边界停顿代替口头禅。',
    }[score]
    return scored('filler', score,
                  raw={'rate_per_min': None if rate is None else round(rate, 2),
                       'percent': None if pct is None else round(pct, 2), 'unit': '次/分钟 与 %'},
                  target='≤5 次/分钟且≤3%（绿区）；理想≤2 次/分钟且≤1%',
                  rule_id=rule_id,
                  explanation=f'次数率 {rate if rate is not None else "—"} 次/分钟，占比 {pct if pct is not None else "—"}%。取更保守子分。{zero_note}',
                  suggestion=tip, evidence_grade='A', measurement_quality=quality, sources=sources)


def _pause_subscore_boundary(median_s):
    m = _finite(median_s, lo=0)
    if m is None:
        return None
    if 0.5 <= m <= 0.7:
        return 4
    if 0.4 <= m <= 0.8:
        return 3
    if 0.2 <= m < 0.4 or 0.8 < m <= 1.2:
        return 2
    return 1


def _pause_subscore_non_boundary(ratio):
    r = _finite(ratio, lo=0, hi=1)
    if r is None:
        return None
    pct = r * 100
    if pct < 5:
        return 4
    if pct < 10:
        return 3
    if pct <= 20:
        return 2
    return 1


def _pause_subscore_long(rate):
    r = _finite(rate, lo=0)
    if r is None:
        return None
    if r <= 1:
        return 4
    if r < 2:  # product: (1, 2) treated as green edge
        return 3
    if r <= 3:
        return 2
    return 1


def score_pause(boundary_median_s, non_boundary_ratio, long_pause_per_min, *, boundary_samples, sources=None):
    if (boundary_samples or 0) < 3:
        return unscored('pause', '边界停顿样本不足，不能因未观察到异常而给满分',
                        evidence_grade='B', measurement_quality='insufficient',
                        raw={'boundary_samples': boundary_samples or 0},
                        target='边界 0.5–0.7 秒；非边界<5%；长停顿≤1 次/分钟', sources=sources)
    subs = [
        ('boundary', _pause_subscore_boundary(boundary_median_s)),
        ('non_boundary', _pause_subscore_non_boundary(non_boundary_ratio)),
        ('long', _pause_subscore_long(long_pause_per_min)),
    ]
    available = [(name, value) for name, value in subs if value is not None]
    if len(available) != 3:
        return unscored('pause', '停顿子指标不足', evidence_grade='B', measurement_quality='insufficient', sources=sources)
    score = min(value for _, value in available)
    tip = {
        4: '边界停顿较自然，可保持。',
        3: '停顿大体有效，可把句中犹豫挪到意群边界。',
        2: '句中停顿或长短停顿偏多，建议在标点/意群处停 0.5–0.7 秒，减少句中卡顿。',
        1: '非边界或长停顿干扰节奏，优先练习完整意群后再换气。',
    }[score]
    return scored('pause', score,
                  raw={'boundary_median_s': boundary_median_s, 'non_boundary_ratio': non_boundary_ratio,
                       'long_pause_per_min': long_pause_per_min, 'boundary_samples': boundary_samples},
                  target='边界 0.5–0.7 秒；非边界<5%；长停顿≤1 次/分钟',
                  rule_id='pause.min_subscore',
                  explanation='按边界中位、非边界占比、长停顿三项取最低分。答题前 0–3 秒思考已豁免。',
                  suggestion=tip, evidence_grade='B', measurement_quality='ready', sources=sources)


def score_pitch_pvq(pvq, *, pitch_range_st=None, sources=None):
    return unscored('pitch', '音高指标与评分标准的量纲尚未校准，暂不评分',
                    evidence_grade='D', measurement_quality='uncalibrated',
                    raw={'pitch_range_st': pitch_range_st, 'pvq': None},
                    target='保留真实半音跨度，待核实评分量纲',
                    suggestion='可回听重点词的音调变化；暂不根据未校准指标判断好坏。', sources=sources)


def score_duration(actual_ms, target_ms, *, profile, exempt=False, sources=None):
    if profile == 'sales_reference':
        return unscored('duration', '销售沟通不套用面试/路演单题时长规则',
                        evidence_grade='E', measurement_quality='inapplicable',
                        target='可在面试场景或设置目标时长后评分', sources=sources)
    if exempt:
        return unscored('duration', '因追问/澄清延长，本场时长豁免',
                        evidence_grade='E', measurement_quality='inapplicable', sources=sources)
    actual = _finite(actual_ms, lo=0)
    target = _finite(target_ms, lo=1)
    if actual is None or target is None:
        return unscored('duration', '未设置题型或无法识别单次回答边界',
                        evidence_grade='E', measurement_quality='inapplicable',
                        target='事实约30秒；介绍60–90秒；行为约120秒', sources=sources)
    deviation = abs(actual - target) / target
    if deviation <= 0.08:
        score, rule = 4, 'duration.dev.4_product'
    elif deviation <= 0.15:
        score, rule = 3, 'duration.dev.3'
    elif deviation <= 0.30:
        score, rule = 2, 'duration.dev.2'
    else:
        score, rule = 1, 'duration.dev.1'
    tip = {
        4: '单次回答时长贴近目标，可保持结构。',
        3: '时长基本合适，收尾可更干脆。',
        2: f'相对目标偏差约 {deviation:.0%}，建议先答结论再补一例。',
        1: f'相对目标偏差约 {deviation:.0%}，请按题型重设结构并控制在目标附近。',
    }[score]
    return scored('duration', score,
                  raw={'actual_ms': actual, 'target_ms': target, 'deviation': round(deviation, 3)},
                  target=f'目标约 {target/1000:.0f} 秒（偏差≤15% 为绿区）',
                  rule_id=rule, explanation=f'实际 {actual/1000:.1f}s，目标 {target/1000:.0f}s。',
                  suggestion=tip, evidence_grade='E', measurement_quality='ready', sources=sources)


def overall_grade(axes: dict):
    scores = []
    for key in AXES:
        item = axes.get(key) or {}
        if item.get('status') == 'scored' and item.get('score') in {1, 2, 3, 4}:
            scores.append((key, item['score']))
    if len(scores) < 5:
        return None
    values = [s for _, s in scores]
    red = sum(1 for s in values if s == 1)
    yellow = sum(1 for s in values if s == 2)
    green = sum(1 for s in values if s >= 3)
    filler = next(s for k, s in scores if k == 'filler')
    duration = next(s for k, s in scores if k == 'duration')
    # Priority: risk → strong → effective → improve (covers remaining / doc gaps).
    if red >= 2 or filler == 1 or duration == 1:
        level = 1
    elif green >= 4 and yellow <= 1 and red == 0:
        level = 4
    elif green == 3 and yellow == 2 and red == 0:
        level = 3
    elif yellow >= 2 or red == 1:
        level = 2
    else:
        level = 2
    return {'score': level, 'label': LABELS[level], 'color': COLORS[level],
            'rule_id': 'overall.table_v1', 'explanation': '仅在五轴均有参考分时给出；不预测录用或成交。'}


def profile_for_scenario(scenario: str) -> str:
    return 'interview_general' if scenario == 'interview' else 'sales_reference'


def score_session(row: dict) -> dict:
    text = row.get('text') or ''
    language = row.get('language') or detect_language(text)
    profile = profile_for_scenario(row.get('scenario') or 'sales')
    sources = row.get('sources') or [{'session_id': row.get('id')}]
    units = tokenize_units(text)
    fillers, filler_debug = count_fillers(text, language)
    spoken_ms = _finite(row.get('acoustic_ms'), lo=1) or _finite(row.get('self_ms'), lo=1)
    rate = (fillers * 60000 / spoken_ms) if spoken_ms else None
    pct = (fillers * 100 / len(units)) if units else None
    artic = _finite(row.get('articulation_rate'), lo=0)
    if artic is None and _finite(row.get('voiced_ms'), lo=1) and row.get('words'):
        artic = row['words'] * 60000 / row['voiced_ms']
    axes = {
        'pace': score_pace(artic, language, pace=row.get('pace'), content_type=row.get('content_type', 'unknown'), sources=sources),
        'pause': score_pause(row.get('boundary_pause_median_s'), row.get('non_boundary_pause_ratio'),
                             row.get('long_pause_rate'), boundary_samples=row.get('boundary_pause_samples') or 0,
                             sources=sources),
        'filler': score_filler(rate, pct, transcript_zero=(fillers == 0 and bool(text.strip())), sources=sources),
        'pitch': score_pitch_pvq(row.get('pvq'), pitch_range_st=row.get('pitch_range_st'), sources=sources),
        'duration': score_duration(row.get('answer_ms'), row.get('target_answer_ms'),
                                   profile=profile, exempt=bool(row.get('duration_exempt')), sources=sources),
    }
    # Attach filler debug without breaking schema consumers.
    axes['filler']['debug'] = filler_debug
    if not units or not _finite(row.get('self_ms'), lo=1000):
        for axis in ('pace', 'filler'):
            axes[axis] = unscored(axis, '本人有效文本或时长不足', evidence_grade='C' if axis == 'pace' else 'A',
                                  measurement_quality='insufficient', sources=sources)
    return {
        'rule_version': RULE_VERSION,
        'profile': profile,
        'language': language,
        'overall': overall_grade(axes),
        'axes': axes,
        'note': '参考评分，来自研究稿 v1.0；不是校准科学定论，不预测结果。',
    }


def aggregate_axis_scores(session_scores: list[dict]) -> dict:
    """Median of per-session scores; unscored excluded; never average raw metrics first."""
    out = {'rule_version': RULE_VERSION, 'axes': {}, 'session_count': len(session_scores)}
    session_scores = [s for s in session_scores if s.get('rule_version') == RULE_VERSION]
    for axis in AXES:
        values, covered = [], 0
        for item in session_scores:
            cell = (item.get('axes') or {}).get(axis) or {}
            if cell.get('status') == 'scored' and cell.get('score') in {1, 2, 3, 4}:
                values.append(cell['score']); covered += 1
        if not values:
            out['axes'][axis] = unscored(axis, '该窗口无有效参考分', evidence_grade='—',
                                         measurement_quality='insufficient')
            out['axes'][axis]['coverage'] = 0
            continue
        score = sorted(values)[(len(values) - 1) // 2]
        cell = scored(axis, score, raw={'median_of_session_scores': values},
                      target='逐场评分后取中位数', rule_id=f'{axis}.window_median',
                      explanation=f'有效 {covered}/{len(session_scores)} 场，场次分 {values}，中位数 {score}',
                      suggestion='查看逐场记录定位偏弱场次。', evidence_grade='—',
                      measurement_quality='ready')
        cell['coverage'] = covered
        out['axes'][axis] = cell
    out['overall'] = overall_grade(out['axes'])
    return out
