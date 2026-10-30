#!/usr/bin/env bash
# Rebuild vendor/escargot-install from the pinned submodule (THREADING + GNU2 TLS).
# Fresh clone: git submodule update --init --recursive vendor/escargot
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ESCARGOT_SRC:-$ROOT/vendor/escargot}"
BUILD="${ESCARGOT_BUILD:-$ROOT/vendor/escargot-build}"
PREFIX="${ESCARGOT_PREFIX:-$ROOT/vendor/escargot-install}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "ERROR: Escargot sources missing at $SRC (init submodule vendor/escargot --recursive)" >&2
  exit 1
fi

mkdir -p "$BUILD" "$PREFIX/lib" "$PREFIX/include"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DESCARGOT_THREADING=ON \
  -DESCARGOT_TLS_ACCESS_BY_PTHREAD_KEY=ON \
  -DESCARGOT_TLS_ACCESS_BY_ADDRESS=OFF \
  -DESCARGOT_FORCE_TLS_DIALECT_GNU2=ON \
  -DESCARGOT_LIBICU_SUPPORT=OFF \
  -DESCARGOT_ENABLE_SHELL=ON
ninja -C "$BUILD" -j"$JOBS"

# Install headers + static libs into prefix (layout expected by build.zig addEscargotSources).
mkdir -p "$PREFIX/include" "$PREFIX/lib"
if [[ -d "$SRC/src/api" ]]; then
  # Public headers ship as EscargotPublic.h via install or source tree — prefer build/install.
  true
fi
# Copy artifacts used by jsbay (names from existing install layout).
for lib in libescargot.a libgc-lib.a liblibbf.a liblibsimdutf.a libruntime-icu-binder-static.a; do
  if [[ -f "$BUILD/$lib" ]]; then
    cp -f "$BUILD/$lib" "$PREFIX/lib/$lib"
  elif [[ -f "$BUILD/third_party/GCutil/$lib" ]]; then
    cp -f "$BUILD/third_party/GCutil/$lib" "$PREFIX/lib/$lib"
  else
    # search
    found="$(find "$BUILD" -name "$lib" -print -quit || true)"
    if [[ -n "$found" ]]; then cp -f "$found" "$PREFIX/lib/$lib"; else echo "WARN: missing $lib"; fi
  fi
done
# Headers: use existing install tree if present; else copy from src api + generated.
if [[ ! -f "$PREFIX/include/EscargotPublic.h" ]]; then
  if [[ -f "$SRC/src/api/EscargotPublic.h" ]]; then
    cp -f "$SRC/src/api/EscargotPublic.h" "$PREFIX/include/"
    # related public headers
    find "$SRC/src/api" -maxdepth 1 -name '*.h' -exec cp -f {} "$PREFIX/include/" \;
  fi
fi

# Bridge .o (static into Zig link). Needs g++ with local-exec TLS (GNU2).
: "${CXX:=g++}"
"$CXX" -c -std=c++17 -O0 -g -fPIC \
  -I "$ROOT/src/backend/escargot" -I "$PREFIX/include" \
  -o "$PREFIX/lib/escargot_bridge.o" \
  "$ROOT/src/backend/escargot/escargot_bridge.cpp"

echo "Escargot install ready: $PREFIX"
echo "Zig: export JSBAY_LIBSTDCXX=/path/to/libstdc++.a"
echo "     zig build test-engine -Dbackend=escargot -Dlibstdcxx=\"\$JSBAY_LIBSTDCXX\" -Descargot-install=$PREFIX"
