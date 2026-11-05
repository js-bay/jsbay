#!/usr/bin/env bash
# Build a local ICU prefix for Hermes (libicuuc/icui18n/icudata).
# Default: ICU 73 sources from GitHub release tarball into vendor/icu-prefix.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${ICU_PREFIX:-$ROOT/vendor/icu-prefix}"
VER="${ICU_VERSION:-73.2}"
SRC_DIR="${ICU_SRC:-$ROOT/vendor/icu-src}"
BUILD="${ICU_BUILD:-$ROOT/vendor/icu-build}"

mkdir -p "$(dirname "$SRC_DIR")"
if [[ ! -f "$SRC_DIR/source/configure" ]]; then
  url="https://github.com/unicode-org/icu/releases/download/release-${VER//./-}/icu4c-${VER//./_}-src.tgz"
  echo "Downloading $url"
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$url"
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  tar -xzf "$tmp" -C "$SRC_DIR" --strip-components=1
  rm -f "$tmp"
fi

mkdir -p "$BUILD"
cd "$BUILD"
"$SRC_DIR/source/configure" --prefix="$PREFIX" --disable-samples --disable-tests
make -j"$(nproc 2>/dev/null || echo 4)"
make install
echo "ICU ready: $PREFIX (export JSBAY_ICU_LIB_DIR=$PREFIX/lib)"
