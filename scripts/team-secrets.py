#!/usr/bin/env python3
"""Pack/import the team's service credentials; plaintext and password stay outside Git."""
import argparse
import base64
import getpass
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 'candid-team-secrets@1'
AAD = SCHEMA.encode()
ROUNDS = 600_000
MAX_BYTES = 256_000


def private_write(path, data):
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp-' + secrets.token_hex(6))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def read_env(paths):
    sys.path.insert(0, str(ROOT / 'backend'))
    from run import ENV_KEYS
    values = {}
    for path in paths:
        if not path.exists():
            continue
        for line in path.read_text('utf8').splitlines():
            if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            key, value = key.strip(), value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                value = value[1:-1]
            if key in ENV_KEYS and value:
                values[key] = value
    return values


def password(args, creating=False):
    if args.password_file:
        path = args.password_file.resolve()
        if creating and not path.exists():
            private_write(path, (secrets.token_urlsafe(36) + '\n').encode())
        value = path.read_text('utf8').strip()
    else:
        value = getpass.getpass('配置包解密口令（不会显示）：')
    if len(value) < 16:
        raise ValueError('口令至少 16 个字符；推荐用 --password-file 自动生成随机口令')
    return value.encode()


def derive(value, salt, rounds):
    return hashlib.pbkdf2_hmac('sha256', value, salt, rounds, dklen=32)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['pack', 'import'])
    parser.add_argument('--bundle', type=Path, default=ROOT / 'config/team-services.enc.json')
    parser.add_argument('--password-file', type=Path)
    parser.add_argument('--env-file', type=Path, action='append')
    parser.add_argument('--output', type=Path, default=ROOT / '.env.team.local')
    parser.add_argument('--replace', action='store_true', help='明确允许替换已有本地配置')
    args = parser.parse_args()
    if args.action == 'pack':
        paths = args.env_file or [ROOT.parents[1] / '.env.anker.local', ROOT / '.env.dashscope.local',
                                  ROOT / '.env.monid.local', ROOT / '.env.team.local']
        values = read_env(paths)
        legacy = ROOT / 'backend/data/llm-config.json'
        if legacy.exists():
            configuration=json.loads(legacy.read_text('utf8'))
            if configuration.get('api_key'):values.setdefault('DEEPSEEK_API_KEY',configuration['api_key'])
            if configuration.get('model'):values.setdefault('DEEPSEEK_MODEL',configuration['model'])
        if not values:
            raise ValueError('没有找到可打包的服务配置')
        salt, nonce = os.urandom(16), os.urandom(12)
        key = derive(password(args, creating=True), salt, ROUNDS)
        ciphertext = AESGCM(key).encrypt(nonce, json.dumps(values, ensure_ascii=False).encode(), AAD)
        package = {'schema': SCHEMA, 'cipher': 'AES-256-GCM', 'kdf': 'PBKDF2-HMAC-SHA256',
                   'rounds': ROUNDS, 'salt': base64.b64encode(salt).decode(),
                   'nonce': base64.b64encode(nonce).decode(), 'ciphertext': base64.b64encode(ciphertext).decode()}
        private_write(args.bundle, (json.dumps(package, indent=2) + '\n').encode())
        print('已生成加密配置包：' + str(args.bundle.resolve()))
        print('解密口令单独保管，不得提交 Git；配置项数量：' + str(len(values)))
    else:
        if args.output.exists() and not args.replace:
            raise ValueError('本地配置已存在；确认替换时使用 --replace')
        if args.bundle.stat().st_size > MAX_BYTES:
            raise ValueError('配置包过大')
        package = json.loads(args.bundle.read_text('utf8'))
        if package.get('schema') != SCHEMA or package.get('cipher') != 'AES-256-GCM' or package.get('kdf') != 'PBKDF2-HMAC-SHA256':
            raise ValueError('配置包格式不支持')
        rounds = package.get('rounds')
        if not isinstance(rounds, int) or not 100_000 <= rounds <= 2_000_000:
            raise ValueError('KDF 参数无效')
        salt, nonce, ciphertext = [base64.b64decode(package[field], validate=True)
                                   for field in ('salt', 'nonce', 'ciphertext')]
        if len(salt) != 16 or len(nonce) != 12:
            raise ValueError('配置包参数无效')
        key = derive(password(args), salt, rounds)
        values = json.loads(AESGCM(key).decrypt(nonce, ciphertext, AAD))
        sys.path.insert(0, str(ROOT / 'backend'))
        from run import ENV_KEYS
        if not isinstance(values, dict) or any(k not in ENV_KEYS or not isinstance(v, str)
            or any(c in v for c in '\r\n\x00') for k, v in values.items()):
            raise ValueError('配置包字段无效')
        lines = ['# Private team configuration. Never commit this file.']
        lines += [k + '=' + json.dumps(v, ensure_ascii=False) for k, v in sorted(values.items())]
        private_write(args.output, ('\n'.join(lines) + '\n').encode())
        print('已导入私有配置：' + str(args.output.resolve()))


if __name__ == '__main__':
    try:
        main()
    except InvalidTag:
        sys.exit('解密失败：口令不匹配或配置包已损坏；未写入配置')
    except (ValueError, KeyError, OSError) as error:
        sys.exit('配置操作失败：' + str(error))
