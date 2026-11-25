#!/usr/bin/env bash
# Build the pinned Escargot sources and current bridge for Android device tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK root}"
API="${ANDROID_API:-24}"
ABI="${ANDROID_ABI:-x86_64}"
[[ "$ABI" == x86_64 ]] || { echo "Unsupported Android test ABI: $ABI" >&2; exit 2; }
[[ "$API" =~ ^[0-9]+$ && "$API" -ge 24 ]] || { echo "Android API must be at least 24" >&2; exit 2; }
HOST="${ANDROID_NDK_HOST_PREBUILT:-linux-x86_64}"
SRC="${ESCARGOT_SRC:-$ROOT/vendor/escargot}"
BUILD="${ESCARGOT_BUILD:-$ROOT/.zig-cache/escargot-android-$ABI-api$API}"
PREFIX="${ESCARGOT_PREFIX:-$ROOT/vendor/escargot-android-install-$ABI}"
CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST/bin/$ABI-linux-android$API-clang++"
[[ -x "$CLANG" && -f "$SRC/CMakeLists.txt" ]] || { echo "NDK compiler or pinned Escargot source missing" >&2; exit 1; }
for patch_name in escargot-debugger.patch escargot-default-async.patch escargot-module-bindings.patch escargot-execution-termination.patch; do
    PATCH="$ROOT/vendor/$patch_name"
    if ! patch -d "$SRC" -p1 --reverse --dry-run < "$PATCH" >/dev/null 2>&1; then
        patch -d "$SRC" -p1 --forward --batch < "$PATCH"
    fi
done

CMAKE_FLAGS=()
if [[ -n "${PKG_CONFIG_EXECUTABLE:-}" ]]; then
    CMAKE_FLAGS+=("-DPKG_CONFIG_EXECUTABLE=$PKG_CONFIG_EXECUTABLE")
fi
cmake -S "$SRC" -B "$BUILD" -G Ninja     -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"     -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API"     -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF     -DESCARGOT_THREADING=ON -DESCARGOT_TLS_ACCESS_BY_PTHREAD_KEY=ON     -DESCARGOT_TLS_ACCESS_BY_ADDRESS=OFF -DESCARGOT_LIBICU_SUPPORT=OFF     -DESCARGOT_DEBUGGER=ON -DESCARGOT_CODE_CACHE=OFF -DESCARGOT_ENABLE_SHELL=OFF     "${CMAKE_FLAGS[@]}"
cmake --build "$BUILD" -j"${JOBS:-4}"
mkdir -p "$PREFIX/lib" "$PREFIX/include"
cp "$BUILD/libescargot.a" "$BUILD/liblibbf.a" "$BUILD/liblibsimdutf.a"     "$BUILD/third_party/GCutil/libgc-lib.a"     "$BUILD/third_party/runtime_icu_binder/libruntime-icu-binder-static.a" "$PREFIX/lib/"
cp "$SRC/src/api/"*.h "$PREFIX/include/"
"$CLANG" -c -std=c++17 -O0 -g -fPIC -DESCARGOT_DEBUGGER     -I"$ROOT/src/backend/escargot" -I"$PREFIX/include"     -o "$PREFIX/lib/escargot_bridge.o" "$ROOT/src/backend/escargot/escargot_bridge.cpp"
bash "$ROOT/scripts/native-prefix-stamp.sh" escargot write "$PREFIX"
echo "Escargot Android prefix ready: $PREFIX"
