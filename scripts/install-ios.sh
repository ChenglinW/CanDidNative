#!/bin/sh
# Build, sign and install the local CanDid source on physical iPhones/iPads.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec python3 - "$ROOT" "$@" <<'PY'
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(prog='install-ios.sh', description="构建、签名并安装当前本地 CanDid；不会自动 git pull 或卸载 App。")
choice = parser.add_mutually_exclusive_group(required=True)
choice.add_argument('--all', action='store_true', help='安装到所有已配对的 iPhone/iPad，包含离线设备的失败报告')
choice.add_argument('--device', action='append', help='指定设备标识、UDID 或完整名称；可重复传入')
choice.add_argument('--list', action='store_true', help='只查看设备')
parser.add_argument('--team', default=os.environ.get('CANDID_DEVELOPMENT_TEAM', 'SYG7G3A475'), help='开发团队 ID，默认沿用本项目已有团队')
parser.add_argument('--no-launch', action='store_true', help='只安装，不尝试启动')
args = parser.parse_args(sys.argv[2:])

def call(command, **kwargs):
    return subprocess.run(command, cwd=str(root), check=True, **kwargs)

def output(command):
    return call(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

if sys.platform != 'darwin':
    parser.error('需要 macOS 和完整 Xcode')
if args.list:
    sys.exit(subprocess.call(['xcrun', 'devicectl', 'list', 'devices'], cwd=str(root)))

base = root / '.build' / 'DeviceInstall'
base.mkdir(parents=True, exist_ok=True)
lock = (base / 'install.lock').open('w')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    parser.error('另一个安装脚本正在运行，请等待其完成')
run = base / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()))
run.mkdir()
derived = base / 'DerivedData'
app = derived / 'Build/Products/Release-iphoneos/CanDid.app'
revision = output(['git', 'rev-parse', 'HEAD']).decode().strip()
receipt = {'source_commit': revision, 'configuration': 'Release', 'team': args.team, 'devices': []}

def save():
    (run / 'summary.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')

def logged(command, name, timeout=None):
    path = run / name
    with path.open('w') as log:
        call(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)

def reason(path):
    try:
        data = json.loads(path.read_text())
    except (ValueError, OSError):
        return '启动失败，请查看日志'
    text = json.dumps(data, ensure_ascii=False)
    if 'Locked' in text:
        return '手机/iPad 锁屏；解锁后打开 CanDid 即可'
    if 'Security' in text or 'trusted' in text:
        return 'iOS 安全检查拦截；请核对设置 → 通用 → VPN 与设备管理中的开发者信任'
    return '启动失败，请查看日志'

