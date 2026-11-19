#!/usr/bin/env bash
# Build the pinned Hermes bridge and VM for Android x86_64 native validation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
: "${HERMES_HOST_COMPILERS:?set HERMES_HOST_COMPILERS to a native build ImportHostCompilers.cmake}"
SRC="${HERMES_SRC:-$ROOT/vendor/hermes}"
BUILD="${HERMES_BUILD:-$ROOT/.zig-cache/hermes-android-x86_64}"
PREFIX="${HERMES_PREFIX:-$ROOT/vendor/hermes-android-install-x86_64}"
ICU="${ICU_ANDROID_PREFIX:-$ROOT/vendor/icu-android-prefix-x86_64}"
API="${ANDROID_API:-24}"
HOST="${ANDROID_NDK_HOST_PREBUILT:-linux-x86_64}"
[[ -f "$HERMES_HOST_COMPILERS" && -f "$ICU/include/unicode/ucnv.h" ]] || { echo "Native hermesc export or Android ICU prefix missing" >&2; exit 1; }
for name in hermes-drain-microtasks-hint.patch hermes-cdp-frame-url.patch hermes-cdp-cancel-pending.patch hermes-debugger-step-out.patch; do
    if ! patch -d "$SRC" -p1 --reverse --dry-run < "$ROOT/vendor/$name" >/dev/null 2>&1; then
        patch -d "$SRC" -p1 --forward --batch < "$ROOT/vendor/$name"
    fi
done
cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=x86_64 -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DHERMES_ENABLE_DEBUGGER=ON -DHERMES_BUILD_SHARED_JSI=ON \
    -DICU_ROOT="$ICU" -DICU_INCLUDE_DIR="$ICU/include" \
    -DIMPORT_HOST_COMPILERS="$HERMES_HOST_COMPILERS"
cmake --build "$BUILD" --target hermesvm jsi compileJS -j"${JOBS:-4}"
mkdir -p "$PREFIX/lib" "$PREFIX/include/jsi" "$PREFIX/include/hermes"
cp -R "$SRC/include/hermes/". "$PREFIX/include/hermes/"
cp -R "$SRC/API/hermes/". "$PREFIX/include/hermes/"
cp -R "$SRC/public/hermes/". "$PREFIX/include/hermes/"
cp "$SRC/API/jsi/jsi/"*.h "$PREFIX/include/jsi/"
cp "$BUILD/lib/libhermesvm.so" "$BUILD/jsi/libjsi.so" "$PREFIX/lib/"
source "$ROOT/scripts/hermes-compilejs-libs.sh"
COMPILEJS_OUTPUT="$(hermes_compilejs_static_libs "$BUILD")"
mapfile -t COMPILEJS <<< "$COMPILEJS_OUTPUT"
CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST/bin/x86_64-linux-android$API-clang++"
"$CLANG" -DHERMES_ENABLE_DEBUGGER -shared -fPIC -std=c++17 -O0 -g \
    -I"$ROOT/src/backend/hermes" -I"$PREFIX/include" \
    -L"$PREFIX/lib" -L"$ICU/lib" -Wl,-rpath,'$ORIGIN' \
    -o "$PREFIX/lib/libhermes_bridge.so" \
    "$ROOT/src/backend/hermes/hermes_bridge.cpp" "$ROOT/src/backend/hermes/hermes_esm.cpp" \
    "$ROOT/src/backend/hermes/hermes_inspector.cpp" "${COMPILEJS[@]}" \
    -lhermesvm -ljsi
bash "$ROOT/scripts/native-prefix-stamp.sh" hermes write "$PREFIX"
echo "Hermes Android prefix ready: $PREFIX"
