#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-smoke-builder.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

test -n "${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
test -n "${ANDROID_BUILD_TOOLS:-}"
test -n "${KOTLIN_GRADLE_LIB:-}"
mkdir -p "$WORK/aar/jni/arm64-v8a" "$WORK/aar/jni/x86_64" "$WORK/bin"
for abi in arm64-v8a x86_64; do
    printf '%s\n' "$abi-core" > "$WORK/aar/jni/$abi/libjsbay.so"
    printf '%s\n' "$abi-adapter" > "$WORK/aar/jni/$abi/libjsbay_android.so"
done
(cd "$WORK/aar" && zip -qr "$WORK/sdk.aar" jni)
cat > "$WORK/bin/build-core" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="$1"
test ! -e "$out/arm64-v8a/libjsbay_android.so"
test ! -e "$out/x86_64/libjsbay_android.so"
for abi in arm64-v8a x86_64; do
    mkdir -p "$out/$abi"
    printf '%s\n' "$abi-core" > "$out/$abi/libjsbay.so"
done
printf '%s\n' "$out" >> "$ANDROID_SMOKE_TEST_LOG"
EOF
chmod +x "$WORK/bin/build-core"
export ANDROID_SMOKE_TEST_LOG="$WORK/builds"

for run in first second; do
    ANDROID_SMOKE_JNI_LIBS="$WORK/payload" \
        ANDROID_SMOKE_CORE_BUILDER="$WORK/bin/build-core" \
        ANDROID_SMOKE_AAR="$WORK/sdk.aar" \
        ANDROID_SMOKE_BUILD_ONLY=true \
        bash "$ROOT/tests/ci/run-android-device-smoke.sh"
done

test "$(wc -l < "$WORK/builds" | tr -d ' ')" = 2
for abi in arm64-v8a x86_64; do
    test "$(cat "$WORK/payload/$abi/libjsbay.so")" = "$abi-core"
    test "$(cat "$WORK/payload/$abi/libjsbay_android.so")" = "$abi-adapter"
done
echo 'PASS: Android smoke builder keeps core staging separate from payload'
