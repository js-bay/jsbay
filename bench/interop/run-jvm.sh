#!/usr/bin/env bash
# Host-JVM public Android SDK benchmark. stdout is exactly five elapsed ns values.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
runner=${1:?usage: run-jvm.sh jvm_kotlin\|jvm_java quickjs\|quickjs_ng\|jsc}
backend=${2:-quickjs_ng}
case "$runner" in jvm_kotlin|jvm_java) ;; *) echo "unsupported JVM runner: $runner" >&2; exit 64 ;; esac
case "$backend" in quickjs|quickjs_ng|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac

jdk_home=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}
test -x "$jdk_home/bin/java"
test -x "$jdk_home/bin/javac"
gradle_lib=${KOTLIN_GRADLE_LIB:-}
if [ -z "$gradle_lib" ]; then
  gradle_lib=$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d -print -quit 2>/dev/null || true)
fi
test -n "$gradle_lib" && test -f "$gradle_lib/kotlin-stdlib-1.9.22.jar"

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-jvm-interop.XXXXXX")
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
classes="$work/classes"
mkdir -p "$classes"
zig build --prefix "$prefix" -Dlibrary-only=true -Dshared=false "-Dbackend=$backend" -Doptimize=ReleaseFast >&2
link_flags=(-lm)
if [ "$backend" = jsc ]; then link_flags+=(-framework JavaScriptCore); fi
cc -std=c11 -Wall -Wextra -Werror -fPIC -shared \
  -I"$jdk_home/include" -I"$jdk_home/include/darwin" -I"$root/include" \
  "$root/sdk/android/jsbay/src/main/cpp/jsbay_android.c" "$prefix/lib/libjsbay.a" "${link_flags[@]}" \
  -o "$work/libjsbay_android.dylib" >&2

kotlin_cp="$gradle_lib/kotlin-stdlib-1.9.22.jar:$gradle_lib/annotations-24.0.1.jar"
sdk_sources=("$root"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt)
if [ "$runner" = jvm_kotlin ]; then
  "$jdk_home/bin/java" -cp "$gradle_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -classpath "$kotlin_cp" -d "$classes" "${sdk_sources[@]}" \
    "$root/bench/interop/jvm/KotlinInteropBench.kt" >&2
  main_class=io.jsbay.interop.KotlinInteropBenchKt
else
  "$jdk_home/bin/java" -cp "$gradle_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -no-stdlib -classpath "$kotlin_cp" -d "$classes" "${sdk_sources[@]}" >&2
  "$jdk_home/bin/javac" -encoding UTF-8 -cp "$classes:$kotlin_cp" -d "$classes" \
    "$root/bench/interop/jvm/JavaInteropBench.java" >&2
  main_class=io.jsbay.interop.JavaInteropBench
fi
"$jdk_home/bin/java" -Xcheck:jni -Djava.library.path="$work" -cp "$classes:$kotlin_cp" "$main_class"
