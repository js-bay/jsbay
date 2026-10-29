#!/usr/bin/env bash
# TEST-ONLY: build arm64-v8a libjsbay.so with -Dfault-injection=true.
# Writes ONLY to a dedicated output dir. NEVER touches build-android/jniLibs (publish).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${1:-${JSBAY_ANDROID_FAULT_OUT:-/tmp/jsbay-android-fault-injection/jniLibs}}"
ANDROID_API_LEVEL=24
QUICKJS_BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"

case "$OUTPUT_DIR" in
  */build-android/jniLibs|*/build-android/jniLibs/*)
    echo "ERROR: refusing to write fault-injection .so into publish jniLibs: $OUTPUT_DIR" >&2
    exit 2
    ;;
esac
case "$QUICKJS_BACKEND" in
  quickjs_ng|quickjs) ;;
  *) echo "ERROR: QUICKJS_BACKEND must be quickjs_ng or quickjs" >&2; exit 2 ;;
esac

NDK_BIN=""
if [ -d "${ANDROID_NDK_HOME:-}" ]; then
  NDK_BIN="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 2 -name bin 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$NDK_BIN" ]; then
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
    [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
    NDK_BIN="$(ls -d "$sdk"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | tail -n 1 || true)"
    [ -n "$NDK_BIN" ] && break
  done
fi
CLANG="$NDK_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang"
test -x "$CLANG" || { echo "ERROR: NDK clang missing: $CLANG" >&2; exit 2; }
NDK_SYSROOT="$(cd "$NDK_BIN/../sysroot" && pwd)"

TEMP_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-fault-build.XXXXXX")"
trap 'rm -rf "$TEMP_BUILD"' EXIT
printf '{ global: jsbay_*; local: *; };\n' > "$TEMP_BUILD/exports.map"

mkdir -p "$TEMP_BUILD/arm-stub"
printf '/* empty libm stub for the static archive */\n' > "$TEMP_BUILD/arm-stub/libm_stub.c"
"$CLANG" -c "$TEMP_BUILD/arm-stub/libm_stub.c" -o "$TEMP_BUILD/arm-stub/libm_stub.o"
"$NDK_BIN/llvm-ar" rcs "$TEMP_BUILD/arm-stub/libm.a" "$TEMP_BUILD/arm-stub/libm_stub.o"

echo "==> zig build arm64 fault-injection (test-only)"
(cd "$ROOT" && zig build \
  -Dbackend="$QUICKJS_BACKEND" -Dshared=false -Doptimize=ReleaseFast -Dlibrary-only=true \
  -Dfault-injection=true \
  --prefix "$TEMP_BUILD/prefix" \
  -Dandroid-sysroot="$NDK_SYSROOT" \
  -Dandroid-lib-dir="$TEMP_BUILD/arm-stub" \
  -Dtarget=aarch64-linux-android.${ANDROID_API_LEVEL})

ARCHIVE="$TEMP_BUILD/prefix/lib/libjsbay.a"
test -f "$ARCHIVE"
if ! "$NDK_BIN/llvm-nm" "$ARCHIVE" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  echo "FAIL: fault-injection archive missing jsbay_test_trigger_native_fault" >&2
  exit 1
fi
echo "PASS: fault-injection archive has jsbay_test_trigger_native_fault"

OBJS="$(mktemp -d "$TEMP_BUILD/objects.XXXXXX")"
( cd "$OBJS" && "$NDK_BIN/llvm-ar" x "$ARCHIVE" )
find "$OBJS" -type f ! -name '*.o' -delete

mkdir -p "$OUTPUT_DIR/arm64-v8a"
OUT_SO="$OUTPUT_DIR/arm64-v8a/libjsbay.so"
"$CLANG" -shared "$OBJS"/*.o -Wl,-z,defs -Wl,-soname,libjsbay.so \
  "-Wl,--version-script=$TEMP_BUILD/exports.map" -lm -ldl -o "$OUT_SO"
# Skip check-c-abi: jsbay_test_trigger_native_fault is intentionally outside include/jsbay.h.
# Publish build-android.sh still runs check-c-abi and never enables fault-injection.

if ! "$NDK_BIN/llvm-nm" -D "$OUT_SO" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null \
  && ! "$NDK_BIN/llvm-nm" "$OUT_SO" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  echo "FAIL: fault-injection .so missing jsbay_test_trigger_native_fault" >&2
  exit 1
fi

# Keep the .a beside the .so for static harness linking.
cp "$ARCHIVE" "$OUTPUT_DIR/arm64-v8a/libjsbay.a"
printf '%s\n' "$QUICKJS_BACKEND" > "$OUTPUT_DIR/../backend" 2>/dev/null || true
echo "PASS: wrote test-only fault-injection arm64 libs to $OUTPUT_DIR/arm64-v8a"
ls -la "$OUTPUT_DIR/arm64-v8a"
