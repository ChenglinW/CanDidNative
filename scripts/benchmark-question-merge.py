#!/usr/bin/env python3
"""Predeclared group-wise calibration/validation and frozen extra-set evaluation."""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'backend'))
from question_merge import candidate_average_groups, Qwen38MergeJudge, MERGE_PROMPT_VERSION
from question_fallback import FALLBACK_MODEL
from question_grouping import average_groups
from memory import Fault
spec = importlib.util.spec_from_file_location('smoke', ROOT/'scripts/benchmark-question-fallback.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--cache-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in (args.data_dir/'questions.zh.jsonl').read_text().splitlines()]
    vectors = json.loads((args.data_dir/'qwen3.7-text-embedding.json').read_text())
    train = [r for r in rows if r['split']=='train']
    # Keep label groups AND duplicate translations together across calibration/validation.
    parent = {r['group']:r['group'] for r in train}
    def root(g):
        while parent[g] != g:
            parent[g] = parent[parent[g]]
            g = parent[g]
        return g
    seen = {}
    for r in train:
        for text in [r['english'],r['chinese']]:
            if text in seen:
                a,b = root(r['group']),root(seen[text])
                parent[max(a,b)] = min(a,b)
            seen[text] = r['group']
    rank = lambda g:int(hashlib.sha256(('merge-control-v1:'+root(g)).encode()).hexdigest(),16)%10
    splits = {'calibration':[r for r in train if rank(r['group'])<7],
              'validation':[r for r in train if rank(r['group'])>=7],
              'extra':[r for r in rows if r['split']=='extra']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    plan = {'version':'merge-control@1', 'anchor_threshold':.6646, 'width_grid':[0,.04,.08],
        'selection':'Highest calibration pair F1; ties prefer fewer LLM decisions then narrower band. Validate chosen width once; accept only if F1 >= baseline and recall >= baseline - 0.02. Freeze before extra.',
        'scope':'Chinese translations, cached embeddings. Extra was previously benchmarked for embedding methods, but not used to choose this fallback policy. Legacy anchor was fitted on original training set; validation is not unseen for that anchor.',
        'model':FALLBACK_MODEL, 'prompt_version':MERGE_PROMPT_VERSION,
        'dataset_sha256':hashlib.sha256((args.data_dir/'questions.zh.jsonl').read_bytes()).hexdigest(),
        'splits':{k:[r['id'] for r in v] for k,v in splits.items()}}
    plan_path = args.output.with_suffix('.plan.json')
    if plan_path.exists() and json.loads(plan_path.read_text()) != plan:
        raise ValueError('existing preregistered plan differs')
    plan_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2)+'\n')
    report = {'plan':plan_path.name, 'timing':'Vectors already cached; embedding API excluded. Wall time includes cache reads; replay-equivalent seconds substitutes original measured request time for cache reads and is an estimate, not a fresh latency measurement.', 'runs':{}}
    judge = Qwen38MergeJudge()
    def save():
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    def run(split, width):
        subset = splits[split]
        calls, hits, durations = [], [], []
        def decide(a,b):
            digest = hashlib.sha256(json.dumps([FALLBACK_MODEL,MERGE_PROMPT_VERSION,a,b],ensure_ascii=False).encode()).hexdigest()
            path = args.cache_dir/(digest+'.json')
            if path.exists():
                cached = json.loads(path.read_text()); hits.append(cached['seconds']); durations.append(cached['seconds'])
                return cached['merge']
            # Retry transient gateway connection drops; only time the successful call.
            for attempt in range(5):
                started = time.perf_counter()
                try:
                    value = judge.merge(a,b)
                    elapsed = time.perf_counter()-started
                    break
                except Fault as e:
                    if e.code in ('GROUPING_MODEL_CONNECTION','GROUPING_MODEL_FORMAT') and attempt < 4:
                        print(json.dumps({'split':split,'width':width,'retry':attempt+1,'code':e.code}),flush=True)
                        time.sleep(2.0); continue
                    raise
            calls.append(elapsed); durations.append(elapsed)
            path.write_text(json.dumps({'merge':value,'seconds':elapsed}, ensure_ascii=False))
            print(json.dumps({'split':split,'width':width,'new_call':len(calls),'seconds':round(elapsed,3)}),flush=True)
            return value
        texts = [r['chinese'] for r in subset]; vecs = [vectors[t] for t in texts]
        start = time.perf_counter()
        groups, decisions = candidate_average_groups(texts,vecs,width=width,judge=decide)
        elapsed = time.perf_counter()-start
        if width == 0:
            assert groups == average_groups(vecs), 'Baseline mismatch'
        metrics = smoke.metrics(subset,groups)
        result = {**metrics, 'questions':len(subset), 'gold_groups':len({r['group'] for r in subset}),
            'width':width,'lower':.6646-width,'upper':.6646+width,'wall_seconds':elapsed,
            'replay_equivalent_seconds':elapsed+sum(hits),'new_llm_calls':len(calls),
            'cached_llm_calls':len(hits),'mean_request_seconds':sum(durations)/len(durations) if durations else None,
            'decision_counts':dict(Counter(d['method'] for d in decisions)),
            'false_positive_pairs':metrics['predicted_pairs']-metrics['true_positive_pairs'],
            'false_negative_pairs':metrics['gold_pairs']-metrics['true_positive_pairs'],
            'groups_by_id':[[subset[i]['id'] for i in g] for g in groups]}
        report['runs'][f'{split}:{width}'] = result
        save()
        print(json.dumps({'completed':f'{split}:{width}',**{k:v for k,v in result.items() if k != 'groups_by_id'}},ensure_ascii=False),flush=True)
        return result
    calibrated = [run('calibration', w) for w in plan['width_grid']]
    best = max(calibrated,key=lambda r:(r['pair_f1'],-r['new_llm_calls']-r['cached_llm_calls'],-r['width']))
    val_base = run('validation',0)
    val_best = run('validation',best['width']) if best['width'] else val_base
    passed = val_best['pair_f1'] >= val_base['pair_f1'] and val_best['pair_recall'] >= val_base['pair_recall']-.02
    frozen = best['width'] if passed else 0
    report['selection'] = {'calibration_best_width':best['width'],'validation_gate_passed':passed,'frozen_width':frozen}
    save()
    run('extra',0)
    # Also report the preregistered challenger if validation rejected it. No retuning.
    if best['width']:
        run('extra',best['width'])
    report['status'] = 'completed'
    save()


if __name__ == '__main__':
    main()
