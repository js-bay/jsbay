#!/bin/bash
# Build the JS Bay C library for Android. JNI belongs to the host application. Usage: ./build-android.sh [output-dir] Optional env: QUICKJS_BACKEND, ANDROID_NDK_HOME / ANDROID_HOME,
#   RELEASE_VERSION, RELEASE_COMMIT (written beside jniLibs when set).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/build-android/jniLibs}"
PUBLISH_ABIS=(arm64-v8a x86_64)

# The Zig target uses Android Bionic (linux-android). Minimum OS is Android 7 (API 24). Headers, the Zig target, and the NDK clang wrapper all use that level so newer libc symbols stay out of the .so.
ANDROID_API_LEVEL=24
QUICKJS_BACKEND="${QUICKJS_BACKEND:-quickjs}"
case "$QUICKJS_BACKEND" in
    quickjs_ng|quickjs) ;;
    *)
        echo "ERROR: QUICKJS_BACKEND must be quickjs or quickjs_ng." >&2
        exit 2
        ;;
esac
# Product Android archives must NEVER pass -Dfault-injection=true (keeps jsbay_test_* out of jniLibs).
COMMON_FLAGS="-Dbackend=$QUICKJS_BACKEND -Dshared=false -Doptimize=ReleaseFast -Dlibrary-only=true"
TEMP_BUILD="$(mktemp -d)"
STAGING_ROOT="$(mktemp -d)"
STAGING_OUTPUT="$STAGING_ROOT/jniLibs"
trap 'rm -rf "$TEMP_BUILD" "$STAGING_ROOT"' EXIT
# Version script must list exact public C ABI symbols from headers (same set as check-c-abi).
# A jsbay_* wildcard would also export internal QuickJS wrappers named jsbay_qjs_*.
write_exports_map() {
    local out="$1"
    python3 - "$SCRIPT_DIR" "$out" <<'PY'
import pathlib, sys
repo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
names = ("jsbay.h", "jsbay_bytecode.h", "jsbay_sync.h")
symbols = []
seen = set()
for name in names:
    text = (repo / "include" / name).read_text(encoding="utf-8")
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise SystemExit(f"unterminated comment in {name}")
            i = j + 2
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if text.startswith("jsbay_", i):
            if i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
                i += 1
                continue
            start = i
            i += len("jsbay_")
            while i < n and (text[i].isalnum() or text[i] == "_"):
                i += 1
            sym = text[start:i]
            if sym.endswith("_t"):
                continue
            while i < n and text[i].isspace():
                i += 1
            if i < n and text[i] == "(" and sym not in seen:
                seen.add(sym)
                symbols.append(sym)
            continue
        i += 1
if not symbols:
    raise SystemExit("no public jsbay_* function symbols found in headers")
body = "\n".join(f"  {s};" for s in symbols)
out.write_text("{\n  global:\n" + body + "\n  local: *;\n};\n", encoding="utf-8")
PY
}
write_exports_map "$TEMP_BUILD/exports.map"

