#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
gate="$repo_root/scripts/check-harmony-local.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-local-gate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  for log in "$tmp/success.log" "$tmp/failure.log" "$tmp/missing-har.log"; do
    if [[ -f $log ]]; then cat "$log" >&2; fi
  done
  if [[ -d $tmp/success ]]; then ls -R "$tmp/success" >&2; fi
  exit 1
}
mkdir -p "$tmp/bin" "$tmp/modules/@ohos/hvigor" "$tmp/modules/@ohos/hvigor-ohos-plugin" "$tmp/sdk/default/openharmony/native/llvm/bin" "$tmp/sdk/default/openharmony/native/sysroot" "$tmp/sdk/command-line-tools/bin"
printf '%s\n' '{"name":"@ohos/hvigor"}' > "$tmp/modules/@ohos/hvigor/package.json"
printf '%s\n' '{"name":"@ohos/hvigor-ohos-plugin"}' > "$tmp/modules/@ohos/hvigor-ohos-plugin/package.json"
for tool in llvm-ar hvigorw ohpm; do
  : > "$tmp/sdk/default/openharmony/native/llvm/bin/$tool"
  chmod +x "$tmp/sdk/default/openharmony/native/llvm/bin/$tool"
done
for tool in hvigorw ohpm; do
  : > "$tmp/sdk/command-line-tools/bin/$tool"
  chmod +x "$tmp/sdk/command-line-tools/bin/$tool"
done

