#!/usr/bin/env bash
set -euo pipefail

assets_dir=${1:?release assets directory required}
version=${2:?release version required}
source_sha=${3:?source commit SHA required}
output_dir=${4:?generated Swift package output directory required}
root=$(cd "$(dirname "$0")/../.." && pwd)

if [[ ! -f $output_dir/Package.swift ]]; then
  GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-jsbay/jsbay} \
    bash "$root/scripts/prepare-swift-package-release.sh" "$assets_dir" "$version" "$source_sha" "$output_dir"
fi

test ! -e "$output_dir/.git"
test ! -d "$output_dir/Frameworks"
test -f "$output_dir/Package.swift"
if rg -n '/(Users|tmp|private)/|file://' "$output_dir/Package.swift"; then
  echo 'generated manifest contains a local path' >&2
  exit 1
fi

backends=(quickjs quickjs_ng jsc)
modules=(JsBayQuickJS JsBayQuickJSNG JsBayJavaScriptCore)
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-swift-package-consumer.XXXXXX")
trap 'rm -rf "$work"' EXIT
test_package="$work/package"
cp -R "$output_dir" "$test_package"
mkdir -p "$test_package/Frameworks"

for index in "${!backends[@]}"; do
  backend=${backends[$index]}
  module=${modules[$index]}
  source_archive="$assets_dir/jsbay-${version}-apple-${backend}-JsBay.xcframework.zip"
  archive="$assets_dir/jsbay-${version}-apple-${backend}-${module}.xcframework.zip"
  source_root="jsbay-${version}-apple-${backend}"
  test "$(unzip -p "$source_archive" "$source_root/VERSION")" = "$version"
  test "$(unzip -p "$source_archive" "$source_root/COMMIT")" = "$source_sha"
  test "$(unzip -p "$source_archive" "$source_root/backend")" = "$backend"
  test -s "$archive"
  actual_checksum=$(shasum -a 256 "$archive" | awk '{print $1}')
  grep -F "name: \"${module}\", url: \"https://github.com/${GITHUB_REPOSITORY:-jsbay/jsbay}/releases/download/v${version}/$(basename "$archive")\", checksum: \"${actual_checksum}\"" "$output_dir/Package.swift" >/dev/null
  unzip -q "$archive" -d "$test_package/Frameworks"
  framework="$test_package/Frameworks/${module}.xcframework"
  test -f "$framework/Info.plist"
  map_count=0
  while IFS= read -r -d '' modulemap; do
    map_count=$((map_count + 1))
    grep -Fx "module ${module} {" "$modulemap" >/dev/null
    if grep -Fx 'module JsBay {' "$modulemap" >/dev/null; then
      echo "${modulemap} still declares the shared module JsBay" >&2
      exit 1
    fi
  done < <(find "$framework" -name module.modulemap -type f -print0)
  test "$map_count" -gt 0
done

sed -i.bak -E 's@\.binaryTarget\(name: "(JsBay(QuickJS|QuickJSNG|JavaScriptCore))", url: "[^"]+", checksum: "[a-f0-9]+"\)@.binaryTarget(name: "\1", path: "Frameworks/\1.xcframework")@' "$test_package/Package.swift"
rm -f "$test_package/Package.swift.bak"
target_count=$(grep -c 'binaryTarget(name: "JsBay.*path: "Frameworks/' "$test_package/Package.swift")
test "$target_count" -eq 3

package_identity=$(basename "$test_package" | tr '[:upper:]' '[:lower:]')
for index in "${!backends[@]}"; do
  engine=${modules[$index]#JsBay}
  consumer="$work/consumer-$engine"
  mkdir -p "$consumer/Sources/SwiftConsumer" "$consumer/Sources/ObjCConsumer"
  cat > "$consumer/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Consumer${engine}", platforms: [.macOS(.v11)], dependencies: [.package(path: "${test_package}")], targets: [
  .executableTarget(name: "SwiftConsumer", dependencies: [.product(name: "JsBay${engine}SDK", package: "${package_identity}")]),
  .executableTarget(name: "ObjCConsumer", dependencies: [.product(name: "JsBay${engine}ObjC", package: "${package_identity}")])
])
EOF
  sed "s/import JsBaySDK/import JsBay${engine}SDK/" "$root/tests/apple-sdk/spm-consumer/Sources/SwiftConsumer/main.swift" > "$consumer/Sources/SwiftConsumer/main.swift"
  sed "s/@import JsBayObjC;/@import JsBay${engine}ObjC;/" "$root/tests/apple-sdk/spm-consumer/Sources/ObjCConsumer/main.m" > "$consumer/Sources/ObjCConsumer/main.m"
  echo "Building Swift and Objective-C consumers for ${engine}"
  (cd "$consumer" && swift build && swift run SwiftConsumer && swift run ObjCConsumer)
done
