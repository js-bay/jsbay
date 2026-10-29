#!/usr/bin/env bash
# Build and stage a distributable Harmony SDK 12 HAR on a configured DevEco host.
# Optional env: QUICKJS_BACKEND / JSBAY_BACKEND (quickjs|quickjs_ng, default quickjs) — selects the staged asset name suffix.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
stage_dir=${1:?usage: stage-harmony-har.sh <stage-dir> <version-label>}
version=${2:?usage: stage-harmony-har.sh <stage-dir> <version-label>}
: "${DEVECO_SDK_HOME:?set DEVECO_SDK_HOME to the DevEco SDK 12 directory}"
: "${HVIGORW:?set HVIGORW to the DevEco Hvigor wrapper}"
: "${OHPM:?set OHPM to the Harmony command-line-tools ohpm executable}"
: "${JSBAY_LIBRARY:?set JSBAY_LIBRARY to a matching aarch64-linux-ohos libjsbay.a}"
backend=${QUICKJS_BACKEND:-${JSBAY_BACKEND:-quickjs}}
case "$backend" in
  quickjs_ng|quickjs) ;;
  *)
    echo "QUICKJS_BACKEND must be quickjs or quickjs_ng (got: $backend)" >&2
    exit 2
    ;;
esac

test -d "$DEVECO_SDK_HOME"
test -x "$HVIGORW"
test -x "$OHPM"
test -f "$JSBAY_LIBRARY"

if [[ -n ${AR:-} ]]; then
  ar_tool=$AR
else
  sdk_ar="$DEVECO_SDK_HOME/default/openharmony/native/llvm/bin/llvm-ar"
  if [[ ! -x "$sdk_ar" ]]; then
    echo "Set AR to an LLVM ar that reads Zig GNU archives (for example <DevEco SDK>/default/openharmony/native/llvm/bin/llvm-ar)" >&2
    exit 1
  fi
  ar_tool=$sdk_ar
fi
file_tool=${FILE:-file}
command -v "$ar_tool" >/dev/null
command -v "$file_tool" >/dev/null
command -v tar >/dev/null

work=$(mktemp -d "${TMPDIR:-/tmp}/js-bay-harmony-stage.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

first_member=$("$ar_tool" t "$JSBAY_LIBRARY" | sed -n '1p')
test -n "$first_member"
"$ar_tool" p "$JSBAY_LIBRARY" "$first_member" > "$work/core.o"
core_kind=$("$file_tool" "$work/core.o")
case "$core_kind" in
  *arm64*|*aarch64*) ;;
  *) echo "JSBAY_LIBRARY is not an aarch64 OpenHarmony core: $core_kind" >&2; exit 1 ;;
esac

cd "$repo_root"
bash tests/harmony-sdk/build_har.sh
har=sdk/harmony/build/default/outputs/default/jsbay_harmony.har
test -f "$har"

members="$work/members"
if tar -tzf "$har" > "$members" 2>/dev/null; then
  :
elif command -v unzip >/dev/null && unzip -Z1 "$har" > "$members" 2>/dev/null; then
  :
else
  echo "HAR is neither a gzip tar archive nor a ZIP archive: $har" >&2
  exit 1
fi
sort -o "$members" "$members"
for member in \
  package/libs/arm64-v8a/libjsbay_harmony.so \
  package/ets/modules.abc \
  package/src/main/ets/JsBay.d.ets \
  package/src/main/ets/index.d.ets; do
  grep -Fx "$member" "$members" >/dev/null
done
if grep -Fq 'ConformanceFixture' "$members"; then
  echo "HAR contains the build-only ConformanceFixture" >&2
  exit 1
fi

mkdir -p "$stage_dir"
asset="$stage_dir/jsbay-${version}-harmony-${backend}-arm64-v8a.har"
cp "$har" "$asset"
printf '%s\n' "$backend" > "$stage_dir/backend"
if command -v sha256sum >/dev/null; then
  sha256sum "$asset" > "$stage_dir/SHA256SUMS"
else
  shasum -a 256 "$asset" > "$stage_dir/SHA256SUMS"
fi
printf 'Staged %s\n' "$asset"
