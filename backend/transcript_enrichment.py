"""Transient mark annotations at the transcript boundary; evidence stays verbatim."""
import re

# Explicit quantities only. No model inference, speaker attribution or factual rewrite.
UNIT = r'(?:%|％|万元|萬元|亿元|億元|人民币|港币|港幣|美元|元|块|塊|万|萬|亿|億|千|百|年|月|日|号|號|天|周|週|星期|小时|小時|分钟|分鐘|秒|台|家|个|個|人|套|件|批|倍|成)'
CN = r'[零〇一二两兩三四五六七八九十百千万萬亿億]+(?:[点點][零〇一二两兩三四五六七八九]+)?'
NUMBER = re.compile(
    r'(?:[¥￥$＄]\s*)?[0-9]+(?:[,，][0-9]{3})*(?:[.．][0-9]+)?(?:\s*' + UNIT + r')?'
    r'|(?:百分之|千分之)' + CN +
    r'|' + CN + r'\s*' + UNIT +
    r'|(?<![\w\u3400-\u9fff])' + CN + r'(?=[，。；！？、,.!?;\s]|$)'
)
PREFIX = '【系统标记提示·非原话：'
NUMBER_NOTE = PREFIX + '注意这个数字】'
GENERAL_NOTE = PREFIX + '用户标记关注此处】'


def enhance_transcript(store, owner, sid, segments):
    """Return fresh segment copies. Never mutate persisted text or source versions.

    Use the same 30s-before/15s-after attention window as the highlight card.
    Multiple marks annotate a segment only once; hiding marks removes annotations
    on the next preparation. Caller retains raw segments for quotes and evidence.
    """
    session = store.get('sessions', owner, sid)
    hidden = set(session.get('hidden_mark_ids', []))
    times = [m['t_ms'] for m in store.rows('marks', owner, session_id=sid) if m['id'] not in hidden]
    output = []
    for original in segments:
        row = dict(original)
        if any(row['end_ms'] >= max(0, t-30000) and row['start_ms'] <= t+15000 for t in times):
            text = row['text']
            # The original may literally contain similar bracketed words: do not
            # remove or reinterpret user speech. Input always comes from raw rows.
            if NUMBER.search(text):
                row['text'] = NUMBER.sub(lambda match: match.group(0) + NUMBER_NOTE, text)
            else:
                row['text'] = text + GENERAL_NOTE
        output.append(row)
    return output
