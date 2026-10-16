#!/usr/bin/env python3
"""Translate Quora intent groups into Chinese and evaluate complete clustering.

Source and translated questions live in --cache-dir, separate from the repository.
Only the train split selects thresholds; test labels are used only for final scores.
"""

import argparse
import importlib.util
import json
import sys
import time
from collections import Counter
from pathlib import Path

import httpx
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
from question_candidates import QuestionCandidateIndex

spec = importlib.util.spec_from_file_location('question_benchmark', Path(__file__).with_name('benchmark-question-clustering.py'))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
TRANSLATION_URL = 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation'


def translate(texts, cache_dir, api_key):
    path = cache_dir / 'qwen-mt-uni-en-zh.json'
    cache = json.loads(path.read_text()) if path.exists() else {}
    unique = list(dict.fromkeys(texts))
    missing = [text for text in unique if text not in cache]
    started = time.perf_counter()
    with httpx.Client(timeout=httpx.Timeout(90, connect=10)) as client:
        for start in range(0, len(missing), 10):
            batch = missing[start:start + 10]
            payload = {'model': 'qwen-mt-uni', 'input': {
                'source_texts': batch, 'source_lang': 'en', 'target_lang': 'zh'}}
            for attempt in range(3):
                response = client.post(TRANSLATION_URL,
                    headers={'Authorization': 'Bearer ' + api_key}, json=payload)
                if response.status_code == 200 and response.json().get('output', {}).get('Success'):
                    break
                if attempt == 2:
                    raise RuntimeError('translation failed: HTTP ' + str(response.status_code))
                time.sleep(1 + attempt)
            translated = response.json()['output']['Data']['TranslatedTexts']
            if len(translated) != len(batch) or any(not isinstance(x, str) or not x.strip() for x in translated):
                raise ValueError('incomplete translation batch')
            cache.update(zip(batch, translated))
            path.write_text(json.dumps(cache, ensure_ascii=False))
            print('translated', len(cache), '/', len(unique), flush=True)
    return cache, time.perf_counter() - started, len(missing)


def candidate_metrics(score, labels, top_k=15):
    groups = Counter(labels)
    hits = 0
    eligible = 0
    true_pairs = 0
    retrieved_pairs = 0
    edges = shared.top_edges(score, top_k)
    for i, label in enumerate(labels):
        if groups[label] < 2:
            continue
        eligible += 1
        row = score[i].copy()
        row[i] = -np.inf
        neighbors = np.argpartition(row, -min(top_k, len(row) - 1))[-min(top_k, len(row) - 1):]
        hits += any(labels[j] == label for j in neighbors)
    for i in range(len(labels)):
        for j in range(i + 1, len(labels)):
            if labels[i] == labels[j]:
                true_pairs += 1
                retrieved_pairs += (i, j) in edges
    return {'queries_with_match': eligible, 'hit_at_15': hits / eligible if eligible else 0,
            'positive_pair_recall_at_15': retrieved_pairs / true_pairs if true_pairs else 0}


def index_speed(rows, cache, model):
    """Time the reusable exact-search implementation on already encoded vectors."""
    class CachedEncoder:
        def __init__(self, embeddings):
            self.model = model
            self.embeddings = embeddings

        def encode(self, texts):
            return [self.embeddings[text] for text in texts]

    index = QuestionCandidateIndex(CachedEncoder(cache))
    started = time.perf_counter()
    index.upsert([{'id': str(i), 'text': row[1]} for i, row in enumerate(rows)])
    build_seconds = time.perf_counter() - started
    counts = Counter(row[2] for row in rows)
    eligible = hits = 0
    started = time.perf_counter()
    for i, row in enumerate(rows):
        candidates = index.search_vector(index.records[str(i)]['vector'], top_k=15, exclude_id=str(i))
        if counts[row[2]] > 1:
            eligible += 1
            hits += any(rows[int(item['id'])][2] == row[2] for item in candidates)
    search_seconds = time.perf_counter() - started
    return {'index_build_seconds': build_seconds, 'all_queries_seconds': search_seconds,
            'mean_query_milliseconds': search_seconds * 1000 / len(rows),
            'queries_with_match': eligible, 'hit_at_15': hits / eligible if eligible else 0}


