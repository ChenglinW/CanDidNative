"""Transient semantic attention notes; original transcript remains evidence."""
PREFIX = '【系统标记提示·非原话：'


def enhance_transcript(store, owner, sid, segments, *, processor=None):
    """Prepare once through the shared mark job, then render current semantic notes.

    Missing/failed analysis yields unchanged copies, never mechanical annotations.
    Callers keep raw rows for quotes and evidence. No downstream prompt changes.
    """
    output = [dict(row) for row in segments]
    if processor is None:
        return output
    groups = processor.prepare(owner, sid)
    byid = {row['id']: row for row in output}
    for group in groups:
        if group['status'] != 'ready':
            continue
        for note in group.get('annotations', []):
            anchor = byid.get(note['anchor_segment_id'])
            # In a cross-session or partial read, don't insert a context note whose
            # supporting sentences were not supplied to this particular consumer.
            if anchor is None or any(e['segment_id'] not in byid or e['quote'] not in byid[e['segment_id']]['text'] for e in note['evidence']):
                continue
            rendered = PREFIX + note['text'] + '】'
            if rendered not in anchor['text']:
                anchor['text'] += '\n' + rendered
    return output
