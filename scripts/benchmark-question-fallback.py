#!/usr/bin/env python3
"""Small held-out Chinese comparison, using cached embeddings and real Qwen fallback.

Sampling is deterministic, by gold group only for evaluation coverage. Labels never
enter model prompts. This is a smoke comparison, not a replacement full benchmark.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from question_grouping import average_groups, POLICY
from question_fallback import hybrid_groups, Qwen38QuestionJudge, FALLBACK_MODEL, PROMPT_VERSION


def metrics(rows, groups):
    labels=[None]*len(rows)
    for group, indices in enumerate(groups):
        for i in indices: labels[i]=group
    gold=Counter(r['group'] for r in rows); pred=Counter(labels)
    overlap=Counter((r['group'],g) for r,g in zip(rows,labels))
    pairs=lambda c:sum(n*(n-1)//2 for n in c.values())
    tp,pp,gp=pairs(overlap),pairs(pred),pairs(gold)
    p=tp/pp if pp else 0; r=tp/gp if gp else 0
    return {'pair_precision':p,'pair_recall':r,'pair_f1':2*p*r/(p+r) if p+r else 0,
            'groups':len(groups),'gold_pairs':gp,'predicted_pairs':pp,'true_positive_pairs':tp}


def main():
    p=argparse.ArgumentParser();p.add_argument('--data-dir',type=Path,required=True)
    p.add_argument('--cache-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--groups',type=int,default=8);p.add_argument('--threshold',type=float,default=.85)
    args=p.parse_args();bygroup=defaultdict(list)
    for line in (args.data_dir/'questions.zh.jsonl').read_text().splitlines():
        row=json.loads(line)
        if row['split']=='test':bygroup[row['group']].append(row)
    rank=lambda value:hashlib.sha256(('fallback-smoke-v1:'+value).encode()).hexdigest()
    multi=sorted((g for g,rows in bygroup.items() if len(rows)>1),key=rank)[:args.groups]
    single=sorted((g for g,rows in bygroup.items() if len(rows)==1),key=rank)[:args.groups]
    rows=[r for g in multi+single for r in sorted(bygroup[g],key=lambda r:rank(r['id']))[:3]]
    cache=json.loads((args.data_dir/'qwen3.7-text-embedding.json').read_text())
    vectors=[cache[r['chinese']] for r in rows];texts=[r['chinese'] for r in rows]
    start=time.perf_counter();baseline=average_groups(vectors);baseline_time=time.perf_counter()-start
    judge=Qwen38QuestionJudge();args.cache_dir.mkdir(parents=True,exist_ok=True)
    calls=[];hits=0
    def choose(question,candidates):
        nonlocal hits
        digest=hashlib.sha256(json.dumps([POLICY,PROMPT_VERSION,FALLBACK_MODEL,question,candidates],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        file=args.cache_dir/(digest+'.json')
        if file.exists():hits+=1;return json.loads(file.read_text())['group_id']
        started=time.perf_counter();choice=judge.choose(question,candidates);elapsed=time.perf_counter()-started
        file.write_text(json.dumps({'group_id':choice},ensure_ascii=False));calls.append(elapsed)
        print(json.dumps({'fallback_call':len(calls),'seconds':round(elapsed,2),'selected_group':choice}),flush=True)
        return choice
    start=time.perf_counter();hybrid,decisions=hybrid_groups(texts,vectors,args.threshold,choose);elapsed=time.perf_counter()-start
    report={'scope':'deterministic Chinese translated test subset; not full benchmark; threshold not tuned',
        'questions':len(rows),'gold_groups':len(multi+single),'sample_ids':[r['id'] for r in rows],
        'embedding_timing':'cached vectors; embedding API latency excluded from both methods',
        'baseline':{**metrics(rows,baseline),'seconds':baseline_time,'policy':'average Top15 threshold 0.6646'},
        'hybrid':{**metrics(rows,hybrid),'seconds':elapsed,'auto_threshold':args.threshold,
                  'score_type':'cosine_similarity','fallback_model':FALLBACK_MODEL,
                  'decisions':dict(Counter(d['method'] for d in decisions)),
                  'new_llm_calls':len(calls),'cached_llm_calls':hits,
                  'mean_new_llm_call_seconds':sum(calls)/len(calls) if calls else None}}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,ensure_ascii=False),flush=True)

if __name__=='__main__':main()