def translation_audit(splits, translation, cache_dir):
    audit = {'unique_source_questions': len(translation),
             'unique_translations': len(set(translation.values())), 'splits': {}}
    with (cache_dir / 'questions.zh.jsonl').open('w', encoding='utf-8') as handle:
        for name, rows in zip(('train', 'test', 'extra'), splits):
            by_translation = {}
            for qid, text, label in rows:
                zh = translation[text]
                by_translation.setdefault(zh, []).append((text, label))
                handle.write(json.dumps({'split': name, 'id': qid, 'english': text,
                                         'chinese': zh, 'group': label}, ensure_ascii=False) + '\n')
            collisions = [values for values in by_translation.values()
                          if len({text for text, label in values}) > 1]
            audit['splits'][name] = {
                'translation_collisions': len(collisions),
                'collisions_across_gold_groups': sum(len({label for text, label in values}) > 1
                                                    for values in collisions)}
    return audit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cache-dir', type=Path, default=Path('/private/tmp/candid-translated-question-benchmark'))
    parser.add_argument('--output', type=Path, default=Path('docs/translated-question-clustering-results.json'))
    args = parser.parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    shared.fetch_data(args.cache_dir)
    splits = shared.load_data(args.cache_dir)
    key = shared.key_from_env()
    translation, seconds, count = translate([row[1] for split in splits for row in split], args.cache_dir, key)
    translated = [[(qid, translation[text], label) for qid, text, label in split] for split in splits]
    previous = json.loads(args.output.read_text()) if args.output.exists() else {}
    result = {'source': 'iKernels/intent-qa Quora', 'translation_model': 'qwen-mt-uni',
              'translation_seconds': seconds,
              'cold_translation_seconds': previous.get('cold_translation_seconds', seconds),
              'new_translations': count,
              'translation_audit': translation_audit(splits, translation, args.cache_dir),
              'question_counts': [len(split) for split in translated], 'methods': {}}
    for name in ('lexical', 'text-embedding-v4', 'qwen3.7-text-embedding'):
        texts = [row[1] for split in translated for row in split]
        if name == 'lexical':
            started = time.perf_counter()
            matrices = [shared.lexical_matrix([row[1] for row in split], char_ngrams=(2, 3))
                        for split in translated]
            prep_seconds = time.perf_counter() - started
            added = 0
        else:
            whole, prep_seconds, added = shared.model_matrix(name, texts, args.cache_dir, key)
            a, b = len(translated[0]), len(translated[1])
            matrices = [whole[:a, :a], whole[a:a+b, a:a+b], whole[a+b:, a+b:]]
        method = {'preparation_seconds': prep_seconds,
                  'cold_preparation_seconds': previous.get('methods', {}).get(name, {}).get('cold_preparation_seconds', prep_seconds),
                  'new_embedding_inputs': added, 'candidate_recall': {}, 'clustering': {}}
        for split_name, rows, score in zip(('train', 'test', 'extra'), translated, matrices):
            method['candidate_recall'][split_name] = candidate_metrics(score, [row[2] for row in rows])
        for linkage in ('complete', 'average'):
            threshold, train_scores = shared.tune(matrices[0], [row[2] for row in translated[0]], linkage=linkage)
            started = time.perf_counter()
            test_labels = shared.cluster(matrices[1], threshold, linkage=linkage)
            test_seconds = time.perf_counter() - started
            extra_labels = shared.cluster(matrices[2], threshold, linkage=linkage)
            method['clustering'][linkage] = {
                'threshold': threshold, 'train': train_scores,
                'test': shared.scores([row[2] for row in translated[1]], test_labels),
                'extra': shared.scores([row[2] for row in translated[2]], extra_labels),
                'test_seconds': test_seconds}
        if name == 'qwen3.7-text-embedding':
            vector_cache = json.loads((args.cache_dir / (name + '.json')).read_text())
            method['candidate_index_speed'] = index_speed(translated[1], vector_cache, name)
        result['methods'][name] = method
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(name, json.dumps(method['clustering'], ensure_ascii=False), flush=True)

    qwen = result['methods']['qwen3.7-text-embedding']
    guard = qwen['clustering']['complete']['threshold']
    dense = shared.model_matrix('qwen3.7-text-embedding',
                                [row[1] for split in translated for row in split], args.cache_dir, key)[0]
    a, b = len(translated[0]), len(translated[1])
    dense_splits = (dense[:a, :a], dense[a:a+b, a:a+b], dense[a+b:, a+b:])
    ranked = [shared.rerank_matrix([row[1] for row in split], score, args.cache_dir, key)
              for split, score in zip(translated, dense_splits)]
    method = {'rerank_seconds': [part[2] for part in ranked],
              'cold_rerank_seconds': previous.get('methods', {}).get('qwen3.7+rerank', {}).get(
                  'cold_rerank_seconds', previous.get('methods', {}).get('qwen3.7+rerank', {}).get(
                      'rerank_seconds', [part[2] for part in ranked])),
              'new_rerank_calls': sum(part[3] for part in ranked), 'clustering': {}}
    for linkage in ('complete', 'average'):
        threshold, train_scores = shared.tune(ranked[0][0], [row[2] for row in translated[0]],
                                               ranked[0][1], dense_splits[0], guard, linkage)
        method['clustering'][linkage] = {'threshold': threshold, 'guard_threshold': guard,
            'train': train_scores,
            'test': shared.scores([row[2] for row in translated[1]],
                shared.cluster(ranked[1][0], threshold, ranked[1][1], dense_splits[1], guard, linkage)),
            'extra': shared.scores([row[2] for row in translated[2]],
                shared.cluster(ranked[2][0], threshold, ranked[2][1], dense_splits[2], guard, linkage))}
    result['methods']['qwen3.7+rerank'] = method
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