validate_output_dir() {
    [ ! -e "$OUTPUT_DIR" ] && return 0
    [ -d "$OUTPUT_DIR" ] || { echo "ERROR: output path is not a directory: $OUTPUT_DIR" >&2; return 1; }
    local entry name abi unexpected
    for entry in "$OUTPUT_DIR"/* "$OUTPUT_DIR"/.[!.]* "$OUTPUT_DIR"/..?*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        case "$name" in
            arm64-v8a|x86_64) ;;
            *) echo "ERROR: output directory contains unsupported ABI or file: $name" >&2; return 1 ;;
        esac
    done
    for abi in "${PUBLISH_ABIS[@]}"; do
        [ ! -e "$OUTPUT_DIR/$abi" ] && continue
        [ -d "$OUTPUT_DIR/$abi" ] || { echo "ERROR: output ABI path is not a directory: $abi" >&2; return 1; }
        unexpected="$(find "$OUTPUT_DIR/$abi" -mindepth 1 -maxdepth 1 ! -name libjsbay.so -print -quit)"
        [ -z "$unexpected" ] || { echo "ERROR: output ABI directory contains an unexpected member: $unexpected" >&2; return 1; }
    done
}

publish_staged_output() {
    local abi staged temporary
    validate_output_dir
    for abi in "${PUBLISH_ABIS[@]}"; do
        staged="$STAGING_OUTPUT/$abi/libjsbay.so"
        [ -f "$staged" ] || { echo "ERROR: missing staged library for $abi" >&2; return 1; }
    done
    for abi in "${PUBLISH_ABIS[@]}"; do
        mkdir -p "$OUTPUT_DIR/$abi"
        cp "$STAGING_OUTPUT/$abi/libjsbay.so" "$OUTPUT_DIR/$abi/.libjsbay.so.$$"
    done
    for abi in "${PUBLISH_ABIS[@]}"; do
        mv "$OUTPUT_DIR/$abi/.libjsbay.so.$$" "$OUTPUT_DIR/$abi/libjsbay.so"
    done
}

validate_output_dir
mkdir -p "$STAGING_OUTPUT/arm64-v8a" "$STAGING_OUTPUT/x86_64"

# Find NDK LLVM toolchain (required: Android needs a .so linked against Bionic, not a musl static archive). Prefer $ANDROID_NDK_HOME, then $ANDROID_HOME/$ANDROID_SDK_ROOT/ndk, then the macOS SDK default directory.
NDK_BIN=""
if [ -d "${ANDROID_NDK_HOME:-}" ]; then
    NDK_BIN="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 2 -name bin 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$NDK_BIN" ]; then
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
        [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
        NDK_BIN="$(ls -d "$sdk"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | tail -n 1 || true)"
        [ -n "$NDK_BIN" ] && break
    done
fi
if [ -z "$NDK_BIN" ] || [ ! -x "$NDK_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang" ]; then
    echo "ERROR: NDK LLVM toolchain not found (aarch64-linux-android${ANDROID_API_LEVEL}-clang missing)." >&2
    echo "  Set ANDROID_NDK_HOME or ANDROID_HOME to an SDK with an NDK installed." >&2
    echo "  Android needs a Bionic-linked libjsbay.so; a musl static .a is unusable." >&2
    exit 2
fi
NDK_SYSROOT="$(cd "$NDK_BIN/../sysroot" && pwd)"

# Zig refuses to finish a static archive until it can see libm, and it will archive a real libm.so if that is what it finds. A one-object static stub satisfies Zig. The NDK link below is what records the real Bionic libraries.

# Zig copies the libm stub archive into the static library as a non-ELF member. Link the relocatable objects directly so Bionic libm/libdl stay dynamic dependencies instead of being archived.
link_android_so() {
    local clang="$1"
    local out="$2"
    local objs
    objs="$(mktemp -d "$TEMP_BUILD/objects.XXXXXX")"
    ( cd "$objs" && "$NDK_BIN/llvm-ar" x "$TEMP_BUILD/prefix/lib/libjsbay.a" )
    find "$objs" -type f ! -name '*.o' -delete
    "$clang" -shared "$objs"/*.o -Wl,-z,defs -Wl,-soname,libjsbay.so "-Wl,--version-script=$TEMP_BUILD/exports.map" -lm -ldl -o "$out"
    # Hide QuickJS C wrappers from the public ABI (names match jsbay_* but are not in public headers).
    "$NDK_BIN/llvm-objcopy" --wildcard --localize-symbol='jsbay_qjs_*' "$out"
    (cd "$SCRIPT_DIR" && zig build tool -- check-c-abi "$out" --nm "$NDK_BIN/llvm-nm")
    rm -rf "$objs"
}

make_libm_stub() {
    local clang="$1"
    local dir="$2"
    mkdir -p "$dir"
    printf '/* empty libm stub for the static archive */\n' > "$dir/libm_stub.c"
    "$clang" -c "$dir/libm_stub.c" -o "$dir/libm_stub.o"
    "$NDK_BIN/llvm-ar" rcs "$dir/libm.a" "$dir/libm_stub.o"
}

echo "==> Building for Android arm64-v8a"
cd "$SCRIPT_DIR"
ARM_STUB="$TEMP_BUILD/arm-stub"
make_libm_stub "$NDK_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang" "$ARM_STUB"
zig build $COMMON_FLAGS --prefix "$TEMP_BUILD/prefix" -Dandroid-sysroot="$NDK_SYSROOT" -Dandroid-lib-dir="$ARM_STUB" -Dtarget=aarch64-linux-android.${ANDROID_API_LEVEL}

echo "==> Linking arm64-v8a with NDK Clang"
link_android_so "$NDK_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang" "$STAGING_OUTPUT/arm64-v8a/libjsbay.so"
rm -rf "$ARM_STUB"

echo "==> Building Android x86_64 (emulator)"
X64_STUB="$TEMP_BUILD/x64-stub"
make_libm_stub "$NDK_BIN/x86_64-linux-android${ANDROID_API_LEVEL}-clang" "$X64_STUB"
zig build $COMMON_FLAGS --prefix "$TEMP_BUILD/prefix" -Dandroid-sysroot="$NDK_SYSROOT" -Dandroid-lib-dir="$X64_STUB" -Dtarget=x86_64-linux-android.${ANDROID_API_LEVEL}

echo "==> Linking x86_64 with NDK Clang"
link_android_so "$NDK_BIN/x86_64-linux-android${ANDROID_API_LEVEL}-clang" "$STAGING_OUTPUT/x86_64/libjsbay.so"
rm -rf "$X64_STUB"

publish_staged_output

echo "==> Android libraries built at $OUTPUT_DIR"

META_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)"
printf '%s\n' "$QUICKJS_BACKEND" > "$META_DIR/backend"
if [ -n "${RELEASE_VERSION:-}" ]; then
    printf '%s\n' "$RELEASE_VERSION" > "$META_DIR/VERSION"
fi
if [ -n "${RELEASE_COMMIT:-}" ]; then
    printf '%s\n' "$RELEASE_COMMIT" > "$META_DIR/COMMIT"
fi
