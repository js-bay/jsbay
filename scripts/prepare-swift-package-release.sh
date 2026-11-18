#!/usr/bin/env bash
set -euo pipefail

assets_dir=${1:?release assets directory required}
version=${2:?release version required}
source_sha=${3:?source commit SHA required}
output_dir=${4:?Swift package output directory required}

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo 'invalid release version' >&2; exit 2; }
[[ $source_sha =~ ^[0-9a-fA-F]{7,64}$ ]] || { echo 'invalid source commit SHA' >&2; exit 2; }
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the release repository}
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid GitHub repository' >&2; exit 2; }

assets_dir=$(cd "$assets_dir" && pwd)
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo 'output directory must be empty' >&2
  exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-swift-release.XXXXXX")
package_dir="$work/package"
generated_archives=()
staged_archives=()
cleanup() {
  result=$1
  rm -rf "$work"
  if (( result != 0 )); then
    for archive in "${generated_archives[@]}"; do
      rm -f "$archive"
    done
    rm -rf "$output_dir/Sources" "$output_dir/Package.swift"
  fi
  return "$result"
}
trap 'cleanup "$?"' EXIT
mkdir -p "$package_dir/Sources"

backends=(quickjs quickjs_ng jsc)
modules=(JsBayQuickJS JsBayQuickJSNG JsBayJavaScriptCore)
binary_target_declarations=()
release_urls=()
release_checksums=()

for index in "${!backends[@]}"; do
  backend=${backends[$index]}
  module=${modules[$index]}
  source_archive="$assets_dir/jsbay-${version}-apple-${backend}-JsBay.xcframework.zip"
  [[ -f $source_archive ]] || { echo "missing Apple release archive: $source_archive" >&2; exit 1; }

  unpack="$work/$backend"
  mkdir -p "$unpack"
  unzip -q "$source_archive" -d "$unpack"
  package_root="$unpack/jsbay-${version}-apple-${backend}"
  for required in Package.swift Sources/JsBaySDK/JsBaySDK.swift Sources/JsBaySDK/DedicatedEngineThread.swift Sources/JsBayObjC/JSBay.m Sources/JsBayObjC/include/JSBayObjC.h Frameworks/JsBay.xcframework/Info.plist VERSION COMMIT backend; do
    [[ -e $package_root/$required ]] || { echo "missing $backend package entry: $required" >&2; exit 1; }
  done
  [[ $(cat "$package_root/VERSION") == "$version" ]] || { echo "$backend archive version mismatch" >&2; exit 1; }
  [[ $(cat "$package_root/COMMIT") == "$source_sha" ]] || { echo "$backend archive source SHA mismatch" >&2; exit 1; }
  [[ $(cat "$package_root/backend") == "$backend" ]] || { echo "$backend archive backend mismatch" >&2; exit 1; }

  renamed="$work/${module}.xcframework"
  cp -RP "$package_root/Frameworks/JsBay.xcframework" "$renamed"
  while IFS= read -r -d '' modulemap; do
    sed -i.bak "s/^module JsBay {/module ${module} {/" "$modulemap"
    rm -f "${modulemap}.bak"
  done < <(find "$renamed" -name module.modulemap -type f -print0)
  plutil -extract AvailableLibraries json -o - "$renamed/Info.plist" | jq -er '.[] | [.LibraryIdentifier, .HeadersPath] | @tsv' > "$work/${module}-slices.tsv"
  slice_count=0
  while IFS=$'\t' read -r identifier headers; do
    slice_count=$((slice_count + 1))
    modulemap="$renamed/$identifier/$headers/module.modulemap"
    if [[ ! -f $modulemap ]] || ! grep -Fx "module ${module} {" "$modulemap" >/dev/null; then
      echo "missing or invalid XCFramework module map for slice $identifier: $modulemap" >&2
      exit 1
    fi
  done < "$work/${module}-slices.tsv"
  (( slice_count > 0 )) || { echo "no XCFramework slices found for $backend" >&2; exit 1; }

  while IFS= read -r -d '' file; do
    if [[ -x $file ]]; then
      chmod 755 "$file"
    else
      chmod 644 "$file"
    fi
  done < <(find "$renamed" -type f -print0)
  find "$renamed" -type d -exec chmod 755 {} +
  TZ=UTC find "$renamed" -depth -exec touch -h -t 198001010000 {} +

  final_archive="$assets_dir/jsbay-${version}-apple-${backend}-${module}.xcframework.zip"
  [[ ! -e $final_archive ]] || { echo "release archive already exists: $final_archive" >&2; exit 1; }
  staged_archive="$work/$(basename "$final_archive")"
  staged_archives+=("$staged_archive")
  (cd "$work" && LC_ALL=C find "${module}.xcframework" -print | LC_ALL=C sort | TZ=UTC zip -X -y -q "$staged_archive" -@)
  unzip -Z1 "$staged_archive" | grep -Fx "${module}.xcframework/Info.plist" >/dev/null
  checksum=$(shasum -a 256 "$staged_archive" | awk '{print $1}')
  url="https://github.com/${repository}/releases/download/v${version}/$(basename "$final_archive")"
  swift_target="${module}SDK"
  objc_target="${module}ObjC"
  binary_target_declarations+=(".binaryTarget(name: \"${module}\", url: \"${url}\", checksum: \"${checksum}\")")
  release_urls+=("$url")
  release_checksums+=("$checksum")

  mkdir -p "$package_dir/Sources/$swift_target" "$package_dir/Sources/$objc_target/include"
  cp "$package_root/Sources/JsBaySDK/JsBaySDK.swift" "$package_dir/Sources/$swift_target/"
  cp "$package_root/Sources/JsBaySDK/DedicatedEngineThread.swift" "$package_dir/Sources/$swift_target/"
  sed "s/^import JsBay$/import ${module}/" "$package_dir/Sources/$swift_target/JsBaySDK.swift" > "$work/JsBaySDK.swift"
  mv "$work/JsBaySDK.swift" "$package_dir/Sources/$swift_target/JsBaySDK.swift"
  cp "$package_root/Sources/JsBayObjC/JSBay.m" "$package_dir/Sources/$objc_target/"
  cp "$package_root/Sources/JsBayObjC/include/JSBayObjC.h" "$package_dir/Sources/$objc_target/include/"
  cat > "$package_dir/Sources/$objc_target/include/module.modulemap" <<EOF
