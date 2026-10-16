import pytest

from question_candidates import Qwen37Embedding, QuestionCandidateIndex


class FakeEncoder:
    model = 'qwen3.7-text-embedding'

    def __init__(self):
        self.calls = []

    def encode(self, texts):
        self.calls.append(texts)
        vectors = {'工资多少': (1, 0), '薪水是多少': (0.9, 0.1),
                   '工作地点在哪': (0, 1), '办公地点': (0.1, 0.9)}
        return [vectors[text] for text in texts]


def test_recall_upsert_exclusion_and_reload(tmp_path):
    encoder = FakeEncoder()
    index = QuestionCandidateIndex(encoder, [
        {'id': '1', 'text': '工资多少'}, {'id': '2', 'text': '薪水是多少'},
        {'id': '3', 'text': '工作地点在哪'}])
    assert index.upsert([{'id': '1', 'text': '工资多少'}]) == 0
    assert [item['id'] for item in index.search('工资多少', top_k=2, exclude_id='1')] == ['2', '3']
    assert [item['id'] for item in index.search('工资多少', min_score=0.9)] == ['1', '2']
    index.upsert([{'id': '3', 'text': '办公地点'}])
    index.remove('1')
    path = tmp_path / 'questions.json'
    index.save(path)
    restored = QuestionCandidateIndex.load(path, encoder)
    assert [item['id'] for item in restored.search('工作地点在哪')] == ['3', '2']
    assert [item['id'] for item in restored.search_vector((1, 0))] == ['2', '3']


def test_invalid_encoder_batch_does_not_partially_update():
    class Broken(FakeEncoder):
        def encode(self, texts):
            return [(1, 0)]

    index = QuestionCandidateIndex(Broken())
    with pytest.raises(ValueError, match='incomplete'):
        index.upsert([{'id': '1', 'text': 'a'}, {'id': '2', 'text': 'b'}])
    assert not index.records


def test_provider_reorders_embeddings_and_rejects_incomplete_output(monkeypatch):
    import dashscope
    from types import SimpleNamespace

    response = SimpleNamespace(status_code=200, output={'embeddings': [
        {'text_index': 1, 'embedding': [0, 4]}, {'text_index': 0, 'embedding': [3, 0]}]})
    monkeypatch.setattr(dashscope.TextEmbedding, 'call', lambda **kwargs: response)
    encoder = Qwen37Embedding(api_key='offline-test-key')
    assert encoder.encode(['a', 'b']) == [(1, 0), (0, 1)]
    response.output['embeddings'].pop()
    with pytest.raises(ValueError, match='incomplete'):
        encoder.encode(['a', 'b'])


def test_no_match_and_invalid_vector():
    index = QuestionCandidateIndex(FakeEncoder(), [{'id': 'salary', 'text': '工资多少'}])
    assert index.search('工作地点在哪', min_score=0.5) == []
    for vector in ((float('nan'), 1), (0, 0), (1, 2, 3)):
        with pytest.raises(ValueError):
            index.search_vector(vector)
