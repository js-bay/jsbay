#!/usr/bin/env bash
# Push a cross-compiled unit_tests ELF to a booted x86_64 Android emulator/device and run it. Counts come from actual device execution (compile is not a pass).
#
# Isolation + per-test timeout so one crash/hang does not abort the rest.
#
# Official runs must push docs/state-tcas-*.md next to the ELF: state_tcas picture.lock maps a missing docs file to PictureDrift. Do not create .state_tcas-update-pictures here.
#
# UNIT_TEST_ARGS is host-side and is expanded into the remote argv. For an official unfiltered run, invoke with `env -u UNIT_TEST_ARGS`. Prefer ANDROID_SERIAL so a second emulator is not selected. This is x86_64 verification, not ARM64 hardware.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# prepare-link-env.sh also sets REPO, LIBCXX_SHARED, and ANDROID_UNIT_TEST_OUT.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/prepare-link-env.sh"

BACKEND="${1:?usage: run-device.sh <quickjs|quickjs_ng|hermes|escargot> [per-test-timeout-s] [overall-timeout-s]}"
PER_TEST_TIMEOUT="${2:-180}"
OVERALL_TIMEOUT="${3:-2400}"
BIN="${UNIT_TEST_BIN:-$ANDROID_UNIT_TEST_OUT/$BACKEND/unit_tests}"
LOG="${UNIT_TEST_LOG:-$ANDROID_UNIT_TEST_OUT/logs/run-${BACKEND}-unit_tests.log}"
LIST_LOG="${UNIT_TEST_LIST_LOG:-$ANDROID_UNIT_TEST_OUT/logs/list-${BACKEND}-unit_tests.log}"
mkdir -p "$ANDROID_UNIT_TEST_OUT/logs"

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
echo "===== device unit_tests $BACKEND start $(date -R) ====="

[[ -f "$BIN" ]] || { echo "ERROR: missing $BIN (build with compile.sh first)" >&2; exit 1; }
if ! readelf -h "$BIN" | rg -q "Machine:.*X86-64"; then
  echo "ERROR: $BIN is not an x86_64 ELF — not ARM64 verification" >&2
  exit 1
fi

adb start-server >/dev/null
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  SERIAL="$ANDROID_SERIAL"
  st="$(adb -s "$SERIAL" get-state 2>/dev/null | tr -d '\r' || true)"
  if [[ "$st" != "device" ]]; then
    echo "ERROR: ANDROID_SERIAL=$SERIAL is not in 'device' state (got ${st:-missing})" >&2
    adb devices -l || true
    exit 2
  fi
