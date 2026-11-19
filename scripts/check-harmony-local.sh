#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
output_dir=${1:?usage: check-harmony-local.sh <output-dir-outside-repository>}

resolve_uncreated_path() {
  local path=$1 parent component
  local -a missing=()
  if [[ $path != /* ]]; then path="$PWD/$path"; fi
  while [[ ! -e $path && ! -L $path ]]; do
    component=$(basename "$path")
    parent=$(dirname "$path")
    missing=("$component" "${missing[@]-}")
    path=$parent
  done
  if [[ -d $path ]]; then
    path=$(cd "$path" && pwd -P)
  elif [[ -L $path ]]; then
    echo "Cannot resolve output path through a dangling symlink: $path" >&2
    return 2
  else
    path=$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")
  fi
  if ((${#missing[@]})); then
    for component in "${missing[@]}"; do
      case "$component" in
        ''|.) ;;
        ..) path=$(dirname "$path") ;;
        *) path="$path/$component" ;;
      esac
    done
  fi
  printf '%s\n' "$path"
}

output_dir=$(resolve_uncreated_path "$output_dir")
case "$output_dir" in
  "$repo_root"|"$repo_root"/*)
    echo 'Choose an output directory outside the repository so build logs and staged HAR files stay untracked.' >&2
    exit 2
    ;;
esac
if [[ -d $output_dir && -n $(ls -A "$output_dir") ]]; then
  echo "Output directory must be empty: $output_dir" >&2
  exit 2
fi
mkdir -p "$output_dir"
report="$output_dir/summary.txt"
: > "$report"
write_final_status() {
  local status=$?
  if ((status != 0)); then printf 'OVERALL=FAIL EXIT=%s\n' "$status" >> "$report"; fi
}
trap write_final_status EXIT

source "$repo_root/scripts/harmony-toolchain.sh"
harmony_toolchain_resolve
zig_bin=${ZIG_BIN:-zig}
node_bin=${NODE_BIN:-node}
stage_script=${HARMONY_STAGE_SCRIPT:-$repo_root/scripts/stage-harmony-har.sh}
target_sdk=${HARMONY_TARGET_SDK_VERSION:-5.0.0(12)}
printf 'SDK_TARGET=%s\nBACKENDS=quickjs_ng,quickjs\n' "$target_sdk" >> "$report"
printf 'SDK_ROOT=%s\nHVIGORW=%s\nOHPM=%s\n' "$DEVECO_SDK_HOME" "$HVIGORW" "$OHPM" >> "$report"
test -f "$stage_script"
if [[ $zig_bin == */* ]]; then
  zig_dir=$(cd "$(dirname "$zig_bin")" && pwd)
  zig_bin="$zig_dir/$(basename "$zig_bin")"
else
  zig_bin=$(command -v "$zig_bin" 2>/dev/null) || { echo "Zig executable not found: ${ZIG_BIN:-zig}" >&2; exit 1; }
fi
[[ -x $zig_bin ]] || { echo "Zig executable is not executable: $zig_bin" >&2; exit 1; }
command -v "$node_bin" >/dev/null 2>&1 || { echo "Node.js executable not found: $node_bin" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required by the Harmony HAR packaging scripts.' >&2; exit 1; }
test -d "$OHOS_NATIVE_HOME/sysroot" || { echo "OpenHarmony sysroot not found: $OHOS_NATIVE_HOME/sysroot" >&2; exit 1; }
: "${NODE_PATH:?Set NODE_PATH to the matching Hvigor module root.}"
NODE_PATH="$NODE_PATH" "$node_bin" -e 'for (const name of ["@ohos/hvigor", "@ohos/hvigor-ohos-plugin"]) require.resolve(name + "/package.json");' || {
  echo 'The configured NODE_PATH must contain @ohos/hvigor and @ohos/hvigor-ohos-plugin.' >&2
  exit 1
}
cd "$repo_root"

run_logged() {
  local log=$1
  shift
  local -a pipeline_status
  local status
  if "$@" 2>&1 | tee "$log"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  status=${pipeline_status[0]}
  if ((status == 0 && pipeline_status[1] != 0)); then status=${pipeline_status[1]}; fi
  printf 'EXIT=%s\n' "$status" >> "$log"
  return "$status"
}

for backend in quickjs_ng quickjs; do
  backend_dir="$output_dir/$backend"
  core_prefix="$backend_dir/core"
  stage_dir="$backend_dir/stage"
  mkdir -p "$backend_dir"
  printf 'Building fresh OpenHarmony core and SDK %s HAR for %s\n' "$target_sdk" "$backend"
  run_logged "$backend_dir/build.log" "$zig_bin" build \
    "-Dbackend=$backend" \
    -Dtarget=aarch64-linux-ohos \
    "-Dohos-sysroot=$OHOS_NATIVE_HOME/sysroot" \
    -Dlibrary-only=true \
    -Doptimize=ReleaseFast \
    --prefix "$core_prefix" \
    --summary all || {
      status=$?
      echo "OpenHarmony core build failed for $backend; see $backend_dir/build.log" >&2
      printf '%s core EXIT=%s\n' "$backend" "$status" >> "$report"
      exit "$status"
    }
  printf '%s core EXIT=0\n' "$backend" >> "$report"
  JSBAY_LIBRARY="$core_prefix/lib/libjsbay.a" \
  JSBAY_HARMONY_ARCHIVE="$core_prefix/lib/libjsbay.a" \
  QUICKJS_BACKEND="$backend" \
  HARMONY_TARGET_SDK_VERSION="$target_sdk" \
    run_logged "$backend_dir/har.log" bash "$stage_script" "$stage_dir" "local-$backend" || {
      status=$?
      echo "Harmony HAR build or staging failed for $backend; see $backend_dir/har.log" >&2
      printf '%s HAR EXIT=%s\n' "$backend" "$status" >> "$report"
      exit "$status"
    }
  printf '%s HAR EXIT=0\n' "$backend" >> "$report"

  har="$stage_dir/jsbay-local-$backend-harmony-$backend-arm64-v8a.har"
  if [[ ! -s $har || ! -s $stage_dir/SHA256SUMS || ! -s $stage_dir/backend ]] ||
    [[ $(cat "$stage_dir/backend") != "$backend" ]]; then
    echo "missing or empty HAR output for $backend: $har" >&2
    printf '%s staged-HAR validation FAIL\n' "$backend" >> "$report"
    exit 1
  fi
  printf '%s staged-HAR validation PASS\n' "$backend" >> "$report"
  printf '%s\n' "PASS: $backend HAR staged at $har"
done

printf 'PASS: both SDK %s Harmony HAR builds completed; logs and artifacts are in %s\n' "$target_sdk" "$output_dir"
printf 'OVERALL=PASS\n' >> "$report"
