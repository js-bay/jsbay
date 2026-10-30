#!/bin/bash
# Build JS Bay as an XCFramework for Apple platforms (macOS + iOS + iOS Simulator).
# Usage: ./build-apple.sh [quickjs|quickjs_ng|jsc]
#
# Optional env:
#   JSBAY_APPLE_BACKEND
#       Backend override; wins over the positional argument (default: jsc)
#   RELEASE_VERSION  written into build-apple/VERSION when set
#   RELEASE_COMMIT   written into build-apple/COMMIT when set
#   OPTIMIZE         Zig optimize mode (default ReleaseSafe)
#   BUILD_DIR        output directory (default: <repo>/build-apple)
#   JSBAY_SKIP_IOS_ZIG_CONSUMER=1
#       Skip tests/zig-consumer `zig build check` for aarch64-ios when Zig 0.17
#       cannot link against Xcode 26+ arm64e-only system TBDs. clang probes still run.
#       Legacy alias: JS_BAY_SKIP_IOS_ZIG_CONSUMER.
#   JSBAY_FORCE_IOS_ZIG_CONSUMER=1
#       Always run the Zig iOS consumer even when the SDK looks arm64e-only.
#       Legacy alias: JS_BAY_FORCE_IOS_ZIG_CONSUMER.
#   JSBAY_APPLE_SMOKE=simulator
#       Build and run only the host-architecture iOS Simulator slice. Skip the macOS slice, the device slice, the other simulator architecture, the three-slice XCFramework, and Swift package packaging. The full script remains the release and daily path.
set -euo pipefail

BACKEND="${JSBAY_APPLE_BACKEND:-${1:-jsc}}"
case "$BACKEND" in
    quickjs|quickjs_ng|jsc) ;;
    *)
        echo "ERROR: backend must be quickjs, quickjs_ng, or jsc (got: $BACKEND)" >&2
        exit 2
        ;;
esac
case "${JSBAY_APPLE_SMOKE:-}" in
    ""|simulator) ;;
    *)
        echo "ERROR: JSBAY_APPLE_SMOKE must be empty or simulator (got: ${JSBAY_APPLE_SMOKE})" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build-apple}"
XCFW_NAME="JsBay"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"

# Resolve Apple SDK paths (requires Xcode CLT / full Xcode).
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

COMMON_FLAGS="-Dbackend=$BACKEND -Doptimize=$OPTIMIZE -Dlibrary-only=true -Dapple-package=true"

zig build --build-file "$SCRIPT_DIR/build.zig" install-tool
ARCHIVE_TOOL=("$SCRIPT_DIR/zig-out/bin/jsbay-tool" apple-archive)
CONSUMER_PROBE="$SCRIPT_DIR/scripts/apple_consumer_probe.c"
CONSUMER_IOS_MAIN="$SCRIPT_DIR/scripts/apple_consumer_ios_main.m"
CONSUMER_IOS_PLIST="$SCRIPT_DIR/scripts/apple_consumer_ios_Info.plist"

normalize_archive() {
    local source="$1"
    local output="$2"
    local check_rc=0
    if "${ARCHIVE_TOOL[@]}" check "$source"; then
        cp "$source" "$output"
        return
    else
        check_rc=$?
    fi
    if [ "$check_rc" -ne 1 ]; then
        echo "ERROR: cannot inspect Apple archive $source" >&2
        return "$check_rc"
    fi

    local work objects filelist rebuilt
    work="$(mktemp -d "$BUILD_DIR/archive-normalize.XXXXXX")"
    objects="$work/objects"
    filelist="$work/objects.list"
    rebuilt="$work/libjsbay.a"
    "${ARCHIVE_TOOL[@]}" extract "$source" "$objects" --filelist "$filelist"
    xcrun libtool -static -D -filelist "$filelist" -o "$rebuilt"
    "${ARCHIVE_TOOL[@]}" check "$rebuilt"
    cp "$rebuilt" "$output"
    rm -rf "$work"
}

