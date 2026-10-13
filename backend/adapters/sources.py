"""Stable source identities, content versions and human/AI/evidence distinctions."""
from datetime import datetime, timezone
import hashlib
import json

from memory import L1, L2, L3

SOURCE_TABLES = {'asset': 'assets', 'experience': 'experiences', 'occasion': 'occasions',
                 'transcript': 'transcript_segments', 'diagnosis': 'diagnoses',
                 'document': 'documents', 'research': 'agent_sources',
                 'personal': 'personal_memories', 'knowledge': 'recording_knowledge', 'message': 'chat_messages'}


def version(row):
    # Exclude updated_at-only touches. Content, status and provenance changes invalidate a reference.
    ignored = {'updated_at', 'visibility'}
    body = {k: v for k, v in row.items() if k not in ignored}
    return 'sha256:' + hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def text_of(kind, row):
    if kind == 'diagnosis':
        return row.get('finding', '') + '\n' + row.get('suggestion', '')
    return row.get('text') or json.dumps(row.get('body') or row.get('fields') or row.get('bullets') or {}, ensure_ascii=False)


def state_of(row):
    if row.get('status') in {'archived', 'deleted', 'withdrawn'} or row.get('user_disagrees'):
        return 'archived'
    if row.get('conflict_status') == 'unresolved' or row.get('conflict') is True:
        return 'conflict'
    expiry = row.get('valid_until') or row.get('expires_at')
    if expiry:
        try:
            until = datetime.fromisoformat(expiry.replace('Z', '+00:00'))
            if until.tzinfo is None:
                return 'unverifiable'
            if until <= datetime.now(timezone.utc):
                return 'stale'
        except (ValueError, TypeError, AttributeError):
            return 'unverifiable'
    return 'current'


def source(kind, row, *, reading_range='snippet', limit=2200):
    sid = kind + ':' + row['id']
    v = version(row)
    trust = 'CONFIRMED' if row.get('trust') == L3 else 'INFERRED' if row.get('trust') == L2 else 'EVIDENCE'
    text = text_of(kind, row)
    result = {'source_id': sid, 'source_version': v, 'ref': sid + '@' + v[7:19],
              'title': row.get('title') or ('AI 复盘建议' if kind == 'diagnosis' else '本人原文'),
              'text': text[:limit], 'trust': trust, 'trust_layer': row.get('trust', L1),
              'reference_status': state_of(row), 'reading_range': reading_range,
              'text_truncated': len(text) > limit, 'record_version': row.get('version'),
              'evidence_refs': row.get('evidence_refs', [])}
    if row.get('session_id') or row.get('source_session_id'):
        result['session_id'] = row.get('session_id') or row.get('source_session_id')
    for key in ('start_ms', 'end_ms', 'occasion_id', 'url', 'page', 'fetched_at', 'material_kind', 'confirmation_mode', 'producer', 'personal_identity_confirmed'):
        if row.get(key) is not None:
            result[key] = row[key]
    return result


def collect(item, sources):
    prior = next((x for x in sources if x['ref'] == item['ref']), None)
    if prior:
        item = {**item, 'citation': prior['citation']}
        sources[sources.index(prior)] = item
    else:
        item = {**item, 'citation': f'[{len(sources) + 1}]'}
        sources.append(item)
    return item