else
  mapfile -t DEVS < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  if [[ ${#DEVS[@]} -eq 0 ]]; then
    echo "ERROR: no adb device in 'device' state" >&2
    adb devices -l || true
    exit 2
  fi
  SERIAL="${DEVS[0]}"
fi
ABI="$(adb -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')"
SDK="$(adb -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
echo "SERIAL=$SERIAL sdk=$SDK abi=$ABI"
if [[ "$ABI" != "x86_64" ]]; then
  echo "ERROR: expected x86_64 emulator, got $ABI — not ARM64 verification" >&2
  exit 3
fi

REMOTE="/data/local/tmp/jsbay-unit-$BACKEND"
adb -s "$SERIAL" shell "rm -rf $REMOTE && mkdir -p $REMOTE"
adb -s "$SERIAL" push "$BIN" "$REMOTE/unit_tests"
adb -s "$SERIAL" shell "chmod 755 $REMOTE/unit_tests"

push_so() {
  local src="$1"
  local name
  name="$(basename "$src")"
  [[ -e "$src" ]] || { echo "ERROR: missing dep $src" >&2; exit 1; }
  adb -s "$SERIAL" push "$src" "$REMOTE/$name"
}

case "$BACKEND" in
  hermes)
    HERMES_ANDROID_PREFIX="${HERMES_ANDROID_PREFIX:-$REPO/vendor/hermes-android-install-x86_64}"
    ICU_ANDROID_PREFIX="${ICU_ANDROID_PREFIX:-$REPO/vendor/icu-android-prefix-x86_64}"
    push_so "$HERMES_ANDROID_PREFIX/lib/libhermes_bridge.so"
    push_so "$HERMES_ANDROID_PREFIX/lib/libhermesvm.so"
    push_so "$HERMES_ANDROID_PREFIX/lib/libjsi.so"
    push_so "$LIBCXX_SHARED"
    push_so "$ICU_ANDROID_PREFIX/lib/libicuuc.so.73.2"
    push_so "$ICU_ANDROID_PREFIX/lib/libicui18n.so.73.2"
    push_so "$ICU_ANDROID_PREFIX/lib/libicudata.so.73.2"
    adb -s "$SERIAL" shell "cd $REMOTE && ln -sf libicuuc.so.73.2 libicuuc.so && ln -sf libicuuc.so.73.2 libicuuc.so.73 && ln -sf libicui18n.so.73.2 libicui18n.so && ln -sf libicui18n.so.73.2 libicui18n.so.73 && ln -sf libicudata.so.73.2 libicudata.so && ln -sf libicudata.so.73.2 libicudata.so.73"
    ;;
  escargot)
    if readelf -d "$BIN" | rg -q 'libc\+\+_shared\.so'; then
      push_so "$LIBCXX_SHARED"
    fi
    ;;
  quickjs|quickjs_ng) ;;
  *) echo "ERROR: unknown backend $BACKEND" >&2; exit 2 ;;
esac

if [[ ! -d "$REPO/docs" ]]; then
  echo "ERROR: missing $REPO/docs (required for state_tcas picture locks)" >&2
  exit 1
fi
adb -s "$SERIAL" shell "mkdir -p $REMOTE/docs"
docs_pushed=0
for doc in "$REPO/docs"/state-tcas-*.md; do
  [[ -f "$doc" ]] || continue
  adb -s "$SERIAL" push "$doc" "$REMOTE/docs/$(basename "$doc")"
  docs_pushed=$((docs_pushed+1))
done
if [[ "$docs_pushed" -eq 0 ]]; then
  echo "ERROR: no $REPO/docs/state-tcas-*.md lock files to push" >&2
  exit 1
fi
echo "pushed $docs_pushed state_tcas picture lock docs to $REMOTE/docs"

# Host RUNPATH on hermes points at the workstation prefix; override on device.
# env -u UNIT_TEST_ARGS avoids a leaked device-shell variable changing the filter.
ENV_PREFIX="cd $REMOTE && export TMPDIR=/data/local/tmp HOME=/data/local/tmp LD_LIBRARY_PATH=$REMOTE:\$LD_LIBRARY_PATH && env -u UNIT_TEST_ARGS"

echo "---- --list ----"
set +e
run_to 180 adb -s "$SERIAL" shell "$ENV_PREFIX ./unit_tests --list" | tee "$LIST_LOG"
list_rc=${PIPESTATUS[0]}
set -e
echo "list_exit=$list_rc"
if [[ "$list_rc" -ne 0 ]]; then
  echo "ERROR: --list failed; not counting as a test pass" >&2
  echo "===== done $(date -R) ====="
  exit 4
fi

UNIT_TEST_ARGS="${UNIT_TEST_ARGS:-}"
echo "---- run --isolate --timeout=$PER_TEST_TIMEOUT $UNIT_TEST_ARGS (overall ${OVERALL_TIMEOUT}s) ----"
set +e
run_to "$OVERALL_TIMEOUT" adb -s "$SERIAL" shell "$ENV_PREFIX ./unit_tests --isolate --timeout=$PER_TEST_TIMEOUT $UNIT_TEST_ARGS"
run_rc=$?
set -e
echo "run_exit=$run_rc"
if [[ "$run_rc" -eq 124 ]]; then
  echo "OVERALL_TIMEOUT after ${OVERALL_TIMEOUT}s"
fi
echo "===== done $(date -R) ====="
exit "$run_rc"
