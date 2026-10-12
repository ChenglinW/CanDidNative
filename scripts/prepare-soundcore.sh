#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_ROOT=${1:-"$ROOT/资料包/sdk/iosFrameworkExport-v1.3.01"}
mkdir -p "$ROOT/ios/Vendor"
for NAME in module_spplinkKit SoundcoreWorkAppleSDK; do
    case "$NAME" in
        module_spplinkKit) SOURCE="$SDK_ROOT/module_spplink_Release/$NAME.xcframework" ;;
        *) SOURCE="$SDK_ROOT/$NAME/$NAME.xcframework" ;;
    esac
    if [ ! -d "$SOURCE" ]; then
        echo "找不到 $SOURCE，请将 iOS v1.3.01 资料包放入项目，或传入 SDK 解压目录。" >&2
        exit 1
    fi
    if [ ! -d "$ROOT/ios/Vendor/$NAME.xcframework" ]; then
        cp -R "$SOURCE" "$ROOT/ios/Vendor/"
    fi
done
echo "soundcore v1.3.01 本地框架已准备；不复制或输出大赛 app_key。"
