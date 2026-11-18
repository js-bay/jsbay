#!/usr/bin/env bash
set -euo pipefail

source_archive=${1:?usage: pack-zig-source.sh source-archive zig-package-archive}
output_archive=${2:?output archive required}
source_archive=$(cd "$(dirname "$source_archive")" && pwd)/$(basename "$source_archive")
mkdir -p "$(dirname "$output_archive")"
output_dir=$(cd "$(dirname "$output_archive")" && pwd)
output_archive="$output_dir/$(basename "$output_archive")"
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-zig-package.XXXXXX")
trap 'rm -rf "$work"' EXIT

tar -xzf "$source_archive" -C "$work" --strip-components=1
test -s "$work/build.zig.zon"
test -s "$work/build.zig"
test ! -e "$work/.git"
tar -C "$work" -czf "$output_archive" .
tar -tzf "$output_archive" > "$work/archive-members.txt"
rg -q '^\./build\.zig\.zon$' "$work/archive-members.txt"
