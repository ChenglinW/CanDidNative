"""Prepare and evaluate AISHELL-4 clips, or exercise the five scripted review scenarios."""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'backend'))
from asr import QwenASR
from aishell_eval import prepare_suite, run_suite, write_report, review_text
from llm import DeepSeek, ModelError


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config-dir', type=Path, default=Path(os.environ.get('CANDID_DATA_DIR', ROOT/'backend/data')))
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('prepare', help='Create mono WAV clips and a fixed manifest; no cloud calls')
    prepare.add_argument('--source', type=Path, default=ROOT/'.build/aishell4/source')
    prepare.add_argument('--output', type=Path, default=ROOT/'.build/aishell4/suite')
    prepare.add_argument('--limit', type=int, default=20)
    prepare.add_argument('--channel', type=int, default=0)
    run = commands.add_parser('run', help='Dry run by default; use --live-asr for billable Qwen calls')
    run.add_argument('--manifest', type=Path, default=ROOT/'.build/aishell4/suite/manifest.json')
    run.add_argument('--output', type=Path, required=True)
    run.add_argument('--live-asr', action='store_true')
    run.add_argument('--with-review', action='store_true', help='Also send eligible ASR text to DeepSeek')
    scenarios = commands.add_parser('scenarios', help='Separate scripted cases; NOT AISHELL audio')
    scenarios.add_argument('--output', type=Path, required=True)
    scenarios.add_argument('--live-review', action='store_true')
    args = parser.parse_args()
    if args.command == 'prepare':
        manifest = prepare_suite(args.source, args.output, args.limit, args.channel)
        print(json.dumps({'prepared': len(manifest['cases']), 'coverage': manifest['coverage']}, ensure_ascii=False))
        return 0
    # Check before any billable work. Never overwrite a prior report.
    if args.output.exists(): parser.error('Output report already exists; choose a new path')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.command == 'run':
        if args.with_review and not args.live_asr: parser.error('--with-review requires --live-asr')
        asr = QwenASR.from_config(args.config_dir)
        provider = DeepSeek.from_config(args.config_dir) if args.with_review else None
        if args.live_asr and not asr.configured: parser.error('ASR_NOT_CONFIGURED: fill asr-config.json first')
        if provider is not None and not provider.configured: parser.error('LLM_NOT_CONFIGURED')
        report = run_suite(args.manifest, asr, live=args.live_asr, review_provider=provider)
        write_report(report, args.output)
        print(json.dumps(report['summary'], ensure_ascii=False))
        return 1 if report['summary']['failed'] or report['summary']['review_failed'] else 0
    source = json.loads((ROOT/'backend/evaluation/scenarios.json').read_text('utf8'))
    provider = DeepSeek.from_config(args.config_dir)
    if args.live_review and not provider.configured: parser.error('LLM_NOT_CONFIGURED')
    results = []
    for case in source['cases']:
        row = {**case, 'status': 'prepared_not_run'}
        if args.live_review:
            try:
                # Deliberately exclude other_text, unknown_text and human_checks from the prompt.
                row['review'] = review_text(case['self_text'], provider, case['scenario'])
                row['status'] = 'evidence_checks_passed_semantics_pending'
            except ModelError as e: row.update(status='failed', error_code=e.code)
        results.append(row)
    write_report({'source': source['source'], 'mode': 'live_review' if args.live_review else 'dry_run',
                  'cases': results, 'semantic_quality': 'requires_human_review'}, args.output)
    print(f'{len(results)} scripted review cases; mode={"live" if args.live_review else "dry_run"}')
    return 1 if any(r['status'] == 'failed' for r in results) else 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (ValueError, OSError) as e:
        # Paths may be useful locally; never print request/response or configuration content.
        sys.exit('Evaluation input error: '+type(e).__name__+'. Check local paths, manifest and config.')
