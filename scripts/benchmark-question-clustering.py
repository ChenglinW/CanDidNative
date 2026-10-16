#!/usr/bin/env python3
"""Compare question clustering pipelines on the Quora Intent-qa gold groups.

Run with backend/.venv/bin/python. The script caches public input files and model
outputs under --cache-dir so a repeated run does not incur provider requests.
"""

import argparse
import base64
import csv
import hashlib
import json
import math
import os
import re
import subprocess
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np


TRAIN_SAMPLES = ("01", "03", "05", "07", "09")
EXTRA_SAMPLES = ("15", "16", "17")
DATA_FILES = [
    *(f"Quora/train/{sample}/clusters.question-text.qid.tsv" for sample in TRAIN_SAMPLES),
    *(f"Quora/test/{sample}/clusters.question-text.qid.tsv" for sample in EXTRA_SAMPLES),
    "Quora/test/quora-sample06_08-reannotated.csv",
]
MODELS = ("text-embedding-v4", "qwen3.7-text-embedding")
TOP_K = 15


def fetch_data(root):
    for remote in DATA_FILES:
        local = root / remote
        if local.exists():
            continue
        local.parent.mkdir(parents=True, exist_ok=True)
        url = "https://api.github.com/repos/iKernels/intent-qa/contents/" + remote
        payload = subprocess.check_output(
            ["curl", "-fLsS", "--retry", "2", "--max-time", "30", url]
        )
        local.write_bytes(base64.b64decode(json.loads(payload)["content"]))


def load_data(root):
    train = []
    for sample in TRAIN_SAMPLES:
        path = root / f"Quora/train/{sample}/clusters.question-text.qid.tsv"
        for label, block in enumerate(re.split(r"\n\s*\n", path.read_text().strip())):
            for line in block.splitlines():
                if line.strip():
                    qid, question = line.split("\t", 1)
                    train.append((sample + ":" + qid, question.strip(), sample + ":" + str(label)))
    gold = root / "Quora/test/quora-sample06_08-reannotated.csv"
    with gold.open(newline="") as handle:
        rows = list(csv.reader(handle, delimiter=";"))[2:]
    test = [(row[0], row[1].strip(), row[2].strip()) for row in rows if len(row) > 2 and row[2].strip()]
    extra = []
    for sample in EXTRA_SAMPLES:
        path = root / f"Quora/test/{sample}/clusters.question-text.qid.tsv"
        for label, block in enumerate(re.split(r"\n\s*\n", path.read_text().strip())):
            for line in block.splitlines():
                if line.strip():
                    qid, question = line.split("\t", 1)
                    extra.append((sample + ":" + qid, question.strip(), sample + ":" + str(label)))
    return train, test, extra


def key_from_env():
    key = os.environ.get("DASHSCOPE_API_KEY")
    if key:
        return key
    path = Path(__file__).resolve().parents[1] / ".env.team.local"
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith("DASHSCOPE_API_KEY="):
                return line.split("=", 1)[1].strip().strip("\"'")
    raise RuntimeError("Set DASHSCOPE_API_KEY to run model comparisons")


def lexical_matrix(texts, char_ngrams=(3,)):
    docs = []
    df = Counter()
    for text in texts:
        words = re.findall(r"[a-z0-9]+", text.lower())
        chars = re.sub(r"\s+", " ", text.lower()).strip()
        features = Counter("w:" + word for word in words)
        features.update("b:" + words[i] + "_" + words[i + 1] for i in range(len(words) - 1))
        for width in char_ngrams:
            features.update("c:" + chars[i:i + width]
                            for i in range(max(0, len(chars) - width + 1)))
        docs.append(features)
        df.update(features.keys())
    n = len(texts)
    inverted = defaultdict(list)
    for index, doc in enumerate(docs):
        weighted = {}
        for term, count in doc.items():
            weighted[term] = (1 + math.log(count)) * (math.log((n + 1) / (df[term] + 1)) + 1)
        norm = math.sqrt(sum(value * value for value in weighted.values())) or 1
        for term, value in weighted.items():
            inverted[term].append((index, value / norm))
    score = np.eye(n, dtype=np.float32)
    for postings in inverted.values():
        for offset, (i, a) in enumerate(postings):
            for j, b in postings[offset + 1:]:
                score[i, j] += a * b
                score[j, i] += a * b
    return score


def model_matrix(model, texts, cache_dir, api_key):
    import dashscope

    path = cache_dir / (model + ".json")
    cache = json.loads(path.read_text()) if path.exists() else {}
    missing = list(dict.fromkeys(text for text in texts if text not in cache))
    started = time.perf_counter()
    for offset in range(0, len(missing), 10):
        batch = missing[offset:offset + 10]
        for attempt in range(3):
            response = dashscope.TextEmbedding.call(model=model, input=batch, api_key=api_key)
            if response.status_code == 200:
                break
            if attempt == 2:
                raise RuntimeError(f"{model}: HTTP {response.status_code}, {getattr(response, 'code', '')}")
            time.sleep(1 + attempt)
        for item in response.output["embeddings"]:
            cache[batch[item["text_index"]]] = item["embedding"]
        path.write_text(json.dumps(cache, ensure_ascii=False))
    elapsed = time.perf_counter() - started
    vectors = np.asarray([cache[text] for text in texts], dtype=np.float32)
    vectors /= np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)
    return vectors @ vectors.T, elapsed, len(missing)


