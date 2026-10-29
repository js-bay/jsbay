#!/usr/bin/env bash
# Link consumers against the headers and library extracted from the release archive.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
archive=${1:?usage: release-desktop-consumer.sh archive version commit backend}
version=${2:?version required}
commit=${3:?commit required}
backend=${4:?backend required}
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-release-consumer.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/unpacked" "$work/bin"
tar -xzf "$archive" -C "$work/unpacked"
shopt -s nullglob
packages=("$work/unpacked"/*)
[[ ${#packages[@]} == 1 && -d ${packages[0]} ]]
package=${packages[0]}
printf '%s\n' "$version" | cmp - "$package/VERSION"
printf '%s\n' "$commit" | cmp - "$package/COMMIT"
printf '%s\n' "$backend" | cmp - "$package/backend"
cmp "$root/LICENSE" "$package/LICENSE"
cmp "$root/THIRD_PARTY_NOTICES.md" "$package/THIRD_PARTY_NOTICES.md"
for header in jsbay.h jsbay_bytecode.h jsbay_sync.h; do
    cmp "$root/include/$header" "$package/include/$header"
done
library="$package/lib/libjsbay.a"
test -s "$library"
zig build --build-file "$root/build.zig" tool -- check-c-abi "$library"
libraries=(-lm -pthread)
if [[ $(uname -s) == Darwin ]]; then
    libraries=(-lm -framework Foundation -framework JavaScriptCore -lobjc -fsanitize=undefined)
fi
for consumer in value_contract_consumer value_edge_consumer jsc_bind_contract_consumer c_consumer bytecode_consumer native_sync_consumer; do
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$package/include" \
        "$root/tests/$consumer.c" "$library" "${libraries[@]}" -o "$work/bin/$consumer"
    "$work/bin/$consumer"
    printf 'RELEASE_CONSUMER_PASS=%s\n' "$consumer"
done
