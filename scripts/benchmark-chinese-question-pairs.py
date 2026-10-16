#!/usr/bin/env python3
"""Chinese same-question pair benchmark using stratified LCQMC holdouts."""

import argparse
import hashlib
import importlib.util
import json
import random
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np


MODULE_PATH = Path(__file__).with_name("benchmark-question-clustering.py")
spec = importlib.util.spec_from_file_location("question_benchmark", MODULE_PATH)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
SOURCE = "https://modelscope.cn/datasets/mteb/LCQMC/resolve/master/data/"
FILES = {"validation": "validation-00000-of-00001.parquet",
         "test": "test-00000-of-00001.parquet"}


def load_sample(cache_dir, split, size):
    import pyarrow.parquet as parquet

    path = cache_dir / FILES[split]
    if not path.exists():
        subprocess.run(["curl", "-fLsS", "--retry", "2", "--max-time", "30",
                        SOURCE + path.name, "-o", str(path)], check=True)
    rows = parquet.read_table(path).to_pylist()
    positives = [row for row in rows if row["score"] == 1]
    negatives = [row for row in rows if row["score"] == 0]
    rng = random.Random(20261016 + (0 if split == "validation" else 1))
    sample = rng.sample(positives, size // 2) + rng.sample(negatives, size // 2)
    rng.shuffle(sample)
    return sample


def pair_score(matrix, rows, index):
    return np.array([matrix[index[row["sentence1"]], index[row["sentence2"]]]
                     for row in rows], dtype=np.float32)


def metrics(values, labels, threshold):
    predictions = values >= threshold
    labels = np.asarray(labels, dtype=bool)
    tp = int(np.sum(predictions & labels))
    fp = int(np.sum(predictions & ~labels))
    fn = int(np.sum(~predictions & labels))
    tn = int(np.sum(~predictions & ~labels))
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"accuracy": (tp + tn) / len(labels), "precision": precision,
            "recall": recall, "f1": f1, "tp": tp, "fp": fp, "fn": fn, "tn": tn}


def tune(values, labels):
    possible = sorted(set(float(x) for x in values))
    candidates = [possible[0] - 1e-6] + [(a + b) / 2 for a, b in zip(possible, possible[1:])] + [possible[-1] + 1e-6]
    return max(candidates, key=lambda threshold:
               (metrics(values, labels, threshold)["f1"],
                metrics(values, labels, threshold)["accuracy"], threshold))


def rerank(rows, cache_dir, key):
    import dashscope

    path = cache_dir / "lcqmc-rerank.json"
    cache = json.loads(path.read_text()) if path.exists() else {}
    pairs = list(dict.fromkeys((row["sentence1"], row["sentence2"]) for row in rows))

    def request(pair):
        q, d = pair
        digest = hashlib.sha256(json.dumps(pair, ensure_ascii=False).encode()).hexdigest()
        for attempt in range(3):
            response = dashscope.TextReRank.call(
                model="qwen3-rerank", query=q, documents=[d],
                instruct="Retrieve questions asking for the same specific information.",
                api_key=key)
            if response.status_code == 200:
                return digest, float(response.output["results"][0]["relevance_score"])
            if attempt == 2:
                raise RuntimeError(f"qwen3-rerank: HTTP {response.status_code}, {getattr(response, 'code', '')}")
            time.sleep(1 + attempt)

    outstanding = []
    for pair in pairs:
        digest = hashlib.sha256(json.dumps(pair, ensure_ascii=False).encode()).hexdigest()
        if digest not in cache:
            outstanding.append(pair)
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=4) as pool:
        for future in as_completed(pool.submit(request, pair) for pair in outstanding):
            digest, value = future.result()
            cache[digest] = value
            if len(cache) % 10 == 0:
                path.write_text(json.dumps(cache))
    path.write_text(json.dumps(cache))
    return np.array([cache[hashlib.sha256(json.dumps(
        (row["sentence1"], row["sentence2"]), ensure_ascii=False).encode()).hexdigest()]
        for row in rows], dtype=np.float32), time.perf_counter() - started, len(outstanding)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", type=Path, default=Path("/private/tmp/candid-chinese-benchmark"))
    parser.add_argument("--output", type=Path, default=Path("docs/chinese-question-pair-results.json"))
    args = parser.parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    validation = load_sample(args.cache_dir, "validation", 200)
    test = load_sample(args.cache_dir, "test", 400)
    all_rows = validation + test
    texts = list(dict.fromkeys(value for row in all_rows
                               for value in (row["sentence1"], row["sentence2"])))
    index = {text: i for i, text in enumerate(texts)}
    labels_val = [row["score"] for row in validation]
    labels_test = [row["score"] for row in test]
    key = shared.key_from_env()
    previous = json.loads(args.output.read_text()) if args.output.exists() else {}
    results = {"dataset": "mteb/LCQMC", "validation_pairs": len(validation),
               "test_pairs": len(test), "unique_questions": len(texts),
               "sampling_seed": 20261016, "methods": {}}
    for model in ("lexical", *shared.MODELS):
        started = time.perf_counter()
        if model == "lexical":
            matrix = shared.lexical_matrix(texts, char_ngrams=(2, 3))
            elapsed, count = time.perf_counter() - started, 0
        else:
            matrix, elapsed, count = shared.model_matrix(model, texts, args.cache_dir, key)
        train_scores = pair_score(matrix, validation, index)
        test_scores = pair_score(matrix, test, index)
        threshold = tune(train_scores, labels_val)
        old = previous.get("methods", {}).get(model, {})
        results["methods"][model] = {
            "threshold": threshold, "validation": metrics(train_scores, labels_val, threshold),
            "test": metrics(test_scores, labels_test, threshold),
            "scoring_seconds": elapsed, "new_embedding_inputs": count,
            "cold_scoring_seconds": old.get("cold_scoring_seconds", elapsed)}
        print(model, results["methods"][model], flush=True)
        args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    train_scores, train_time, train_calls = rerank(validation, args.cache_dir, key)
    test_scores, test_time, test_calls = rerank(test, args.cache_dir, key)
    threshold = tune(train_scores, labels_val)
    old = previous.get("methods", {}).get("qwen3-rerank", {})
    results["methods"]["qwen3-rerank"] = {
        "threshold": threshold, "validation": metrics(train_scores, labels_val, threshold),
        "test": metrics(test_scores, labels_test, threshold),
        "validation_seconds": train_time, "test_seconds": test_time,
        "cold_validation_seconds": old.get("cold_validation_seconds", train_time),
        "cold_test_seconds": old.get("cold_test_seconds", test_time),
        "new_rerank_calls": train_calls + test_calls}
    print("qwen3-rerank", results["methods"]["qwen3-rerank"], flush=True)
    args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
