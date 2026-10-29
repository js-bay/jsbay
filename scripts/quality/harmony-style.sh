#!/usr/bin/env bash
# Run Huawei Code Linter against every hand-written Harmony source.
set -euo pipefail

expected_version='1.0.0'
expected_sdk_version='5.0.0.71'
script_dir=$(cd "$(dirname "$0")" && pwd)
default_root=$(cd "$script_dir/../.." && pwd)
mode=${1:-}
shift || true
root=$default_root
report_dir=''

usage() { echo "usage: $0 check|fix [--root CHECKOUT] [--report-dir DIRECTORY]" >&2; exit 2; }
case "$mode" in check|fix) ;; *) usage ;; esac
while (($#)); do
  case "$1" in
    --root) shift; (($#)) || usage; root=$1 ;;
    --report-dir) shift; (($#)) || usage; report_dir=$1 ;;
    *) usage ;;
  esac
  shift
done
root=$(cd "$root" && pwd)

codelinter=${CODELINTER:-}
if [[ -z "$codelinter" && -n ${HARMONY_SDK_HOME:-} && -f "$HARMONY_SDK_HOME/command-line-tools/bin/codelinter" ]]; then codelinter=$HARMONY_SDK_HOME/command-line-tools/bin/codelinter; fi
if [[ -z "$codelinter" ]]; then codelinter=$(command -v codelinter || true); fi
[[ -n "$codelinter" && -x "$codelinter" ]] || { echo 'harmony-style: set CODELINTER to Code Linter 1.0.0' >&2; exit 2; }
version=$("$codelinter" --version)
[[ "$version" == "$expected_version" ]] || { echo "harmony-style: Code Linter $expected_version required; found '$version'" >&2; exit 2; }

ets_sdk=${HARMONY_ETS_SDK:-}
if [[ -z "$ets_sdk" ]]; then
  for variable in OHOS_SDK_HOME OHOS_SDK_ROOT DEVECO_SDK_HOME HARMONY_SDK_HOME; do
    candidate=${!variable:-}
    [[ -n "$candidate" ]] || continue
    for layout in "$candidate/12/ets" "$candidate/sdk/packages/ohos-sdk/darwin/12/ets" "$candidate/sdk/packages/ohos-sdk/linux/12/ets" "$candidate/default/openharmony/ets"; do
      if [[ -d "$layout/api" ]]; then ets_sdk=$layout; break 2; fi
    done
  done
fi
[[ -n "$ets_sdk" && -d "$ets_sdk/api" ]] || { echo 'harmony-style: set HARMONY_ETS_SDK to SDK API 12 ets (containing api/)' >&2; exit 2; }
ets_sdk=$(cd "$ets_sdk" && pwd)
metadata=$ets_sdk/oh-uni-package.json
[[ -f "$metadata" ]] || { echo "harmony-style: missing SDK metadata: $metadata" >&2; exit 2; }
[[ $(jq -r '.apiVersion // empty' "$metadata") == '12' && $(jq -r '.version // empty' "$metadata") == "$expected_sdk_version" ]] || { echo "harmony-style: SDK API 12 version $expected_sdk_version required: $metadata" >&2; exit 2; }

# Build the manifest in the temporary workspace instead of a process substitution: with pipefail, a failed find or sort is now a hard failure.
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-style.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
source_list=$work/sources.list
: > "$source_list"
for source_dir in "$root/sdk/harmony" "$root/tests/harmony-sdk"; do
  [[ -d "$source_dir" ]] || continue
  set +e
  find "$source_dir" \( -type d \( -name build -o -name .cxx -o -name .hvigor -o -name .idea -o -name oh_modules -o -name node_modules \) -prune \) -o -type f \( -name '*.ets' -o -name '*.ts' \) -print | LC_ALL=C sort >> "$source_list"
  find_status=$?
  set -e
  (( find_status == 0 )) || { echo "harmony-style: cannot enumerate $source_dir" >&2; exit 2; }
done
sources=()
while IFS= read -r source; do
  relative=${source#"$root/"}
  [[ "$relative" == sdk/harmony/BuildProfile.ets ]] && continue
  sources+=("$relative")
done < "$source_list"
(( ${#sources[@]} > 0 )) || { echo 'harmony-style: no Harmony sources found' >&2; exit 2; }

project=$work/project
module=$project/module
mkdir -p "$module"
for relative in "${sources[@]}"; do
  target=$module/$relative
  mkdir -p "$(dirname "$target")"
  cp -p "$root/$relative" "$target"
done
printf '%s\n' '{"app":{"compileSdkVersion":12},"modules":[{"name":"style","srcPath":"./module"}]}' > "$project/build-profile.json5"
printf '%s\n' '{"apiType":"stageMode","targets":[{"name":"default","runtimeOS":"OpenHarmony"}]}' > "$module/build-profile.json5"
mkdir -p "$module/src/main" "$work/sdk/12" "$project/.idea/code-linter"
printf '%s\n' '{"module":{"name":"style","type":"har"}}' > "$module/src/main/module.json5"
ln -s "$ets_sdk" "$work/sdk/12/ets"
printf 'sdk.dir=%s\n' "$work/sdk" > "$project/local.properties"

reports=$project/.idea/code-linter
report=$reports/report.txt
detail=$reports/codelinter.log
transcript=$work/command.log
command=("$codelinter" --config "$root/sdk/harmony/code-linter.json5" --source "$project" --output "$report")
[[ "$mode" == fix ]] && command+=(--fix)
set +e
"${command[@]}" > "$transcript" 2>&1
command_status=$?
set -e
if [[ -n "$report_dir" ]]; then
  mkdir -p "$report_dir"
  [[ -f "$report" ]] && cp -p "$report" "$report_dir/report.txt"
  [[ -f "$detail" ]] && cp -p "$detail" "$report_dir/codelinter.log"
  cp -p "$transcript" "$report_dir/command.log"
  printf '%s\n' "${sources[@]}" | jq -R . | jq -s . > "$report_dir/sources.json"
fi
if (( command_status != 0 )) || [[ ! -f "$report" || ! -f "$detail" ]] || ! grep -Fq 'lint code finished' "$detail" || ! grep -Fq 'report succeed' "$detail" || grep -Fq '[ERROR]' "$detail"; then
  cat "$transcript" >&2; [[ -f "$detail" ]] && tail -c 4000 "$detail" >&2 || true
  echo 'harmony-style: official Code Linter did not complete' >&2; exit 2
fi
count_occurrences() {
  awk -v needle="$1" 'index($0, needle) { count += 1 } END { print count + 0 }' "$2"
}
hidden=$(count_occurrences 'this not shown:' "$detail")
defects=$(count_occurrences 'severity:' "$report")
if (( hidden > 0 || defects > 0 )); then
  if [[ "$mode" == check ]]; then cat "$report" >&2; echo "harmony-style: $defects reported, $hidden additional diagnostics" >&2; exit 1; fi
  changed=0
  for relative in "${sources[@]}"; do
    formatted=$module/$relative; original=$root/$relative
    if ! cmp -s "$formatted" "$original"; then cp -p "$formatted" "$original"; changed=$((changed + 1)); fi
  done
  echo "Harmony Code Linter $version: ${#sources[@]} source files; $changed formatted; validating result" >&2
  set +e
  if [[ -n "$report_dir" ]]; then /bin/bash "$0" check --root "$root" --report-dir "$report_dir";
  else /bin/bash "$0" check --root "$root"; fi
  validation_status=$?
  set -e
  exit "$validation_status"
fi

# The tool can silently ignore a source. Append a rule violation to each copied source and demand a source-specific diagnostic from the official report.
probe=$'\ndeclare const jsbayLintCoverageProbe: any;\n'
for relative in "${sources[@]}"; do printf '%s' "$probe" >> "$module/$relative"; done
coverage_dir=$reports/coverage/.idea/code-linter
mkdir -p "$coverage_dir"
coverage_report=$coverage_dir/report.txt
coverage_command=("$codelinter" --config "$root/sdk/harmony/code-linter.json5" --source "$project" --output "$coverage_report")
set +e
"${coverage_command[@]}" > "$work/coverage-command.log" 2>&1
coverage_status=$?
set -e
coverage_log=$coverage_dir/codelinter.log
missing=''
for relative in "${sources[@]}"; do
  formatted=$module/$relative
  if [[ ! -f "$coverage_report" ]] || ! grep -Fq -- "-$formatted(" "$coverage_report"; then missing="$missing $relative"; fi
done
if [[ -n "$report_dir" ]]; then
  mkdir -p "$report_dir/coverage"
  [[ -f "$coverage_report" ]] && cp -p "$coverage_report" "$report_dir/coverage/report.txt"
  [[ -f "$coverage_log" ]] && cp -p "$coverage_log" "$report_dir/coverage/codelinter.log"
  cp -p "$work/coverage-command.log" "$report_dir/coverage/command.log"
fi
if (( coverage_status != 0 )) || [[ ! -f "$coverage_log" ]] || grep -Fq '[ERROR]' "$coverage_log" || [[ -n "$missing" ]]; then echo "harmony-style: coverage probe failed; uninspected sources:$missing" >&2; exit 2; fi
probe_bytes=${#probe}
for relative in "${sources[@]}"; do
  formatted=$module/$relative
  size=$(wc -c < "$formatted" | tr -d ' ')
  (( size >= probe_bytes )) || { echo "harmony-style: coverage probe changed $relative" >&2; exit 2; }
  tail -c "$probe_bytes" "$formatted" | cmp -s - <(printf '%s' "$probe") || { echo "harmony-style: coverage probe changed $relative" >&2; exit 2; }
  head -c $((size - probe_bytes)) "$formatted" > "$formatted.without-probe"; mv "$formatted.without-probe" "$formatted"
done
changed=0
for relative in "${sources[@]}"; do
  formatted=$module/$relative; original=$root/$relative
  if ! cmp -s "$formatted" "$original"; then
    if [[ "$mode" == fix ]]; then cp -p "$formatted" "$original"; changed=$((changed + 1));
    else echo "harmony-style: check unexpectedly changed $original" >&2; exit 2; fi
  fi
done
echo "Harmony Code Linter $version: ${#sources[@]} source files, 0 diagnostics; $changed formatted"
