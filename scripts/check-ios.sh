#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:---build}
case "$MODE" in
    --build|--run|--test) ;;
    *) echo "用法：sh scripts/check-ios.sh [--build | --run [模拟器 UDID] | --test [模拟器 UDID]]" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != Darwin ]; then
    echo "需要在 macOS 上运行，并安装完整 Xcode。" >&2
    exit 1
fi

# Use a local override instead of changing the machine's global developer directory.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        export DEVELOPER_DIR
    fi
fi
if ! xcodebuild -version; then
    echo "未找到可用 Xcode。请安装并首次打开 Xcode，完成组件安装。" >&2
    echo "若安装在其他位置：DEVELOPER_DIR='/完整路径/Xcode.app/Contents/Developer' sh scripts/check-ios.sh" >&2
    exit 1
fi

DERIVED_DATA="$ROOT/.build/DerivedData"
for FRAMEWORK in module_spplinkKit SoundcoreWorkAppleSDK libopus; do
    if [ ! -d "$ROOT/ios/Vendor/$FRAMEWORK.xcframework" ]; then
        echo "缺少 $FRAMEWORK，请先运行 sh scripts/prepare-soundcore.sh 和 sh scripts/build-opus.sh。" >&2
        exit 1
    fi
done
DESTINATION='generic/platform=iOS Simulator'
if [ "$MODE" != --build ]; then
    DEVICE=${2:-}
    if [ -z "$DEVICE" ]; then
        DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [device for group in json.load(sys.stdin)["devices"].values()
           for device in group if device.get("isAvailable") and "iPhone" in device["name"]]
devices.sort(key=lambda device: device["state"] != "Booted")
if not devices:
    sys.exit("没有可用 iPhone 模拟器，请在 Xcode Settings > Components 中安装 iOS 运行时。")
print(devices[0]["udid"])
')
    fi
    DESTINATION="platform=iOS Simulator,id=$DEVICE"
fi

if [ "$MODE" = --test ]; then
    RESULT="$ROOT/.build/TestResults/CanDid-$(date +%Y%m%d-%H%M%S).xcresult"
    mkdir -p "$ROOT/.build/TestResults"
    xcodebuild -project "$ROOT/ios/CanDid.xcodeproj" -scheme CanDid \
        -configuration Debug -sdk iphonesimulator -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$RESULT" \
        -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
    echo "测试结果：$RESULT"
else
    xcodebuild -project "$ROOT/ios/CanDid.xcodeproj" -scheme CanDid \
        -configuration Debug -sdk iphonesimulator -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
fi

if [ "$MODE" = --run ]; then
    # bootstatus -b boots a shutdown device and waits for it to become ready.
    xcrun simctl bootstatus "$DEVICE" -b
    DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
    SIMULATOR_APP=""
    for APP_PATH in "$DEVELOPER_PATH/Applications/Simulator.app" \
        "$DEVELOPER_PATH/../Applications/DeviceHub.app"; do
        if [ -d "$APP_PATH" ]; then
            SIMULATOR_APP="$APP_PATH"
            break
        fi
    done
    if [ -z "$SIMULATOR_APP" ]; then
        echo "未找到 Simulator 或 Device Hub，请检查 Xcode 安装。" >&2
        exit 1
    fi
    open -a "$SIMULATOR_APP"
    xcrun simctl install "$DEVICE" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CanDid.app"
    xcrun simctl launch "$DEVICE" com.candid.memory.prototype
    echo "App 已启动；请按 README 的验收步骤检查页面和录音。启动成功不代表 soundcore 硬件验证通过。"
fi
