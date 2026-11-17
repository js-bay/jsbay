#!/usr/bin/env bash
# Prepare the Zig --libc file, Bionic name stubs, CRT name overlay, and exe-libdir needed to replay `zig build test-compile` for Android x86_64.
#
# Generates machine-local paths from ANDROID_NDK_HOME; does not record workstation prefixes in the repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the NDK root (e.g. .../ndk/28.2.13676358)}"
ANDROID_API="${ANDROID_API:-24}"
ANDROID_ABI="${ANDROID_ABI:-x86_64}"
if [[ "$ANDROID_ABI" != "x86_64" ]]; then
  echo "ERROR: official Android unit_tests replay currently supports ANDROID_ABI=x86_64 only (got $ANDROID_ABI)" >&2
  exit 2
fi

HOST_PREBUILT="${ANDROID_NDK_HOST_PREBUILT:-linux-x86_64}"
NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_PREBUILT}"
ANDROID_SYSROOT="${NDK_TOOLCHAIN}/sysroot"
NDK_BIN="${NDK_TOOLCHAIN}/bin"
NDK_CLANG="${NDK_BIN}/${ANDROID_ABI}-linux-android${ANDROID_API}-clang"
API_LIBDIR="${ANDROID_SYSROOT}/usr/lib/${ANDROID_ABI}-linux-android/${ANDROID_API}"
ABI_LIBDIR="${ANDROID_SYSROOT}/usr/lib/${ANDROID_ABI}-linux-android"

if [[ ! -x "$NDK_CLANG" ]]; then
  echo "ERROR: missing NDK clang $NDK_CLANG" >&2
  exit 1
fi
if [[ ! -d "$API_LIBDIR" ]]; then
  echo "ERROR: missing NDK lib dir $API_LIBDIR" >&2
  exit 1
fi

