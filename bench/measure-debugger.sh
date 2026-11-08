#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
target=${1:?usage: measure-debugger.sh NEW_OUTPUT_DIRECTORY [quickjs_ng]}
backend=${2:-quickjs_ng}
zig_bin=${ZIG:-zig}
if [ "$backend" != quickjs_ng ]; then
    echo "debugger benchmark requires backend quickjs_ng" >&2
    exit 64
fi
if [ -e "$target" ]; then
    echo "debugger benchmark requires a new output directory: $target" >&2
    exit 64
fi
case "$(uname -s)" in Darwin|Linux) ;; *) echo "debugger benchmark requires a POSIX host" >&2; exit 64 ;; esac
node_major=$(node -p 'process.versions.node.split(".")[0]')
if [ "$node_major" -lt 24 ]; then echo "debugger benchmark requires Node.js 24 or newer" >&2; exit 64; fi
mkdir -p "$target"
target=$(cd "$target" && pwd)
cd "$root"
work="$target/work"
mkdir "$work"
active_pid=
active_run=false
forward_signal() {
    local signal=$1
    trap - INT TERM
    local pid=$active_pid
    if [ -z "$pid" ] && [ "$active_run" = true ]; then pid=$(jobs -p); fi
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" || true
        active_pid=
    fi
    exit $((128 + $(kill -l "$signal")))
}
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
run() {
    local log=$1
    shift
    local result=0
    printf 'COMMAND=' >"$log"
    printf ' %q' "$@" >>"$log"
    printf '\n' >>"$log"
    active_run=true
    "$@" >>"$log" 2>&1 &
    active_pid=$!
    wait "$active_pid" || result=$?
    active_pid=
    active_run=false
    printf '\nEXIT=%s\n' "$result" >>"$log"
    if [ "$result" -ne 0 ]; then cat "$log" >&2; return "$result"; fi
}
run "$work/build.log" "$zig_bin" build -Dbackend="$backend" -Dlibrary-only=true -Doptimize=ReleaseFast --prefix "$work/prefix"
cc_bin=${CC:-cc}
run "$work/link.log" "$cc_bin" -std=c11 -O2 -Wall -Wextra -Werror -I"$root/include" "$root/bench/debugger_benchmark.c" "$work/prefix/lib/libjsbay.a" -lm -lpthread -o "$work/debugger-benchmark"
benchmark_source_sha=$(shasum -a 256 "$root/bench/debugger_benchmark.c" | awk '{print $1}')
driver_sha=$(shasum -a 256 "$root/bench/debugger_benchmark_driver.mjs" | awk '{print $1}')
engine_source_sha=$(
    {
        printf '%s\n' build.zig build.zig.zon bench/debugger_benchmark.c bench/debugger_benchmark_driver.mjs bench/measure-debugger.sh
        find src libs include tools \( -type d \( -name .git -o -name .zig-cache -o -name zig-out -o -name node_modules \) -prune -o -type f -print \) || exit 1
        find vendor -maxdepth 1 -type f -name '*.patch' -print || exit 1
        find vendor/quickjs-ng -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) -print || exit 1
    } | LC_ALL=C sort -u | while IFS= read -r file; do
        digest=$(shasum -a 256 "$file") || exit 1
        printf '%s  %s\n' "${digest%% *}" "$file"
    done | shasum -a 256 | awk '{print $1}'
)
toolchain=$("$zig_bin" version)
cc_version=$("$cc_bin" --version 2>&1 | sed -n '1p')
source_commit=null
source_dirty=null
if [ -e "$root/.git" ] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    source_commit=$(git -C "$root" rev-parse HEAD)
    if git -C "$root" diff --quiet && git -C "$root" diff --cached --quiet && [ -z "$(git -C "$root" ls-files --others --exclude-standard)" ]; then source_dirty=false; else source_dirty=true; fi
fi
run "$work/measure.log" env JSBAY_DEBUGGER_SOURCE_SHA="$benchmark_source_sha" JSBAY_DEBUGGER_ENGINE_SOURCE_SHA="$engine_source_sha" JSBAY_DEBUGGER_DRIVER_SHA="$driver_sha" JSBAY_DEBUGGER_TOOLCHAIN="$toolchain" JSBAY_DEBUGGER_CC_VERSION="$cc_version" JSBAY_DEBUGGER_SOURCE_COMMIT="$source_commit" JSBAY_DEBUGGER_SOURCE_DIRTY="$source_dirty" node "$root/bench/debugger_benchmark_driver.mjs" --bin "$work/debugger-benchmark" --out "$target/report.json.tmp"
mv "$target/report.json.tmp" "$target/report.json"
cat "$target/report.json"
