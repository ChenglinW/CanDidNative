"""Installation-scoped credentials for the fixed-server app; no shared client secret."""
import hashlib
import hmac
import os
import secrets
import time
from uuid import uuid4

from memory import Fault, now


class DeviceAuth:
    def __init__(self, store, root):
        self.store = store
        self.enabled = os.getenv('CANDID_DEVICE_AUTH', '0') == '1'
        self.secret_path = root / 'device-auth.key'
        self.secret = b''
        if not self.enabled:
            return
        try:
            fd = os.open(self.secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(secrets.token_bytes(32))
        self.secret = self.secret_path.read_bytes()
        if len(self.secret) != 32:
            raise RuntimeError('Invalid device signing key')
        with store.lock:
            store.db.executescript('''
                CREATE TABLE IF NOT EXISTS device_credentials (
                    installation_hash TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL UNIQUE,
                    owner_id TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS device_registration_limits (
                    hour INTEGER PRIMARY KEY, count INTEGER NOT NULL
                );
            ''')

    @staticmethod
    def digest(value):
        return hashlib.sha256(value.encode()).hexdigest()

    def register(self, installation_secret):
        if not self.enabled:
            raise Fault('NOT_FOUND', '服务尚未开放设备接入', 404)
        installation_hash = self.digest(installation_secret)
        token = 'candid_device_' + hmac.new(self.secret, installation_hash.encode(), hashlib.sha256).hexdigest()
        token_hash = self.digest(token)
        with self.store.transaction():
            row = self.store.db.execute('SELECT owner_id FROM device_credentials WHERE installation_hash=?',
                                        (installation_hash,)).fetchone()
            if row:
                uid = row['owner_id']
                self.store.check_owner(uid)
                self.store.db.execute('UPDATE device_credentials SET token_hash=? WHERE installation_hash=?',
                                      (token_hash, installation_hash))
            else:
                # Bound anonymous enrollment for this small hackathon server, across all source IPs.
                hour = int(time.time() // 3600)
                limit = self.store.db.execute('SELECT count FROM device_registration_limits WHERE hour=?', (hour,)).fetchone()
                total = self.store.db.execute('SELECT COUNT(*) FROM device_credentials').fetchone()[0]
                if (limit and limit['count'] >= 30) or total >= 500:
                    raise Fault('REGISTRATION_LIMITED', '暂时无法建立新连接，请稍后重试', 429)
                uid = str(uuid4())
                self.store.db.execute('INSERT INTO device_credentials VALUES(?,?,?,?)',
                                      (installation_hash, token_hash, uid, now()))
                self.store.db.execute('INSERT INTO device_registration_limits VALUES(?,1) '
                                      'ON CONFLICT(hour) DO UPDATE SET count=count+1', (hour,))
                self.store.db.execute('DELETE FROM device_registration_limits WHERE hour<?', (hour - 24,))
        return {'access_token': token, 'token_type': 'bearer', 'owner_id': uid}

    def owner(self, token):
        if not self.enabled or not token.startswith('candid_device_') or len(token) != 78:
            raise Fault('UNAUTHORIZED', '连接凭证无效，请重新连接', 401)
        with self.store.lock:
            row = self.store.db.execute('SELECT owner_id FROM device_credentials WHERE token_hash=?',
                                        (self.digest(token),)).fetchone()
        if not row:
            raise Fault('UNAUTHORIZED', '连接凭证无效，请重新连接', 401)
        self.store.check_owner(row['owner_id'])
        return row['owner_id']