module ${objc_target} {
    umbrella header "JSBayObjC.h"
    export *
}
EOF
done

cat > "$package_dir/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "JsBay",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [
    .library(name: "JsBayQuickJSSDK", targets: ["JsBayQuickJSSDK"]),
    .library(name: "JsBayQuickJSObjC", targets: ["JsBayQuickJSObjC"]),
    .library(name: "JsBayQuickJSNGSDK", targets: ["JsBayQuickJSNGSDK"]),
    .library(name: "JsBayQuickJSNGObjC", targets: ["JsBayQuickJSNGObjC"]),
    .library(name: "JsBayJavaScriptCoreSDK", targets: ["JsBayJavaScriptCoreSDK"]),
    .library(name: "JsBayJavaScriptCoreObjC", targets: ["JsBayJavaScriptCoreObjC"]),
  ],
  targets: [
    ${binary_target_declarations[0]},
    .target(
      name: "JsBayQuickJSSDK",
      dependencies: [.target(name: "JsBayQuickJS")],
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .target(
      name: "JsBayQuickJSObjC",
      dependencies: [.target(name: "JsBayQuickJS")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    ${binary_target_declarations[1]},
    .target(
      name: "JsBayQuickJSNGSDK",
      dependencies: [.target(name: "JsBayQuickJSNG")],
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .target(
      name: "JsBayQuickJSNGObjC",
      dependencies: [.target(name: "JsBayQuickJSNG")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    ${binary_target_declarations[2]},
    .target(
      name: "JsBayJavaScriptCoreSDK",
      dependencies: [.target(name: "JsBayJavaScriptCore")],
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .target(
      name: "JsBayJavaScriptCoreObjC",
      dependencies: [.target(name: "JsBayJavaScriptCore")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
  ]
)
EOF

echo "Swift package source: $output_dir"
for index in "${!backends[@]}"; do
  final_archive="$assets_dir/jsbay-${version}-apple-${backends[$index]}-${modules[$index]}.xcframework.zip"
  [[ ! -e $final_archive ]] || { echo "release archive already exists: $final_archive" >&2; exit 1; }
  generated_archives+=("$final_archive")
  mv "${staged_archives[$index]}" "$final_archive"
done
cp -R "$package_dir/." "$output_dir/"
for index in "${!backends[@]}"; do
  backend=${backends[$index]}
  module=${modules[$index]}
  archive="$assets_dir/jsbay-${version}-apple-${backend}-${module}.xcframework.zip"
  echo "release asset: $(basename "$archive")"
  echo "release URL: ${release_urls[$index]}"
  echo "SHA256: ${release_checksums[$index]}"
done