verify_xcframework_archives() {
    local archive count=0
    while IFS= read -r archive; do
        "${ARCHIVE_TOOL[@]}" check "$archive"
        count=$((count + 1))
    done < <(find "$BUILD_DIR/$XCFW_NAME.xcframework" -type f -name '*.a' | sort)
    if [ "$count" -ne 3 ]; then
        echo "ERROR: expected 3 static-library slices in XCFramework, found $count" >&2
        return 1
    fi
}

# Do not let the Swift package manifest claim an older OS than the archive actually contains. Static archives have one Mach-O build-version command per member, so inspect every member rather than only the first one.
verify_archive_minos() {
    local archive="$1"
    local expected="$2"
    xcrun otool -l "$archive" | awk -v archive="$archive" -v expected="$expected" '
        /LC_BUILD_VERSION/ { looking = 1; next }
        looking && /^[[:space:]]*minos[[:space:]]/ {
            if ($2 != expected) {
                printf "ERROR: %s has Mach-O minos %s, expected %s\\n", archive, $2, expected > "/dev/stderr"
                failed = 1
            }
            seen += 1
            looking = 0
        }
        END {
            if (seen == 0) {
                printf "ERROR: %s has no LC_BUILD_VERSION records\\n", archive > "/dev/stderr"
                exit 1
            }
            exit failed
        }
    '
}

# The JSC headers currently mark these BigInt C APIs as iOS 18 / macOS 15. The public typed ABI does not need them.  Keep the lower deployment target honest by rejecting a future strong import before it reaches an XCFramework.
verify_jsc_baseline_imports() {
    local archive="$1"
    [ "$BACKEND" = jsc ] || return 0
    local symbol
    for symbol in \
        JSValueIsBigInt JSValueToInt64 JSValueToUInt64 \
        JSBigIntCreateWithInt64 JSBigIntCreateWithUInt64; do
        if nm -u "$archive" | awk -v expected="_$symbol" '$NF == expected { found = 1 } END { exit !found }'; then
            echo "ERROR: $archive strongly imports $symbol, which requires iOS 18 / macOS 15" >&2
            return 1
        fi
    done
}

# iOS 13 lacks preadv and pwritev. Reject only strong undefined imports: weak imports are deliberately not treated as an error by this deployment gate.
verify_ios13_vectored_io_imports() {
    local archive="$1"
    local imports symbol
    if ! imports="$(nm -u -m "$archive")"; then
        echo "ERROR: cannot inspect undefined imports in $archive" >&2
        return 1
    fi
    for symbol in preadv pwritev; do
        if printf '%s\n' "$imports" | awk -v expected="_$symbol" '$NF == expected && /\(undefined\)/ && /external/ && !/weak/ { found = 1 } END { exit !found }'; then
            echo "ERROR: $archive strongly imports $symbol, which requires iOS 14" >&2
            return 1
        fi
    done
}

xcframework_archive() {
    local platform="$1"
    local archive
    archive="$(find "$BUILD_DIR/$XCFW_NAME.xcframework/$platform" -maxdepth 1 -type f -name '*.a' -print -quit)"
    if [ ! -f "$archive" ]; then
        echo "ERROR: missing XCFramework archive for $platform" >&2
        return 1
    fi
    printf '%s\n' "$archive"
}

