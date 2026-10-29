#!/usr/bin/env bash
# Public interop benchmark runner. Each host runner measures public SDK calls and writes exactly five elapsed nanosecond values to stdout.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
runner=${1:-${RUNNER:-c_abi}}
backend=${BACKEND:-quickjs_ng}
case "$runner" in
  c_abi|csharp|jvm_kotlin|jvm_java|swift|objc|harmony_host_napi|harmony_arkts_check|harmony_typescript_check) ;;
  *) echo "unsupported benchmark runner: $runner" >&2; exit 64 ;;
esac
case "$backend" in quickjs|quickjs_ng|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac
command -v jq >/dev/null

one_line() {
  local value=$1
  value=${value//$'\n'/ }
  printf '%s' "$value"
}

resolve_harmony_tsc() {
  if [ -n "${TSC:-}" ]; then printf '%s\n' "$TSC"; return; fi
  local sdk candidate
  for sdk in "${HARMONY_ETS_SDK:-}" "${DEVECO_SDK_HOME:-}/default/openharmony/ets" "${HARMONY_SDK_HOME:-}/sdk/packages/ohos-sdk/darwin/12/ets" "${HARMONY_SDK_HOME:-}/sdk/packages/ohos-sdk/linux/12/ets"; do
    candidate="$sdk/build-tools/ets-loader/node_modules/typescript/lib/tsc.js"
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
  done
  return 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-interop.XXXXXX")
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
link_flags=(-lm)
if [ "$backend" = jsc ]; then link_flags+=(-framework JavaScriptCore); fi
case "$runner" in
  c_abi)
    zig build --prefix "$prefix" -Dlibrary-only=true -Dshared=false "-Dbackend=$backend" -Doptimize=ReleaseFast >&2
    cc -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -I"$root/include" "$root/bench/interop/c_abi.c" "$prefix/lib/libjsbay.a" "${link_flags[@]}" -o "$work/c-abi" >&2
    measurements=$("$work/c-abi")
    language=c_abi; runtime=native-c
    runtime_toolchain=''
    source_roots=("$root/bench/interop/c_abi.c" "$root/include/jsbay.h")
    ;;
  csharp)
    if [ -n "${DOTNET:-}" ]; then dotnet_bin=$DOTNET
    elif command -v dotnet >/dev/null 2>&1; then dotnet_bin=$(command -v dotnet)
    else dotnet_bin="$HOME/.dotnet/dotnet"
    fi
    test -x "$dotnet_bin"
    zig build --prefix "$prefix" -Dlibrary-only=true -Dshared=true "-Dbackend=$backend" -Doptimize=ReleaseFast >&2
    export DYLD_LIBRARY_PATH="$prefix/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    "$dotnet_bin" build "$root/bench/interop/csharp/InteropBench.csproj" --configuration Release --output "$work/csharp" \
      -p:BaseIntermediateOutputPath="$work/csharp-obj/" >&2
    measurements=$("$dotnet_bin" "$work/csharp/InteropBench.dll")
    language=csharp; runtime=.NET
    runtime_toolchain=".NET $(one_line "$("$dotnet_bin" --version)")"
    source_roots=("$root/bench/interop/csharp" "$root/sdk/dotnet/JsBay" "$root/include/jsbay.h")
    ;;
  jvm_kotlin|jvm_java)
    measurements=$(bash "$root/bench/interop/run-jvm.sh" "$runner" "$backend")
    language=$runner
    if [ "$runner" = jvm_kotlin ]; then runtime='JVM Kotlin'; else runtime='JVM Java'; fi
    jvm_home=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}
    gradle_lib=${KOTLIN_GRADLE_LIB:-}
    if [ -z "$gradle_lib" ]; then gradle_lib=$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d -print -quit 2>/dev/null || true); fi
    jvm_version=$(one_line "$("$jvm_home/bin/java" -version 2>&1)")
    kotlin_version=$(one_line "$("$jvm_home/bin/java" -cp "$gradle_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -version 2>&1)")
    runtime_toolchain="JVM $jvm_version; Kotlin $kotlin_version"
    source_roots=("$root/bench/interop/jvm" "$root/bench/interop/run-jvm.sh" "$root/sdk/android/jsbay/src/main" "$root/include/jsbay.h")
    ;;
  swift)
    measurements=$(bash "$root/bench/interop/run-apple.sh" swift "$backend")
    language=swift; runtime=Swift
    runtime_toolchain="$(one_line "$(xcrun --sdk macosx swiftc --version)")"
    source_roots=("$root/bench/interop/apple/SwiftInteropBench.swift" "$root/bench/interop/run-apple.sh" "$root/sdk/apple/Sources/JsBaySDK" "$root/include/jsbay.h")
    ;;
  objc)
    measurements=$(bash "$root/bench/interop/run-apple.sh" objc "$backend")
    language=objective-c; runtime=Objective-C
    runtime_toolchain="$(one_line "$(xcrun --sdk macosx clang --version)")"
    source_roots=("$root/bench/interop/apple/ObjectiveCInteropBench.m" "$root/bench/interop/run-apple.sh" "$root/sdk/apple/Sources/JsBayObjC" "$root/include/jsbay.h")
    ;;
  harmony_host_napi)
    measurements=$(bash "$root/bench/interop/run-harmony.sh" harmony_host_napi "$backend")
    language=harmony_host_napi; runtime='OpenHarmony N-API host'
    harmony_node=${NODE_BIN:-node}
    harmony_tsc=$(resolve_harmony_tsc)
    runtime_toolchain="Node $(one_line "$("$harmony_node" --version)"); TypeScript $(one_line "$("$harmony_node" "$harmony_tsc" --version)")"
    source_roots=("$root/bench/interop/harmony" "$root/bench/interop/run-harmony.sh" "$root/sdk/harmony/src/main" "$root/include/jsbay.h")
    ;;
  harmony_arkts_check|harmony_typescript_check)
    bash "$root/bench/interop/run-harmony.sh" "$runner" "$backend" >&2
    exit 0
    ;;
