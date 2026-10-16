"""Owner-scoped Qwen3.7 question grouping, matching the Chinese benchmark policy.

The benchmark's candidate-edge average linkage is intentionally preserved (it is
not scipy's globally greedy agglomerative clustering). No network on read paths.

The Qwen3.8-Max fallback was evaluated as a single-variable change (see
docs/memory-redesign/MERGE_CONTROL.md) and did not improve pair F1, so production
routing stays on the pure embedding baseline below. The fallback/merge helpers in
question_fallback.py / question_merge.py remain available for experiments only.
"""
import hashlib
import json
import numpy as np
from memory import Fault, L2
from question_candidates import Qwen37Embedding, MODEL, _unit

THRESHOLD = 0.6646
TOP_K = 15
POLICY = 'qwen3.7-average-top15-0.6646@1'


def average_groups(vectors):
    if not vectors:
        return []
    matrix = np.asarray([_unit(v) for v in vectors], dtype=np.float32)
    scores = matrix @ matrix.T
    n = len(vectors)
    # Bound Top K edges; compute cross-group means only for candidate merges.
    edges = set()
    for i in range(n):
        neighbors = sorted((j for j in range(n) if j != i), key=lambda j: (-float(scores[i, j]), j))[:TOP_K]
        edges.update((min(i, j), max(i, j)) for j in neighbors)
    parent = list(range(n))
    members = {i: [i] for i in range(n)}
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for i, j in sorted(edges, key=lambda pair: (-float(scores[pair]), pair)):
        if scores[i, j] < THRESHOLD:
            break
        a, b = root(i), root(j)
        if a == b:
            continue
        if float(np.mean(scores[np.ix_(members[a], members[b])])) < THRESHOLD:
            continue
        if len(members[a]) < len(members[b]):
            a, b = b, a
        parent[b] = a
        members[a].extend(members.pop(b))
    return sorted((sorted(group) for group in members.values()), key=lambda group: group[0])


