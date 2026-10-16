#!/usr/bin/env python3
"""Measure question-fallback LLM call latency through the configured gateway.

Loads Anker router credentials from an env file (default .env.team.local), issues
a fixed choose() probe N times, and prints the latency distribution. This does
not touch the benchmark decision cache and does not evaluate accuracy; it only
characterizes per-call latency of the fallback judge on the current transport.
"""
import argparse
import os
from pathlib import Path
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'backend'))


def load_env(path):
    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"\''))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--env-file', default=str(ROOT/'.env.team.local'))
    ap.add_argument('--calls', type=int, default=6)
    args = ap.parse_args()
    load_env(args.env_file)
    from question_fallback import Qwen38QuestionJudge
    judge = Qwen38QuestionJudge()
    print('url:', judge.url, '| model:', judge.model, '| key set:', bool(judge.key))
    cands = [{'id': '0', 'questions': ['方案价格是多少？', '怎么收费？']},
             {'id': '1', 'questions': ['多久可以交付？']}]
    times = []
    for i in range(args.calls):
        # Retry transient gateway connection resets; only time the successful call.
        for attempt in range(5):
            t0 = time.perf_counter()
            try:
                choice = judge.choose('这个服务要花多少钱？', cands)
                dt = time.perf_counter() - t0
                break
            except Exception as e:
                if getattr(e, 'code', '') == 'GROUPING_MODEL_CONNECTION' and attempt < 4:
                    print('call %d: transient retry %d' % (i+1, attempt+1), flush=True)
                    time.sleep(2.0)
                    continue
                raise
        times.append(dt)
        print('call %d: %.3fs -> %r' % (i+1, dt, choice), flush=True)
    print('mean=%.3f p50=%.3f min=%.3f max=%.3f n=%d' % (
        statistics.mean(times), statistics.median(times), min(times), max(times), len(times)))


if __name__ == '__main__':
    main()
