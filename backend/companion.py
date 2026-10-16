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
        return {'expressions': expressions, 'discoveries': discoveries, 'delivery': self.delivery(owner)}

    def delivery(self, owner):
        """Only factual recording totals; calibrated five-axis scores are not available yet."""
        media = {r['session_id'] for r in self.store.rows('session_media', owner)}
        sessions = [s for s in self.store.rows('sessions', owner) if s['id'] in media
                    and not s.get('fixture') and s.get('kind') != 'practice' and s.get('consent') == 'yes']
        knowledge_by_session, segments_by_session = {}, {}
        for item in self.store.rows('recording_knowledge', owner):
            knowledge_by_session.setdefault(item['session_id'], []).append(item)
        for item in self.store.rows('transcript_segments', owner):
            segments_by_session.setdefault(item['session_id'], []).append(item)
        reviewed, next_steps, samples = 0, 0, []
        for session in sessions:
            revision = session.get('transcript_revision', 1)
            knowledge = [k for k in knowledge_by_session.get(session['id'], [])
                         if str(k.get('revision')) == str(revision) and k.get('status') == 'active']
            if knowledge:
                reviewed += 1
                next_steps += int(any(k.get('review', {}).get('next_steps') for k in knowledge))
            segments = [s for s in segments_by_session.get(session['id'], [])
                        if s.get('transcript_revision', 1) == revision]
            if not segments or any(s.get('speaker') not in {'self', 'other'} for s in segments):
                continue
            own = sum(s['end_ms'] - s['start_ms'] for s in segments if s['speaker'] == 'self')
            total = sum(s['end_ms'] - s['start_ms'] for s in segments)
            if total and own:
                samples.append({'id': session['id'], 'title': session.get('title') or '沟通录音',
                                'date': session.get('started_at', session['created_at']),
                                'speaking_share': round(100 * own / total, 1)})
        return {'recording_count': len(sessions), 'reviewed_count': reviewed,
                'next_step_count': next_steps, 'speaking_samples': samples,
                'radar_status': 'awaiting_calibration'}

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
            if not space.get('is_scope_context'):
                patch={'scenario':space.get('scenario') or data['scenario']}
                if space.get('name_source') != 'manual':patch.update(name=data['client'],goal=data['goal'],auto_seeded=True)
                self.store.update('project_spaces',owner,space['id'],patch)
                if 'name' in patch:self.store.update('chat_threads',owner,thread_id,{'title':patch['name']})
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
            if session.get('customer_assignment_required') and not session.get('customer_confirmed_at'):
                return {'recording_id':sid,'published':False,'reason':'customer_confirmation_required'}
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
            target = self.spaces.get(owner,session['customer_workspace_id'])['default_thread_id'] if session.get('customer_confirmed_at') else self.thread(owner)['id']
            if previous:
                # A revision updates the same published card; it does not notify twice.
                old_thread=previous[0]['thread_id']
                self.store.update('chat_messages', owner, previous[0]['id'], {**artifact,'thread_id':target})
                for tid in {old_thread,target}:
                    self.store.update('chat_threads',owner,tid,{'message_count':len(self.store.rows('chat_messages',owner,thread_id=tid))})
            else:
                self.message(owner, key, content, target_thread_id=target,recording_id=sid, recording_revision=str(revision),sources=citations)
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
        return self.edit_faq(owner, aid, {'text': text, 'expected_version': expected,
            'period': self.store.get('assets', owner, aid).get('faq_period', ''),
            'expires_on': self.store.get('assets', owner, aid).get('faq_expires_on', '')})


    def edit_faq(self, owner, aid, changes):
        from datetime import date
        with self.store.transaction(owner):
            row = self.store.get('assets', owner, aid)
            if not row.get('companion_expression'):
                raise Fault('NOT_FOUND', '问题不存在', 404)
            if row['version'] != changes['expected_version']:
                raise Fault('VERSION_CONFLICT', '说法已更新，请返回后重新打开', 409)
            patch = {'version': row['version'] + 1}
            if changes.get('topic') is not None:
                if changes['topic'] not in ['车型与配置','价格与保值','金融与分期','置换','交付与售后','用车场景','其他']:
                    raise Fault('INVALID_TOPIC', '请选择已有主题', 422)
                patch['faq_topic'] = changes['topic']
            if changes.get('text') is not None:
                text = changes['text'].strip()
                if not text: raise Fault('INVALID_TEXT', '先写下你会怎么说', 422)
                expiry = changes.get('expires_on') or ''
                try:
                    if expiry: date.fromisoformat(expiry)
                except ValueError:
                    raise Fault('INVALID_DATE', '截止日期格式应为 YYYY-MM-DD', 422)
                history = list(row.get('faq_history', []))
                history.insert(0, {'text': row['body']['text'], 'period': row.get('faq_period',''),
                    'version': row['version'], 'edited_at': row.get('edited_at', row.get('created_at',''))})
                self.store.put('asset_revisions', owner, {'asset_id': aid, 'version': row['version'], 'body': row['body']}, L1)
                patch.update(body={'text': text}, user_edited=True, edited_at=now(),
                    faq_period=changes.get('period') or '', faq_expires_on=expiry, faq_history=history)
            return self.store.update('assets', owner, aid, patch, actor=owner)
