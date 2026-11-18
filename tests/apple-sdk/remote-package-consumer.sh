#!/usr/bin/env bash
set -euo pipefail

package_dir=${1:?generated Swift package directory required}
version=${2:?release version required}
root=$(cd "$(dirname "$0")/../.." && pwd)
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the release repository}
simulator=${JSBAY_IOS_SIM_UDID:?set JSBAY_IOS_SIM_UDID to a booted iOS Simulator}
local_package=${JSBAY_SWIFTPM_LOCAL_PACKAGE:-0}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo 'invalid release version' >&2; exit 2; }
test -f "$package_dir/Package.swift"
simulator_state=$(xcrun simctl list devices | grep -F "$simulator" || true)
printf '%s\n' "$simulator_state" | grep -Fq '(Booted)' || { echo "Simulator is not booted: $simulator" >&2; exit 1; }
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
case "$(uname -m)" in
  arm64|aarch64) simulator_triple=arm64-apple-ios14.0-simulator ;;
  x86_64) simulator_triple=x86_64-apple-ios13.0-simulator ;;
  *) echo 'unsupported simulator host architecture' >&2; exit 2 ;;
esac

backends=(quickjs quickjs_ng jsc)
modules=(JsBayQuickJS JsBayQuickJSNG JsBayJavaScriptCore)
if [[ $local_package == 1 ]]; then
  test -d "$package_dir/Frameworks"
  package_dependency=".package(path: \"${package_dir}\")"
  package_identity=$(basename "$package_dir" | tr '[:upper:]' '[:lower:]')
else
  test ! -d "$package_dir/Frameworks"
  for index in "${!backends[@]}"; do
    backend=${backends[$index]}
    module=${modules[$index]}
    archive="jsbay-${version}-apple-${backend}-${module}.xcframework.zip"
    grep -F "https://github.com/${repository}/releases/download/v${version}/${archive}" "$package_dir/Package.swift" >/dev/null
    grep -F ".binaryTarget(name: \"${module}\", url:" "$package_dir/Package.swift" >/dev/null
  done
  package_dependency=".package(url: \"https://github.com/${repository}.git\", exact: \"${version}\")"
  package_identity=$(basename "$repository" | tr '[:upper:]' '[:lower:]')
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-remote-package-consumer.XXXXXX")
trap 'rm -rf "$work"' EXIT
for index in "${!backends[@]}"; do
  engine=${modules[$index]#JsBay}
  consumer="$work/consumer-$engine"
  mkdir -p "$consumer/Sources/SwiftConsumer" "$consumer/Sources/ObjCConsumer"
  cat > "$consumer/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RemoteConsumer${engine}", platforms: [.iOS(.v13), .macOS(.v11)], dependencies: [${package_dependency}], targets: [
  .executableTarget(name: "SwiftConsumer", dependencies: [.product(name: "JsBay${engine}SDK", package: "${package_identity}")]),
  .executableTarget(name: "ObjCConsumer", dependencies: [.product(name: "JsBay${engine}ObjC", package: "${package_identity}")])
])
EOF
  sed "s/import JsBaySDK/import JsBay${engine}SDK/" "$root/tests/apple-sdk/spm-consumer/Sources/SwiftConsumer/main.swift" > "$consumer/Sources/SwiftConsumer/main.swift"
  sed "s/@import JsBayObjC;/@import JsBay${engine}ObjC;/" "$root/tests/apple-sdk/spm-consumer/Sources/ObjCConsumer/main.m" > "$consumer/Sources/ObjCConsumer/main.m"
  if [[ $local_package != 1 ]]; then
    echo "Building remote Swift and Objective-C products for ${engine}"
    (cd "$consumer" && swift build && swift run SwiftConsumer && swift run ObjCConsumer)
  fi
  for product in SwiftConsumer ObjCConsumer; do
    echo "Building ${product} for iOS Simulator (${simulator_triple})"
    (cd "$consumer" && swift build --triple "$simulator_triple" --sdk "$simulator_sdk" --product "$product")
    simulator_bin_dir=$(cd "$consumer" && swift build --show-bin-path --triple "$simulator_triple" --sdk "$simulator_sdk")
    binary="$simulator_bin_dir/$product"
    test -x "$binary" || { echo "missing iOS Simulator consumer executable: $binary" >&2; exit 1; }
    codesign -s - --force --timestamp=none "$binary"
    simulator_output=$(xcrun simctl spawn "$simulator" "$binary" 2>&1)
    printf '%s\n' "$simulator_output"
    echo "PASS iOS Simulator ${product} for ${engine}"
  done
done
