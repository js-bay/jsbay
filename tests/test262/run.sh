#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
backend=quickjs_ng
args=(--manifest "$root/tests/test262/manifest.json")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --backend) [ "$#" -ge 2 ] || exit 64; backend=$2; shift 2 ;;
        --source-root|--manifest|--output) [ "$#" -ge 2 ] || exit 64; args+=("$1" "$2"); shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done
case "$backend" in quickjs_ng|quickjs|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac
# JSBAY_TEST262_HOST_DIR reuses one host across caller invocations (the runner contract). A fresh temp dir remains the default.
persistent=0
if [ -n "${JSBAY_TEST262_HOST_DIR:-}" ]; then
    out=${JSBAY_TEST262_HOST_DIR}
    mkdir -p "$out"
    persistent=1
else
    out=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-test262.XXXXXX")
    cleanup() {
        local cleanup_status=$?
        rm -rf "$out"
        exit "$cleanup_status"
    }
    trap cleanup EXIT
fi
cd "$root"
fingerprint() {
    # Backend, toolchain, host sources, and the archive Zig just produced.
    {
        printf '%s\n' "$backend"
        command -v zig
        zig version 2>/dev/null || true
        printf '%s\n' "${CC:-cc}"
        "${CC:-cc}" --version 2>/dev/null | head -n 1 || true
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 \
                "$root/tests/test262/host.c" \
                "$root/build.zig" \
                "$root/build.zig.zon" \
                "$out/core/lib/libjsbay_test262.a" \
                2>/dev/null || true
        elif command -v sha256sum >/dev/null 2>&1; then
            sha256sum \
                "$root/tests/test262/host.c" \
                "$root/build.zig" \
                "$root/build.zig.zon" \
                "$out/core/lib/libjsbay_test262.a" \
                2>/dev/null || true
        fi
    }
}
# Always invoke zig build so its dependency graph refreshes stale engine objects.
zig build test262-host -Dbackend="$backend" -Dlibrary-only=true -Doptimize=ReleaseFast --prefix "$out/core" >&2
need_relink=0
if [ "$persistent" -eq 0 ] || [ ! -x "$out/host" ]; then
    need_relink=1
elif [ "$(cat "$out/backend" 2>/dev/null || true)" != "$backend" ]; then
    need_relink=1
elif [ "$(cat "$out/fingerprint" 2>/dev/null || true)" != "$(fingerprint)" ]; then
    need_relink=1
fi
if [ "$need_relink" -eq 1 ]; then
    flags=(-lm)
    if [ "$backend" = jsc ] && [ "$(uname -s)" = Darwin ]; then flags+=(-framework JavaScriptCore -framework Foundation); fi
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -O2 -I"$root/include" "$root/tests/test262/host.c" "$out/core/lib/libjsbay_test262.a" "${flags[@]}" -o "$out/host"
    if [ "$persistent" -eq 1 ]; then
        printf '%s\n' "$backend" > "$out/backend"
        fingerprint > "$out/fingerprint"
    fi
fi
node "$root/tests/test262/run.mjs" --backend "$backend" --host "$out/host" "${args[@]}"
