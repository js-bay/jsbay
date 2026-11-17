#!/bin/bash
# Builds and runs external SPM consumers against a packaged SwiftPackage.
set -euo pipefail
PACKAGE_ROOT="${1:?packaged SwiftPackage path required}"
OUTPUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/jsbay-spm-consumer.XXXXXX")}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/tests/apple-sdk/spm-consumer"
mkdir -p "$OUTPUT/Sources"
cp -R "$FIXTURE/Sources/SwiftConsumer" "$OUTPUT/Sources/"
cp -R "$FIXTURE/Sources/ObjCConsumer" "$OUTPUT/Sources/"
mkdir -p "$OUTPUT/Sources/DedicatedEngineThreadConsumer"
cp "$ROOT/tests/apple-sdk/DedicatedEngineThreadConsumer.swift" "$OUTPUT/Sources/DedicatedEngineThreadConsumer/main.swift"
sed "s#@JSBAY_PACKAGE@#$PACKAGE_ROOT#g" "$FIXTURE/Package.swift.template" > "$OUTPUT/Package.swift"
(
  cd "$OUTPUT"
  swift package dump-package --package-path "$PACKAGE_ROOT" > "$OUTPUT/package.json"
  for target in JsBaySDK JsBayObjC; do
    for setting in 'linkedFramework("JavaScriptCore")' 'linkedFramework("Foundation")' 'linkedLibrary("m")'; do
      if ! jq -e --arg target "$target" --arg setting "$setting" '.targets[] | select(.name == $target) | .settings[]? | select(.tool == "linker") | .kind | to_entries[] | select((.key + "(\"" + .value["_0"] + "\")") == $setting)' "$OUTPUT/package.json" > /dev/null; then
        echo "Swift package target $target must declare $setting" >&2
        exit 1
      fi
    done
  done
  swift build
  swift run SwiftConsumer
  swift run ObjCConsumer
  swift run DedicatedEngineThreadConsumer
)
