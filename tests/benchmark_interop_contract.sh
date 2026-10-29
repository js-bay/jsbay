#!/usr/bin/env bash
# Public interop benchmark output contract. The benchmark itself owns timing; this test only rejects malformed or misleading records.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-all}
case "$mode" in
  all|--host-only|--arkts-only) ;;
  *) echo "usage: tests/benchmark_interop_contract.sh [--host-only|--arkts-only]" >&2; exit 64 ;;
esac
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-bench-contract.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

cd "$repo_root"
if [ "$mode" != --arkts-only ]; then
    if make benchmark-interop RUNNER=not-a-runner >"$tmp_dir/invalid.out" 2>"$tmp_dir/invalid.err"; then
        echo "unknown benchmark runner unexpectedly succeeded" >&2
        exit 1
    fi

    if ! make benchmark-interop RUNNER=c_abi >"$tmp_dir/c-abi.json" 2>"$tmp_dir/c-abi.err"; then
        cat "$tmp_dir/c-abi.err" >&2
        exit 1
    fi

    line_count=$(wc -l <"$tmp_dir/c-abi.json" | tr -d '[:space:]')
    if [ "$line_count" != "1" ]; then
        echo "benchmark stdout must contain exactly one JSON line" >&2
        exit 1
    fi

    jq -e '
  .schema_version == 1 and
  (.suite | type == "string" and length > 0) and
  (.language | type == "string" and length > 0) and
  (.runner_kind == "c_abi") and
  (.runtime | type == "string" and length > 0) and
  (.backend | type == "string" and length > 0) and
  (.optimize == "ReleaseFast") and
  (.engine_version | type == "string" and length > 0) and
  (.sdk_version | type == "string" and length > 0) and
  (.os | type == "string" and length > 0) and
  (.arch | type == "string" and length > 0) and
  (.cpu_model | type == "string" and length > 0) and
  (.device | type == "string" and length > 0) and
  (.toolchain | type == "string" and length > 0) and
  (.warmup_iterations | type == "number" and . >= 0) and
  (.measured_iterations | type == "number" and . > 0) and
  (.payload_bytes | type == "number" and . >= 0) and
  (.operations | type == "array" and length >= 5) and
  ([.operations[].name] | sort == ["buffer_copy", "eval_compute", "host_callback", "lifecycle", "text_json"]) and
  all(.operations[];
    (.name | type == "string") and
    (.warmup_iterations | type == "number" and . == 100) and
    (.measured_iterations | type == "number" and . > 0) and
    (.status == "ok" or .status == "unsupported" or .status == "unmeasured") and
    (if .status == "ok" then
       (.elapsed_ns | type == "number" and . > 0) and
       (.operations | type == "number" and . > 0) and
       (.ns_per_op | type == "number" and . > 0) and
       (if .name == "lifecycle" then
          .measured_iterations == 100 and .operations == 100
        else .measured_iterations == 1000 and .operations == 1000 end)
     else
       (has("elapsed_ns") | not) and
       (has("operations") | not) and
       (has("ns_per_op") | not)
     end)
  )
' "$tmp_dir/c-abi.json" >/dev/null

# Provenance must be trustworthy. A failed digest command cannot be converted into an empty/partial source hash and then published as a benchmark record.
    mkdir "$tmp_dir/hash-bin"
    real_shasum=$(command -v shasum)
    cat >"$tmp_dir/hash-bin/shasum" <<EOF
#!/bin/sh
case "\$*" in
  *bench/interop/c_abi.c*) exit 17 ;;
esac
exec "$real_shasum" "\$@"
EOF
    chmod +x "$tmp_dir/hash-bin/shasum"
    if PATH="$tmp_dir/hash-bin:$PATH" make benchmark-interop RUNNER=c_abi >"$tmp_dir/hash-failure.json" 2>"$tmp_dir/hash-failure.err"; then
        echo "benchmark published a record after source hash failure" >&2
        exit 1
    fi
    [ ! -s "$tmp_dir/hash-failure.json" ] || { echo "benchmark emitted JSON after source hash failure" >&2; exit 1; }
fi

validate_host_runner() {
    local runner=$1
    local language=$2
    local runtime=$3
    local output="$tmp_dir/$runner.json"
    if ! make benchmark-interop "RUNNER=$runner" >"$output" 2>"$tmp_dir/$runner.err"; then
        cat "$tmp_dir/$runner.err" >&2
        return 1
    fi
    [ "$(wc -l <"$output" | tr -d '[:space:]')" = "1" ] || { echo "$runner stdout must be one JSON line" >&2; return 1; }
    jq -e --arg runner "$runner" --arg language "$language" --arg runtime "$runtime" '
      .schema_version == 1 and .runner_kind == $runner and .language == $language and .runtime == $runtime and
      (.backend | type == "string" and length > 0) and .optimize == "ReleaseFast" and
      (.engine_version | type == "string" and length > 0) and (.sdk_version | type == "string" and length > 0) and
      (.os | type == "string" and length > 0) and (.arch | type == "string" and length > 0) and
      (.cpu_model | type == "string" and length > 0) and (.device == "host") and
      (.warmup_iterations | type == "number" and . >= 0) and (.measured_iterations | type == "number" and . > 0) and
      ([.operations[].name] | sort == ["buffer_copy", "eval_compute", "host_callback", "lifecycle", "text_json"]) and
      all(.operations[]; (.warmup_iterations | type == "number" and . == 100) and
        (.measured_iterations | type == "number" and . > 0) and
        (.status == "ok" or .status == "unsupported" or .status == "unmeasured") and
        (if .status == "ok" then (.elapsed_ns > 0 and .operations > 0 and .ns_per_op > 0 and
          (if .name == "lifecycle" then .measured_iterations == 100 and .operations == 100
           else .measured_iterations == 1000 and .operations == 1000 end))
         else (has("elapsed_ns") | not) and (has("operations") | not) and (has("ns_per_op") | not) end))
    ' "$output" >/dev/null
}

if [ "$mode" != --arkts-only ]; then
    validate_host_runner csharp csharp .NET
    validate_host_runner jvm_kotlin jvm_kotlin 'JVM Kotlin'
    validate_host_runner jvm_java jvm_java 'JVM Java'
    validate_host_runner swift swift Swift
    validate_host_runner objc objective-c 'Objective-C'
    validate_host_runner harmony_host_napi harmony_host_napi 'OpenHarmony N-API host'
fi

# ArkTS is a device-facing SDK path. It must have a compile/typecheck entry, but the host benchmark result above must never be reported as an Ark device measurement. The implementation supplies this command without a device.
if [ "$mode" != --host-only ]; then
    if ! make benchmark-interop RUNNER=harmony_arkts_check >"$tmp_dir/harmony-arkts-check.out" 2>"$tmp_dir/harmony-arkts-check.err"; then
        cat "$tmp_dir/harmony-arkts-check.err" >&2
        exit 1
    fi
    [ ! -s "$tmp_dir/harmony-arkts-check.out" ] || { echo "ArkTS check must not emit benchmark JSON" >&2; exit 1; }
fi