cat > "$tmp/bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
backend=''
prefix=''
while (($#)); do
  case "$1" in
    -Dbackend=*) backend=${1#*=} ;;
    --prefix) shift; prefix=$1 ;;
  esac
  shift
done
printf '%s\n' "$backend" >> "$HARMONY_BACKENDS_FILE"
printf '%s\n' "$PWD" >> "$HARMONY_BUILD_CWD_FILE"
mkdir -p "$prefix/lib"
: > "$prefix/lib/libjsbay.a"
EOF
chmod +x "$tmp/bin/zig"

cat > "$tmp/mock-stage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
stage_dir=$1
version=$2
backend=${QUICKJS_BACKEND:?}
printf '%s\n' "$backend" >> "$HARMONY_STAGED_FILE"
if [[ ${HARMONY_STAGE_MODE:-} == fail-backend && $backend == quickjs_ng ]]; then exit 17; fi
if [[ ${HARMONY_STAGE_MODE:-} == omit-har ]]; then exit 0; fi
mkdir -p "$stage_dir"
printf '%s\n' "$backend" > "$stage_dir/backend"
printf '%s\n' 'fake HAR' > "$stage_dir/jsbay-${version}-harmony-${backend}-arm64-v8a.har"
printf '%s\n' 'fake checksum' > "$stage_dir/SHA256SUMS"
EOF
chmod +x "$tmp/mock-stage.sh"

export DEVECO_SDK_HOME="$tmp/sdk"
export NODE_PATH="$tmp/modules"
export HVIGORW="$tmp/sdk/command-line-tools/bin/hvigorw"
export OHPM="$tmp/sdk/command-line-tools/bin/ohpm"
export ZIG_BIN="$tmp/bin/zig"
export HARMONY_STAGE_SCRIPT="$tmp/mock-stage.sh"
export HARMONY_BACKENDS_FILE="$tmp/backends"
export HARMONY_STAGED_FILE="$tmp/staged"
export HARMONY_BUILD_CWD_FILE="$tmp/build-cwds"

if [[ ! -x $gate ]]; then fail "missing executable local gate: $gate"; fi

(cd "$tmp" && "$gate" "$tmp/success") > "$tmp/success.log" 2>&1 || fail 'both backend HAR builds should pass'
[[ $(cat "$HARMONY_BACKENDS_FILE") == $'quickjs_ng\nquickjs' ]] || fail 'both backend core builds must run in a stable order'
[[ $(cat "$HARMONY_BUILD_CWD_FILE") == "$repo_root"$'\n'"$repo_root" ]] || fail 'core builds must use the script checkout rather than the caller working directory'
[[ $(cat "$HARMONY_STAGED_FILE") == $'quickjs_ng\nquickjs' ]] || fail 'both backend HAR stages must run'
for backend in quickjs_ng quickjs; do
  test -s "$tmp/success/$backend/stage/jsbay-local-$backend-harmony-$backend-arm64-v8a.har" || fail "missing $backend HAR output"
  grep -Fxq 'EXIT=0' "$tmp/success/$backend/build.log" || fail "$backend build log must record its exit code"
  grep -Fxq 'EXIT=0' "$tmp/success/$backend/har.log" || fail "$backend HAR log must record its exit code"
done
grep -Fxq 'OVERALL=PASS' "$tmp/success/summary.txt" || fail 'success report must have an explicit aggregate result'
grep -Fxq "SDK_ROOT=$tmp/sdk" "$tmp/success/summary.txt" || fail 'resolved SDK root must be reported'
grep -Fxq "HVIGORW=$tmp/sdk/command-line-tools/bin/hvigorw" "$tmp/success/summary.txt" || fail 'resolved Hvigor path must be reported'
grep -Fxq "OHPM=$tmp/sdk/command-line-tools/bin/ohpm" "$tmp/success/summary.txt" || fail 'resolved OHPM path must be reported'

if "$gate" "$repo_root/tmp-harmony-gate-must-not-be-created" > "$tmp/in-repo.log" 2>&1; then
  fail 'the gate must reject output paths inside the checkout'
fi
test ! -e "$repo_root/tmp-harmony-gate-must-not-be-created" || fail 'rejected output path must not be created'
if "$gate" "$repo_root/nested/path/output" > "$tmp/nested-in-repo.log" 2>&1; then fail 'the gate must reject nested output paths inside the checkout'; fi
test ! -e "$repo_root/nested" || fail 'nested rejected output must not create any checkout path'
if "$gate" "$repo_root/missing-parent/../normalized-output" > "$tmp/dotdot-in-repo.log" 2>&1; then fail 'the gate must reject normalized paths inside the checkout'; fi
test ! -e "$repo_root/missing-parent" || fail 'normalizing a rejected path must not create its missing parent'
ln -s "$repo_root" "$tmp/checkout-link"
if "$gate" "$tmp/checkout-link/symlink-output" > "$tmp/symlink-in-repo.log" 2>&1; then fail 'the gate must reject output reached through a checkout symlink'; fi
test ! -e "$repo_root/symlink-output" || fail 'symlink rejected output must not create a checkout path'
ln -s "$repo_root" "$tmp/output-link"
if "$gate" "$tmp/output-link" > "$tmp/symlink-output.log" 2>&1; then fail 'the gate must reject an output directory symlink into the checkout'; fi


rm -f "$HARMONY_BACKENDS_FILE" "$HARMONY_STAGED_FILE"
export HARMONY_STAGE_MODE=fail-backend
if "$gate" "$tmp/failure" > "$tmp/failure.log" 2>&1; then fail 'a failed backend must fail the local gate'; fi
[[ $(cat "$HARMONY_BACKENDS_FILE") == 'quickjs_ng' ]] || fail 'the gate must stop immediately after a backend failure'
[[ $(cat "$HARMONY_STAGED_FILE") == 'quickjs_ng' ]] || fail 'the failed backend must be recorded as attempted'
grep -Fxq 'EXIT=17' "$tmp/failure/quickjs_ng/har.log" || fail 'failed HAR log must preserve the tool exit code'
grep -Fxq 'quickjs_ng HAR EXIT=17' "$tmp/failure/summary.txt" || fail 'failure report must identify the failed backend'

rm -f "$HARMONY_BACKENDS_FILE" "$HARMONY_STAGED_FILE"
export HARMONY_STAGE_MODE=omit-har
if "$gate" "$tmp/missing-har" > "$tmp/missing-har.log" 2>&1; then fail 'a successful stage command without a HAR must fail'; fi
grep -Fq 'missing or empty HAR output' "$tmp/missing-har.log" || fail 'missing HAR failure must be explicit'
grep -Fxq 'quickjs_ng staged-HAR validation FAIL' "$tmp/missing-har/summary.txt" || fail 'missing HAR report must identify validation failure'
if grep -Fq 'OVERALL=PASS' "$tmp/missing-har/summary.txt"; then fail 'missing HAR must never produce a passing report'; fi

echo 'Harmony local HAR gate tests passed.'