class QuestionGrouping:
    def __init__(self, store, business=None, encoder_factory=Qwen37Embedding):
        self.store, self.business, self.encoder_factory = store, business, encoder_factory

    def questions(self, owner):
        from companion import Companion
        domain = Companion(self.store)
        rows = []
        for row in self.store.rows('assets', owner):
            if not row.get('companion_expression') or row.get('status') == 'withdrawn':
                continue
            if '客户常问' not in row.get('tags', []) or not row.get('quote', '').strip():
                continue
            refs = row.get('evidence_refs', [])
            if not refs or not domain.current(owner, refs):
                continue
            session = self.store.get('sessions', owner, row['source_session_id'])
            if session.get('fixture') or session.get('kind') == 'practice' or session.get('consent') != 'yes':
                continue
            rows.append({'id': row['id'], 'text': row['quote'].strip(), 'title': row['title'],
                         'session_id': session['id'], 'evidence_refs': refs})
        return sorted(rows, key=lambda row: row['id'])

    def fingerprint(self, rows):
        return hashlib.sha256(json.dumps([POLICY, rows], sort_keys=True, ensure_ascii=False).encode()).hexdigest()

    def snapshot(self, owner):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            return self._snapshot(owner)

    def _snapshot(self, owner):
        rows = self.questions(owner)
        active = {hashlib.sha256(row['text'].encode()).hexdigest() for row in rows}
        # Polling the memory screen must not deserialize the vector cache.
        metadata = self.store.db.execute("SELECT id,json_extract(data,'$.text_hash') AS text_hash,"
            "json_extract(data,'$.model') AS model FROM question_embeddings WHERE owner_id=?", (owner,)).fetchall()
        for cached in metadata:
            if cached['text_hash'] not in active or cached['model'] != MODEL:
                self.store.remove('question_embeddings', owner, cached['id'])
        if not rows:
            for cached in self.store.rows('question_groupings', owner):
                self.store.remove('question_groupings', owner, cached['id'])
        revision = self.fingerprint(rows)
        saved = self.store.rows('question_groupings', owner, revision=revision)
        job = None
        if rows and not saved and self.business:
            job = self.business.submit(owner, 'question_grouping', 'memory', revision)
            if job['status'] == 'completed':
                # The same inputs can become current again after a source restore.
                job = self.store.update('business_jobs', owner, job['id'], {
                    'status': 'queued', 'attempt': job['attempt'] + 1, 'error': None,
                    'progress': '等待处理'})
        # Never display a previous grouping after a source revision/deletion.
        membership = saved[0]['groups'] if saved else [[row['id']] for row in rows]
        byid = {row['id']: row for row in rows}
        groups = []
        for ids in membership:
            items = [byid[i] for i in ids if i in byid]
            if not items:
                continue
            groups.append({'id': min(ids), 'title': items[0]['title'], 'question': items[0]['text'],
                           'expression_ids': ids, 'occurrences': len(items),
                           'recording_count': len({r['session_id'] for r in items})})
        groups.sort(key=lambda group: (-group['occurrences'], group['id']))
        return {'groups': groups, 'status': 'ready' if saved or not rows else (job['status'] if job else 'pending'),
                'job_id': job['id'] if job else None, 'error': job.get('error') if job else None,
                'model': MODEL, 'policy': POLICY}

    def run(self, owner, job):
        with self.store.transaction(owner):
            self.business.guard(owner, job)
            rows = self.questions(owner)
            if self.fingerprint(rows) != job['revision']:
                return {'superseded': True}
            cached = {r['text_hash']: r for r in self.store.rows('question_embeddings', owner, model=MODEL)}
        texts = list(dict.fromkeys(r['text'] for r in rows))
        dimension = next((len(r['vector']) for r in cached.values()), None)
        key = lambda text: hashlib.sha256(text.encode()).hexdigest()
        missing = [text for text in texts if key(text) not in cached]
        if missing:
            try:
                encoder = self.encoder_factory()
            except ValueError:
                raise Fault('EMBEDDING_UNAVAILABLE', '问题归类尚未配置，请联系服务管理员', 503) from None
            for offset in range(0, len(missing), 10):
                self.business.guard(owner, job)
                batch = missing[offset:offset + 10]
                vectors = encoder.encode(batch)  # Network outside the database transaction.
                if len(vectors) != len(batch):
                    raise ValueError('incomplete embeddings')
                vectors = [_unit(v) for v in vectors]
                dimension = dimension or len(vectors[0])
                if any(len(v) != dimension for v in vectors):
                    raise ValueError('embedding dimensions differ')
                with self.store.transaction(owner):
                    self.business.guard(owner, job)
                    if self.fingerprint(self.questions(owner)) != job['revision']:
                        return {'superseded': True}
                    for text, vector in zip(batch, vectors):
                        data = {'model': MODEL, 'text_hash': key(text), 'vector': vector,
                                'producer': MODEL, 'rubric_version': POLICY}
                        # Multiple revisions may run concurrently; reuse the committed cache.
                        prior = self.store.db.execute("SELECT data FROM question_embeddings WHERE owner_id=? "
                            "AND json_extract(data,'$.model')=? AND json_extract(data,'$.text_hash')=?",
                            (owner, MODEL, key(text))).fetchone()
                        cached[key(text)] = json.loads(prior['data']) if prior else self.store.put('question_embeddings', owner, data, L2, source='ai')
        groups = average_groups([cached[key(row['text'])]['vector'] for row in rows])
        with self.store.transaction(owner):
            self.business.guard(owner, job)
            if self.fingerprint(self.questions(owner)) != job['revision']:
                return {'superseded': True}
            for prior in self.store.rows('question_groupings', owner):
                self.store.remove('question_groupings', owner, prior['id'])
            self.store.put('question_groupings', owner, {'revision': job['revision'],
                'groups': [[rows[i]['id'] for i in group] for group in groups],
                'producer': MODEL, 'rubric_version': POLICY}, L2, source='ai')
            active = {key(text) for text in texts}
            for prior in self.store.rows('question_embeddings', owner):
                if prior['text_hash'] not in active or prior['model'] != MODEL:
                    self.store.remove('question_embeddings', owner, prior['id'])
        return {'question_count': len(rows), 'group_count': len(groups), 'new_embeddings': len(missing)}
