#!/usr/bin/env bash
# A single unreadable input must invalidate benchmark provenance, even when the final aggregate digest itself can still be calculated.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-benchmark-source-hash.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
real_shasum=$(command -v shasum)
cat >"$tmp/bin/shasum" <<EOF
#!/bin/sh
case "\$*" in
  *bench/interop/c_abi.c*) exit 17 ;;
esac
exec "$real_shasum" "\$@"
EOF
chmod +x "$tmp/bin/shasum"

cd "$root"
if PATH="$tmp/bin:$PATH" make benchmark-interop RUNNER=c_abi >"$tmp/stdout" 2>"$tmp/stderr"; then
    echo "benchmark published success after a source digest read failed" >&2
    exit 1
fi
[ ! -s "$tmp/stdout" ] || { echo "benchmark emitted JSON after a source digest read failed" >&2; exit 1; }
