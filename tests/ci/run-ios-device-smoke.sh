#!/usr/bin/env bash
# Build the SDK consumer from this checkout and run it on a provisioned iPhone.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
backend=${1:-quickjs_ng}
: "${JSBAY_IOS_DEVICE_ID:?configure a connected device}"
: "${JSBAY_IOS_SIGNING_IDENTITY:?configure an installed signing identity}"
: "${JSBAY_IOS_PROVISIONING_PROFILE:?configure a matching provisioning profile}"
: "${JSBAY_IOS_ENTITLEMENTS:?configure matching signing entitlements}"
: "${JSBAY_IOS_BUNDLE_ID:?configure the provisioned app bundle identifier}"
test -f "$JSBAY_IOS_PROVISIONING_PROFILE"
test -f "$JSBAY_IOS_ENTITLEMENTS"
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-ios-device.XXXXXX")
installed=false
cleanup() {
    if [[ "$installed" == true ]]; then
        xcrun devicectl --timeout 60 device uninstall app --device "$JSBAY_IOS_DEVICE_ID" "$JSBAY_IOS_BUNDLE_ID" || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
BUILD_DIR="$work/apple" bash "$root/build-apple.sh" "$backend"
archives=("$work/apple/JsBay.xcframework/ios-arm64/"*.a)
[[ ${#archives[@]} == 1 ]]
bash "$root/tests/apple-sdk/run.sh" "${archives[0]}" "$work/consumer" "$backend" iphoneos
app="$work/consumer/JsBayAppleConsumer.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $JSBAY_IOS_BUNDLE_ID" "$app/Info.plist"
cp "$JSBAY_IOS_PROVISIONING_PROFILE" "$app/embedded.mobileprovision"
codesign --force --sign "$JSBAY_IOS_SIGNING_IDENTITY" --entitlements "$JSBAY_IOS_ENTITLEMENTS" "$app"
xcrun devicectl --timeout 120 device install app --device "$JSBAY_IOS_DEVICE_ID" "$app"
installed=true
xcrun devicectl --timeout 180 device process launch --device "$JSBAY_IOS_DEVICE_ID" \
    --console --terminate-existing "$JSBAY_IOS_BUNDLE_ID" > "$work/device.log" 2>&1
cat "$work/device.log"
grep -F 'JSBAY_APPLE_CONSUMER_PASS' "$work/device.log"
grep -F 'JSBAY_IOS13_IO_COMPAT_PASS' "$work/device.log"
