#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
resolver="$repo_root/scripts/harmony-toolchain.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-resolver.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
make_sdk() {
  local root=$1
  mkdir -p "$root/default/openharmony/native/llvm/bin" "$root/command-line-tools/bin"
  : > "$root/default/openharmony/native/llvm/bin/llvm-ar"
  : > "$root/command-line-tools/bin/hvigorw"
  : > "$root/command-line-tools/bin/ohpm"
  chmod +x "$root/default/openharmony/native/llvm/bin/llvm-ar" "$root/command-line-tools/bin/hvigorw" "$root/command-line-tools/bin/ohpm"
}
mkdir -p "$tmp/bin" "$tmp/DevEco.app/Contents/tools/hvigor/bin" "$tmp/DevEco.app/Contents/tools/ohpm/bin"
make_sdk "$tmp/SDK with spaces"
make_sdk "$tmp/Explicit SDK"
mkdir -p "$tmp/Explicit SDK/default/openharmony"
mkdir -p "$tmp/bin"
cp "$tmp/Explicit SDK/default/openharmony/native/llvm/bin/llvm-ar" "$tmp/bin/test-llvm-ar"
mkdir -p "$tmp/DevEco.app/Contents/sdk/default/openharmony/native/llvm/bin"
: > "$tmp/DevEco.app/Contents/sdk/default/openharmony/native/llvm/bin/llvm-ar"
chmod +x "$tmp/DevEco.app/Contents/sdk/default/openharmony/native/llvm/bin/llvm-ar"
: > "$tmp/Explicit SDK/custom-ar"
chmod +x "$tmp/Explicit SDK/custom-ar"
: > "$tmp/DevEco.app/Contents/tools/hvigor/bin/hvigorw"
: > "$tmp/DevEco.app/Contents/tools/ohpm/bin/ohpm"
chmod +x "$tmp/DevEco.app/Contents/tools/hvigor/bin/hvigorw" "$tmp/DevEco.app/Contents/tools/ohpm/bin/ohpm"

if [[ ! -f "$resolver" ]]; then
  echo "FAIL: missing resolver $resolver" >&2
  exit 1
fi

env -i PATH="$tmp/bin:/usr/bin:/bin" DEVECO_HOME="$tmp/DevEco.app" bash -c 'source "$1"; harmony_toolchain_resolve; [[ $DEVECO_SDK_HOME == "$2/Contents/sdk" && $HVIGORW == "$2/Contents/tools/hvigor/bin/hvigorw" && $OHPM == "$2/Contents/tools/ohpm/bin/ohpm" ]]' _ "$resolver" "$tmp/DevEco.app" || fail 'DEVECO_HOME app root resolution'

env -i PATH="$tmp/bin:/usr/bin:/bin" HOS_SDK_HOME="$tmp/SDK with spaces/default/openharmony" bash -c 'source "$1"; harmony_toolchain_resolve; [[ $DEVECO_SDK_HOME == "$2" ]]' _ "$resolver" "$tmp/SDK with spaces" || fail 'HOS_SDK_HOME SDK root resolution'

env -i PATH="$tmp/bin:/usr/bin:/bin" OHOS_BASE_SDK_HOME="$tmp/SDK with spaces/default/openharmony" bash -c 'source "$1"; harmony_toolchain_resolve; [[ $DEVECO_SDK_HOME == "$2" ]]' _ "$resolver" "$tmp/SDK with spaces" || fail 'OHOS_BASE_SDK_HOME SDK root resolution'

env -i PATH="$tmp/Explicit SDK/command-line-tools/bin:$tmp/bin:/usr/bin:/bin" DEVECO_SDK_HOME="$tmp/Explicit SDK" AR=test-llvm-ar bash -c 'source "$1"; harmony_toolchain_resolve; [[ $HVIGORW == "$2/command-line-tools/bin/hvigorw" && $OHPM == "$2/command-line-tools/bin/ohpm" && $AR == "$3/test-llvm-ar" ]]' _ "$resolver" "$tmp/Explicit SDK" "$tmp/bin" || fail 'PATH tools and archive command resolution'

env -i PATH="$tmp/bin:/usr/bin:/bin" DEVECO_SDK_HOME="$tmp/Explicit SDK" HVIGORW="$tmp/Explicit SDK/command-line-tools/bin/hvigorw" OHPM="$tmp/Explicit SDK/command-line-tools/bin/ohpm" AR="$tmp/Explicit SDK/custom-ar" DEVECO_HOME="$tmp/SDK with spaces" bash -c 'source "$1"; harmony_toolchain_resolve; [[ $DEVECO_SDK_HOME == "$2" && $AR == "$2/custom-ar" ]]' _ "$resolver" "$tmp/Explicit SDK" || fail 'explicit overrides must take precedence'

if env -i PATH="$tmp/bin:/usr/bin:/bin" DEVECO_SDK_HOME="$tmp/missing" HOS_SDK_HOME="$tmp/SDK with spaces" bash -c 'source "$1"; harmony_toolchain_resolve' _ "$resolver" 2>/dev/null; then fail 'invalid explicit SDK must fail despite valid alias'; fi
if env -i PATH="$tmp/bin:/usr/bin:/bin" HOS_SDK_HOME="$tmp/missing" DEVECO_HOME="$tmp/DevEco.app" bash -c 'source "$1"; harmony_toolchain_resolve' _ "$resolver" 2>/dev/null; then fail 'invalid HOS_SDK_HOME must fail rather than fall back'; fi
if env -i PATH="$tmp/bin:/usr/bin:/bin" OHOS_BASE_SDK_HOME="$tmp/missing" DEVECO_HOME="$tmp/DevEco.app" bash -c 'source "$1"; harmony_toolchain_resolve' _ "$resolver" 2>/dev/null; then fail 'invalid OHOS_BASE_SDK_HOME must fail rather than fall back'; fi
if env -i PATH="$tmp/bin:/usr/bin:/bin" DEVECO_HOME="$tmp/missing" bash -c 'source "$1"; harmony_toolchain_resolve' _ "$resolver" 2>/dev/null; then fail 'invalid DEVECO_HOME must fail rather than use a default installation'; fi
if env -i PATH="$tmp/bin:/usr/bin:/bin" DEVECO_SDK_HOME="$tmp/Explicit SDK" HVIGORW="$tmp/missing" bash -c 'source "$1"; harmony_toolchain_resolve' _ "$resolver" 2>/dev/null; then fail 'invalid executable override must fail'; fi
touch "$tmp/sentinel"
env -i PATH="$tmp/bin:/usr/bin:/bin" HOS_SDK_HOME="$tmp/SDK with spaces/default/openharmony" bash -c 'source "$1"; harmony_toolchain_resolve' _ "$resolver" || fail 'valid HOS_SDK_HOME resolver call'
[[ -f "$tmp/sentinel" ]] || fail 'resolver changed unrelated files'

echo 'Harmony toolchain resolver tests passed.'
