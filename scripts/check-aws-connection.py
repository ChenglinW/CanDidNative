"""Smoke-test HTTPS reachability of the Singapore AWS backend.

Checks TLS health, auth gate, disposable device registration, and authenticated
profile/capabilities. Does not call paid models. Cleans up the temporary owner.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from pathlib import Path

import httpx

DEFAULT_BASE = 'https://47.129.137.212'
DEFAULT_LEGACY = 'https://16.144.9.183'


def check(name, ok, detail=None, failures=None, results=None):
    entry = {'name': name, 'ok': bool(ok), 'detail': detail}
    results.append(entry)
    mark = 'ok' if ok else 'FAIL'
    print(f'{mark:4} {name}' + (f'  {detail}' if detail is not None else ''), flush=True)
    if not ok:
        failures.append(name)


def main():
    p = argparse.ArgumentParser(description='Check CanDid AWS HTTPS connectivity')
    p.add_argument('--base', default=DEFAULT_BASE, help='Singapore backend base URL')
    p.add_argument('--legacy', default=DEFAULT_LEGACY, help='Oregon proxy URL; empty to skip')
    p.add_argument('--timeout', type=float, default=20)
    p.add_argument('--output', type=Path, default=Path('.build/aws-connection.json'))
    args = p.parse_args()

    results, failures = [], []
    report = {
        'base': args.base,
        'legacy': args.legacy or None,
        'started_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'checks': results,
    }
    token = ''
    started = time.monotonic()

    with httpx.Client(base_url=args.base, timeout=args.timeout, follow_redirects=False) as client:
        # 1) Public health over TLS
        try:
            r = client.get('/health')
            body = r.json() if r.headers.get('content-type', '').startswith('application/json') else {}
            check(
                'tls_health',
                r.status_code == 200 and body.get('status') == 'ok',
                {'status_code': r.status_code, 'status': body.get('status'), 'auth_mode': body.get('auth_mode')},
                failures, results,
            )
        except Exception as e:
            check('tls_health', False, f'{type(e).__name__}: {e}', failures, results)

        # 2) Auth gate on capabilities
        try:
            r = client.get('/v1/capabilities')
            check(
                'unauthenticated_capabilities',
                r.status_code == 401,
                {'status_code': r.status_code},
                failures, results,
            )
        except Exception as e:
            check('unauthenticated_capabilities', False, f'{type(e).__name__}: {e}', failures, results)

        # 3) Device registration + authenticated reads
        try:
            secret = uuid.uuid4().hex + uuid.uuid4().hex
            auth = client.post('/v1/auth/device', json={'installation_secret': secret})
            auth.raise_for_status()
            token = auth.json()['access_token']
            headers = {'Authorization': 'Bearer ' + token}
            check('device_auth', True, {'status_code': auth.status_code}, failures, results)

            caps = client.get('/v1/capabilities', headers=headers)
            caps.raise_for_status()
            payload = caps.json()
            check(
                'authenticated_capabilities',
                caps.status_code == 200 and 'recording_mode' in payload,
                {
                    'status_code': caps.status_code,
                    'recording_mode': payload.get('recording_mode'),
                    'agent_configured': payload.get('agent_configured'),
                    'asr_configured': payload.get('asr_configured'),
                },
                failures, results,
            )

            profile = client.get('/v1/profile', headers=headers)
            profile.raise_for_status()
            check(
                'authenticated_profile',
                profile.status_code == 200 and 'id' in profile.json(),
                {'status_code': profile.status_code},
                failures, results,
            )
        except Exception as e:
            msg = str(e).replace(token, '[redacted]') if token else str(e)
            if 'device_auth' not in {c['name'] for c in results}:
                check('device_auth', False, f'{type(e).__name__}: {msg}', failures, results)
            else:
                check('authenticated_reads', False, f'{type(e).__name__}: {msg}', failures, results)

        # 4) Cleanup disposable owner (expect 410 after wipe)
        if token:
            try:
                wipe = client.delete('/v1/memory', headers={'Authorization': 'Bearer ' + token})
                after = client.get('/v1/profile', headers={'Authorization': 'Bearer ' + token})
                check(
                    'cleanup',
                    wipe.status_code in {200, 204} and after.status_code == 410,
                    {'wipe': wipe.status_code, 'profile_after': after.status_code},
                    failures, results,
                )
            except Exception as e:
                check('cleanup', False, f'{type(e).__name__}: {e}', failures, results)

    # 5) Optional legacy Oregon proxy still reaches Singapore health
    if args.legacy:
        try:
            with httpx.Client(base_url=args.legacy, timeout=args.timeout, follow_redirects=True) as legacy:
                r = legacy.get('/health')
                body = r.json() if r.headers.get('content-type', '').startswith('application/json') else {}
                check(
                    'legacy_proxy_health',
                    r.status_code == 200 and body.get('status') == 'ok',
                    {'status_code': r.status_code, 'status': body.get('status')},
                    failures, results,
                )
        except Exception as e:
            check('legacy_proxy_health', False, f'{type(e).__name__}: {e}', failures, results)

    report['seconds'] = round(time.monotonic() - started, 3)
    report['ok'] = not failures
    report['failed'] = failures
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"\n{'passed' if report['ok'] else 'failed'}  {args.output}  ({report['seconds']}s)", flush=True)
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
