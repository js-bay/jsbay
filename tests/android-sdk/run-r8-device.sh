#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JNI_LIBS="${1:?usage: run-r8-device.sh <jniLibs directory>}"
ADB="${ADB:-adb}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
JDK_HOME="${JAVA_HOME:?set JAVA_HOME to JDK 17}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:-$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d | head -1)}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-}"
OUT="${ANDROID_R8_TEST_OUT:-${TMPDIR:-/tmp}/jsbay-android-r8}"
REMOTE="${ANDROID_R8_TEST_REMOTE:-/data/local/tmp/jsbay-android-r8}"

test -n "$SDK_ROOT" && test -d "$SDK_ROOT"
test -x "$JDK_HOME/bin/java" && test -n "$GRADLE_LIB"
KOTLIN_STDLIB="$(find "$GRADLE_LIB" -maxdepth 1 -name 'kotlin-stdlib-*.jar' -print -quit)"
KOTLIN_ANNOTATIONS="$(find "$GRADLE_LIB" -maxdepth 1 -name 'annotations-*.jar' -print -quit)"
test -f "$KOTLIN_STDLIB" && test -f "$KOTLIN_ANNOTATIONS"
source "$ROOT/tests/android-sdk/android-device-lib.sh"
if [ -z "$BUILD_TOOLS" ]; then BUILD_TOOLS="$(find "$SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"; fi
test -f "$BUILD_TOOLS/lib/d8.jar" && "$ADB" get-state | grep -qx device
require_android_device_abi "$JNI_LIBS"

ANDROID_DEVICE_TEST_OUT="$OUT/base" ANDROID_DEVICE_TEST_REMOTE="$REMOTE/base" "$ROOT/tests/android-sdk/run-device.sh" "$JNI_LIBS"
mkdir -p "$OUT/dex"
printf '%s\n' \
    '-keep class io.jsbay.consumer.ConsumerMain { public static void main(java.lang.String[]); }' \
    '-keep class io.jsbay.consumer.DeviceLoopMain { public static void main(java.lang.String[]); }' > "$OUT/main.pro"
cat "$ROOT/sdk/android/jsbay/consumer-rules.pro" >> "$OUT/main.pro"
"$JDK_HOME/bin/java" -cp "$BUILD_TOOLS/lib/d8.jar" com.android.tools.r8.R8 --release --min-api 24 --lib "$SDK_ROOT/platforms/android-35/android.jar" --output "$OUT/dex" --pg-conf "$OUT/main.pro" --pg-map-output "$OUT/mapping.txt" "$OUT/base/consumer.jar" "$KOTLIN_STDLIB" "$KOTLIN_ANNOTATIONS"
test -s "$OUT/dex/classes.dex"
if strings "$OUT/dex/classes.dex" | grep -Eq 'Ljava/nio/file/(Files|Path);'; then
    echo 'R8 consumer DEX references an API 26 java.nio.file class' >&2
    exit 1
fi
(cd "$ROOT" && zig build tool -- check-r8 "$OUT/mapping.txt" "$OUT/base/consumer.jar")
"$ADB" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
push_android_device_payload "$OUT/dex/classes.dex" "$REMOTE/"
run_android_device_consumer "$REMOTE"
