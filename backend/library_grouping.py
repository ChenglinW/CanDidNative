"""Canonical FAQ grouping with source/scenario boundaries and legacy group links."""
import hashlib
import json
from memory import L1
from question_grouping import QuestionGrouping, average_groups, POLICY


class LibraryGrouping(QuestionGrouping):
    embedding_table = 'library_embeddings'
    grouping_table = 'library_groupings'
    job_kind = 'library_grouping'
    # The embedding model, threshold and linkage policy remain unchanged.
    policy = POLICY + '/canonical-scope@1'

    def questions(self, owner):
        from adapters.sqlite_memory import SQLiteMemoryAdapter
        from tasks.workspaces import WorkspaceStore
        adapter, spaces = SQLiteMemoryAdapter(self.store), WorkspaceStore(self.store)
        result = []
        for row in self.store.rows('library_items', owner):
            if row.get('item_type') != 'faq' or row.get('status') != 'active' or row.get('fixture'):
                continue
            refs = row.get('evidence_refs', [])
            current_refs = not refs or all(r['status'] == 'current' for r in adapter.references_status(owner, refs))
            scope = spaces.scope(owner, 'faq:' + row['id'])
            # Keep implicit session/workspace ownership separate too; no cross-client merge.
            boundary = ({'mode': scope['mode'], 'workspace_ids': sorted(scope.get('workspace_ids', []))} if scope else
                        {'workspace_id': row.get('workspace_id'), 'session_id': row.get('source_session_id') or row.get('session_id')})
            sid = row.get('source_session_id') or row.get('session_id')
            if sid and not scope and not row.get('workspace_id'):
                sessions = self.store.rows('sessions', owner, id=sid)
                if sessions and sessions[0].get('customer_confirmed_at'):
                    boundary = {'workspace_id': sessions[0].get('customer_workspace_id')}
            if not current_refs:
                # Keep stale questions visible for repair, but never merge their invalid sources.
                boundary = {**boundary, 'source_needs_review': row['id']}
            result.append({'id': row['id'], 'text': (row.get('original_question') or row['title']).strip(), 'title': row['title'],
                'scenario': row.get('scenario', 'unclassified'), 'boundary': boundary,
                'session_id': sid, 'evidence_refs': refs, 'legacy_id': row.get('legacy_id'),
                'legacy_table': row.get('legacy_table', 'assets'),
                'session_ids': sorted({u['session_id'] for u in self.store.rows('library_uses', owner, item_id=row['id']) if u.get('session_id')} | ({sid} if sid else set()))})
        return sorted(result, key=lambda r: r['id'])

    def group_indices(self, rows, vectors):
        partitions = {}
        for i, row in enumerate(rows):
            key = json.dumps([row['scenario'], row['boundary']], sort_keys=True)
            partitions.setdefault(key, []).append(i)
        return [[indices[j] for j in group] for indices in partitions.values()
                for group in average_groups([vectors[i] for i in indices])]

    def snapshot(self, owner):
        with self.store.transaction(owner):
            result = super().snapshot(owner)
            byid = {r['id']: r for r in self.questions(owner)}
            legacy = {r['legacy_id']: r['id'] for r in byid.values() if r.get('legacy_id') and r['legacy_table'] == 'assets'}
            old_groups = [(members, r.get('rubric_version', 'unknown')) for r in self.store.rows('question_groupings', owner) for members in r.get('groups', [])]
            for group in result['groups']:
                ids = group['expression_ids']
                group['item_ids'] = ids
                group['scenario'] = byid[ids[0]]['scenario']
                sessions = set(sid for i in ids for sid in byid[i]['session_ids'])
                group['recording_count'] = len(sessions)
                occurrences = set()
                for i in ids:
                    row = byid[i]
                    for ref in row['evidence_refs']:
                        if ref.get('session_id'):
                            occurrences.add((ref['session_id'], ref.get('source_id') or str(ref.get('start_ms')) + ':' + str(ref.get('end_ms'))))
                    for sid in row['session_ids']:
                        if not any(key[0] == sid for key in occurrences):
                            occurrences.add((sid, 'question'))
                # Copies of the same source segment do not add another question occurrence.
                group['occurrences'] = len(occurrences)
                group['legacy_counts'] = [r['legacy_payload']['seen_count'] for i in ids
                    for r in self.store.rows('library_items',owner,id=i)
                    if isinstance(r.get('legacy_payload',{}).get('seen_count'),int)]
                links, canonical_links = [], []
                for old, old_policy in old_groups:
                    canonical = old_policy.startswith('library-')
                    candidates = set(old) if canonical else {legacy[i] for i in old if i in legacy}
                    members = sorted(candidates & set(ids))
                    if not members:
                        continue
                    link = {'old_group_id': min(old), 'new_group_id': group['id'], 'item_ids': members, 'policy': self.policy,
                            'old_policy':old_policy, 'old_group_kind':'canonical' if canonical else 'legacy'}
                    key = hashlib.sha256(json.dumps(link, sort_keys=True).encode()).hexdigest()
                    if not self.store.rows('library_group_links', owner, mapping_key=key):
                        self.store.put('library_group_links', owner, {**link, 'mapping_key': key}, L1)
                    (canonical_links if canonical else links).append(min(old))
                group['legacy_group_ids'] = sorted(set(links))
                group['prior_canonical_group_ids'] = sorted(set(canonical_links))
            return result
