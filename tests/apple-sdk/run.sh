#!/bin/bash
# Run both public Apple language consumers against a supplied core archive. For iOS Simulator, build a UIKit app; build-apple.sh installs and runs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="${1:?core archive required}"
OUTPUT="${2:?output directory required}"
BACKEND="${3:-quickjs_ng}"
PLATFORM="${4:-macosx}"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
mkdir -p "$OUTPUT"
machine="$(uname -m)"
case "$machine" in
    arm64|aarch64) host_arch=arm64 ;;
    x86_64) host_arch=x86_64 ;;
    *)
        echo "Unsupported host machine for Apple consumers: $machine" >&2
        exit 2
        ;;
esac
if [ "$PLATFORM" = iphonesimulator ]; then
    if [ "$host_arch" = arm64 ]; then
        TARGET=arm64-apple-ios13.0-simulator
        ZIG_TARGET=aarch64-ios.13.0-simulator
    else
        TARGET=x86_64-apple-ios13.0-simulator
        ZIG_TARGET=x86_64-ios.13.0-simulator
    fi
elif [ "$PLATFORM" = iphoneos ]; then
    TARGET=arm64-apple-ios13.0
    ZIG_TARGET=aarch64-ios.13.0
elif [ "$PLATFORM" = macosx ]; then
    TARGET="${host_arch}-apple-macos11.0"
else
    echo "Unsupported consumer platform: $PLATFORM" >&2
    exit 2
fi
SWIFT_FLAGS=(-swift-version 5 -target "$TARGET" -sdk "$SDK" -I"$ROOT/include")
CLANG_FLAGS=(-target "$TARGET" -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/include" -I"$ROOT/sdk/apple/Sources/JsBayObjC/include")
BACKEND_FLAGS=(-DJSBAY_WITH_BYTECODE_CACHE)
if [ "$BACKEND" = jsc ]; then BACKEND_FLAGS=(-DJSBAY_NO_BYTECODE_CACHE); fi

xcrun --sdk "$PLATFORM" swiftc "${SWIFT_FLAGS[@]}" -emit-library -static -emit-module \
    -module-name JsBaySDK "$ROOT/sdk/apple/Sources/JsBaySDK/JsBaySDK.swift" \
    -emit-module-path "$OUTPUT/JsBaySDK.swiftmodule" -o "$OUTPUT/libJsBaySDK.a"

if [ "$PLATFORM" = macosx ]; then
    xcrun --sdk "$PLATFORM" swiftc "${SWIFT_FLAGS[@]}" "${BACKEND_FLAGS[@]}" -parse-as-library \
        -I"$OUTPUT" "$ROOT/tests/apple-sdk/SwiftConsumer.swift" "$OUTPUT/libJsBaySDK.a" "$ARCHIVE" \
        -framework JavaScriptCore -Xlinker -lm -o "$OUTPUT/swift-consumer"
    "$OUTPUT/swift-consumer"
    xcrun --sdk "$PLATFORM" clang "${CLANG_FLAGS[@]}" "${BACKEND_FLAGS[@]}" \
        "$ROOT/sdk/apple/Sources/JsBayObjC/JSBay.m" "$ROOT/tests/apple-sdk/ObjectiveCConsumer.m" \
        "$ARCHIVE" -framework Foundation -framework JavaScriptCore -lm -o "$OUTPUT/objc-consumer"
    "$OUTPUT/objc-consumer"
    bash "$ROOT/tests/apple-sdk/allocation-failure.sh" "$ARCHIVE" "$OUTPUT/allocation-failure"
else
    ZIG_LIB="$(zig env | sed -n 's/.*\.lib_dir = "\([^"]*\)".*/\1/p')"
    OVERLAY="$OUTPUT/zig-ios-stdlib"
    (cd "$ROOT" && zig build tool -- prepare-ios-stdlib "$ZIG_LIB/std/process.zig" "$OVERLAY")
    zig build-obj --zig-lib-dir "$OVERLAY" -target "$ZIG_TARGET" -O ReleaseSafe \
        "$ROOT/tests/apple-sdk/ios_io_compat.zig" -femit-bin="$OUTPUT/ios-io-compat.o"
    xcrun --sdk "$PLATFORM" swiftc "${SWIFT_FLAGS[@]}" "${BACKEND_FLAGS[@]}" -parse-as-library \
        -DJSBAY_SDK_APP_CONSUMER -emit-object -I"$OUTPUT" "$ROOT/tests/apple-sdk/SwiftConsumer.swift" -o "$OUTPUT/swift-consumer.o"
    xcrun --sdk "$PLATFORM" clang "${CLANG_FLAGS[@]}" -c "$ROOT/sdk/apple/Sources/JsBayObjC/JSBay.m" -o "$OUTPUT/objc-sdk.o"
    xcrun --sdk "$PLATFORM" clang "${CLANG_FLAGS[@]}" "${BACKEND_FLAGS[@]}" -DJSBAY_SDK_PROBE_NO_MAIN \
        -c "$ROOT/tests/apple-sdk/ObjectiveCConsumer.m" -o "$OUTPUT/objc-consumer.o"
    xcrun --sdk "$PLATFORM" clang -target "$TARGET" -isysroot "$SDK" -I"$ROOT/include" \
        -DJSBAY_APPLE_CONSUMER_NO_MAIN -c "$ROOT/scripts/apple_consumer_probe.c" -o "$OUTPUT/c-consumer.o"
    xcrun --sdk "$PLATFORM" clang "${CLANG_FLAGS[@]}" -DJSBAY_WITH_SDK_PROBES -DJSBAY_WITH_IOS_IO_PROBE \
        -c "$ROOT/scripts/apple_consumer_ios_main.m" -o "$OUTPUT/main.o"
    APP="$OUTPUT/JsBayAppleConsumer.app"
    mkdir -p "$APP"
    cp "$ROOT/scripts/apple_consumer_ios_Info.plist" "$APP/Info.plist"
    xcrun --sdk "$PLATFORM" swiftc "${SWIFT_FLAGS[@]}" "$OUTPUT/swift-consumer.o" "$OUTPUT/objc-sdk.o" \
        "$OUTPUT/objc-consumer.o" "$OUTPUT/c-consumer.o" "$OUTPUT/main.o" "$OUTPUT/ios-io-compat.o" "$OUTPUT/libJsBaySDK.a" "$ARCHIVE" \
        -framework Foundation -framework UIKit -framework JavaScriptCore -Xlinker -lm -o "$APP/JsBayAppleConsumer"
    codesign -s - --force --deep "$APP"
fi
