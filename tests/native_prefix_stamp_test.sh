#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-prefix-stamp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts" "$WORK/src/backend/escargot" "$WORK/vendor" "$WORK/prefix"
cp "$ROOT/scripts/native-prefix-stamp.sh" "$WORK/scripts/"
cp "$ROOT/scripts/rebuild-escargot-install.sh" "$WORK/scripts/"
cp "$ROOT/src/backend/escargot/escargot_bridge.cpp" "$ROOT/src/backend/escargot/escargot_bridge.h" "$WORK/src/backend/escargot/"
cp "$ROOT/vendor/escargot-debugger.patch" "$WORK/vendor/"
check=(bash "$WORK/scripts/native-prefix-stamp.sh" escargot check "$WORK/prefix")
if "${check[@]}"; then echo 'Missing native stamp was accepted.' >&2; exit 1; fi
bash "$WORK/scripts/native-prefix-stamp.sh" escargot write "$WORK/prefix"
"${check[@]}"
printf '\n' >> "$WORK/src/backend/escargot/escargot_bridge.cpp"
if "${check[@]}"; then echo 'Changed native bridge was accepted.' >&2; exit 1; fi
bash "$WORK/scripts/native-prefix-stamp.sh" escargot write "$WORK/prefix"
"${check[@]}"
printf 'invalid\n' > "$WORK/prefix/jsbay-build.sha256"
if "${check[@]}"; then echo 'Invalid native stamp was accepted.' >&2; exit 1; fi
echo 'PASS native prefix freshness checks'
