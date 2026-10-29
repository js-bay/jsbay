#!/bin/bash
# Builds and runs two external SPM consumers against a packaged SwiftPackage.
set -euo pipefail
PACKAGE_ROOT="${1:?packaged SwiftPackage path required}"
OUTPUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/jsbay-spm-consumer.XXXXXX")}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/tests/apple-sdk/spm-consumer"
mkdir -p "$OUTPUT/Sources"
cp -R "$FIXTURE/Sources/SwiftConsumer" "$OUTPUT/Sources/"
cp -R "$FIXTURE/Sources/ObjCConsumer" "$OUTPUT/Sources/"
sed "s#@JSBAY_PACKAGE@#$PACKAGE_ROOT#g" "$FIXTURE/Package.swift.template" > "$OUTPUT/Package.swift"
(
  cd "$OUTPUT"
  swift build
  swift run SwiftConsumer
  swift run ObjCConsumer
)
