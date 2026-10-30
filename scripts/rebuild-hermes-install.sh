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
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DHERMES_ENABLE_TEST=OFF \
  -DICU_ROOT="$ICU" \
  -DCMAKE_PREFIX_PATH="$ICU"
ninja -C "$BUILD" -j"$JOBS"
ninja -C "$BUILD" install

: "${CXX:=g++}"
export JSBAY_ICU_LIB_DIR="${JSBAY_ICU_LIB_DIR:-$ICU/lib}"
"$CXX" -shared -fPIC -std=c++17 -O0 -g \
  -I "$ROOT/src/backend/hermes" -I "$PREFIX/include" \
  -L "$PREFIX/lib" -L "$JSBAY_ICU_LIB_DIR" \
  -Wl,-rpath,'$ORIGIN' -Wl,-rpath,"$JSBAY_ICU_LIB_DIR" \
  -o "$PREFIX/lib/libhermes_bridge.so" \
  "$ROOT/src/backend/hermes/hermes_bridge.cpp" "$ROOT/src/backend/hermes/hermes_esm.cpp" \
  -lhermesvm -ljsi -lgcc_s

echo "Hermes install ready: $PREFIX (bridge: libhermes_bridge.so)"
echo "Zig: export JSBAY_LIBSTDCXX=/path/to/libstdc++.a"
echo "     export JSBAY_ICU_LIB_DIR=$JSBAY_ICU_LIB_DIR"
echo "     zig build test-engine -Dbackend=hermes -Dlibstdcxx=\"\$JSBAY_LIBSTDCXX\" -Dicu-lib-dir=\"\$JSBAY_ICU_LIB_DIR\" -Dhermes-install=$PREFIX"
echo "Optional: -Dhermes-max-heap=N  or EngineConfig.max_heap_size / js_bay_engine_create2"