link_consumer_probes() {
    local mac_archive ios_archive sim_archive
    mac_archive="$(xcframework_archive macos-arm64)"
    ios_archive="$(xcframework_archive ios-arm64)"
    sim_archive="$(xcframework_archive ios-arm64_x86_64-simulator)"
    local probe_dir="$BUILD_DIR/consumer-probes"
    mkdir -p "$probe_dir"

    xcrun --sdk macosx clang -arch arm64 -isysroot "$MACOS_SDK" -I"$(dirname "$mac_archive")/Headers" \
        "$CONSUMER_PROBE" "$mac_archive" -lm -framework JavaScriptCore -o "$probe_dir/macos-consumer"
    "$probe_dir/macos-consumer"

    xcrun --sdk iphoneos clang -target arm64-apple-ios13.0 -isysroot "$IOS_SDK" -I"$(dirname "$ios_archive")/Headers" \
        "$CONSUMER_PROBE" "$ios_archive" -lm -framework JavaScriptCore -o "$probe_dir/ios-device-consumer"

    xcrun --sdk iphonesimulator clang -target x86_64-apple-ios13.0-simulator -isysroot "$IOS_SIM_SDK" \
        -I"$(dirname "$sim_archive")/Headers" "$CONSUMER_PROBE" "$sim_archive" \
        -lm -framework JavaScriptCore -o "$probe_dir/ios-simulator-x86_64-consumer"

    local app="$probe_dir/JsBayAppleConsumer.app"

    local udid owned_sim=0
    udid="${JSBAY_IOS_SIM_UDID:-}"
    if [ -z "$udid" ]; then
        local runtimes_json="$probe_dir/sim-runtimes.json"
        local device_types_json="$probe_dir/sim-device-types.json"
        if ! xcrun simctl list runtimes -j > "$runtimes_json" 2>/dev/null \
            || ! xcrun simctl list devicetypes -j > "$device_types_json" 2>/dev/null; then
            printf '%s\n' 'FAIL: iOS Simulator runtime unavailable' > "$probe_dir/ios-simulator-consumer.status"
            echo "ERROR: iOS Simulator runtime unavailable; simulator runtime smoke is required" >&2
            return 1
        fi
        local runtime device_type created
        while IFS= read -r runtime; do
            [ -n "$runtime" ] || continue
            while IFS= read -r device_type; do
                [ -n "$device_type" ] || continue
                if created="$(xcrun simctl create "JsBayAppleConsumer-$$" "$device_type" "$runtime" 2>/dev/null)"; then
                    udid="$created"
                    owned_sim=1
                    break 2
                fi
            done < <(zig build tool -- simulator-list devices "$device_types_json" 2>/dev/null || true)
        done < <(zig build tool -- simulator-list runtimes "$runtimes_json" 2>/dev/null || true)
    fi
    if [ -z "$udid" ]; then
        printf '%s\n' 'FAIL: iOS Simulator runtime unavailable' > "$probe_dir/ios-simulator-consumer.status"
        echo "ERROR: iOS Simulator runtime unavailable; simulator runtime smoke is required" >&2
        return 1
    fi
    if ! bash "$SCRIPT_DIR/tests/apple-sdk/run.sh" "$mac_archive" "$probe_dir/macos-sdk" "$BACKEND" macosx || \
       ! bash "$SCRIPT_DIR/tests/apple-sdk/run.sh" "$sim_archive" "$probe_dir" "$BACKEND" iphonesimulator; then
        if [ "$owned_sim" -eq 1 ]; then xcrun simctl delete "$udid" 2>/dev/null || true; fi
        return 1
    fi
    local sim_log="$probe_dir/ios-simulator-consumer.log"
    local sim_rc=0
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b || sim_rc=$?
    if [ "$sim_rc" -eq 0 ]; then
        xcrun simctl install "$udid" "$app" || sim_rc=$?
    fi
    if [ "$sim_rc" -eq 0 ]; then
        xcrun simctl launch --console-pty "$udid" org.js-bay.appleconsumer >"$sim_log" 2>&1 || \
            xcrun simctl launch --console "$udid" org.js-bay.appleconsumer >"$sim_log" 2>&1 || sim_rc=$?
    fi
    if [ "$sim_rc" -eq 0 ] && ! grep -q 'JSBAY_APPLE_CONSUMER_PASS' "$sim_log"; then
        sim_rc=1
        echo "ERROR: iOS Simulator consumer probe did not report success; log: $sim_log" >&2
    fi
    if [ "$owned_sim" -eq 1 ]; then
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl delete "$udid" 2>/dev/null || true
    fi
    if [ "$sim_rc" -ne 0 ]; then
        return "$sim_rc"
    fi
    printf '%s\n' 'PASS: iOS Simulator consumer smoke' > "$probe_dir/ios-simulator-consumer.status"
}