esac

case "$measurements" in *$'\n'*) echo "benchmark runner emitted more than one output line" >&2; exit 65 ;; esac
read -r eval callback text_json buffer lifecycle <<<"$measurements"
for measurement in "$eval" "$callback" "$text_json" "$buffer" "$lifecycle"; do
  case "$measurement" in ''|*[!0-9]*) echo "benchmark runner emitted malformed measurements" >&2; exit 65 ;; esac
  [ "$measurement" -gt 0 ] || { echo "benchmark runner emitted non-positive measurement" >&2; exit 65; }
done

source_hash=$({
  printf '%s\n' build.zig build.zig.zon bench/interop/run.sh
  (cd "$root" && find src -type f -print) || exit $?
  (cd "$root" && find vendor -maxdepth 1 -type f -print) || exit $?
  for source_root in "${source_roots[@]}"; do
    source_relative=${source_root#"$root"/}
    if [ -d "$source_root" ]; then
      (cd "$root" && find "$source_relative" -type f \
        ! -path '*/build/*' ! -path '*/bin/*' ! -path '*/obj/*' ! -path '*/node_modules/*' \
        ! -path '*/.gradle/*' ! -path '*/.cxx/*' -print) || exit $?
    else
      printf '%s\n' "$source_relative"
    fi
  done
} | LC_ALL=C sort -u | while IFS= read -r source_file; do
  source_sum=$(shasum -a 256 "$root/$source_file") || exit $?
  printf '%s  %s\n' "${source_sum%% *}" "$source_file"
done | shasum -a 256 | awk '{print $1}') || exit $?
os=$(uname -s); arch=$(uname -m); cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -p)
cc_version=$(cc --version 2>/dev/null || true); cc_version=${cc_version%%$'\n'*}
toolchain="zig $(zig version); C compiler $cc_version${runtime_toolchain:+; $runtime_toolchain}"
jq -cn \
  --arg backend "$backend" --arg runner "$runner" --arg language "$language" --arg runtime "$runtime" --arg engine "$source_hash" --arg os "$os" --arg arch "$arch" --arg cpu "$cpu" --arg toolchain "$toolchain" \
  --argjson eval "$eval" --argjson callback "$callback" --argjson text_json "$text_json" --argjson buffer "$buffer" --argjson lifecycle "$lifecycle" \
  '{schema_version:1,suite:"js-bay-public-interop",language:$language,runner_kind:$runner,runtime:$runtime,backend:$backend,optimize:"ReleaseFast",engine_version:$engine,sdk_version:$engine,os:$os,arch:$arch,cpu_model:$cpu,device:"host",toolchain:$toolchain,warmup_iterations:100,measured_iterations:1000,payload_bytes:4096,operations:[{name:"eval_compute",status:"ok",warmup_iterations:100,measured_iterations:1000,elapsed_ns:$eval,operations:1000,ns_per_op:($eval/1000)},{name:"host_callback",status:"ok",warmup_iterations:100,measured_iterations:1000,elapsed_ns:$callback,operations:1000,ns_per_op:($callback/1000)},{name:"text_json",status:"ok",warmup_iterations:100,measured_iterations:1000,elapsed_ns:$text_json,operations:1000,ns_per_op:($text_json/1000)},{name:"buffer_copy",status:"ok",warmup_iterations:100,measured_iterations:1000,elapsed_ns:$buffer,operations:1000,ns_per_op:($buffer/1000)},{name:"lifecycle",status:"ok",warmup_iterations:100,measured_iterations:100,elapsed_ns:$lifecycle,operations:100,ns_per_op:($lifecycle/100),notes:"Lifecycle uses 100 measured create/evaluate/destroy iterations."}]}'
