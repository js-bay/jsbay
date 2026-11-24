#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo 'Usage: pawl-ratchet.sh <base-ref>' >&2
    exit 2
fi

root="$(git rev-parse --show-toplevel)"
base="$(git -C "$root" rev-parse --verify "$1^{commit}")"
pawl="${PAWL:-pawl}"
work="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-pawl-ratchet.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/base"
git -C "$root" archive "$base" | tar -xf - -C "$work/base"
for definition in pawl.ratchet.yaml pawl.length.yaml scripts/quality/pawl-long-lines.mjs scripts/quality/pawl-ratchet.sh scripts/quality/pawl-config-migration.mjs; do
    if git -C "$root" cat-file -e "$base:$definition" 2>/dev/null && ! cmp -s "$root/$definition" "$work/base/$definition"; then
        if { [ "$definition" = pawl.length.yaml ] || [ "$definition" = scripts/quality/pawl-ratchet.sh ]; } && node "$root/scripts/quality/pawl-config-migration.mjs" "$definition" "$work/base/$definition" "$root/$definition"; then
            continue
        fi
        echo "Ratchet definition changed: $definition" >&2
        exit 2
    fi
done
node "$(dirname "$0")/pawl-baseline-renames.mjs" "$root" "$base" "$work/base"
cp "$root/pawl.ratchet.yaml" "$work/base/pawl.ratchet.yaml"
cp "$root/pawl.length.yaml" "$work/base/pawl.length.yaml"
mkdir -p "$work/base/scripts/quality"
cp "$root/scripts/quality/pawl-long-lines.mjs" "$work/base/scripts/quality/pawl-long-lines.mjs"

"$pawl" measure -c "$root/pawl.ratchet.yaml" > "$work/current.json"
if ! "$pawl" record -c "$work/base/pawl.ratchet.yaml" > "$work/record.log"; then
    cat "$work/record.log" >&2
    exit 2
fi
"$pawl" check -c "$work/base/pawl.ratchet.yaml" --current "$work/current.json" --format json
