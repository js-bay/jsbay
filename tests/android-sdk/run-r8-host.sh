#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="${1:?usage: run-r8-host.sh <libjsbay.a>}"
OUT="${ANDROID_R8_HOST_OUT:-${TMPDIR:-/tmp}/jsbay-android-r8-host}"
JDK_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
R8_JAR="${ANDROID_R8_JAR:-$SDK_ROOT/build-tools/35.0.0/lib/d8.jar}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:-$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d | head -1)}"
test -f "$R8_JAR"
RUNTIME_HOME="$("$JDK_HOME/bin/java" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.home = //p')"
test -d "$RUNTIME_HOME/jmods"
ANDROID_TEST_OUT="$OUT/base" "$ROOT/tests/android-sdk/run-host.sh" "$CORE"
mkdir -p "$OUT"
cat > "$OUT/main.pro" <<'EOF'
-keep class io.jsbay.consumer.HostLoopMain { public static void main(java.lang.String[]); }
-keep class android.os.Looper { *; }
-keep class android.os.Handler { *; }
EOF
cat "$ROOT/sdk/android/jsbay/consumer-rules.pro" >> "$OUT/main.pro"
"$JDK_HOME/bin/java" -cp "$R8_JAR" com.android.tools.r8.R8 --release --classfile \
    --lib "$RUNTIME_HOME" --output "$OUT/consumer.jar" --pg-conf "$OUT/main.pro" \
    --pg-map-output "$OUT/mapping.txt" "$OUT/base/consumer.jar" \
    "$GRADLE_LIB/kotlin-stdlib-1.9.22.jar" "$GRADLE_LIB/annotations-24.0.1.jar"
if ! awk '/^io\.jsbay\.consumer\.JavaConsumer -> / { if ($3 != "io.jsbay.consumer.JavaConsumer:") found=1 } END { exit found ? 0 : 1 }' "$OUT/mapping.txt"; then
    echo "R8 did not rename the external Java consumer" >&2
    exit 1
fi
if ! awk '/^io\.jsbay\.LoopDriver -> / { if ($3 == "io.jsbay.LoopDriver:") found=1 } END { exit found ? 0 : 1 }' "$OUT/mapping.txt"; then
    echo "R8 did not retain the JNI-reflected LoopDriver" >&2
    exit 1
fi
"$JDK_HOME/bin/java" -Xcheck:jni -Djava.library.path="$OUT/base" -cp "$OUT/consumer.jar" io.jsbay.consumer.HostLoopMain