ios_sdk_libobjc_arm64e_only() {
    local tbd="$IOS_SDK/usr/lib/libobjc.A.tbd"
    [ -f "$tbd" ] || return 1
    if grep -E '^targets:[[:space:]]*\[ arm64e-ios \]' "$tbd" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_ios_zig_consumer() {
    if [ "${JSBAY_SKIP_IOS_ZIG_CONSUMER:-${JS_BAY_SKIP_IOS_ZIG_CONSUMER:-}}" = "1" ]; then
        echo "WARN: skipping Zig iOS consumer (JSBAY_SKIP_IOS_ZIG_CONSUMER=1); clang link_consumer_probes still validate linking"
        return 0
    fi
    if [ "${JSBAY_FORCE_IOS_ZIG_CONSUMER:-${JS_BAY_FORCE_IOS_ZIG_CONSUMER:-}}" != "1" ] && ios_sdk_libobjc_arm64e_only; then
        echo "WARN: skipping Zig iOS consumer — $IOS_SDK libobjc.A.tbd is arm64e-only; Zig 0.17 cannot link aarch64-ios against it (set JSBAY_FORCE_IOS_ZIG_CONSUMER=1 to override). clang link_consumer_probes still validate linking."
        return 0
    fi
    (
        cd "$SCRIPT_DIR/tests/zig-consumer"
        zig build check -Dbackend="$BACKEND" -Dtarget=aarch64-ios.13.0 -Doptimize="$OPTIMIZE" "-Dapple-sysroot=$IOS_SDK"
    )
}

# Pull-request smoke: one simulator slice for this machine, then install and launch. The three-slice XCFramework stays on the default path.
link_simulator_smoke() {
    local archive="$1"
    local probe_dir="$BUILD_DIR/consumer-probes"
    mkdir -p "$probe_dir"

    local udid owned_sim=0
    udid="${JSBAY_IOS_SIM_UDID:-}"
    if [ -z "$udid" ]; then
        local runtimes_json="$probe_dir/sim-runtimes.json"
        local device_types_json="$probe_dir/sim-device-types.json"
        if ! xcrun simctl list runtimes -j > "$runtimes_json" 2>/dev/null \
            || ! xcrun simctl list devicetypes -j > "$device_types_json" 2>/dev/null; then
            printf '%s\n' 'FAIL: iOS Simulator runtime unavailable' > "$probe_dir/ios-simulator-consumer.status"
            echo "ERROR: iOS Simulator runtime unavailable; simulator runtime smoke is required" >&2
            return 1
        fi
        local runtime device_type created
        while IFS= read -r runtime; do
            [ -n "$runtime" ] || continue
            while IFS= read -r device_type; do
                [ -n "$device_type" ] || continue
                if created="$(xcrun simctl create "JsBayAppleConsumer-$$" "$device_type" "$runtime" 2>/dev/null)"; then
                    udid="$created"
                    owned_sim=1
                    break 2
                fi
            done < <(zig build tool -- simulator-list devices "$device_types_json" 2>/dev/null || true)
        done < <(zig build tool -- simulator-list runtimes "$runtimes_json" 2>/dev/null || true)
    fi
    if [ -z "$udid" ]; then
        printf '%s\n' 'FAIL: iOS Simulator runtime unavailable' > "$probe_dir/ios-simulator-consumer.status"
        echo "ERROR: iOS Simulator runtime unavailable; simulator runtime smoke is required" >&2
        return 1
    fi
    if ! bash "$SCRIPT_DIR/tests/apple-sdk/run.sh" "$archive" "$probe_dir" "$BACKEND" iphonesimulator; then
        if [ "$owned_sim" -eq 1 ]; then xcrun simctl delete "$udid" 2>/dev/null || true; fi
        return 1
    fi
    local sim_log="$probe_dir/ios-simulator-consumer.log"
    local app="$probe_dir/JsBayAppleConsumer.app"
    local sim_rc=0
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b || sim_rc=$?
    if [ "$sim_rc" -eq 0 ]; then
        xcrun simctl install "$udid" "$app" || sim_rc=$?
    fi
    if [ "$sim_rc" -eq 0 ]; then
        xcrun simctl launch --console-pty "$udid" org.js-bay.appleconsumer >"$sim_log" 2>&1 || \
            xcrun simctl launch --console "$udid" org.js-bay.appleconsumer >"$sim_log" 2>&1 || sim_rc=$?
    fi
    if [ "$sim_rc" -eq 0 ] && ! grep -q 'JSBAY_APPLE_CONSUMER_PASS' "$sim_log"; then
        sim_rc=1
        echo "ERROR: iOS Simulator consumer probe did not report success; log: $sim_log" >&2
    fi
    if [ "$owned_sim" -eq 1 ]; then
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl delete "$udid" 2>/dev/null || true
    fi
    if [ "$sim_rc" -ne 0 ]; then
        return "$sim_rc"
    fi
    printf '%s\n' 'PASS: iOS Simulator consumer smoke' > "$probe_dir/ios-simulator-consumer.status"
}

simulator_only_smoke() {
    local machine sim_target sim_minos sim_label archive
    machine="$(uname -m)"
    case "$machine" in
        arm64|aarch64)
            sim_target="aarch64-ios.14.0-simulator"
            sim_minos="14.0"
            sim_label="iOS Simulator (arm64)"
            ;;
        x86_64)
            sim_target="x86_64-ios.13.0-simulator"
            sim_minos="13.0"
            sim_label="iOS Simulator (x86_64)"
            ;;
        *)
            echo "ERROR: simulator smoke does not support machine $machine" >&2
            return 2
            ;;
    esac
    echo "==> Building for ${sim_label} [$BACKEND] (simulator smoke)"
    cd "$SCRIPT_DIR"
    zig build $COMMON_FLAGS -Dtarget="$sim_target" "-Dapple-sysroot=$IOS_SIM_SDK" --prefix "$BUILD_DIR/zig-prefix"
    # Keep arch in the filename so distribution fixture otool minos rules (*ios-sim-arm64* → 14.0, else 13.0) stay honest.
    if [ "$machine" = x86_64 ]; then
        archive="$BUILD_DIR/libjsbay-ios-sim-x86_64-smoke.a"
    else
        archive="$BUILD_DIR/libjsbay-ios-sim-arm64-smoke.a"
    fi
    normalize_archive "$BUILD_DIR/zig-prefix/lib/libjsbay.a" "$archive"
    verify_archive_minos "$archive" "$sim_minos"
    verify_jsc_baseline_imports "$archive"
    if [ "$sim_minos" = "13.0" ]; then
        verify_ios13_vectored_io_imports "$archive"
    fi
    link_simulator_smoke "$archive"
}

