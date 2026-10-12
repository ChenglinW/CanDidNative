"""Explicit live API check using synthetic text and an isolated temporary database.
Run: backend/.venv/bin/python scripts/check-deepseek.py --live
"""
import argparse
import os
from pathlib import Path
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root/'backend'))
from llm import DeepSeek

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true', help='Permit one billable analysis of synthetic text')
args = parser.parse_args()
if not args.live:
    parser.error('Use --live to explicitly call DeepSeek')

provider = DeepSeek.from_config(os.environ.get('CANDID_DATA_DIR', root/'backend/data'))
with tempfile.TemporaryDirectory(prefix='candid-deepseek-') as temp:
    os.environ['CANDID_DATA_DIR'] = temp
    os.environ['CANDID_AUTH_MODE'] = 'local'
    os.environ['CANDID_LOCAL_TOKEN'] = 'isolated-smoke-token'
    import app
    from fastapi.testclient import TestClient
    from memory import ident
    app.store.llm = provider
    h = {'Authorization': 'Bearer isolated-smoke-token'}
    with TestClient(app.app) as c:
        s = c.post('/v1/sessions', headers=h, json={'client_request_id': ident(),
                   'kind': 'oral_debrief', 'consent': 'unknown', 'scenario': 'sales'}).json()
        base = '/v1/sessions/' + s['id']
        response = c.post(base+'/transcript', headers=h, json={'analyze': True, 'segments': [{
            'speaker': 'self', 'start_ms': 0, 'end_ms': 1000,
            'text': '我先向客户确认门店数量和现有系统，再整理接口清单和实施范围。试点还未开始，实际结果需要后续核实。'}]})
        assert response.status_code == 200
        deadline = time.monotonic()+110
        while time.monotonic() < deadline:
            review = c.get(base+'/review', headers=h).json()
            status = review['session']['pipeline_status']
            if status == 'done':
                assert review['diagnoses'] and review['draft_assets']
                assert all(d['producer'] == 'deepseek/'+provider.model+'@candid-v1' for d in review['diagnoses'])
                assert all(a['status'] == 'draft' and a['trust'] == 'L2_inferred' for a in review['draft_assets'])
                print(f'PASS: {provider.model}; HTTP submit → worker → evidence-validated review → draft material', flush=True)
                break
            if status.startswith('failed:'):
                sys.exit('FAIL: '+review['session'].get('pipeline_error', 'unknown'))
            time.sleep(.5)
        else:
            sys.exit('FAIL: analysis did not finish within 110 seconds')
    app.store.db.close()
