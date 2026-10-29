#!/usr/bin/env bash
# Compare identical release builds and execute their public C consumer.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
target=${1:?usage: measure-diagnostics.sh NEW_OUTPUT_DIRECTORY [quickjs_ng|quickjs|jsc]}
backend=${2:-quickjs_ng}
zig_bin=${ZIG:-zig}
case "$backend" in quickjs_ng|quickjs|jsc) ;; *) exit 64 ;; esac
if [ -e "$target" ]; then echo "measurement output already exists: $target" >&2; exit 64; fi
mkdir -p "$target"
target=$(cd "$target" && pwd)
cd "$root"
run() {
    local log=$1
    shift
    local result=0
    "$@" >"$log" 2>&1 || result=$?
    printf '\nEXIT=%s\n' "$result" >>"$log"
    if [ "$result" -ne 0 ]; then cat "$log" >&2; return "$result"; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
bytes() { wc -c <"$1" | tr -d '[:space:]'; }
for mode in full heap_off inspector_off; do
    work="$target/$mode"
    mkdir "$work"
    inspector=true; heap=true
    case "$mode" in heap_off) heap=false ;; inspector_off) inspector=false; heap=false ;; esac
    run "$work/build.log" "$zig_bin" build -Dbackend="$backend" -Dlibrary-only=true -Doptimize=ReleaseFast \
        -Dinspector="$inspector" -Dheap-snapshot="$heap" --prefix "$work"
    artifact="$work/lib/libjsbay.a"
    flags=(-lm)
    if [ "$backend" = jsc ] && [ "$(uname -s)" = Darwin ]; then flags+=(-framework JavaScriptCore -framework Foundation); fi
    run "$work/link.log" "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$root/include" \
        "$root/tests/c_consumer.c" "$artifact" "${flags[@]}" -o "$work/consumer"
    run "$work/consumer.log" "$work/consumer"
    run "$work/benchmark-link.log" "${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror -I"$root/include" \
        "$root/bench/interop/c_abi.c" "$artifact" "${flags[@]}" -o "$work/benchmark"
    run "$work/benchmark.log" "$work/benchmark"
    read -r eval_ns callback_ns json_ns buffer_ns lifecycle_ns <"$work/benchmark.log"
    for elapsed in "$eval_ns" "$callback_ns" "$json_ns" "$buffer_ns" "$lifecycle_ns"; do
        case "$elapsed" in ''|*[!0-9]*) echo 'invalid benchmark timing' >&2; exit 65 ;; esac
        [ "$elapsed" -gt 0 ] || exit 65
    done
    jq -n --arg source_sha "$(sha "$root/bench/interop/c_abi.c")" \
        --argjson eval "$eval_ns" --argjson callback "$callback_ns" --argjson json "$json_ns" \
        --argjson buffer "$buffer_ns" --argjson lifecycle "$lifecycle_ns" \
        '{runner_kind:"c_abi",language:"c_abi",warmup_iterations:100,measured_iterations:1000,payload_bytes:4096,source_sha256:$source_sha,operations:([
          {name:"eval_compute",elapsed_ns:$eval},{name:"host_callback",elapsed_ns:$callback},
          {name:"text_json",elapsed_ns:$json},{name:"buffer_copy",elapsed_ns:$buffer},{name:"lifecycle",elapsed_ns:$lifecycle}
        ] | map(. + {status:"ok",warmup_iterations:100,measured_iterations:(if .name == "lifecycle" then 100 else 1000 end),operations:(if .name == "lifecycle" then 100 else 1000 end),ns_per_op:(.elapsed_ns / (if .name == "lifecycle" then 100 else 1000 end))}))}' >"$work/runtime.json"
    if [ "$(uname -s)" = Darwin ]; then nm -gU "$artifact" >"$work/symbols.txt" 2>"$work/symbols.stderr";
    else nm -g --defined-only "$artifact" >"$work/symbols.txt" 2>"$work/symbols.stderr"; fi
    awk '{name=$NF; sub(/^_/,"",name); if(name ~ /^jsbay_[A-Za-z0-9_]+$/) print name}' "$work/symbols.txt" | LC_ALL=C sort -u >"$work/exports.txt"
    jq -Rn '[inputs | select(length > 0)]' <"$work/exports.txt" >"$work/exports.json"
    if [ "$mode" != full ]; then cmp "$target/full/exports.txt" "$work/exports.txt"; fi
    case "$mode" in
        full)
            inspector_status=ok
            if [ "$backend" = jsc ]; then filter='cdp diagnostics: JSC reports heap snapshots'; heap_status=unsupported;
            else filter='cdp diagnostics: QuickJS heap snapshot exposes'; heap_status=partial; fi ;;
        heap_off) inspector_status=ok; heap_status=unsupported; filter='cdp diagnostics: heap-snapshot-disabled' ;;
        inspector_off) inspector_status=unsupported; heap_status=unsupported; filter='c api diagnostics: inspector-disabled' ;;
    esac
    run "$work/diagnostics.log" "$zig_bin" build test -Dbackend="$backend" -Doptimize=ReleaseFast \
        -Dinspector="$inspector" -Dheap-snapshot="$heap" -Dtest-filter="$filter" --summary all
    cp "$work/consumer" "$work/consumer.stripped"
    run "$work/strip.log" strip "$work/consumer.stripped"
    jq -n --arg name "$mode" --arg artifact "$artifact" --arg consumer "$work/consumer" \
        --arg asha "$(sha "$artifact")" --arg csha "$(sha "$work/consumer")" \
        --argjson abytes "$(bytes "$artifact")" --argjson cbytes "$(bytes "$work/consumer")" \
        --argjson stripped_bytes "$(bytes "$work/consumer.stripped")" \
        --arg inspector "$inspector_status" --arg heap "$heap_status" --slurpfile exports "$work/exports.json" --slurpfile runtime "$work/runtime.json" \
        '{name:$name,build:{exit_code:0},consumer:{path:$consumer,exit_code:0,bytes:$cbytes,sha256:$csha,stripped_bytes:$stripped_bytes},artifact:{path:$artifact,bytes:$abytes,sha256:$asha},exports:$exports[0],inspector_start:$inspector,heap_snapshot:$heap,runtime_benchmark:$runtime[0]}' >"$work/record.json"
done
jq -s --arg backend "$backend" --arg zig "$("$zig_bin" version)" --arg os "$(uname -s)" --arg arch "$(uname -m)" \
    '{schema_version:1,backend:$backend,optimize:"ReleaseFast",zig:$zig,os:$os,arch:$arch,modes:.}' \
    "$target/full/record.json" "$target/heap_off/record.json" "$target/inspector_off/record.json" >"$target/report.json.tmp"
mv "$target/report.json.tmp" "$target/report.json"
cat "$target/report.json"
