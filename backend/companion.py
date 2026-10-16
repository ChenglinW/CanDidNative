"""V2 product layer: one durable conversation, source-bound reports and proactive reviews."""
from datetime import datetime, timezone
import hashlib
import json
from memory import Fault, L1, L2, ident, now
from tasks.workspaces import WorkspaceStore
from adapters.sqlite_memory import SQLiteMemoryAdapter
from adapters.sources import source, version


class Companion:
    def __init__(self, store):
        self.store = store
        self.spaces = WorkspaceStore(store)
        self.adapter = SQLiteMemoryAdapter(store)

    def thread(self, owner):
        with self.store.transaction(owner):
            space = self.spaces.create(owner, 'Candid', '', 'companion:v2')
            if not space.get('is_companion'):
                self.store.update('project_spaces', owner, space['id'], {
                    'is_companion': True, 'is_scope_context': True, 'auto_seeded': True,
                    'query_scope': {'mode': 'companion'}, 'scope_label': '所有沟通与资料'})
            return self.store.get('chat_threads', owner, space['default_thread_id'])

    def current(self, owner, refs, workspace_id=None):
        return all(r['status'] == 'current' for r in self.adapter.references_status(
            owner, refs, workspace_id or self.thread(owner)['workspace_id']))

    def snapshot(self, owner):
        thread = self.thread(owner)
        packs = []
        for row in self.store.rows('companion_preparations', owner):
            packs.append({**row, 'reference_status': 'current' if self.current(owner, row['evidence_refs']) else 'superseded'})
        active = [p for p in packs if p['status'] == 'ready' and p['reference_status'] == 'current']
        present = datetime.now(timezone.utc)
        def date(p):
            return datetime.fromisoformat(p['scheduled_at'].replace('Z', '+00:00')) if p.get('scheduled_at') else None
        future = sorted([p for p in active if date(p) and date(p) >= present], key=lambda p: (date(p), -datetime.fromisoformat(p['updated_at']).timestamp()))
        undated = sorted([p for p in active if not date(p)], key=lambda p: p['updated_at'], reverse=True)
        # Multiple revisions of the same intended meeting are one candidate.
        candidates = future + undated
        return {'thread': thread, 'preparations': packs, 'next_preparation': candidates[0] if candidates else None}

    def memory(self, owner):
        expressions = []
        for row in self.store.rows('assets', owner):
            if row.get('companion_expression') and row.get('status') != 'withdrawn':
                expressions.append({**row, 'reference_status': 'current' if self.current(owner, row['evidence_refs']) else 'superseded'})
        discoveries = []
        for row in self.store.rows('discoveries', owner):
            if row.get('companion') and row.get('status') != 'withdrawn':
                discoveries.append({**row, 'reference_status': 'current' if self.current(owner, row['evidence_refs']) else 'superseded'})
        return {'expressions': expressions, 'discoveries': discoveries}

    def save_preparation(self, owner, thread_id, request_id, data, references, guard=None):
        thread = self.store.get('chat_threads', owner, thread_id)
        space = self.spaces.get(owner, thread['workspace_id'])
        if space['status'] != 'active':
            raise Fault('WORKSPACE_ARCHIVED', '请先恢复空间后再准备', 409)
        when = data.get('scheduled_at')
        if when:
            try:
                parsed = datetime.fromisoformat(when.replace('Z', '+00:00'))
                if parsed.tzinfo is None: raise ValueError()
                data = {**data, 'scheduled_at': parsed.isoformat()}
            except ValueError: raise Fault('DATE_INVALID', '时间需要包含时区，未定可留空', 422)
        with self.store.transaction(owner):
            if guard:guard()
            prior = self.store.rows('companion_preparations', owner, client_request_id=request_id)
            if prior: return prior[0]
            if not self.current(owner, references, thread['workspace_id']): raise Fault('SOURCE_SUPERSEDED', '准备依据已变化，请重新整理', 409)
            same = next((p for p in self.store.rows('companion_preparations', owner)
                         if p.get('workspace_id', self.thread(owner)['workspace_id']) == thread['workspace_id'] and p['client'] == data['client'] and p.get('scheduled_at') == data.get('scheduled_at') and p['status'] == 'ready'), None)
            pack = self.store.put('companion_preparations', owner, {**data, 'workspace_id': thread['workspace_id'], 'thread_id': thread_id, 'status': 'ready',
                'version': (same['version'] + 1) if same else 1, 'client_request_id': request_id,
                'evidence_refs': references, 'producer': 'agent/preparation', 'rubric_version': 'companion-prep@2'}, L2, source='ai')
            if same: self.store.update('companion_preparations', owner, same['id'], {'status': 'superseded'})
            self.message(owner, 'preparation:' + pack['id'], '准备包已整理：' + pack['client'],
                         target_thread_id=thread_id, preparation_package_id=pack['id'])
            return pack

    def finish(self, owner, pid, expected):
        with self.store.transaction(owner):
            pack = self.store.get('companion_preparations', owner, pid)
            if pack['version'] != expected: raise Fault('VERSION_CONFLICT', '准备包已更新，请刷新', 409)
            return self.store.update('companion_preparations', owner, pid, {'status': 'completed', 'version': expected + 1})

    def message(self, owner, key, content, target_thread_id=None, **artifact):
        # Caller holds transaction: one commit covers the artifact and its publication.
        thread = self.store.get('chat_threads',owner,target_thread_id) if target_thread_id else self.thread(owner)
        prior = self.store.rows('chat_messages', owner, publication_key=key)
        if prior: return prior[0]
        message = self.store.put('chat_messages', owner, {'thread_id': thread['id'], 'role': 'assistant',
            'content': content, 'sources': [], 'tool_steps': [], 'publication_key': key, **artifact}, L1)
        self.store.update('chat_threads', owner, thread['id'], {
            'message_count': len(self.store.rows('chat_messages', owner, thread_id=thread['id']))})
        return message

    def publish_recording(self, owner, sid, revision):
        with self.store.transaction(owner):
            session = self.store.get('sessions', owner, sid)
            if str(session.get('transcript_revision', 1)) != str(revision):
                raise Fault('TRANSCRIPT_CHANGED', '转写已更新，请重新整理', 409)
            knowledge = self.store.rows('recording_knowledge', owner, session_id=sid, revision=str(revision))
            if not knowledge or session.get('pipeline_status') != 'done':
                raise Fault('REVIEW_NOT_READY', '复盘尚未完成', 409)
            key = 'recording-review:' + sid
            previous = self.store.rows('chat_messages', owner, publication_key=key)
            content = '这场沟通整理好了。\n\n' + '\n\n'.join(k['text'] for k in sorted(knowledge, key=lambda k:k['part']))[:10000]
            citations=[{**source('knowledge',k),'citation':f'[{i+1}]'} for i,k in enumerate(sorted(knowledge,key=lambda k:k['part']))]
            artifact = {'recording_id': sid, 'recording_revision': str(revision), 'content': content,'sources':citations}
            if previous:
                # A revision updates the same published card; it does not notify twice.
                self.store.update('chat_messages', owner, previous[0]['id'], artifact)
            else: self.message(owner, key, content, recording_id=sid, recording_revision=str(revision),sources=citations)
            return {'recording_id': sid, 'published': True}

    def save_expressions(self, owner, sid, revision, result, segments, part):
        byid = {s['id']: s for s in segments}
        items = result.get('expressions', [])
        if not isinstance(items, list): return
        for number, item in enumerate(items[:12]):
            if not isinstance(item, dict) or not isinstance(item.get('text'), str) or not item['text'].strip(): continue
            segment = byid.get(item.get('segment_id'))
            quote = item.get('quote')
            if not segment or not isinstance(quote, str) or not quote.strip() or quote not in segment['text']: continue
            key = f'{sid}:{part}:{number}'
            prior = self.store.rows('assets', owner, companion_key=key)
            # A user's wording survives reprocessing; its old source is visibly marked for rechecking.
            if prior and prior[0].get('user_edited'): continue
            ref = {'source_id': 'transcript:' + segment['id'], 'source_version': version(segment),
                   'session_id': sid, 'start_ms': segment['start_ms'], 'end_ms': segment['end_ms']}
            data = {'title': str(item.get('title', '沟通表达'))[:120], 'body': {'text': item['text'][:4000]},
                'kind': 'phrasing', 'scenario': self.store.get('sessions',owner,sid).get('scenario','sales'),
                'tags': [item.get('kind', '需要改善')], 'status': 'draft', 'version': 1,
                'companion_expression': True, 'companion_key': key, 'source_session_id': sid,
                'quote': quote, 'evidence_refs': [ref], 'producer': 'agent/recording-review', 'rubric_version': 'companion-expression@2'}
            if prior: self.store.update('assets', owner, prior[0]['id'], {**data, 'version': prior[0]['version'] + 1})
            else: self.store.put('assets', owner, data, L2, source='ai')

    def edit_expression(self, owner, aid, text, expected):
        with self.store.transaction(owner):
            row = self.store.get('assets', owner, aid)
            if not row.get('companion_expression'): raise Fault('NOT_FOUND', '表达不存在', 404)
            if row['version'] != expected: raise Fault('VERSION_CONFLICT', '表达已更新，请刷新', 409)
            self.store.put('asset_revisions', owner, {'asset_id': aid, 'version': row['version'], 'body': row['body']}, L1)
            return self.store.update('assets', owner, aid, {'body': {'text': text}, 'version': expected+1,
                'user_edited': True, 'edited_at': now()}, actor=owner)
