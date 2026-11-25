#!/usr/bin/env bash
# Cross-compile official `unit_tests` for Android x86_64 without a host run.
#
# Uses the official Android test build step with an NDK libc description and the in-tree device test runner.
#
# Does not run device tests or change test assertions.
#
# Escargot: Android objects use emulated TLS. Zig compiler-rt emutls is not ABI-safe with Clang-generated __emutls_v (create/destroy SIGSEGV in ThreadLocal::emptyString). This build links NDK compiler-rt builtins and passes -fno-compiler-rt, plus zig_probe_stack_x86_64.S for the only remaining Zig compiler-rt symbol (__zig_probe_stack). Product libjsbay.so is already NDK-linked and is not affected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/prepare-link-env.sh"

BACKEND="${1:?usage: compile.sh <quickjs|quickjs_ng|hermes|escargot>}"
OUT_DIR="$ANDROID_UNIT_TEST_OUT/$BACKEND"
OUT="$OUT_DIR/unit_tests"
LOG="${UNIT_TEST_COMPILE_LOG:-$ANDROID_UNIT_TEST_OUT/logs/compile-${BACKEND}-unit_tests.log}"
PROBE_STACK_S="$SCRIPT_DIR/zig_probe_stack_x86_64.S"
PROBE_STACK_O="$ANDROID_UNIT_TEST_OUT/zig_probe_stack_x86_64.o"
mkdir -p "$OUT_DIR" "$ANDROID_UNIT_TEST_OUT/logs"

if [[ ! -f "$PROBE_STACK_O" || "$PROBE_STACK_S" -nt "$PROBE_STACK_O" ]]; then
  "$NDK_CLANG" -c "$PROBE_STACK_S" -o "$PROBE_STACK_O"
fi

TIMEOUT_BIN="$(command -v timeout || true)"
run_to() {
  local sec="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" -k 30 "$sec" "$@"
  else
    "$@"
  fi
}

exec > >(tee "$LOG") 2>&1
echo "===== compile unit_tests $BACKEND android --libc $(date -R) ====="
cd "$REPO"
unset HERMES_INSTALL ICU_PREFIX ESCARGOT_INSTALL JSBAY_ICU_LIB_DIR JSBAY_ICU_PREFIX

ZIG_FLAGS=(
  android-test-compile
  --prefix "$OUT_DIR"
  -Dandroid-test-libc="$ANDROID_UNIT_TEST_LIBC"
  -Dandroid-test-libdir="$ANDROID_UNIT_TEST_EXELIB"
  -Dbackend="$BACKEND"
  -Dtarget="${ANDROID_ABI}-linux-android.${ANDROID_API}"
  -Dcpu=baseline
  -Doptimize=ReleaseSafe
  -Dandroid-lib-dir="$ANDROID_UNIT_TEST_STUBS"
  -Dlibstdcxx="$LIBCXX_STATIC"
)

case "$BACKEND" in
  hermes)
    HERMES_ANDROID_PREFIX="${HERMES_ANDROID_PREFIX:-$REPO/vendor/hermes-android-install-x86_64}"
    ICU_ANDROID_PREFIX="${ICU_ANDROID_PREFIX:-$REPO/vendor/icu-android-prefix-x86_64}"
    ZIG_FLAGS+=(-Dhermes-install="$HERMES_ANDROID_PREFIX" -Dicu-lib-dir="$ICU_ANDROID_PREFIX/lib")
    ;;
  escargot)
    ESCARGOT_ANDROID_PREFIX="${ESCARGOT_ANDROID_PREFIX:-$REPO/vendor/escargot-android-install-x86_64}"
    ZIG_FLAGS+=(-Descargot-install="$ESCARGOT_ANDROID_PREFIX" -Dandroid-test-probe-stack="$PROBE_STACK_O")
    ;;
  quickjs|quickjs_ng) ;;
  *) echo "ERROR: unknown backend $BACKEND" >&2; exit 2 ;;
esac

echo "build: zig build ${ZIG_FLAGS[*]}"
run_to 720 zig build "${ZIG_FLAGS[@]}"
if [[ -f "$OUT" ]]; then
  ls -la "$OUT"
  readelf -h "$OUT" | rg "Class|Machine|Type" || echo "not_elf"
  readelf -d "$OUT" | rg "NEEDED" || true
  readelf -l "$OUT" | rg "interpreter" || true
  if ! readelf -h "$OUT" >/dev/null 2>&1; then
    echo "ERROR: emit-bin is not ELF" >&2
    exit 4
  fi
else
  echo "ERROR: missing $OUT" >&2
  exit 5
fi
echo "===== done $(date -R) ====="
exit 0
