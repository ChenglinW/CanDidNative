"""Server-only D3200 credential exchange. Never return the application key."""
import asyncio
import json
import os
import time
from uuid import UUID

import httpx
from memory import Fault


class SoundcoreAuthorization:
    HOSTS = {'qa': 'https://speaker-api-qa.anker-in.com',
             'production': 'https://speaker-api.anker-in.com'}
    VERSIONS = {'V1.3.01', 'V1.3.02'}

    def __init__(self, *, transport=None, clock=time.time):
        self.transport, self.clock = transport, clock
        self.cache = {}
        self.lock = asyncio.Lock()

    async def authorize(self, owner_id, device_id, product_code, sdk_version):
        if product_code != 'D3200' or sdk_version not in self.VERSIONS:
            raise Fault('SOUNDCORE_SDK_UNSUPPORTED', '录音豆组件版本不匹配，请更新 App。', 409)
        device_id = str(UUID(device_id))
        environment = os.environ.get('SOUNDCORE_ENVIRONMENT', 'qa')
        app_id, key = os.environ.get('SOUNDCORE_APP_ID'), os.environ.get('SOUNDCORE_APP_KEY')
        if not app_id or not key or environment not in self.HOSTS:
            raise Fault('SOUNDCORE_NOT_CONFIGURED', '录音豆连接服务尚未配置，请联系维护者。', 503)
        # Include environment/application in scope so configuration rotation cannot reuse old grants.
        scope = (owner_id, device_id, product_code, sdk_version, environment, app_id, key)
        async with self.lock:
            now = int(self.clock())
            cached = self.cache.get(scope)
            if cached and min(cached['token_expires_at'], cached['license_expires_at']) > now + 300:
                return dict(cached)
            try:
                async with httpx.AsyncClient(timeout=20, transport=self.transport, follow_redirects=False) as client:
                    response = await client.post(self.HOSTS[environment] + '/v1/third_party_sdk/get_token',
                        headers={'X-Product-Code': product_code, 'X-Soundcore-SDK-Version': sdk_version},
                        json={'app_id': app_id, 'app_key': key, 'user_id': owner_id,
                              'device_id': device_id, 'timestamp': now})
                    response.raise_for_status()
                    body = response.json()
                if not isinstance(body, dict):
                    raise ValueError('invalid response')
                if body.get('code') != 1:
                    raise Fault('SOUNDCORE_AUTH_REJECTED', '录音豆授权未通过，请稍后重试或联系维护者检查授权配置。', 502)
                data = body['data']
                if not isinstance(data, dict):
                    raise ValueError('invalid grant')
                license = data['license']
                value = json.loads(license) if isinstance(license, str) else license
                if not isinstance(value, dict):
                    raise ValueError('invalid license')
                if (value['user_id'] != owner_id or value['device_id'] != device_id
                        or value['app_id'] != app_id):
                    raise ValueError('identity mismatch')
                token_expiry, license_expiry = int(data['token_expire_time']), int(value['license_expire_time'])
                if min(token_expiry, license_expiry) <= now + 30 or not data['token'] or not data['license_signature']:
                    raise ValueError('invalid grant')
                result = {'user_id': owner_id, 'device_id': device_id, 'token': data['token'],
                          'license_json': license if isinstance(license, str) else json.dumps(license, separators=(',', ':'), ensure_ascii=False),
                          'license_signature': data['license_signature'],
                          'token_expires_at': token_expiry, 'license_expires_at': license_expiry,
                          'environment': environment, 'product_code': product_code, 'sdk_version': sdk_version}
            except Fault:
                raise
            except (httpx.HTTPError, ValueError, KeyError, TypeError):
                raise Fault('SOUNDCORE_AUTH_UNAVAILABLE', '暂时无法取得录音豆授权，请检查网络后重试。', 502) from None
            self.cache = {k: v for k, v in self.cache.items()
                          if min(v['token_expires_at'], v['license_expires_at']) > now + 300}
            # Limit transient credential retention independently of provider lifetime.
            if len(self.cache) >= 256:
                self.cache.pop(next(iter(self.cache)))
            self.cache[scope] = result
            return dict(result)