if [ "${JSBAY_APPLE_SMOKE:-}" = simulator ]; then
    simulator_only_smoke
    exit 0
fi

echo "==> Building for macOS (arm64) [$BACKEND]"
cd "$SCRIPT_DIR"
zig build $COMMON_FLAGS -Dtarget=aarch64-macos.11.0 "-Dapple-sysroot=$MACOS_SDK" --prefix "$BUILD_DIR/zig-prefix"
normalize_archive "$BUILD_DIR/zig-prefix/lib/libjsbay.a" "$BUILD_DIR/libjsbay-macos-arm64.a"
verify_archive_minos "$BUILD_DIR/libjsbay-macos-arm64.a" 11.0
verify_jsc_baseline_imports "$BUILD_DIR/libjsbay-macos-arm64.a"

echo "==> Building for iOS (arm64)"
zig build $COMMON_FLAGS -Dtarget=aarch64-ios.13.0 "-Dapple-sysroot=$IOS_SDK" --prefix "$BUILD_DIR/zig-prefix"
normalize_archive "$BUILD_DIR/zig-prefix/lib/libjsbay.a" "$BUILD_DIR/libjsbay-ios-arm64.a"
verify_archive_minos "$BUILD_DIR/libjsbay-ios-arm64.a" 13.0
verify_jsc_baseline_imports "$BUILD_DIR/libjsbay-ios-arm64.a"
verify_ios13_vectored_io_imports "$BUILD_DIR/libjsbay-ios-arm64.a"