def top_edges(score, top_k=TOP_K):
    n = len(score)
    edges = set()
    for i in range(n):
        row = score[i].copy()
        row[i] = -np.inf
        for j in np.argpartition(row, -min(top_k, n - 1))[-min(top_k, n - 1):]:
            edges.add((min(i, int(j)), max(i, int(j))))
    return edges


def cluster(score, threshold, edges=None, guard=None, guard_threshold=None, linkage="complete"):
    n = len(score)
    parent = list(range(n))
    members = {i: [i] for i in range(n)}

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    edges = edges if edges is not None else top_edges(score)
    for i, j in sorted(edges, key=lambda pair: float(score[pair]), reverse=True):
        if score[i, j] < threshold:
            break
        a, b = root(i), root(j)
        if a == b:
            continue
        left, right = members[a], members[b]
        check = guard if guard is not None else score
        minimum = guard_threshold if guard is not None else threshold
        cross = check[np.ix_(left, right)]
        cohesion = {"complete": np.min, "average": np.mean, "single": np.max}[linkage](cross)
        if cohesion < minimum:
            continue
        if len(left) < len(right):
            a, b = b, a
        parent[b] = a
        members[a].extend(members.pop(b))
    return [root(i) for i in range(n)]


def scores(gold, predicted):
    gold_count, pred_count, overlap = Counter(gold), Counter(predicted), Counter(zip(gold, predicted))
    choose2 = lambda count: count * (count - 1) // 2
    true_pairs = sum(map(choose2, gold_count.values()))
    pred_pairs = sum(map(choose2, pred_count.values()))
    correct = sum(map(choose2, overlap.values()))
    precision = correct / pred_pairs if pred_pairs else 0.0
    recall = correct / true_pairs if true_pairs else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    b_precision = sum(overlap[g, p] / pred_count[p] for g, p in zip(gold, predicted)) / len(gold)
    b_recall = sum(overlap[g, p] / gold_count[g] for g, p in zip(gold, predicted)) / len(gold)
    b_f1 = 2 * b_precision * b_recall / (b_precision + b_recall)
    return dict(pair_precision=precision, pair_recall=recall, pair_f1=f1,
                bcubed_f1=b_f1, predicted_clusters=len(pred_count))


def tune(score, gold, edges=None, guard=None, guard_threshold=None, linkage="complete"):
    values = [float(score[i, j]) for i, j in (edges or top_edges(score))]
    candidates = sorted(set(round(float(np.quantile(values, q)), 4)
                            for q in np.linspace(0.4, 0.995, 28)))
    best = None
    for threshold in candidates:
        result = scores(gold, cluster(score, threshold, edges, guard, guard_threshold, linkage))
        objective = (result["pair_f1"], result["bcubed_f1"], threshold)
        if best is None or objective > best[0]:
            best = (objective, threshold, result)
    return best[1], best[2]