# clang resource dir (version folder varies by NDK).
mapfile -t BUILTINS < <(compgen -G "${NDK_TOOLCHAIN}/lib/clang/*/lib/linux/libclang_rt.builtins-${ANDROID_ABI}-android.a" || true)
if [[ ${#BUILTINS[@]} -ne 1 ]]; then
  echo "ERROR: expected exactly one libclang_rt.builtins-${ANDROID_ABI}-android.a under ${NDK_TOOLCHAIN}/lib/clang (found ${#BUILTINS[@]})" >&2
  exit 1
fi
CLANG_RT_BUILTINS="${BUILTINS[0]}"
CLANG_LINUX_DIR="$(dirname "$CLANG_RT_BUILTINS")"
UNWIND_A="${CLANG_LINUX_DIR}/${ANDROID_ABI}/libunwind.a"
if [[ ! -f "$UNWIND_A" ]]; then
  echo "ERROR: missing $UNWIND_A" >&2
  exit 1
fi

OUT="${ANDROID_UNIT_TEST_OUT:-$REPO/.zig-cache/android-unit-tests}"
CRT="$OUT/android-crt"
STUB="$OUT/bionic-stubs"
EXELIB="$OUT/exe-libdir"
LIBC_TXT="$OUT/android-libc.txt"
mkdir -p "$CRT" "$STUB" "$EXELIB"

# Empty stubs satisfy Zig -lpthread/-lrt/-lgcc_s (and -lm/-ldl for -Dandroid-lib-dir).
#
# Do not point -Dandroid-lib-dir at the real NDK lib dir or Zig may archive genuine .so files.
printf '/* empty stub for the static archive */\n' > "$STUB/stub.c"
"$NDK_CLANG" -c "$STUB/stub.c" -o "$STUB/stub.o"
for name in m pthread dl rt gcc_s; do
  "${NDK_BIN}/llvm-ar" rcs "$STUB/lib${name}.a" "$STUB/stub.o"
done

# Zig looks for GNU-style CRT names; Bionic ships crtbegin_dynamic / crtend_android.
# crti.o / crtn.o are not provided as separate NDK objects — emit empty ones.
"$NDK_CLANG" -c -x c /dev/null -o "$CRT/crti.o"
"$NDK_CLANG" -c -x c /dev/null -o "$CRT/crtn.o"
ln -sfn "${API_LIBDIR}/crtbegin_dynamic.o" "$CRT/crt1.o"
ln -sfn "${API_LIBDIR}/crtbegin_dynamic.o" "$CRT/crtbegin.o"
ln -sfn "${API_LIBDIR}/crtbegin_dynamic.o" "$CRT/crtbeginS.o"
ln -sfn "${API_LIBDIR}/crtbegin_dynamic.o" "$CRT/crtbegin_dynamic.o"
ln -sfn "${API_LIBDIR}/crtbegin_so.o" "$CRT/crtbegin_so.o"
ln -sfn "${API_LIBDIR}/crtbegin_static.o" "$CRT/crtbegin_static.o"
ln -sfn "${API_LIBDIR}/crtend_android.o" "$CRT/crtend.o"
ln -sfn "${API_LIBDIR}/crtend_android.o" "$CRT/crtendS.o"
ln -sfn "${API_LIBDIR}/crtend_android.o" "$CRT/crtend_android.o"
ln -sfn "${API_LIBDIR}/crtend_so.o" "$CRT/crtend_so.o"
ln -sfn "${API_LIBDIR}/crt_pad_segment.o" "$CRT/crt_pad_segment.o"

link_into() {
  local dest="$1" src="$2"
  [[ -e "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }
  ln -sfn "$src" "$dest"
}

# CRT dir also needs the libs Zig's libc file may look up next to the CRT objects.
link_into "$CRT/libc.so" "${API_LIBDIR}/libc.so"
link_into "$CRT/libdl.so" "${API_LIBDIR}/libdl.so"
link_into "$CRT/libm.so" "${API_LIBDIR}/libm.so"
link_into "$CRT/liblog.so" "${API_LIBDIR}/liblog.so"
link_into "$CRT/libclang_rt.builtins-${ANDROID_ABI}-android.a" "$CLANG_RT_BUILTINS"
link_into "$CRT/libunwind.a" "$UNWIND_A"

# exe-libdir: real Bionic/NDK libs for the replay link, plus stubs for glibc-only names.
link_into "$EXELIB/libc.so" "${API_LIBDIR}/libc.so"
link_into "$EXELIB/libdl.so" "${API_LIBDIR}/libdl.so"
link_into "$EXELIB/libm.so" "${API_LIBDIR}/libm.so"
link_into "$EXELIB/liblog.so" "${API_LIBDIR}/liblog.so"
link_into "$EXELIB/libz.so" "${API_LIBDIR}/libz.so"
link_into "$EXELIB/libc++.a" "${API_LIBDIR}/libc++.a"
link_into "$EXELIB/libc++.so" "${API_LIBDIR}/libc++.so"
link_into "$EXELIB/libc++abi.a" "${ABI_LIBDIR}/libc++abi.a"
link_into "$EXELIB/libc++_static.a" "${ABI_LIBDIR}/libc++_static.a"
link_into "$EXELIB/libc++_shared.so" "${ABI_LIBDIR}/libc++_shared.so"
link_into "$EXELIB/libclang_rt.builtins-${ANDROID_ABI}-android.a" "$CLANG_RT_BUILTINS"
link_into "$EXELIB/libunwind.a" "$UNWIND_A"
link_into "$EXELIB/libpthread.a" "$STUB/libpthread.a"
link_into "$EXELIB/librt.a" "$STUB/librt.a"
link_into "$EXELIB/libgcc_s.a" "$STUB/libgcc_s.a"

# Zig --libc file (paths are local to this machine / NDK install).
cat > "$LIBC_TXT" <<LIBC
include_dir=${ANDROID_SYSROOT}/usr/include
sys_include_dir=${ANDROID_SYSROOT}/usr/include/${ANDROID_ABI}-linux-android
cc_dir=${CRT}
crt_dir=${CRT}
msvc_lib_dir=
kernel32_lib_dir=
darwin_sdk_dir=
LIBC

# Export locations for callers that source this script.
ANDROID_UNIT_TEST_OUT="$OUT"
ANDROID_UNIT_TEST_LIBC="$LIBC_TXT"
ANDROID_UNIT_TEST_EXELIB="$EXELIB"
ANDROID_UNIT_TEST_STUBS="$STUB"
ANDROID_UNIT_TEST_CRT="$CRT"
LIBCXX_STATIC="${ABI_LIBDIR}/libc++_static.a"
LIBCXX_SHARED="${ABI_LIBDIR}/libc++_shared.so"
NDK_TOOLCHAIN="$NDK_TOOLCHAIN"
NDK_CLANG="$NDK_CLANG"
ANDROID_SYSROOT="$ANDROID_SYSROOT"
export ANDROID_UNIT_TEST_OUT ANDROID_UNIT_TEST_LIBC ANDROID_UNIT_TEST_EXELIB ANDROID_UNIT_TEST_STUBS ANDROID_UNIT_TEST_CRT
export LIBCXX_STATIC LIBCXX_SHARED NDK_TOOLCHAIN NDK_CLANG ANDROID_SYSROOT ANDROID_API ANDROID_ABI REPO
echo "prepared Android unit_tests link env under $OUT"
