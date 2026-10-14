"""Launch the built Debug app against a local backend, without putting tokens in argv.

Optional --message runs one real text conversation through the native Store/API.
This helper never reads the model provider key or changes release configuration.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--device', help='iPhone simulator UDID; defaults to a booted iPhone')
parser.add_argument('--port', type=int, default=8000)
parser.add_argument('--thread', help='Open an existing conversation')
parser.add_argument('--message', help='Send one message from the native app after connecting')
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')


def run(*command, capture=False):
    result = subprocess.run(command, env=env, check=True, capture_output=capture, text=True)
    return result.stdout if capture else ''


device = args.device
if not device:
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j', capture=True))['devices']
    phones = [d for group in devices.values() for d in group if 'iPhone' in d['name']]
    phones.sort(key=lambda d: d['state'] != 'Booted')
    if not phones:
        raise SystemExit('请先在 Xcode 中安装 iOS 模拟器')
    device = phones[0]['udid']
app = ROOT / '.build/DerivedData/Build/Products/Debug-iphonesimulator/CanDid.app'
if not app.exists():
    raise SystemExit('请先运行 sh scripts/check-ios.sh --build')
token = (ROOT / 'backend/data/local-access.txt').read_text('utf8').strip()
run('xcrun', 'simctl', 'bootstatus', device, '-b')
run('open', '-a', '/Applications/Xcode.app/Contents/Applications/DeviceHub.app')
run('xcrun', 'simctl', 'install', device, str(app))
env.update(SIMCTL_CHILD_CANDID_LOCAL_BACKEND='1', SIMCTL_CHILD_CANDID_BACKEND_TOKEN=token,
           SIMCTL_CHILD_CANDID_BACKEND_PORT=str(args.port))
if args.thread:
    env['SIMCTL_CHILD_CANDID_CHAT_THREAD_ID'] = args.thread
if args.message:
    env['SIMCTL_CHILD_CANDID_CHAT_MESSAGE'] = args.message
run('xcrun', 'simctl', 'launch', '--terminate-running-process', device, 'com.candid.memory.prototype')
print('Candid 已启动，使用本机后端；模型 Key 仅由后端读取。')
