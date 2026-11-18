#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
framework=${1:?XCFramework directory required for the synthetic engine package test}
[[ -d $framework && $(basename "$framework") == JsBay.xcframework ]] || { echo 'expected a JsBay.xcframework directory' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-swift-multiproduct-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
version=1.2.3
source_sha=0123456789abcdef0123456789abcdef01234567
assets="$work/assets"
output="$work/package"
mkdir -p "$assets"

for backend in quickjs quickjs_ng jsc; do
  package="$work/input/jsbay-${version}-apple-${backend}"
  mkdir -p "$package/Frameworks"
  cp -R "$framework" "$package/Frameworks/"
  ln -s Info.plist "$package/Frameworks/JsBay.xcframework/reproducible-symlink"
  cp -R "$root/sdk/apple/Sources" "$package/"
  cp "$root/sdk/apple/Package.swift" "$package/"
  printf '%s\n' "$version" > "$package/VERSION"
  printf '%s\n' "$source_sha" > "$package/COMMIT"
  printf '%s\n' "$backend" > "$package/backend"
  (cd "$work/input" && zip -qyr "$assets/jsbay-${version}-apple-${backend}-JsBay.xcframework.zip" "$(basename "$package")")
done

bad_assets="$work/missing-map-assets"
bad_package="$work/missing-map-input/jsbay-${version}-apple-quickjs"
bad_output="$work/missing-map-output"
mkdir -p "$bad_assets" "$(dirname "$bad_package")"
cp -R "$work/input/jsbay-${version}-apple-quickjs" "$bad_package"
first_slice=$(plutil -extract AvailableLibraries json -o - "$bad_package/Frameworks/JsBay.xcframework/Info.plist" | jq -r '.[0].LibraryIdentifier')
headers_path=$(plutil -extract AvailableLibraries json -o - "$bad_package/Frameworks/JsBay.xcframework/Info.plist" | jq -r '.[0].HeadersPath')
rm "$bad_package/Frameworks/JsBay.xcframework/$first_slice/$headers_path/module.modulemap"
(cd "$work/missing-map-input" && zip -qyr "$bad_assets/jsbay-${version}-apple-quickjs-JsBay.xcframework.zip" "$(basename "$bad_package")")
if GITHUB_REPOSITORY=jsbay/jsbay bash "$root/scripts/prepare-swift-package-release.sh" \
  "$bad_assets" "$version" "$source_sha" "$bad_output" > "$work/missing-map.log" 2>&1; then
  echo 'package generation unexpectedly accepted a slice with no module map' >&2
  exit 1
fi
grep -F "missing or invalid XCFramework module map for slice $first_slice" "$work/missing-map.log" >/dev/null
test "$(find "$bad_output" -mindepth 1 -print -quit)" = ''
test "$(find "$bad_assets" -name "jsbay-${version}-apple-quickjs-JsBayQuickJS.xcframework.zip" -print -quit)" = ''

GITHUB_REPOSITORY=jsbay/jsbay bash "$root/tests/apple-sdk/single-package-consumer.sh" \
  "$assets" "$version" "$source_sha" "$output"

second_assets="$work/second-assets"
second_output="$work/second-package"
mkdir -p "$second_assets"
for backend in quickjs quickjs_ng jsc; do
  cp "$assets/jsbay-${version}-apple-${backend}-JsBay.xcframework.zip" "$second_assets/"
done
sleep 2
GITHUB_REPOSITORY=jsbay/jsbay bash "$root/scripts/prepare-swift-package-release.sh" \
  "$second_assets" "$version" "$source_sha" "$second_output" > "$work/second-prepare.log"
for module in JsBayQuickJS JsBayQuickJSNG JsBayJavaScriptCore; do
  case "$module" in
    JsBayQuickJS) backend=quickjs ;;
    JsBayQuickJSNG) backend=quickjs_ng ;;
    JsBayJavaScriptCore) backend=jsc ;;
  esac
  first_sha=$(shasum -a 256 "$assets/jsbay-${version}-apple-${backend}-${module}.xcframework.zip" | awk '{print $1}')
  second_sha=$(shasum -a 256 "$second_assets/jsbay-${version}-apple-${backend}-${module}.xcframework.zip" | awk '{print $1}')
  [[ $first_sha == "$second_sha" ]] || { echo "archive checksum changed across runs for $module: $first_sha != $second_sha" >&2; exit 1; }
  test "$(unzip -p "$assets/jsbay-${version}-apple-${backend}-${module}.xcframework.zip" "${module}.xcframework/reproducible-symlink")" = Info.plist
  test "$(unzip -p "$second_assets/jsbay-${version}-apple-${backend}-${module}.xcframework.zip" "${module}.xcframework/reproducible-symlink")" = Info.plist
done
