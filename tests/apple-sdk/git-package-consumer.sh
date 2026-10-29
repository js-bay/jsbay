#!/bin/bash
# Validate that an Apple release zip can become a fresh Git Swift Package. Usage: tests/apple-sdk/git-package-consumer.sh <apple-zip> <output-dir>
set -euo pipefail

APPLE_ZIP="${1:?Apple release zip path required}"
OUTPUT_DIR="${2:?output directory required}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/tests/apple-sdk/spm-consumer"

if [ ! -f "$APPLE_ZIP" ]; then
    echo "ERROR: Apple release zip does not exist: $APPLE_ZIP" >&2
    exit 1
fi

SEMVER="$(sed -nE 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ROOT/build.zig.zon")"
if [[ ! "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "ERROR: build.zig.zon has no valid semantic version" >&2
    exit 1
fi

PACKAGE_NAME="$(unzip -Z1 "$APPLE_ZIP" | awk -F/ 'NF { print $1 }' | sort -u)"
TOP_LEVEL_COUNT="$(printf '%s\n' "$PACKAGE_NAME" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$TOP_LEVEL_COUNT" -ne 1 ]; then
    echo "ERROR: Apple release zip must have exactly one top-level directory" >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"
UNPACKED="$OUTPUT_DIR/unpacked"
BARE_REPO="$OUTPUT_DIR/JsBay.git"
CONSUMER="$OUTPUT_DIR/consumer"
rm -rf "$UNPACKED" "$BARE_REPO" "$CONSUMER"
unzip -q "$APPLE_ZIP" -d "$UNPACKED"
PACKAGE_ROOT="$UNPACKED/$PACKAGE_NAME"

if [ -e "$PACKAGE_ROOT/.git" ]; then
    echo "ERROR: release package must not contain Git history" >&2
    exit 1
fi

for required in \
    "$PACKAGE_ROOT/Package.swift" \
    "$PACKAGE_ROOT/Sources" \
    "$PACKAGE_ROOT/Frameworks/JsBay.xcframework" \
    "$PACKAGE_ROOT/LICENSE" \
    "$PACKAGE_ROOT/THIRD_PARTY_NOTICES.md" \
    "$PACKAGE_ROOT/VERSION" \
    "$PACKAGE_ROOT/COMMIT" \
    "$PACKAGE_ROOT/backend"; do
    test -e "$required" || {
        echo "ERROR: release package is missing $required" >&2
        exit 1
    }
done

git -C "$PACKAGE_ROOT" init -q
git -C "$PACKAGE_ROOT" add .
git -C "$PACKAGE_ROOT" -c user.name='JsBay release test' -c user.email='release-test@example.invalid' \
    commit -qm "release $SEMVER"
git -C "$PACKAGE_ROOT" tag "$SEMVER"
git clone --bare -q "$PACKAGE_ROOT" "$BARE_REPO"

mkdir -p "$CONSUMER/Sources"
cp -R "$FIXTURE/Sources/SwiftConsumer" "$CONSUMER/Sources/"
cp -R "$FIXTURE/Sources/ObjCConsumer" "$CONSUMER/Sources/"
sed "s#\.package(name: \"JsBay\", path: \"@JSBAY_PACKAGE@\")#.package(url: \"file://$BARE_REPO\", from: \"$SEMVER\")#" \
    "$FIXTURE/Package.swift.template" > "$CONSUMER/Package.swift"

(
    cd "$CONSUMER"
    swift build
    swift run SwiftConsumer
    swift run ObjCConsumer
)
