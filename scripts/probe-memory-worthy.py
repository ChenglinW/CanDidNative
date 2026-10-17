"""Live probe: how the current library_extract prompt labels memory_worthy.

Isolated synthetic transcript only. Does not write production DB.
Run: backend/.venv/bin/python scripts/probe-memory-worthy.py --live
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))

ENV_KEYS = {
    'CANDID_TEXT_PROVIDER', 'DASHSCOPE_TEXT_BASE_URL', 'DASHSCOPE_TEXT_MODEL',
    'DASHSCOPE_API_KEY', 'ANKER_AI_API_KEY', 'ANKER_AI_BASE_URL', 'ANKER_AI_MODEL',
}


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text('utf8').splitlines():
        if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        if key in ENV_KEYS:
            os.environ.setdefault(key, value)


PROMPT = (
    '从沟通原文提取本场关键问答，并判断哪些说法值得进入长期记忆库。'
    '只返回 {"session_qa":[{"question":"问题","answer":"对应回答原文摘要，未答则空","status":"answered或pending","segment_ids":["短id"],"reason":"保留原因"}],'
    '"items":[{"question":"问题","answer":"建议说法，不能编报价、承诺或经历","topic":"主题","segment_ids":["短id"],'
    '"state":"improve或reusable","used_text":"原文实际说法","outcome":"unknown或positive或questioned",'
    '"reason":"有具体原文依据的效果说明","document_id":"短资料id或空","document_quote":"资料逐字原文或空",'
    '"general_method":false,"memory_worthy":true}]}。'
    'session_qa只保留涉及需求、异议、价格、决策、承诺和后续行动的实质问答；过滤寒暄、口头确认和无新增信息的重复句；'
    '同一问题的连续追问合并为一条；有价值但未回答的标pending。最多16条。'
    'items仅当说法对以后多场仍有复用价值时设memory_worthy=true；一次性客户细节不得进入items。最多12条。'
    '普通追问不代表失败，只有明确理解/行动才positive。未知说话人不写成用户经历。原文不足则数组为空。'
    '只有可抽象为提问、澄清、确认下一步等通用方法时general_method=true，客户事实不是通用方法。'
    'segment_ids与document_id必须使用输入中的短id。'
)

# Human rubric for this probe only — not product truth.
CASES = [
    {
        'id': 's1', 'start_ms': 0, 'end_ms': 3000, 'speaker': 'other',
        'text': '你们常规交付周期一般多久？',
        'expect': 'reusable_process',
    },
    {
        'id': 's2', 'start_ms': 3000, 'end_ms': 8000, 'speaker': 'self',
        'text': '常规交付三到四周，具体以合同和排期为准，我先确认范围再给准确时间。',
        'expect': 'reusable_process',
    },
    {
        'id': 's3', 'start_ms': 8000, 'end_ms': 11000, 'speaker': 'other',
        'text': '现在有什么优惠政策吗？',
        'expect': 'reusable_policy_shape',
    },
    {
        'id': 's4', 'start_ms': 11000, 'end_ms': 16000, 'speaker': 'self',
        'text': '优惠政策要以书面报价为准，我先确认你们的门店数量和试点范围，再整理适用政策。',
        'expect': 'reusable_policy_shape',
    },
    {
        'id': 's5', 'start_ms': 16000, 'end_ms': 19000, 'speaker': 'other',
        'text': '对吗？',
        'expect': 'verbal_confirm_filter',
    },
    {
        'id': 's6', 'start_ms': 19000, 'end_ms': 22000, 'speaker': 'self',
        'text': '对，先确认范围。',
        'expect': 'verbal_confirm_filter',
    },
    {
        'id': 's7', 'start_ms': 22000, 'end_ms': 27000, 'speaker': 'other',
        'text': '我们华味餐饮只有三家店，预算卡在八十万，王总下周三要去上海，那天不方便。',
        'expect': 'one_off_customer_detail',
    },
    {
        'id': 's8', 'start_ms': 27000, 'end_ms': 30000, 'speaker': 'self',
        'text': '好的，我记下三家店、八十万预算，以及下周三避开上海行程。',
        'expect': 'one_off_customer_detail',
    },
    {
        'id': 's9', 'start_ms': 30000, 'end_ms': 33000, 'speaker': 'other',
        'text': '如果实施范围变大，价格怎么谈？',
        'expect': 'reusable_negotiation',
    },
    {
        'id': 's10', 'start_ms': 33000, 'end_ms': 38000, 'speaker': 'self',
        'text': '范围变大时先拆必做和可选项，再按书面报价调整，不口头承诺数字。',
        'expect': 'reusable_negotiation',
    },
]

TOPICS = [
    '产品与方案', '价格与政策', '需求与场景', '异议与比较', '交付与服务',
    '故事与案例', '车型与配置', '价格与保值', '金融与分期', '置换', '交付与售后', '用车场景', '其他',
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Permit one billable model call')
    args = parser.parse_args()
    if not args.live:
        parser.error('Use --live to explicitly call the text model')

    load_env(ROOT / '.env.team.local')
    if os.environ.get('DASHSCOPE_API_KEY') and not os.environ.get('CANDID_TEXT_PROVIDER'):
        os.environ['CANDID_TEXT_PROVIDER'] = 'dashscope'

    from agent_runtime.providers import Gateway
    from tasks.business import BusinessJobs

    gateway = Gateway()
    if not gateway.configured:
        print('FAIL: text gateway not configured', flush=True)
        return 1

    jobs = BusinessJobs.__new__(BusinessJobs)
    jobs.gateway = gateway

    payload = {
        'scenario': 'sales',
        'topics': TOPICS,
        'segments': [{k: s[k] for k in ('id', 'start_ms', 'end_ms', 'speaker', 'text')} for s in CASES],
        'documents': [],
    }

    started = time.monotonic()
    result = jobs.structured(PROMPT, payload, timeout_seconds=180)
    elapsed_ms = int((time.monotonic() - started) * 1000)

    items = result.get('items') if isinstance(result, dict) else None
    session_qa = result.get('session_qa') if isinstance(result, dict) else None
    if not isinstance(items, list):
        items = []
    if not isinstance(session_qa, list):
        session_qa = []

    out_dir = ROOT / '.build' / 'memory-worthy-probe'
    out_dir.mkdir(parents=True, exist_ok=True)
    raw_path = out_dir / 'raw.json'
    summary_path = out_dir / 'summary.json'
    raw_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), 'utf8')

    print(f'model={gateway.provider}/{gateway.model} elapsed_ms={elapsed_ms}', flush=True)
    print(f'session_qa={len(session_qa)} items={len(items)}', flush=True)
    print('--- session_qa ---', flush=True)
    for row in session_qa:
        if not isinstance(row, dict):
            continue
        print(
            f"  [{row.get('status')}] Q={row.get('question')!r} A={row.get('answer')!r} "
            f"ids={row.get('segment_ids')} reason={row.get('reason')!r}",
            flush=True,
        )
    print('--- items / memory_worthy ---', flush=True)
    worthy_true = []
    worthy_false_or_missing = []
    for row in items:
        if not isinstance(row, dict):
            continue
        flag = row.get('memory_worthy')
        line = (
            f"  memory_worthy={flag!r} topic={row.get('topic')!r} "
            f"Q={row.get('question')!r} A={row.get('answer')!r} ids={row.get('segment_ids')}"
        )
        print(line, flush=True)
        if flag is True:
            worthy_true.append(row)
        else:
            worthy_false_or_missing.append(row)

    # Lightweight alignment notes against the crafted cases (observer judgment).
    joined_true = ' '.join(str(r.get('question', '')) + str(r.get('answer', '')) for r in worthy_true)
    notes = []
    if any(x in joined_true for x in ('三到四周', '交付', '书面报价', '范围变大', '必做')):
        notes.append('reusable_methods_present_in_true')
    if any(x in joined_true for x in ('华味', '八十万', '下周三', '上海')):
        notes.append('WARN_one_off_customer_detail_marked_true')
    else:
        notes.append('one_off_customer_detail_not_in_true')
    if any(isinstance(r, dict) and '对吗' in str(r.get('question', '')) for r in session_qa):
        notes.append('WARN_verbal_confirm_in_session_qa')
    else:
        notes.append('verbal_confirm_filtered_from_session_qa')

    summary = {
        'provider': gateway.provider,
        'model': gateway.model,
        'elapsed_ms': elapsed_ms,
        'session_qa_count': len(session_qa),
        'items_count': len(items),
        'memory_worthy_true': len(worthy_true),
        'memory_worthy_not_true': len(worthy_false_or_missing),
        'notes': notes,
        'raw_path': str(raw_path),
    }
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), 'utf8')
    print('--- notes ---', flush=True)
    for note in notes:
        print(' ', note, flush=True)
    print(f'wrote {raw_path}', flush=True)
    print(f'wrote {summary_path}', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
