#!/usr/bin/env bash
set -euo pipefail

usage='usage: maven-consumer.sh <maven-repo-directory-or-github-packages-url> <version> <gradle-bin> <backend> [--run-on-device]'
MAVEN_REPO="${1:?$usage}"
VERSION="${2:?$usage}"
GRADLE_BIN="${3:?$usage}"
BACKEND="${4:?$usage}"
device_mode=${5:-}
[[ -z "$device_mode" || "$device_mode" == --run-on-device ]] || { echo "$usage" >&2; exit 2; }
script_dir=$(cd "$(dirname "$0")" && pwd)
adb_bin=${ADB:-adb}
application_id=com.example.jsbay.mavenconsumer
installed=false

test -x "$GRADLE_BIN"
repository_auth_mode=
if [[ "$MAVEN_REPO" =~ ^https://maven\.pkg\.github\.com/[^/]+/[^/]+/?$ ]]; then
    test -n "${GITHUB_ACTOR:-}" || { echo 'GITHUB_ACTOR is required for GitHub Packages' >&2; exit 2; }
    test -n "${GITHUB_TOKEN:-}" || { echo 'GITHUB_TOKEN is required for GitHub Packages' >&2; exit 2; }
    repository_auth_mode=github-packages
else
    test -d "$MAVEN_REPO" || { echo 'Maven repository must be a directory or an HTTPS GitHub Packages URL' >&2; exit 2; }
fi
case "$BACKEND" in
    quickjs) artifact=jsbayquickjs ;;
    quickjs_ng) artifact=jsbayquickjsng ;;
    *) echo "unsupported backend: $BACKEND" >&2; exit 2 ;;
esac
OUT="${ANDROID_MAVEN_CONSUMER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-maven-consumer.XXXXXX")}"
LOG="$OUT/gradle.log"
cleanup() {
    local status=$?
    if [[ $status != 0 && -f "$LOG" ]]; then cat "$LOG" >&2; fi
    if [[ "$installed" == true ]]; then "$adb_bin" uninstall "$application_id" >&2 || true; fi
    if [[ -z "${ANDROID_MAVEN_CONSUMER_OUT:-}" ]]; then rm -rf "$OUT"; fi
}
trap cleanup EXIT

mkdir -p "$OUT/app/src/main/java/com/example/jsbay/mavenconsumer"
cat > "$OUT/settings.gradle.kts" <<'EOF'
import org.gradle.authentication.http.BasicAuthentication

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    resolutionStrategy {
        eachPlugin {
            if (requested.id.id == "com.android.application") {
                useModule("com.android.tools.build:gradle:${requested.version}")
            }
        }
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven {
            url = uri(System.getenv("JSBAY_MAVEN_REPO"))
            if (System.getenv("JSBAY_MAVEN_REPOSITORY_AUTH") == "github-packages") {
                credentials {
                    username = System.getenv("GITHUB_ACTOR") ?: error("GITHUB_ACTOR is required")
                    password = System.getenv("GITHUB_TOKEN") ?: error("GITHUB_TOKEN is required")
                }
                authentication {
                    create<BasicAuthentication>("basic")
                }
            }
        }
        google()
        mavenCentral()
    }
}
rootProject.name = "jsbay-maven-consumer"
include(":app")
EOF
cat > "$OUT/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application") version "8.7.3" apply false
}
EOF
cat > "$OUT/app/build.gradle.kts" <<'EOF'
plugins { id("com.android.application") }

android {
    namespace = "com.example.jsbay.mavenconsumer"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.example.jsbay.mavenconsumer"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1"
    }
}

dependencies { implementation("io.jsbay:${System.getenv("JSBAY_MAVEN_ARTIFACT")}:${System.getenv("JSBAY_MAVEN_VERSION")}") }
EOF
cat > "$OUT/app/src/main/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:label="JsBay Maven consumer" />
  <instrumentation
      android:name=".MavenConsumerInstrumentation"
      android:targetPackage="com.example.jsbay.mavenconsumer" />
</manifest>
EOF
cp "$script_dir/MavenConsumerInstrumentation.java" "$OUT/app/src/main/java/com/example/jsbay/mavenconsumer/"

JSBAY_MAVEN_REPO="$MAVEN_REPO" JSBAY_MAVEN_REPOSITORY_AUTH="$repository_auth_mode" \
JSBAY_MAVEN_VERSION="$VERSION" JSBAY_MAVEN_ARTIFACT="$artifact" \
    "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" \
    :app:dependencies --configuration debugRuntimeClasspath >"$LOG" 2>&1
grep -Eq 'org\.jetbrains\.kotlin:kotlin-stdlib(:|[^[:space:]]*:)1\.9\.22' "$LOG"

JSBAY_MAVEN_REPO="$MAVEN_REPO" JSBAY_MAVEN_REPOSITORY_AUTH="$repository_auth_mode" \
JSBAY_MAVEN_VERSION="$VERSION" JSBAY_MAVEN_ARTIFACT="$artifact" \
    "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" :app:assembleDebug >>"$LOG" 2>&1
APK="$OUT/app/build/outputs/apk/debug/app-debug.apk"
test -f "$APK"
for abi in arm64-v8a x86_64; do
    for library in libjsbay.so libjsbay_android.so; do
        unzip -Z1 "$APK" | grep -Fx "lib/$abi/$library" >/dev/null
    done
done

printf 'PASS: Maven consumer assembled %s\n' "$APK"
if [[ "$device_mode" == --run-on-device ]]; then
    "$adb_bin" install "$APK"
    installed=true
    "$adb_bin" shell am instrument -w -r -e backend "$BACKEND" \
        "$application_id/.MavenConsumerInstrumentation" > "$OUT/instrumentation.log" 2>&1
    cat "$OUT/instrumentation.log"
    grep -Eq "^INSTRUMENTATION_RESULT: jsbayResult=$BACKEND:42[[:space:]]*$" "$OUT/instrumentation.log"
    grep -Eq '^INSTRUMENTATION_RESULT: jsbayAsyncClose=creator-drained[[:space:]]*$' "$OUT/instrumentation.log"
    grep -Eq '^INSTRUMENTATION_CODE: -1[[:space:]]*$' "$OUT/instrumentation.log"
    printf 'PASS: installed Maven consumer ran %s on ART\n' "$BACKEND"
fi
