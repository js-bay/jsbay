#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${HERMES_SRC:-$ROOT/vendor/hermes}"
PINNED_REVISION="9a51f48dcbccf0eddd0b67c687d17b3ab4cede58"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

actual_revision="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$actual_revision" != "$PINNED_REVISION" ]]; then
  echo "Hermes source revision mismatch: expected $PINNED_REVISION, got $actual_revision" >&2
  exit 1
fi

WORK="$TMP/hermes"
mkdir -p "$WORK/utils" "$WORK/lib/InternalBytecode"
cp -R "$SRC/utils/promise" "$WORK/utils/"
cp "$SRC/utils/gen-promise-internal-bc.sh" "$WORK/utils/"
git -C "$SRC" show "$PINNED_REVISION:lib/InternalBytecode/01-Promise.js" > "$WORK/lib/InternalBytecode/01-Promise.js"

patch -d "$WORK" -p1 --forward --batch < "$ROOT/vendor/hermes-promise-generator-hook.patch"
JSBAY_HERMES_PROMISE_TRACKER_PATCH="$ROOT/vendor/hermes-promise-tracker-source.patch" \
  sh "$WORK/utils/gen-promise-internal-bc.sh"
cp "$WORK/lib/InternalBytecode/01-Promise.js" "$TMP/generated-01-Promise.js"
git -C "$SRC" show "$PINNED_REVISION:lib/InternalBytecode/01-Promise.js" > "$WORK/lib/InternalBytecode/01-Promise.js"
patch -d "$WORK" -p1 --forward --batch < "$ROOT/vendor/hermes-promise-tracker-checkpoint.patch"
cmp "$TMP/generated-01-Promise.js" "$WORK/lib/InternalBytecode/01-Promise.js"

echo "Hermes Promise tracker generation matches the pinned source patches."
