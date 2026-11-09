#!/usr/bin/env bash
# Rebuild vendor/hermes-install + libhermes_bridge.so from the pinned submodule.
# Requires ICU prefix (see scripts/rebuild-icu-prefix.sh) and g++ (libstdc++ EH shared with hermesvm).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${HERMES_SRC:-$ROOT/vendor/hermes}"
BUILD="${HERMES_BUILD:-$ROOT/vendor/hermes-build}"
PREFIX="${HERMES_PREFIX:-$ROOT/vendor/hermes-install}"
ICU="${JSBAY_ICU_PREFIX:-$ROOT/vendor/icu-prefix}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "ERROR: Hermes sources missing at $SRC (init submodule vendor/hermes)" >&2
  exit 1
fi
if [[ ! -d "$ICU/lib" ]]; then
  echo "ERROR: ICU prefix missing at $ICU/lib — run scripts/rebuild-icu-prefix.sh first" >&2
  exit 1
fi

mkdir -p "$BUILD" "$PREFIX"
# Bounded drainMicrotasks(maxMicrotasksHint) so hosts can honor execution deadlines between batches.
PATCH="$ROOT/vendor/hermes-drain-microtasks-hint.patch"
if [[ -f "$PATCH" ]]; then
  # Apply once; ignore "already applied" (exit 1 with --forward), fail on rejects.
  set +e
  out=$(patch -d "$SRC" -p1 --forward --batch < "$PATCH" 2>&1)
  rc=$?
  set -e
  printf '%s
' "$out"
  if [[ $rc -ne 0 && "$out" != *"previously applied"* && "$out" != *"Ignoring previously applied"* && "$out" != *"Reversed (or previously applied)"* ]]; then
    echo "ERROR: failed to apply $PATCH to $SRC (rc=$rc)" >&2
    exit 1
  fi
fi
PATCH="$ROOT/vendor/hermes-cdp-frame-url.patch"
if [[ -f "$PATCH" ]]; then
  if patch -d "$SRC" -p1 --reverse --dry-run < "$PATCH" >/dev/null 2>&1; then
    echo "Hermes frame URL patch already applied"
  else
    patch -d "$SRC" -p1 --forward --batch < "$PATCH"
  fi
fi
PATCH="$ROOT/vendor/hermes-cdp-cancel-pending.patch"
if [[ -f "$PATCH" ]]; then
  if patch -d "$SRC" -p1 --reverse --dry-run < "$PATCH" >/dev/null 2>&1; then
    echo "Hermes pending-command cancellation patch already applied"
  else
    patch -d "$SRC" -p1 --forward --batch < "$PATCH"
  fi
fi
PATCH="$ROOT/vendor/hermes-debugger-step-out.patch"
if patch -d "$SRC" -p1 --reverse --dry-run < "$PATCH" >/dev/null 2>&1; then
  echo "Hermes return breakpoint restoration patch already applied"
else
  patch -d "$SRC" -p1 --forward --batch < "$PATCH"
fi
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DHERMES_ENABLE_TEST=OFF \
  -DHERMES_ENABLE_DEBUGGER=ON \
  -DICU_ROOT="$ICU" \
  -DCMAKE_PREFIX_PATH="$ICU"
ninja -C "$BUILD" -j"$JOBS"
ninja -C "$BUILD" install

# Hermes installs the VM API but not JSI, while the bridge is compiled against
# both. Keep the prefix self-contained for the bridge and downstream linker.
mkdir -p "$PREFIX/include/jsi" "$PREFIX/lib"
cp -f "$SRC/API/jsi/jsi/"*.h "$PREFIX/include/jsi/"
JSI_LIB="$(find "$BUILD" -name 'libjsi.so' -print -quit)"
if [[ -z "$JSI_LIB" ]]; then
  echo "ERROR: Hermes build did not produce libjsi.so" >&2
  exit 1
fi
cp -f "$JSI_LIB" "$PREFIX/lib/"

: "${CXX:=g++}"
export JSBAY_ICU_LIB_DIR="${JSBAY_ICU_LIB_DIR:-$ICU/lib}"
"$CXX" -DHERMES_ENABLE_DEBUGGER -shared -fPIC -std=c++17 -O0 -g \
  -I "$ROOT/src/backend/hermes" -I "$PREFIX/include" \
  -L "$PREFIX/lib" -L "$JSBAY_ICU_LIB_DIR" \
  -Wl,-rpath,'$ORIGIN' -Wl,-rpath,"$JSBAY_ICU_LIB_DIR" \
  -o "$PREFIX/lib/libhermes_bridge.so" \
  "$ROOT/src/backend/hermes/hermes_bridge.cpp" "$ROOT/src/backend/hermes/hermes_esm.cpp" \
  "$ROOT/src/backend/hermes/hermes_inspector.cpp" \
  -lhermesvm -ljsi -lgcc_s

bash "$ROOT/scripts/native-prefix-stamp.sh" hermes write "$PREFIX"

echo "Hermes install ready: $PREFIX (bridge: libhermes_bridge.so)"
echo "Zig: export JSBAY_LIBSTDCXX=/path/to/libstdc++.a"
echo "     export JSBAY_ICU_LIB_DIR=$JSBAY_ICU_LIB_DIR"
echo "     zig build test-engine -Dbackend=hermes -Dlibstdcxx=\"\$JSBAY_LIBSTDCXX\" -Dicu-lib-dir=\"\$JSBAY_ICU_LIB_DIR\" -Dhermes-install=$PREFIX"
echo "Optional: -Dhermes-max-heap=N  or EngineConfig.max_heap_size / js_bay_engine_create2"
