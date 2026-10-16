"""Qwen3.7 question candidate recall. Scores are candidates, not same-intent decisions.

The index uses exact cosine search, which is appropriate for a modest question bank.
Callers may partition indexes by owner and scenario before inserting questions.
"""

import json
import math
import os
import tempfile
import time
from pathlib import Path


MODEL = 'qwen3.7-text-embedding'


def _unit(values):
    vector = tuple(float(value) for value in values)
    if not vector or not all(math.isfinite(value) for value in vector):
        raise ValueError('invalid embedding')
    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0:
        raise ValueError('zero embedding')
    return tuple(value / norm for value in vector)


class Qwen37Embedding:
    """Batch Qwen3.7 encoder with bounded retries and no credential logging."""

    model = MODEL

    def __init__(self, api_key=None, batch_size=10):
        self.api_key = api_key or os.environ.get('DASHSCOPE_API_KEY', '')
        if not self.api_key:
            raise ValueError('DASHSCOPE_API_KEY is required')
        if not 1 <= batch_size <= 20:
            raise ValueError('batch_size must be between 1 and 20')
        self.batch_size = batch_size

    def encode(self, texts):
        import dashscope
        from requests.exceptions import RequestException

        if not texts:
            return []
        if any(not isinstance(text, str) or not text.strip() for text in texts):
            raise ValueError('questions must be nonempty strings')
        vectors = []
        for start in range(0, len(texts), self.batch_size):
            batch = texts[start:start + self.batch_size]
            for attempt in range(3):
                try:
                    response = dashscope.TextEmbedding.call(
                        model=self.model, input=batch, api_key=self.api_key, request_timeout=30)
                except RequestException:
                    raise RuntimeError('embedding service connection failed') from None
                if response.status_code == 200:
                    break
                if response.status_code not in (429, 500, 502, 503, 504) or attempt == 2:
                    raise RuntimeError(f'{self.model} embedding request failed: HTTP {response.status_code}')
                time.sleep(1 + attempt)
            ordered = [None] * len(batch)
            for item in response.output['embeddings']:
                index = item['text_index']
                if not isinstance(index, int) or index < 0 or index >= len(batch) or ordered[index] is not None:
                    raise ValueError('invalid embedding response indexes')
                ordered[index] = _unit(item['embedding'])
            if any(vector is None for vector in ordered):
                raise ValueError('incomplete embedding response')
            vectors.extend(ordered)
        return vectors


class QuestionCandidateIndex:
    """Exact Top K search over one caller-defined question collection."""

    def __init__(self, encoder, records=None):
        self.encoder = encoder
        self.model = encoder.model
        self.records = {}
        self.dimension = None
        if records:
            self.upsert(records)

    def upsert(self, records):
        """Insert or replace records shaped as {'id': ..., 'text': ...}."""
        records = list(records)
        if len({row['id'] for row in records}) != len(records):
            raise ValueError('duplicate question IDs in batch')
        if any(not isinstance(row['id'], str) or not row['id'] or
               not isinstance(row['text'], str) or not row['text'].strip() for row in records):
            raise ValueError('each question needs a nonempty string id and text')
        changed = [row for row in records if row['id'] not in self.records or
                   self.records[row['id']]['text'] != row['text']]
        if not changed:
            return 0
        vectors = [_unit(vector) for vector in self.encoder.encode([row['text'] for row in changed])]
        if len(vectors) != len(changed):
            raise ValueError('encoder returned an incomplete batch')
        dimension = self.dimension or len(vectors[0])
        if any(len(vector) != dimension for vector in vectors):
            raise ValueError('embedding dimensions differ')
        for row, vector in zip(changed, vectors):
            self.records[row['id']] = {'text': row['text'], 'vector': vector}
        self.dimension = dimension
        return len(changed)

    def remove(self, question_id):
        self.records.pop(question_id, None)

    def search(self, question, top_k=15, exclude_id=None, min_score=None):
        if not isinstance(question, str) or not question.strip():
            raise ValueError('question must be a nonempty string')
        if not isinstance(top_k, int) or top_k < 1:
            raise ValueError('top_k must be positive')
        if min_score is not None and not -1 <= min_score <= 1:
            raise ValueError('min_score must be between -1 and 1')
        if not self.records:
            return []
        vector = _unit(self.encoder.encode([question])[0])
        return self.search_vector(vector, top_k=top_k, exclude_id=exclude_id, min_score=min_score)

    def search_vector(self, vector, top_k=15, exclude_id=None, min_score=None):
        """Search with an already encoded vector, avoiding a provider call."""
        if not isinstance(top_k, int) or top_k < 1:
            raise ValueError('top_k must be positive')
        if min_score is not None and not -1 <= min_score <= 1:
            raise ValueError('min_score must be between -1 and 1')
        vector = _unit(vector)
        if self.dimension is not None and len(vector) != self.dimension:
            raise ValueError('embedding dimensions differ')
        found = []
        for question_id, record in self.records.items():
            if question_id == exclude_id:
                continue
            score = sum(a * b for a, b in zip(vector, record['vector']))
            if min_score is None or score >= min_score:
                found.append({'id': question_id, 'text': record['text'], 'score': score})
        found.sort(key=lambda item: (-item['score'], item['id']))
        return found[:top_k]

    def save(self, path):
        """Persist index to a caller-controlled private path; no API key is saved."""
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix=path.name + '.', delete=False) as handle:
            temporary = Path(handle.name)
            try:
                json.dump({'model': self.model, 'dimension': self.dimension,
                           'records': self.records}, handle, ensure_ascii=False)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        try:
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    @classmethod
    def load(cls, path, encoder):
        data = json.loads(Path(path).read_text(encoding='utf-8'))
        if data['model'] != encoder.model:
            raise ValueError('index model differs from encoder model')
        index = cls(encoder)
        index.dimension = data['dimension']
        for question_id, record in data['records'].items():
            vector = _unit(record['vector'])
            if len(vector) != index.dimension:
                raise ValueError('index embedding dimensions differ')
            index.records[question_id] = {'text': record['text'], 'vector': vector}
        return index
