#!/usr/bin/env python3
"""Build and search a small private Qwen3.7 question candidate index.

Input is JSONL with one {"id": "...", "text": "..."} record per line.
The saved index contains the question text and embeddings; protect it as user data.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from question_candidates import Qwen37Embedding, QuestionCandidateIndex


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--index', type=Path, required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    build = commands.add_parser('build')
    build.add_argument('--questions', type=Path, required=True)
    search = commands.add_parser('search')
    search.add_argument('--query', required=True)
    search.add_argument('--top-k', type=int, default=15)
    search.add_argument('--min-score', type=float)
    args = parser.parse_args()
    encoder = Qwen37Embedding()
    if args.command == 'build':
        with args.questions.open(encoding='utf-8') as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
        index = QuestionCandidateIndex(encoder)
        count = index.upsert(rows)
        index.save(args.index)
        print(json.dumps({'indexed': count, 'model': index.model,
                          'dimension': index.dimension}, ensure_ascii=False))
    else:
        index = QuestionCandidateIndex.load(args.index, encoder)
        print(json.dumps(index.search(args.query, top_k=args.top_k,
                                      min_score=args.min_score), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
