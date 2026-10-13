"""Shared local memory seam: relevance retrieval, evidence reads and version validation.

The existing Memory implements domain writes. This adapter delegates those writes rather
than rebuilding the colleague's memory engine. Remote mode stays disabled until a real
read/write contract is available.
"""
import json
import re

from memory import Fault, L3
from tasks.workspaces import WorkspaceStore
from .sources import SOURCE_TABLES, collect, source, state_of, text_of, version


class SQLiteMemoryAdapter:
    name = 'sqlite'
    contract_version = 'candid-memory@4-draft'

    def __init__(self, store):
        self.store = store
        self.workspaces = WorkspaceStore(store)

    # One adapter instance is shared by Agent reads and App business data access.
    def get(self, table, owner, id):
        self.store.check_owner(owner)
        return self.store.get(table, owner, id)

    def rows(self, table, owner, **filters):
        self.store.check_owner(owner)
        return self.store.rows(table, owner, **filters)

    def put(self, table, owner, data, *args, **kwargs):
        self.store.check_owner(owner)
        return self.store.put(table, owner, data, *args, **kwargs)

    def update(self, table, owner, id, patch, **kwargs):
        self.store.check_owner(owner)
        return self.store.update(table, owner, id, patch, **kwargs)

    def remove(self, table, owner, id):
        self.store.check_owner(owner)
        return self.store.remove(table, owner, id)

    def profile(self, owner):
        self.store.check_owner(owner)
        return self.store.profile(owner)

    def get_occasion(self, owner, occasion_id, workspace_id=None):
        row = self.get('occasions', owner, occasion_id)
        self._require_scope(owner,'occasion',row,workspace_id)
        return row

    def _require_scope(self, owner, kind, row, workspace_id):
        if not self.workspaces.allowed(owner,kind,row,workspace_id):
            raise Fault('SOURCE_OUTSIDE_WORKSPACE','资料尚未关联当前项目空间',403)

    def create_session(self, owner, data):
        return self.store.create_session(owner, data)

    def mutate_asset(self, owner, id, **kwargs):
        return self.store.mutate_asset(owner, id, **kwargs)

    def context(self, owner, *args, **kwargs):
        return self.store.context(owner, *args, **kwargs)

    def resolve(self, owner, source_id, workspace_id=None):
        if not isinstance(source_id, str) or ':' not in source_id:
            raise Fault('SOURCE_UNAVAILABLE', '资料引用格式不正确', 422)
        kind, id = source_id.split(':', 1)
        table = SOURCE_TABLES.get(kind)
        if not table or not id or len(id) > 120:
            raise Fault('SOURCE_UNAVAILABLE', '资料类型不在读取范围内', 422)
        row = self.get(table, owner, id)
        self._require_scope(owner,kind,row,workspace_id)
        scope_versions = self.workspaces.scope_versions(owner,kind,row)
        if scope_versions:
            row = {**row,'context_scope_versions':scope_versions}
        if row.get('fixture') or str(row.get('producer', '')).startswith('fixture'):
            raise Fault('SOURCE_UNAVAILABLE', '示例资料不能作为真实记忆', 404)
        if kind == 'transcript' and row.get('speaker') != 'self':
            session = self.get('sessions',owner,row['session_id'])
            if session.get('consent')!='yes' or not session.get('llm_consent_at'):
                raise Fault('SOURCE_UNAVAILABLE','全场录音没有授权',403)
            row = {**row,'personal_identity_confirmed':False}
        if kind in {'document','research'} and not row.get('text'):
            raise Fault('SOURCE_UNREADABLE', '资料正文尚未取得或解析', 409)
        if kind in {'personal','knowledge'}:
            for reference in row.get('evidence_refs',[]):
                parent_kind,_,parent_id=reference.get('source_id','').partition(':')
                parent_table=SOURCE_TABLES.get(parent_kind)
                if not parent_table:row={**row,'conflict_status':'unresolved'};break
                try:parent=self.get(parent_table,owner,parent_id)
                except Fault:row={**row,'conflict_status':'unresolved'};break
                if reference.get('source_version') and reference['source_version']!=version(parent):
                    row={**row,'conflict_status':'unresolved'};break
                sid=parent.get('session_id')
                if sid and parent_kind=='transcript' and parent.get('transcript_revision',1)!=self.get('sessions',owner,sid).get('transcript_revision',1):
                    row={**row,'conflict_status':'unresolved'};break
        if kind == 'diagnosis':
            feedback = self.rows('diagnosis_feedback', owner, diagnosis_id=row['id'])
            if any(f.get('verdict') == 'disagree' for f in feedback):
                row = {**row, 'user_disagrees':True}
        sid = row.get('session_id') or row.get('source_session_id')
        if sid and self.get('sessions', owner, sid).get('fixture'):
            raise Fault('SOURCE_UNAVAILABLE', '示例场次不作为真实证据', 404)
        return kind, row

    def references_status(self, owner, references, workspace_id=None):
        self.store.check_owner(owner)
        result = []
        for reference in references:
            sid = reference.get('source_id') or reference.get('ref', '').split('@')[0]
            wanted = reference.get('source_version')
            try:
                kind, row = self.resolve(owner, sid, workspace_id)
                actual = version(row)
                status = state_of(row)
                if status == 'current' and (not wanted or not str(wanted).startswith('sha256:')):
                    status = 'unverifiable'
                elif status == 'current' and wanted != actual:
                    status = 'superseded'
                result.append({'source_id': sid, 'source_version': wanted,
                               'status': status, 'current_version': actual})
            except Fault as error:
                if error.code == 'MEMORY_DELETED':
                    raise
                result.append({'source_id': sid, 'source_version': wanted,
                               'status': 'unavailable', 'current_version': None})
        return result

    def _terms(self, query):
        terms = set(re.findall(r'[a-zA-Z0-9]{2,}|[\u4e00-\u9fff]+', query.lower()))
        for word in list(terms):
            if re.fullmatch(r'[\u4e00-\u9fff]+', word):
                terms.update(word[i:i+2] for i in range(len(word)-1))
        return terms

    def search(self, owner, query, *, occasion_id=None, session_id=None, limit=6,
               confirmed_only=True, sources=None, workspace_id=None):
        self.store.check_owner(owner)
        sources = sources if sources is not None else []
        if not isinstance(query, str) or not query.strip() or len(query) > 500:
            raise Fault('BAD_REQUEST', '查询需要 1–500 个字符', 422)
        if occasion_id:
            self.get_occasion(owner, occasion_id, workspace_id)
        if session_id:
            session = self.get('sessions', owner, session_id)
            self._require_scope(owner,'session',session,workspace_id)
            if occasion_id and session.get('occasion_id') != occasion_id:
                raise Fault('BAD_REQUEST', '场次不属于该场合', 422)
        terms, ranked, excluded = self._terms(query), [], []
        sessions = {r['id']: r for r in self.rows('sessions', owner)}
        kinds = ['asset', 'experience', 'occasion', 'personal'] + ([] if confirmed_only else ['transcript'])
        for kind in kinds:
            for row in self.rows(SOURCE_TABLES[kind], owner):
                if not self.workspaces.allowed(owner,kind,row,workspace_id):
                    continue
                sid = row.get('session_id') or row.get('source_session_id')
                if row.get('fixture') or str(row.get('producer', '')).startswith('fixture') or (sid and sessions.get(sid, {}).get('fixture')):
                    continue
                if kind == 'transcript' and row.get('speaker') != 'self':
                    continue
                if kind != 'transcript' and (row.get('trust') != L3 or (kind != 'occasion' and row.get('status') != 'confirmed')):
                    continue
                if session_id and sid != session_id:
                    continue
                oid = row.get('occasion_id') or (row['id'] if kind == 'occasion' else None) or sessions.get(sid, {}).get('occasion_id')
                # Unbound confirmed personal material can be relevant in any occasion.
                if occasion_id and oid and oid != occasion_id:
                    continue
                haystack = (row.get('title', '') + ' ' + text_of(kind, row) + ' ' + json.dumps(row.get('tags', []), ensure_ascii=False)).lower()
                score = sum(1 for term in terms if term in haystack)
                if not score:
                    continue
                try:resolved=self.resolve(owner,kind+':'+row['id'],workspace_id)[1]
                except Fault:continue
                state = state_of(resolved)
                if state != 'current':
                    excluded.append({'source_id': kind+':'+row['id'], 'status': state})
                    continue
                if occasion_id and oid == occasion_id:
                    score += 3
                ranked.append((score, row['created_at'], kind, row))
        ranked.sort(key=lambda x: (x[0], x[1]), reverse=True)
        items = [collect(source(kind, self.resolve(owner,kind+':'+row['id'],workspace_id)[1], limit=600), sources) for _, _, kind, row in ranked[:max(1, min(limit, 6))]]
        excluded = excluded[:20]
        status = 'ok' if items else 'conflict' if any(x['status'] == 'conflict' for x in excluded) else 'stale' if any(x['status'] in {'stale', 'unverifiable'} for x in excluded) else 'empty'
        return {'status': status, 'items': items, 'excluded': excluded, 'retrieval': 'keyword',
                'note': '当前仅按关键词检索相关条目；结果为摘要片段，详细原文按需读取。未配置时效的资料不按年龄自动过期。'}

    def read_evidence(self, owner, references, *, sources=None, workspace_id=None):
        sources = sources if sources is not None else []
        items, unavailable = [], []
        for ref in references[:24]:
            sid = ref['source_id']
            try:
                kind, row = self.resolve(owner, sid, workspace_id)
                state = state_of(row)
                wanted = ref.get('source_version')
                if state != 'current' or (wanted and wanted != version(row)):
                    unavailable.append({'source_id': sid, 'status': state if state != 'current' else 'superseded',
                                        'current_version': version(row)})
                    continue
                item = source(kind, row, reading_range='source_excerpt', limit=2200)
                items.append(collect(item, sources))
            except Fault as error:
                if error.code == 'MEMORY_DELETED':
                    raise
                unavailable.append({'source_id': sid, 'status': 'unavailable'})
        status = 'ok' if items else 'conflict' if any(x['status'] == 'conflict' for x in unavailable) else 'stale' if unavailable else 'empty'
        return {'status': status, 'items': items, 'unavailable': unavailable,
                'note': '原文、用户确认资料及 AI 推断分开标记；text_truncated=true 表示只读了片段。'}

    def decorate_message(self, owner, message, workspace_id=None):
        refs = message.get('sources', [])
        if not refs:
            return dict(message)
        states = self.references_status(owner, refs, workspace_id)
        result = dict(message)
        result['sources'] = [{**s, 'reference_status': state['status'], 'current_version': state['current_version'],
                              'title': s['title'] if state['status'] == 'current' else '旧版或失效来源 · '+s['title']}
                             for s, state in zip(refs, states)]
        result['context_status'] = 'current' if all(s['status']=='current' for s in states) else 'source_changed'
        if result['context_status'] == 'source_changed' and result.get('role') == 'assistant':
            result['content'] = message['content'] + '\n\n（此历史回答的部分来源已变化或无法核对版本，请以当前资料为准。）'
        return result

    def query(self, owner, name, args, sources, occasion_id=None, workspace_id=None):
        if name == 'search_memory':
            return self.search(owner, args['query'], occasion_id=args.get('occasion_id') or occasion_id,
                               session_id=args.get('session_id'), confirmed_only=not args.get('include_evidence', False), sources=sources, workspace_id=workspace_id)
        if name == 'read_evidence':
            return self.read_evidence(owner, args['references'], sources=sources, workspace_id=workspace_id)
        if name == 'list_occasions':
            rows = [r for r in self.rows('occasions', owner) if not r.get('fixture') and state_of(r)=='current' and self.workspaces.allowed(owner,'occasion',r,workspace_id)][:6]
            return {'items': [collect(source('occasion',self.resolve(owner,'occasion:'+r['id'],workspace_id)[1]), sources) for r in rows]}
        if name == 'list_sessions':
            oid = args.get('occasion_id') or occasion_id
            if oid:
                self.get_occasion(owner, oid, workspace_id)
            rows = [r for r in self.rows('sessions', owner, occasion_id=oid) if not r.get('fixture') and self.workspaces.allowed(owner,'session',r,workspace_id)][:6]
            return {'items': [{k: r.get(k) for k in ['occasion_id','scenario','kind','started_at','pipeline_status']} | {'session_id':r['id']} for r in rows]}
        if name == 'read_session':
            sid = args['session_id']
            session = self.get('sessions', owner, sid)
            self._require_scope(owner,'session',session,workspace_id)
            if session.get('fixture'):
                return {'status':'empty','items':[],'note':'示例场次不作为真实记忆'}
            revision=session.get('transcript_revision',1)
            segments = sorted([r for r in self.rows('transcript_segments', owner, session_id=sid) if r.get('transcript_revision',1)==revision and (r.get('speaker')=='self' or (session.get('consent')=='yes' and session.get('llm_consent_at')))], key=lambda r:r['start_ms'])[:20]
            diagnoses = [r for r in self.rows('diagnoses', owner, session_id=sid) if state_of(r)=='current'][:4]
            refs = [{'source_id':'transcript:'+r['id']} for r in segments] + [{'source_id':'diagnosis:'+r['id']} for r in diagnoses]
            return {**self.read_evidence(owner, refs, sources=sources, workspace_id=workspace_id), 'session_id':sid}
        raise Fault('TOOL_UNAVAILABLE', '该工具尚未开放', 422)
