#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-prefix-stamp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts" "$WORK/src/backend/escargot" "$WORK/vendor" "$WORK/prefix"
cp "$ROOT/scripts/native-prefix-stamp.sh" "$WORK/scripts/"
cp "$ROOT/scripts/rebuild-escargot-install.sh" "$ROOT/scripts/rebuild-escargot-android-install.sh" "$WORK/scripts/"
cp "$ROOT/src/backend/escargot/escargot_bridge.cpp" "$ROOT/src/backend/escargot/escargot_bridge.h" "$WORK/src/backend/escargot/"
cp "$ROOT/vendor/escargot-debugger.patch" "$ROOT/vendor/escargot-default-async.patch" "$ROOT/vendor/escargot-module-bindings.patch" "$ROOT/vendor/escargot-execution-termination.patch" "$WORK/vendor/"
check=(bash "$WORK/scripts/native-prefix-stamp.sh" escargot check "$WORK/prefix")
if "${check[@]}"; then echo 'Missing native stamp was accepted.' >&2; exit 1; fi
bash "$WORK/scripts/native-prefix-stamp.sh" escargot write "$WORK/prefix"
"${check[@]}"
printf '\n' >> "$WORK/src/backend/escargot/escargot_bridge.cpp"
if "${check[@]}"; then echo 'Changed native bridge was accepted.' >&2; exit 1; fi
bash "$WORK/scripts/native-prefix-stamp.sh" escargot write "$WORK/prefix"
"${check[@]}"
for input in vendor/escargot-default-async.patch vendor/escargot-module-bindings.patch vendor/escargot-execution-termination.patch scripts/rebuild-escargot-android-install.sh; do
    printf '\n' >> "$WORK/$input"
    if "${check[@]}"; then echo "Changed native prefix input was accepted: $input" >&2; exit 1; fi
    bash "$WORK/scripts/native-prefix-stamp.sh" escargot write "$WORK/prefix"
    "${check[@]}"
done
printf 'invalid\n' > "$WORK/prefix/jsbay-build.sha256"
if "${check[@]}"; then echo 'Invalid native stamp was accepted.' >&2; exit 1; fi
echo 'PASS native prefix freshness checks'

# Reconstruct the published inventory so native stamp checks cannot depend on unshipped source files.
python3 - "$ROOT" "$WORK/package" "${PACKAGE_MANIFEST:-$ROOT/build.zig.zon}" <<'PYTHON'
import pathlib, re, shutil, sys
root, package, manifest = map(pathlib.Path, sys.argv[1:])
paths = re.findall(r'"([^"\n]+)"', manifest.read_text().split('.paths = .{', 1)[1].split('},', 1)[0])
for name in paths:
    source, target = root / name, package / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, target, symlinks=True)
    else:
        shutil.copy2(source, target)
PYTHON
for backend in escargot hermes; do
    mkdir -p "$WORK/package-prefix-$backend"
    bash "$WORK/package/scripts/native-prefix-stamp.sh" "$backend" write "$WORK/package-prefix-$backend"
    bash "$WORK/package/scripts/native-prefix-stamp.sh" "$backend" check "$WORK/package-prefix-$backend"
    if [[ "$backend" == hermes ]]; then
        for input in scripts/hermes-compilejs-libs.sh vendor/hermes-rejection-timers.patch; do
            printf '\n' >> "$WORK/package/$input"
            if bash "$WORK/package/scripts/native-prefix-stamp.sh" hermes check "$WORK/package-prefix-hermes"; then
                echo "Changed Hermes build input was accepted: $input" >&2
                exit 1
            fi
            bash "$WORK/package/scripts/native-prefix-stamp.sh" hermes write "$WORK/package-prefix-hermes"
        done
    fi
done
test -f "$WORK/package/scripts/hermes-compilejs-libs.sh"
echo 'PASS published inventory contains native stamp and rebuild inputs'