echo "==> Building for iOS Simulator (arm64)"
# Xcode's arm64 simulator runtime starts at iOS 14. Keep the device archive at iOS 13, and keep x86_64 simulator at iOS 13 below; these are independently checked from the produced Mach-O objects rather than inferred from flags.
zig build $COMMON_FLAGS -Dtarget=aarch64-ios.14.0-simulator "-Dapple-sysroot=$IOS_SIM_SDK" --prefix "$BUILD_DIR/zig-prefix"
normalize_archive "$BUILD_DIR/zig-prefix/lib/libjsbay.a" "$BUILD_DIR/libjsbay-ios-sim-arm64.a"
verify_archive_minos "$BUILD_DIR/libjsbay-ios-sim-arm64.a" 14.0
verify_jsc_baseline_imports "$BUILD_DIR/libjsbay-ios-sim-arm64.a"

echo "==> Building for iOS Simulator (x86_64)"
zig build $COMMON_FLAGS -Dtarget=x86_64-ios.13.0-simulator "-Dapple-sysroot=$IOS_SIM_SDK" --prefix "$BUILD_DIR/zig-prefix"
normalize_archive "$BUILD_DIR/zig-prefix/lib/libjsbay.a" "$BUILD_DIR/libjsbay-ios-sim-x86_64.a"
verify_archive_minos "$BUILD_DIR/libjsbay-ios-sim-x86_64.a" 13.0
verify_jsc_baseline_imports "$BUILD_DIR/libjsbay-ios-sim-x86_64.a"
verify_ios13_vectored_io_imports "$BUILD_DIR/libjsbay-ios-sim-x86_64.a"
xcrun lipo -create "$BUILD_DIR/libjsbay-ios-sim-arm64.a" "$BUILD_DIR/libjsbay-ios-sim-x86_64.a" \
    -output "$BUILD_DIR/libjsbay-ios-sim.a"
xcrun lipo "$BUILD_DIR/libjsbay-ios-sim.a" -verify_arch arm64 x86_64
"${ARCHIVE_TOOL[@]}" check "$BUILD_DIR/libjsbay-ios-sim.a"

echo "==> Checking public Zig consumer for iOS"
check_ios_zig_consumer

echo "==> Creating XCFramework"
for arch in macos ios ios-sim; do
    mkdir -p "$BUILD_DIR/headers-$arch"
    cp "$SCRIPT_DIR"/include/jsbay*.h "$BUILD_DIR/headers-$arch/"
    cp "$SCRIPT_DIR/include/module.modulemap" "$BUILD_DIR/headers-$arch/"
done

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/libjsbay-macos-arm64.a" \
    -headers "$BUILD_DIR/headers-macos" \
    -library "$BUILD_DIR/libjsbay-ios-arm64.a" \
    -headers "$BUILD_DIR/headers-ios" \
    -library "$BUILD_DIR/libjsbay-ios-sim.a" \
    -headers "$BUILD_DIR/headers-ios-sim" \
    -output "$BUILD_DIR/$XCFW_NAME.xcframework"

verify_xcframework_archives
link_consumer_probes

echo "==> Packaging Swift SDK"
mkdir -p "$BUILD_DIR/SwiftPackage/Frameworks"
cp "$SCRIPT_DIR/sdk/apple/Package.swift" "$BUILD_DIR/SwiftPackage/"
cp -R "$SCRIPT_DIR/sdk/apple/Sources" "$BUILD_DIR/SwiftPackage/"
cp -R "$BUILD_DIR/$XCFW_NAME.xcframework" "$BUILD_DIR/SwiftPackage/Frameworks/JsBay.xcframework"
cp "$SCRIPT_DIR/LICENSE" "$BUILD_DIR/SwiftPackage/"
cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$BUILD_DIR/SwiftPackage/"
echo "==> Checking external Swift Package consumers"
bash "$SCRIPT_DIR/tests/apple-sdk/spm-consumer.sh" "$BUILD_DIR/SwiftPackage" "$BUILD_DIR/spm-consumer"

printf '%s\n' "$BACKEND" > "$BUILD_DIR/backend"
if [ -n "${RELEASE_VERSION:-}" ]; then
    printf '%s\n' "$RELEASE_VERSION" > "$BUILD_DIR/VERSION"
fi
if [ -n "${RELEASE_COMMIT:-}" ]; then
    printf '%s\n' "$RELEASE_COMMIT" > "$BUILD_DIR/COMMIT"
fi

echo "==> XCFramework created at $BUILD_DIR/$XCFW_NAME.xcframework"
