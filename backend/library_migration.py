"""Lossless, owner-scoped legacy import into the canonical library.

Legacy records remain intact. Divergent edits are retained as versions for an
explicit user choice, never resolved by comparing independent version counters.
"""
import hashlib
import json
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from uuid import UUID, uuid5
from memory import L1, L2

NAMESPACE = UUID('35d040db-1d6e-4711-938a-0c587e57cacd')


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def expiry(store, owner, value):
    if not value or len(value) != 10:
        return value
    # Old date-only deadlines include the whole selected calendar day.
    profiles = store.rows('profiles', owner)
    name = profiles[0].get('timezone', 'UTC') if profiles else 'UTC'
    try:
        zone = ZoneInfo(name)
    except (ZoneInfoNotFoundError, TypeError):
        zone = ZoneInfo('UTC')
    return datetime.combine(date.fromisoformat(value) + timedelta(days=1), time.min, zone).isoformat()


def migrate(library, owner, topics):
    store = library.store
    with store.transaction(owner):
        known = {(r.get('legacy_table', 'assets'), r.get('legacy_id')): r
                 for r in store.rows('library_items', owner) if r.get('legacy_id')}
        for table in ('assets', 'experiences', 'question_bank'):
            for old in store.rows(table, owner):
                if old.get('status') == 'withdrawn':
                    continue
                scenario = old.get('scenario') or 'unclassified'
                if scenario == 'unclassified':
                    sid = old.get('source_session_id') or old.get('session_id')
                    sessions = store.rows('sessions', owner, id=sid) if sid else []
                    if sessions:
                        scenario = sessions[0].get('scenario') or 'unclassified'
                body = old.get('body', {})
                text = body.get('text', '') if isinstance(body, dict) else str(body or '')
                text = text or old.get('text') or old.get('answer') or ''
                title = old.get('title') or old.get('question_essence') or old.get('question') or '历史素材'
                faq = table == 'question_bank' or old.get('kind') == 'qa_answer' or '客户常问' in old.get('tags', []) or (old.get('companion_expression') and old.get('kind') != 'story' and '问' in title)
                source = {'table': table, 'id': old['id'], 'version': old.get('version', 1),
                          'text': text, 'status': old.get('status'), 'topic': old.get('faq_topic'),
                          'period': old.get('faq_period'), 'expires_on': old.get('faq_expires_on')}
                digest = fingerprint(source)
                current = known.get((table, old['id']))
                if not current:
                    item_id = old['id'] if table == 'assets' else str(uuid5(NAMESPACE, owner + ':' + table + ':' + old['id']))
                    refs = old.get('evidence_refs', [])
                    # Preserve old time-only references and normalize only unambiguous segments.
                    normalized = []
                    for ref in refs:
                        candidates = []
                        if not ref.get('source_id') and ref.get('session_id'):
                            sessions = store.rows('sessions', owner, id=ref['session_id'])
                            revision = sessions[0].get('transcript_revision', 1) if sessions else None
                            candidates = [r for r in store.rows('transcript_segments', owner, session_id=ref['session_id'])
                                          if r.get('transcript_revision', 1) == revision and
                                          r.get('start_ms') == ref.get('start_ms') and r.get('end_ms') == ref.get('end_ms')]
                        if len(candidates) == 1:
                            from adapters.sources import version
                            ref = {**ref, 'source_id': 'transcript:' + candidates[0]['id'], 'source_version': version(candidates[0])}
                        normalized.append(ref)
                    allowed = topics.get(scenario, ['其他'])
                    topic = old.get('faq_topic') or old.get('topic')
                    if topic not in allowed:
                        topic = '经历与故事' if scenario == 'interview' and not faq else allowed[0]
                    fields = {k: old[k] for k in ('workspace_id', 'source_session_id', 'session_id', 'occasion_id', 'quote', 'tags', 'created_at') if k in old}
                    current = store.put('library_items', owner, {**fields, 'id': item_id,
                        'legacy_id': old['id'], 'legacy_table': table, 'legacy_payload': old,
                        'legacy_fingerprint': digest, 'title': title, 'text': text, 'topic': topic,
                        'scenario': scenario, 'item_type': 'faq' if faq else 'material',
                        'material_kind': 'question' if table == 'question_bank' else old.get('kind', 'experience' if table == 'experiences' else 'expression'),
                        'evidence_refs': normalized, 'legacy_evidence_refs': refs,
                        'expression_state': 'reusable' if old.get('status') == 'confirmed' or old.get('user_edited') or '值得复用' in old.get('tags', []) else 'improve',
                        'version': old.get('version', 1), 'user_edited': bool(old.get('user_edited')),
                        'status': 'archived' if old.get('status') == 'archived' else 'active',
                        'valid_until': expiry(store, owner, old.get('faq_expires_on') or ''), 'period': old.get('faq_period') or '',
                        'fixture': bool(old.get('fixture') or str(old.get('producer', '')).startswith('fixture')),
                        'remind': old.get('remind', False), 'producer': 'library/migration', 'rubric_version': 'library@2'}, L2, source='ai')
                    old_scope = library.spaces.scope(owner, ('experience' if table == 'experiences' else 'asset') + ':' + old['id'])
                    if old_scope:
                        library.spaces.set_scope(owner, 'faq:' + current['id'], old_scope['mode'], old_scope['workspace_ids'], 0)
                    known[(table, old['id'])] = current
                elif current.get('legacy_fingerprint') != digest:
                    patch = {'legacy_fingerprint': digest, 'legacy_payload': old}
                    if current['text'] != text:
                        patch['migration_conflict'] = {'legacy_text': text, 'legacy_version': old.get('version', 1),
                            'legacy_revision': digest,
                            'legacy_status': old.get('status'), 'source_table': table,
                            'message': '旧版与当前说法不同，请核对后选择保留或采用。'}
                    elif current['version'] == old.get('version', 1) and old.get('status') == 'archived':
                        patch['status'] = 'archived'
                    store.update('library_items', owner, current['id'], patch)
                # Upgrade both early imports and upstream legacy_schema=2 in place.
                # Missing compatibility fields must not reset an edited canonical value.
                metadata = {}
                for key, value in {'legacy_table':table, 'legacy_payload':old,
                                   'legacy_schema':3, 'original_question':old.get('quote') or (title if faq else '')}.items():
                    if key == 'legacy_schema' or key not in current or (key == 'original_question' and not current.get(key)):
                        if current.get(key) != value:
                            metadata[key] = value
                if current.get('legacy_schema', 0) < 3:
                    metadata.update(item_type='faq' if faq else 'material',
                        material_kind='question' if table == 'question_bank' else old.get('kind', 'experience' if table == 'experiences' else 'expression'))
                if current.get('scenario', 'unclassified') == 'unclassified' and scenario != 'unclassified':
                    metadata['scenario'] = scenario
                for key in ('workspace_id', 'source_session_id', 'session_id', 'occasion_id', 'quote', 'tags'):
                    if key in old and key not in current:
                        metadata[key] = old[key]
                if 'period' not in current:
                    metadata['period'] = current.get('legacy_period', old.get('faq_period') or '')
                if 'legacy_period' not in current:
                    metadata['legacy_period'] = current.get('period', metadata.get('period', ''))
                if old.get('status') == 'archived' and not current.get('legacy_fingerprint'):
                    metadata['status'] = 'archived'
                if metadata:
                    current = store.update('library_items', owner, current['id'], metadata)
                old_scope = library.spaces.scope(owner, ('experience' if table == 'experiences' else 'asset') + ':' + old['id'])
                if old_scope and not library.spaces.scope(owner, 'faq:' + current['id']):
                    library.spaces.set_scope(owner, 'faq:' + current['id'], old_scope['mode'], old_scope['workspace_ids'], 0)
                # Each source version imports once, including edits made after the first migration.
                revisions = store.rows('asset_revisions', owner, asset_id=old['id']) if table == 'assets' else []
                revisions += [{'version': r.get('version', 1), 'body': {'text': r.get('text', '')}, 'period': r.get('period')}
                              for r in old.get('faq_history', [])]
                if current['text'] != text:
                    revisions.append({'version': old.get('version', 1), 'body': {'text': text}, 'period': old.get('faq_period')})
                history = store.rows('library_versions', owner, item_id=current['id'])
                existing = {r.get('migration_key') for r in history}
                # Upstream imports had no migration_key; retain their original rows.
                imported = {(r.get('answer_version'), r.get('text'), r.get('period') or '') for r in history}
                for revision in revisions:
                    value = revision.get('body', {}).get('text', '')
                    key = fingerprint([table, old['id'], revision.get('version', 1), value, revision.get('period')])
                    signature = (revision.get('version', 1), value, revision.get('period') or '')
                    if key not in existing and signature not in imported:
                        store.put('library_versions', owner, {'item_id': current['id'], 'answer_version': revision.get('version', 1),
                            'text': value, 'period': revision.get('period'), 'reason': '旧版历史 · ' + table,
                            'migration_key': key, 'legacy_version': revision.get('version', 1)}, L1)
                        existing.add(key)
                        imported.add(signature)
