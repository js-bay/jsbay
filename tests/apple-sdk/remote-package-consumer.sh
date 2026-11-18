#!/usr/bin/env bash
set -euo pipefail

package_dir=${1:?generated Swift package directory required}
version=${2:?release version required}
root=$(cd "$(dirname "$0")/../.." && pwd)
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the release repository}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo 'invalid release version' >&2; exit 2; }
test -f "$package_dir/Package.swift"
test ! -d "$package_dir/Frameworks"

backends=(quickjs quickjs_ng jsc)
modules=(JsBayQuickJS JsBayQuickJSNG JsBayJavaScriptCore)
for index in "${!backends[@]}"; do
  backend=${backends[$index]}
  module=${modules[$index]}
  archive="jsbay-${version}-apple-${backend}-${module}.xcframework.zip"
  grep -F "https://github.com/${repository}/releases/download/v${version}/${archive}" "$package_dir/Package.swift" >/dev/null
  grep -F ".binaryTarget(name: \"${module}\", url:" "$package_dir/Package.swift" >/dev/null
done

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-remote-package-consumer.XXXXXX")
trap 'rm -rf "$work"' EXIT
package_identity=$(basename "$package_dir" | tr '[:upper:]' '[:lower:]')
for index in "${!backends[@]}"; do
  engine=${modules[$index]#JsBay}
  consumer="$work/consumer-$engine"
  mkdir -p "$consumer/Sources/SwiftConsumer" "$consumer/Sources/ObjCConsumer"
  cat > "$consumer/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RemoteConsumer${engine}", platforms: [.macOS(.v11)], dependencies: [.package(path: "${package_dir}")], targets: [
  .executableTarget(name: "SwiftConsumer", dependencies: [.product(name: "JsBay${engine}SDK", package: "${package_identity}")]),
  .executableTarget(name: "ObjCConsumer", dependencies: [.product(name: "JsBay${engine}ObjC", package: "${package_identity}")])
])
EOF
  sed "s/import JsBaySDK/import JsBay${engine}SDK/" "$root/tests/apple-sdk/spm-consumer/Sources/SwiftConsumer/main.swift" > "$consumer/Sources/SwiftConsumer/main.swift"
  sed "s/@import JsBayObjC;/@import JsBay${engine}ObjC;/" "$root/tests/apple-sdk/spm-consumer/Sources/ObjCConsumer/main.m" > "$consumer/Sources/ObjCConsumer/main.m"
  echo "Building remote Swift and Objective-C products for ${engine}"
  (cd "$consumer" && swift build && swift run SwiftConsumer && swift run ObjCConsumer)
done
