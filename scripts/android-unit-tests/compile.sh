#!/usr/bin/env bash
# Cross-compile official `unit_tests` for Android x86_64 without a host run.
#
# Probes `zig build test-compile`, then replays the failed `zig test` command with an NDK --libc file, emit-bin, and the in-tree Android test runner.
#
# Does not change production build.zig or test assertions.
#
# Escargot: Android objects use emulated TLS. Zig compiler-rt emutls is not ABI-safe with Clang-generated __emutls_v (create/destroy SIGSEGV in ThreadLocal::emptyString). This replay links NDK compiler-rt builtins and passes -fno-compiler-rt, plus zig_probe_stack_x86_64.S for the only remaining Zig compiler-rt symbol (__zig_probe_stack). Product libjsbay.so is already NDK-linked and is not affected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/prepare-link-env.sh"

BACKEND="${1:?usage: compile.sh <quickjs|quickjs_ng|hermes|escargot>}"
OUT_DIR="$ANDROID_UNIT_TEST_OUT/$BACKEND"
OUT="$OUT_DIR/unit_tests"
LOG="${UNIT_TEST_COMPILE_LOG:-$ANDROID_UNIT_TEST_OUT/logs/compile-${BACKEND}-unit_tests.log}"
PROBE_LOG="$ANDROID_UNIT_TEST_OUT/logs/compile-${BACKEND}-test-compile-probe.log"
RUNNER="$SCRIPT_DIR/android_test_runner.zig"
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
  test-compile
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
    ZIG_FLAGS+=(-Descargot-install="$ESCARGOT_ANDROID_PREFIX")
    ;;
  quickjs|quickjs_ng) ;;
  *) echo "ERROR: unknown backend $BACKEND" >&2; exit 2 ;;
esac

echo "probe: zig build ${ZIG_FLAGS[*]}"
set +e
run_to 720 zig build "${ZIG_FLAGS[@]}" >"$PROBE_LOG" 2>&1
probe_rc=$?
set -e
echo "probe_exit=$probe_rc (expected non-zero: unable to provide libc)"
tail -30 "$PROBE_LOG" || true

if ! rg -q "^failed command: .*zig test " "$PROBE_LOG"; then
  echo "ERROR: probe did not yield a 'failed command: zig test ...' line" >&2
  echo "---- probe log ----"
  cat "$PROBE_LOG"
  exit 3
fi

set +e
run_to 720 python3 - "$PROBE_LOG" "$OUT" "$ANDROID_UNIT_TEST_LIBC" "$ANDROID_UNIT_TEST_EXELIB" "$RUNNER" "$PROBE_STACK_O" << 'REPLAY'
import shlex, sys, os
probe, out, libc, exelib, runner, probe_stack_o = sys.argv[1:7]
cmd_line = None
for line in open(probe, errors="replace"):
    if line.startswith("failed command: ") and "zig test " in line:
        cmd_line = line[len("failed command: "):].strip()
if not cmd_line:
    sys.exit("no failed zig test command")
args = shlex.split(cmd_line)
args = [a for a in args if a != "--listen=-"]
extras = [
    "--libc", libc,
    "-L", exelib,
    "--test-no-exec",
    f"-femit-bin={out}",
    "--test-runner", runner,
]
# Escargot unit_tests only: NDK emutls + __zig_probe_stack (see file header).
if out.rstrip("/").endswith("/escargot/unit_tests"):
    extras[4:4] = [
        "-lc++abi",
        "-llog",
        "-lunwind",
        "-lclang_rt.builtins-x86_64-android",
        "-fno-compiler-rt",
        probe_stack_o,
    ]
print("replay:", " ".join(shlex.quote(a) for a in args[:3]), "...", " ".join(shlex.quote(a) for a in extras))
sys.stdout.flush()
os.execv(args[0], args + extras)
REPLAY
replay_rc=$?
set -e

echo "compile_exit=$replay_rc"
if [[ "$replay_rc" -ne 0 ]]; then
  echo "ERROR: zig test replay failed; leaving any pre-existing $OUT untouched" >&2
  echo "===== done $(date -R) ====="
  exit "$replay_rc"
fi
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
exit "$replay_rc"
