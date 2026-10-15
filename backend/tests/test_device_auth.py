"""Device isolation and restored-state credentials, using temporary databases only."""
import shutil
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from device_auth import DeviceAuth
from memory import Fault, Memory, ident


@pytest.fixture
def auth(tmp_path, monkeypatch):
    monkeypatch.setenv('CANDID_DEVICE_AUTH', '1')
    store = Memory(tmp_path / 'memory.sqlite3', tmp_path / 'storage')
    yield DeviceAuth(store, tmp_path)
    store.db.close()


def test_devices_are_isolated_and_restore_their_identity(auth):
    first = auth.register('a' * 64)
    other = auth.register('b' * 64)
    assert auth.register('a' * 64) == first
    assert first['access_token'] != other['access_token']
    assert first['owner_id'] != other['owner_id']
    recording = auth.store.create_session(first['owner_id'], {
        'client_request_id': ident(), 'kind': 'live', 'consent': 'yes',
        'consent_ack_text_version': 'recording-consent@1', 'recording_source': 'iphone'})
    assert auth.owner(first['access_token']) == first['owner_id']
    with pytest.raises(Fault):
        auth.store.get('sessions', other['owner_id'], recording['id'])
    with pytest.raises(Fault):
        auth.owner(first['access_token'][:-1] + ('0' if first['access_token'][-1] != '0' else '1'))


def test_database_and_key_migration_preserves_access_to_recordings(auth, tmp_path):
    device = auth.register('c' * 64)
    recording = auth.store.create_session(device['owner_id'], {
        'client_request_id': ident(), 'kind': 'live', 'consent': 'yes',
        'consent_ack_text_version': 'recording-consent@1', 'recording_source': 'iphone'})
    destination = tmp_path / 'singapore'
    destination.mkdir()
    restored = Memory(destination / 'memory.sqlite3', destination / 'storage')
    try:
        auth.store.db.backup(restored.db)
        shutil.copy2(auth.secret_path, destination / 'device-auth.key')
        migrated = DeviceAuth(restored, destination)
        assert migrated.register('c' * 64) == device
        assert migrated.owner(device['access_token']) == device['owner_id']
        assert restored.get('sessions', device['owner_id'], recording['id'])['id'] == recording['id']
    finally:
        restored.db.close()


def test_registration_quota_does_not_lock_out_existing_devices(auth):
    devices = [auth.register(f'{number:064x}') for number in range(30)]
    with pytest.raises(Fault) as error:
        auth.register(f'{30:064x}')
    assert error.value.code == 'REGISTRATION_LIMITED'
    assert auth.register(f'{0:064x}') == devices[0]


def test_disabled_device_auth_rejects_registration_and_credentials(auth, monkeypatch):
    device = auth.register('d' * 64)
    monkeypatch.setenv('CANDID_DEVICE_AUTH', '0')
    disabled = DeviceAuth(auth.store, auth.secret_path.parent)
    with pytest.raises(Fault):
        disabled.register('d' * 64)
    with pytest.raises(Fault):
        disabled.owner(device['access_token'])


def test_device_endpoint_validates_secrets_and_keeps_tokens_out_of_caches(auth, monkeypatch, bind_app_store):
    import app
    from fastapi.testclient import TestClient
    bind_app_store(app, auth.store)
    monkeypatch.setattr(app, 'device_auth', auth)
    with TestClient(app.app) as client:
        assert client.post('/v1/auth/device', json={'installation_secret': 'short'}).status_code == 400
        registered = client.post('/v1/auth/device', json={'installation_secret': 'e' * 64})
        assert registered.status_code == 200
        assert registered.headers['cache-control'] == 'no-store'
        token = registered.json()['access_token']
        assert client.get('/v1/profile', headers={'Authorization': 'Bearer ' + token}).status_code == 200
        assert client.get('/v1/profile').status_code == 401
