#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
JNI_LIBS="${ANDROID_SMOKE_JNI_LIBS:-$ROOT/build-android/jniLibs}"
CORE_BUILDER="${ANDROID_SMOKE_CORE_BUILDER:-$ROOT/build-android.sh}"
ANDROID_AAR="${ANDROID_SMOKE_AAR:-}"
GRADLE_BIN="${GRADLE_BIN:-}"
NDK_HOME="${ANDROID_NDK_HOME:-$SDK_ROOT/ndk/28.2.13676358}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-$SDK_ROOT/build-tools/35.0.0}"

test -d "$SDK_ROOT"
test -x "$BUILD_TOOLS/d8"
export ANDROID_BUILD_TOOLS="$BUILD_TOOLS"
if [ -z "${KOTLIN_GRADLE_LIB:-}" ]; then
    test -x "$GRADLE_BIN"
    export KOTLIN_GRADLE_LIB="$(cd "$(dirname "$GRADLE_BIN")/../lib" && pwd)"
fi
test -d "$KOTLIN_GRADLE_LIB"

if [ "${ANDROID_SMOKE_SKIP_BUILD:-false}" != true ]; then
    test -d "$NDK_HOME"
    export ANDROID_NDK_HOME="$NDK_HOME"
    CORE_JNI_LIBS="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-core.XXXXXX")/jniLibs"
    trap 'rm -rf "${CORE_JNI_LIBS%/jniLibs}"' EXIT
    "$CORE_BUILDER" "$CORE_JNI_LIBS"
    if [ -z "$ANDROID_AAR" ]; then
        test -x "$GRADLE_BIN"
        "$GRADLE_BIN" --no-daemon -p "$ROOT/sdk/android" -PjsbayJniLibs="$CORE_JNI_LIBS" :jsbay:assembleRelease
        ANDROID_AAR="$ROOT/sdk/android/jsbay/build/outputs/aar/jsbay-release.aar"
    fi
    test -s "$ANDROID_AAR"
    for abi in arm64-v8a x86_64; do
        mkdir -p "$JNI_LIBS/$abi"
        unzip -p "$ANDROID_AAR" "jni/$abi/libjsbay.so" > "$JNI_LIBS/$abi/.libjsbay.so.$$"
        unzip -p "$ANDROID_AAR" "jni/$abi/libjsbay_android.so" > "$JNI_LIBS/$abi/.libjsbay_android.so.$$"
        test -s "$JNI_LIBS/$abi/.libjsbay.so.$$"
        mv "$JNI_LIBS/$abi/.libjsbay.so.$$" "$JNI_LIBS/$abi/libjsbay.so"
        mv "$JNI_LIBS/$abi/.libjsbay_android.so.$$" "$JNI_LIBS/$abi/libjsbay_android.so"
        test -s "$JNI_LIBS/$abi/libjsbay_android.so"
    done
fi

if [ "${ANDROID_SMOKE_BUILD_ONLY:-false}" = true ]; then
    exit 0
fi

bash "$ROOT/tests/android-sdk/run-r8-device.sh" "$JNI_LIBS"
