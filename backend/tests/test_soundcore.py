"""Credential boundary and expiry tests; provider calls are injected, not paid."""
import asyncio
import json
import sys
from pathlib import Path
from uuid import uuid4
import httpx
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from adapters.soundcore import SoundcoreAuthorization
from memory import Fault

@pytest.fixture
def exchange(monkeypatch):
    monkeypatch.setenv('SOUNDCORE_APP_ID', 'test-app')
    monkeypatch.setenv('SOUNDCORE_APP_KEY', 'private-key')
    monkeypatch.setenv('SOUNDCORE_ENVIRONMENT', 'qa')
    calls = []
    clock = [1800000000]
    def handle(request):
        body = json.loads(request.content); calls.append((request, body))
        license = {k: body[k] for k in ('app_id', 'user_id', 'device_id')}
        license['license_expire_time'] = clock[0] + 86400
        return httpx.Response(200, json={'code': 1, 'data': {
            'token': 'private-token', 'token_expire_time': clock[0] + 3600,
            'license': license, 'license_signature': 'private-signature'}})
    return SoundcoreAuthorization(transport=httpx.MockTransport(handle), clock=lambda: clock[0]), calls, clock

def test_correct_host_headers_identity_seconds_and_secret_boundary(exchange):
    service, calls, _ = exchange
    phone = str(uuid4())
    result = asyncio.run(service.authorize('owner-a', phone, 'D3200', 'V1.3.01'))
    request, body = calls[0]
    assert str(request.url) == 'https://speaker-api-qa.anker-in.com/v1/third_party_sdk/get_token'
    assert request.headers['X-Soundcore-SDK-Version'] == 'V1.3.01'
    assert request.headers['X-Product-Code'] == 'D3200'
    assert body['timestamp'] == 1800000000
    assert result['user_id'] == 'owner-a' and result['device_id'] == phone
    assert 'private-key' not in json.dumps(result)
    assert json.loads(result['license_json'])['device_id'] == phone

def test_cache_isolated_by_owner_phone_and_version_and_refreshes_before_expiry(exchange):
    service, calls, clock = exchange
    phone = str(uuid4())
    async def run():
        await asyncio.gather(*(service.authorize('a', phone, 'D3200', 'V1.3.01') for _ in range(4)))
        assert len(calls) == 1
        await service.authorize('b', phone, 'D3200', 'V1.3.01')
        await service.authorize('a', str(uuid4()), 'D3200', 'V1.3.01')
        await service.authorize('a', phone, 'D3200', 'V1.3.02')
        assert len(calls) == 4
        clock[0] += 3400
        await service.authorize('a', phone, 'D3200', 'V1.3.01')
        assert len(calls) == 5
    asyncio.run(run())

@pytest.mark.parametrize('response', [
    {'code': 8002, 'message': 'private-key private-token'},
    {'code': 1, 'data': {'token': 'private-token'}},
    {'code': 1, 'data': {'token': 'private-token', 'token_expire_time': 1, 'license': {}, 'license_signature': 'secret'}}])
def test_provider_failure_is_actionable_and_does_not_leak(exchange, response):
    service, _, _ = exchange
    service.transport = httpx.MockTransport(lambda _: httpx.Response(200, json=response))
    with pytest.raises(Fault) as exc:
        asyncio.run(service.authorize('a', str(uuid4()), 'D3200', 'V1.3.01'))
    assert exc.value.status == 502
    assert not service.cache
    assert 'private-' not in exc.value.message

def test_wrong_sdk_rejected_before_network(exchange):
    service, calls, _ = exchange
    with pytest.raises(Fault): asyncio.run(service.authorize('a', str(uuid4()), 'D3200', 'V1.0.98'))
    assert not calls

def test_endpoint_uses_authenticated_owner_and_no_store(monkeypatch, exchange, tmp_path, bind_app_store):
    import app
    from memory import Memory
    from fastapi.testclient import TestClient
    store = Memory(tmp_path/'m.sqlite3', tmp_path/'files')
    bind_app_store(app, store)
    monkeypatch.setattr(app, 'soundcore_authorization', exchange[0])
    body = {'device_id': str(uuid4()), 'product_code': 'D3200', 'sdk_version': 'V1.3.01'}
    with TestClient(app.app) as client:
        assert client.post('/v1/soundcore/authorization', json=body).status_code == 401
        headers = {'Authorization': 'Bearer test-token'}
        response = client.post('/v1/soundcore/authorization', json=body, headers=headers)
        assert response.status_code == 200
        assert response.headers['cache-control'] == 'no-store'
        assert response.json()['user_id'] == app.LOCAL_OWNER
        assert client.post('/v1/soundcore/authorization', json={**body, 'user_id':'someone-else'}, headers=headers).status_code == 400
        assert client.post('/v1/soundcore/authorization', json={**body, 'device_id':'recorder-serial'}, headers=headers).status_code == 400