try:
    call(['xcodebuild', '-version'])
    for framework in ('module_spplinkKit', 'SoundcoreWorkAppleSDK', 'libopus'):
        if not (root / 'ios/Vendor' / (framework + '.xcframework')).is_dir():
            raise RuntimeError('缺少 ' + framework + '，请先按 README 准备 soundcore/libopus 依赖')
    logged(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(run / 'devices.json')], 'devices.log', 30)
    devices = json.loads((run / 'devices.json').read_text())['result']['devices']
    phones = [d for d in devices if d.get('hardwareProperties', {}).get('deviceType') in ('iPhone', 'iPad')]
    if args.all:
        selected = phones
    else:
        selected = []
        for requested in args.device:
            found = [d for d in phones if requested in (d['identifier'], d.get('hardwareProperties', {}).get('udid'), d.get('deviceProperties', {}).get('name'))]
            if len(found) != 1:
                raise RuntimeError('设备不存在或名称不唯一：' + requested + '；请先运行 --list 并使用标识')
            if found[0] not in selected:
                selected.append(found[0])
    if not selected:
        raise RuntimeError('没有已配对的 iPhone/iPad，请连接、信任并开启开发者模式')
    # Attempt currently reachable devices first so an offline device cannot delay them.
    selected.sort(key=lambda d: d.get('connectionProperties', {}).get('tunnelState') == 'unavailable')
    print('本地提交：' + revision[:12], flush=True)
    print('安装记录：' + str(run), flush=True)
    for device in selected:
        identifier = device['identifier']
        label = device.get('deviceProperties', {}).get('name', identifier)
        row = {'identifier': identifier, 'name': label, 'installed': False, 'launch': 'not_attempted'}
        receipt['devices'].append(row)
        stem = identifier
        print('\n正在处理：' + label, flush=True)
        try:
            details = run / (stem + '-details.json')
            logged(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', identifier, '--timeout', '25', '--json-output', str(details)], stem + '-details.log', 35)
            current = json.loads(details.read_text())['result']
            if current.get('connectionProperties', {}).get('tunnelState') != 'connected':
                raise RuntimeError('设备未连接；请接线、解锁并确认信任后重试')
            if current.get('deviceProperties', {}).get('developerModeStatus') != 'enabled':
                raise RuntimeError('请在设备设置 → 隐私与安全性中开启开发者模式')
            udid = current['hardwareProperties']['udid']
            if output(['git', 'rev-parse', 'HEAD']).decode().strip() != revision:
                raise RuntimeError('安装期间 Git 提交发生变化；请重新运行，以保证设备使用同一版本')
            print('构建 Release 并配置设备签名…', flush=True)
            logged(['xcodebuild', '-project', str(root / 'ios/CanDid.xcodeproj'), '-scheme', 'CanDid', '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'id=' + udid, '-derivedDataPath', str(derived), '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'DEVELOPMENT_TEAM=' + args.team, 'build'], stem + '-build.log')
            logged(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], stem + '-signature.log')
            profile = plistlib.loads(output(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')]))
            if udid not in profile.get('ProvisionedDevices', []) and not profile.get('ProvisionsAllDevices'):
                raise RuntimeError('签名配置未包含此设备，停止安装；请在 Xcode 检查设备注册')
            expiry = profile.get('ExpirationDate')
            if expiry and expiry <= datetime.datetime.utcnow():
                raise RuntimeError('签名配置已过期，请在 Xcode 刷新')
            bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
            row['bundle_identifier'] = bundle
            row['binary_sha256'] = hashlib.sha256((app / 'CanDid').read_bytes()).hexdigest()
            installed = run / (stem + '-install.json')
            logged(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', identifier, str(app), '--timeout', '120', '--json-output', str(installed)], stem + '-install.log', 130)
            if json.loads(installed.read_text()).get('info', {}).get('outcome') != 'success':
                raise RuntimeError('安装未返回成功，请查看安装回执')
            row['installed'] = True
            print('安装成功：' + label, flush=True)
            if not args.no_launch:
                launch = run / (stem + '-launch.json')
                try:
                    logged(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', identifier, bundle, '--timeout', '30', '--json-output', str(launch)], stem + '-launch.log', 40)
                    row['launch'] = 'success'
                    print('启动成功', flush=True)
                except (subprocess.SubprocessError, OSError):
                    row['launch'] = 'needs_attention'
                    row['message'] = reason(launch)
                    print(row['message'], flush=True)
        except (subprocess.SubprocessError, OSError, RuntimeError, KeyError, ValueError) as error:
            row['error'] = str(error)
            print('未完成：' + label + '；' + str(error), flush=True)
        save()
except (subprocess.SubprocessError, OSError, RuntimeError, KeyError, ValueError) as error:
    receipt['error'] = str(error)
    print('安装流程错误：' + str(error), file=sys.stderr)
    save()
    sys.exit(1)

print('\n结果：', flush=True)
for row in receipt['devices']:
    state = '未安装'
    if row['installed']:
        state = {'success': '已安装并启动', 'needs_attention': '已安装，需要处理启动提示', 'not_attempted': '已安装，未尝试启动'}[row['launch']]
    print(row['name'] + '：' + state, flush=True)
print('完整回执：' + str(run / 'summary.json'), flush=True)
# 0 = installed and launched (or --no-launch); 2 = installed but user action needed;
# 1 = one or more installations failed. Never report an offline device as installed.
if any(not row['installed'] for row in receipt['devices']):
    sys.exit(1)
if any(row['launch'] == 'needs_attention' for row in receipt['devices']):
    sys.exit(2)
PY
