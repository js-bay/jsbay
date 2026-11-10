#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JNI_LIBS="${1:?usage: run-inspector-device.sh <jniLibs directory>}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?set ANDROID_SDK_ROOT or ANDROID_HOME}}"
JDK_HOME="${JAVA_HOME:?set JAVA_HOME to JDK 17 or newer}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:?set KOTLIN_GRADLE_LIB to the Gradle lib directory}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-$SDK_ROOT/build-tools/35.0.0}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-inspector-device.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/classes" "$OUT/dex"
KOTLIN_STDLIB="$(find "$GRADLE_LIB" -maxdepth 1 -name 'kotlin-stdlib-*.jar' -print -quit)"
KOTLIN_ANNOTATIONS="$(find "$GRADLE_LIB" -maxdepth 1 -name 'annotations-*.jar' -print -quit)"
test -f "$KOTLIN_STDLIB" && test -f "$KOTLIN_ANNOTATIONS"
"$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib \
    -classpath "$SDK_ROOT/platforms/android-35/android.jar:$KOTLIN_STDLIB:$KOTLIN_ANNOTATIONS" \
    -d "$OUT/classes" "$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt "$ROOT/tests/android-sdk/InspectorMain.kt"
"$JDK_HOME/bin/jar" --create --file "$OUT/inspector.jar" -C "$OUT/classes" .
"$BUILD_TOOLS/d8" --min-api 24 --output "$OUT/dex" "$OUT/inspector.jar" "$KOTLIN_STDLIB" "$KOTLIN_ANNOTATIONS"
node "$ROOT/tests/inspector/android_driver.cjs" "$JNI_LIBS" "$OUT/dex/classes.dex"
