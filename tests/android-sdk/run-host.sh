#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="${1:?usage: run-host.sh <libjsbay.a>}"
OUT="${ANDROID_TEST_OUT:-${TMPDIR:-/tmp}/jsbay-android-host}"
JDK_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:-$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d | head -1)}"
test -x "$JDK_HOME/bin/java" && test -n "$GRADLE_LIB"
mkdir -p "$OUT/classes"
"$JDK_HOME/bin/javac" -encoding UTF-8 -d "$OUT/classes" "$ROOT"/tests/android-sdk/android/os/Handler.java "$ROOT"/tests/android-sdk/android/os/Looper.java "$ROOT"/tests/android-sdk/android/os/HandlerThread.java
"$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -classpath "$OUT/classes:$GRADLE_LIB/kotlin-stdlib-1.9.22.jar:$GRADLE_LIB/annotations-24.0.1.jar" -d "$OUT/classes" "$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt "$ROOT"/tests/android-sdk/KotlinConsumer.kt
"$JDK_HOME/bin/javac" -encoding UTF-8 -cp "$OUT/classes:$GRADLE_LIB/kotlin-stdlib-1.9.22.jar" -d "$OUT/classes" "$ROOT"/tests/android-sdk/JavaConsumer.java "$ROOT"/tests/android-sdk/ConsumerMain.java "$ROOT"/tests/android-sdk/HostLoopMain.java
cat > "$OUT/JavaHookNegative.java" <<'EOF'
package external;
import io.jsbay.Engine;
final class JavaHookNegative { void use(Engine engine) { engine.beginCallbackScopeForNative(); Engine.currentForNative(); } }
EOF
if "$JDK_HOME/bin/javac" -cp "$OUT/classes:$GRADLE_LIB/kotlin-stdlib-1.9.22.jar" -d "$OUT/negative-java" "$OUT/JavaHookNegative.java"; then echo "JNI hooks leaked to Java" >&2; exit 1; fi
cat > "$OUT/KotlinHookNegative.kt" <<'EOF'
package external
import io.jsbay.Engine
fun use(engine: Engine) { engine.beginCallbackScopeForNative(); Engine.currentForNative() }
EOF
if "$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -classpath "$OUT/classes:$GRADLE_LIB/kotlin-stdlib-1.9.22.jar:$GRADLE_LIB/annotations-24.0.1.jar" -d "$OUT/negative-kotlin" "$OUT/KotlinHookNegative.kt"; then echo "JNI hooks leaked to Kotlin" >&2; exit 1; fi
"$JDK_HOME/bin/jar" --create --file "$OUT/consumer.jar" -C "$OUT/classes" .
if [ -n "${JSBAY_ANDROID_TEST_FAIL_STAGE:-}" ]; then
    cc -std=c11 -Wall -Wextra -Werror -fPIC -shared "-DJSBAY_ANDROID_TEST_FAIL_STAGE=${JSBAY_ANDROID_TEST_FAIL_STAGE}" -I"$JDK_HOME/include" -I"$JDK_HOME/include/darwin" -I"$ROOT/include" "$ROOT/sdk/android/jsbay/src/main/cpp/jsbay_android.c" "$CORE" -lm -fsanitize=undefined -o "$OUT/libjsbay_android.dylib"
    JAVA_LOG="$OUT/jni-fault-java.log"
    if ! "$JDK_HOME/bin/java" -Xcheck:jni -Djava.library.path="$OUT" -Djsbay.android.bridgeFault=true -cp "$OUT/classes:$GRADLE_LIB/kotlin-stdlib-1.9.22.jar" io.jsbay.consumer.ConsumerMain >"$JAVA_LOG" 2>&1; then
        cat "$JAVA_LOG"
        exit 1
    fi
    cat "$JAVA_LOG"
    if awk '/WARNING in native method: JNI call made with exception pending/ { found=1 } END { exit found ? 0 : 1 }' "$JAVA_LOG"; then
        echo "JNI fault consumer left a pending exception" >&2
        exit 1
    fi
else
    cc -std=c11 -Wall -Wextra -Werror -fPIC -shared -I"$JDK_HOME/include" -I"$JDK_HOME/include/darwin" -I"$ROOT/include" "$ROOT/sdk/android/jsbay/src/main/cpp/jsbay_android.c" "$CORE" -lm -fsanitize=undefined -o "$OUT/libjsbay_android.dylib"
    "$JDK_HOME/bin/java" -Xcheck:jni -Djava.library.path="$OUT" -cp "$OUT/classes:$GRADLE_LIB/kotlin-stdlib-1.9.22.jar" io.jsbay.consumer.HostLoopMain
fi
