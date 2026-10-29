#!/bin/sh
# ReleaseSafe retains UBSan's indirect-call checks used by the classic QuickJS allocator regression.  Keep one real public consumer on that configuration.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/zig-out-release-safe-quickjs"}
rm -rf "$out"
zig build --build-file "$root/build.zig" -Dbackend=quickjs -Doptimize=ReleaseSafe -Dlibrary-only=true --prefix "$out"
(cd "$root" && zig build tool -- check-c-abi "$out/lib/libjsbay.a")
bash "$root/tests/run-value-consumers.sh" "$out/lib/libjsbay.a" "$out/consumers"
