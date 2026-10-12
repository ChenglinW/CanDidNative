#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
VERSION=1.6.1
SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
WORK="$ROOT/.build/opus"
ARCHIVE="$WORK/opus-$VERSION.tar.gz"
mkdir -p "$WORK" "$ROOT/ios/Vendor/opus/include"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --retry 2 --output "$ARCHIVE" "https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz"
fi
ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
[ "$ACTUAL" = "$SHA256" ] || { echo "libopus 源码校验失败" >&2; exit 1; }
if [ ! -d "$WORK/opus-$VERSION" ]; then tar -xzf "$ARCHIVE" -C "$WORK"; fi
SOURCE="$WORK/opus-$VERSION"
cp "$SOURCE"/include/*.h "$ROOT/ios/Vendor/opus/include/"
cp "$SOURCE/COPYING" "$ROOT/ios/Vendor/opus/"

for SLICE in device-arm64 simulator-arm64 simulator-x86_64; do
    case "$SLICE" in
        device-arm64) SDK=iphoneos; TARGET=arm64-apple-ios17.0; HOST=aarch64-apple-darwin ;;
        simulator-arm64) SDK=iphonesimulator; TARGET=arm64-apple-ios17.0-simulator; HOST=aarch64-apple-darwin ;;
        simulator-x86_64) SDK=iphonesimulator; TARGET=x86_64-apple-ios17.0-simulator; HOST=x86_64-apple-darwin ;;
    esac
    BUILD="$WORK/$SLICE"
    mkdir -p "$BUILD"
    if [ ! -f "$BUILD/.libs/libopus.a" ]; then
        SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
        COMPILER=$(xcrun --sdk "$SDK" --find clang)
        (cd "$BUILD"
            CC="$COMPILER" CFLAGS="-O2 -target $TARGET -isysroot $SDK_PATH" \
                LDFLAGS="-target $TARGET -isysroot $SDK_PATH" \
                "$SOURCE/configure" --host="$HOST" --disable-shared --enable-static \
                --disable-extra-programs --disable-doc --disable-asm --disable-rtcd \
                --disable-intrinsics
            make -j4
        ) > "$WORK/$SLICE.log" 2>&1 || { tail -n 30 "$WORK/$SLICE.log" >&2; exit 1; }
    fi
done
mkdir -p "$WORK/simulator"
xcrun lipo -create "$WORK/simulator-arm64/.libs/libopus.a" "$WORK/simulator-x86_64/.libs/libopus.a" -output "$WORK/simulator/libopus.a"
if [ ! -d "$ROOT/ios/Vendor/libopus.xcframework" ]; then
    xcodebuild -create-xcframework \
        -library "$WORK/device-arm64/.libs/libopus.a" -headers "$ROOT/ios/Vendor/opus/include" \
        -library "$WORK/simulator/libopus.a" -headers "$ROOT/ios/Vendor/opus/include" \
        -output "$ROOT/ios/Vendor/libopus.xcframework"
fi
echo "libopus $VERSION 已生成，支持 iPhone 与 Intel/Apple Silicon 模拟器。"