def rerank_matrix(texts, embedding_score, cache_dir, api_key):
    import dashscope

    n = len(texts)
    digest = hashlib.sha256(json.dumps(texts, ensure_ascii=False).encode()).hexdigest()[:16]
    path = cache_dir / ("rerank-" + digest + ".json")
    cache = json.loads(path.read_text()) if path.exists() else {}
    candidates = {}
    for i in range(n):
        row = embedding_score[i].copy()
        row[i] = -np.inf
        candidates[i] = [int(j) for j in np.argpartition(row, -10)[-10:]]

    def request(i):
        for attempt in range(3):
            response = dashscope.TextReRank.call(
                model="qwen3-rerank", query=texts[i],
                documents=[texts[j] for j in candidates[i]],
                instruct="Retrieve questions asking for the same specific information.",
                api_key=api_key)
            if response.status_code == 200:
                return i, {str(candidates[i][item["index"]]): item["relevance_score"]
                           for item in response.output["results"]}
            if attempt == 2:
                raise RuntimeError(f"qwen3-rerank: HTTP {response.status_code}, {getattr(response, 'code', '')}")
            time.sleep(1 + attempt)

    missing = [i for i in range(n) if str(i) not in cache]
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=4) as pool:
        for future in as_completed(pool.submit(request, i) for i in missing):
            i, item = future.result()
            cache[str(i)] = item
            if len(cache) % 10 == 0:
                path.write_text(json.dumps(cache))
    path.write_text(json.dumps(cache))
    score = np.zeros((n, n), dtype=np.float32)
    edges = set()
    for raw_i, results in cache.items():
        i = int(raw_i)
        for raw_j, value in results.items():
            j = int(raw_j)
            a, b = min(i, j), max(i, j)
            score[a, b] = score[b, a] = max(score[a, b], float(value))
            edges.add((a, b))
    return score, edges, time.perf_counter() - started, len(missing)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", type=Path, default=Path("/private/tmp/candid-question-benchmark"))
    parser.add_argument("--output", type=Path, default=Path("docs/question-clustering-results.json"))
    args = parser.parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    fetch_data(args.cache_dir)
    train, test, extra = load_data(args.cache_dir)
    key = key_from_env()
    previous = json.loads(args.output.read_text()) if args.output.exists() else {}
    result = {"dataset": "iKernels/intent-qa Quora", "train_questions": len(train),
              "test_questions": len(test), "extra_questions": len(extra),
              "top_k": TOP_K, "methods": {}}
    matrices = {}
    for name in ("lexical", *MODELS):
        started = time.perf_counter()
        if name == "lexical":
            train_score = lexical_matrix([item[1] for item in train])
            test_score = lexical_matrix([item[1] for item in test])
            extra_score = lexical_matrix([item[1] for item in extra])
            preparation_seconds = time.perf_counter() - started
            api_calls = 0
        else:
            all_texts = [item[1] for item in train + test + extra]
            all_score, preparation_seconds, api_calls = model_matrix(name, all_texts, args.cache_dir, key)
            train_score = all_score[:len(train), :len(train)]
            test_end = len(train) + len(test)
            test_score = all_score[len(train):test_end, len(train):test_end]
            extra_score = all_score[test_end:, test_end:]
        matrices[name] = (train_score, test_score, extra_score)
        for linkage in ("complete", "average"):
            method = name + "+" + linkage
            threshold, training = tune(train_score, [item[2] for item in train], linkage=linkage)
            started = time.perf_counter()
            labels = cluster(test_score, threshold, linkage=linkage)
            seconds = time.perf_counter() - started
            extra_labels = cluster(extra_score, threshold, linkage=linkage)
            first = previous.get("methods", {}).get(method,
                        previous.get("methods", {}).get(name, {}))
            cold = first.get("cold_preparation_seconds", first.get("preparation_seconds"))
            result["methods"][method] = {"threshold": threshold, "train": training,
                "test": scores([item[2] for item in test], labels),
                "extra": scores([item[2] for item in extra], extra_labels),
                "preparation_seconds": preparation_seconds,
                "cold_preparation_seconds": cold if cold is not None else preparation_seconds,
                "test_clustering_seconds": seconds, "new_embedding_inputs": api_calls}
            print(method, result["methods"][method], flush=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))

    train_dense, test_dense, extra_dense = matrices["qwen3.7-text-embedding"]
    guard_threshold = result["methods"]["qwen3.7-text-embedding+complete"]["threshold"]
    train_rerank, train_edges, train_seconds, train_calls = rerank_matrix(
        [item[1] for item in train], train_dense, args.cache_dir, key)
    test_rerank, test_edges, test_seconds, test_calls = rerank_matrix(
        [item[1] for item in test], test_dense, args.cache_dir, key)
    extra_rerank, extra_edges, extra_seconds, extra_calls = rerank_matrix(
        [item[1] for item in extra], extra_dense, args.cache_dir, key)
    for linkage in ("complete", "average"):
        threshold, training = tune(train_rerank, [item[2] for item in train], train_edges,
                                   train_dense, guard_threshold, linkage)
        started = time.perf_counter()
        labels = cluster(test_rerank, threshold, test_edges, test_dense, guard_threshold, linkage)
        seconds = time.perf_counter() - started
        extra_labels = cluster(extra_rerank, threshold, extra_edges, extra_dense,
                               guard_threshold, linkage)
        method = "qwen3.7+rerank+" + linkage
        first = previous.get("methods", {}).get(method,
                    previous.get("methods", {}).get("qwen3.7+rerank", {}))
        result["methods"][method] = {"threshold": threshold,
            "guard_threshold": guard_threshold, "train": training,
            "test": scores([item[2] for item in test], labels),
            "extra": scores([item[2] for item in extra], extra_labels),
            "rerank_train_seconds": train_seconds, "rerank_test_seconds": test_seconds,
            "rerank_extra_seconds": extra_seconds,
            "cold_rerank_train_seconds": first.get("cold_rerank_train_seconds",
                    first.get("rerank_train_seconds", train_seconds)),
            "cold_rerank_test_seconds": first.get("cold_rerank_test_seconds",
                    first.get("rerank_test_seconds", test_seconds)),
            "test_clustering_seconds": seconds,
            "new_rerank_calls": train_calls + test_calls + extra_calls}
        print(method, result["methods"][method], flush=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
