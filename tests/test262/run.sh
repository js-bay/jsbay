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
if [ "$persistent" -eq 0 ] || [ ! -x "$out/host" ] || [ "$(cat "$out/backend" 2>/dev/null || true)" != "$backend" ]; then
    zig build test262-host -Dbackend="$backend" -Dlibrary-only=true -Doptimize=ReleaseFast --prefix "$out/core" >&2
    flags=(-lm)
    if [ "$backend" = jsc ] && [ "$(uname -s)" = Darwin ]; then flags+=(-framework JavaScriptCore -framework Foundation); fi
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -O2 -I"$root/include" "$root/tests/test262/host.c" "$out/core/lib/libjsbay_test262.a" "${flags[@]}" -o "$out/host"
    if [ "$persistent" -eq 1 ]; then printf '%s\n' "$backend" > "$out/backend"; fi
fi
node "$root/tests/test262/run.mjs" --backend "$backend" --host "$out/host" "${args[@]}"
