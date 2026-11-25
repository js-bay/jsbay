#!/usr/bin/env bash
set -euo pipefail

usage='usage: maven-consumer.sh <maven-repo-directory-or-github-packages-url> <version> <gradle-bin> <backend> [--run-on-device] [--check-legacy-coordinate-conflict] [--require-current-coordinate]'
MAVEN_REPO="${1:?$usage}"
VERSION="${2:?$usage}"
GRADLE_BIN="${3:?$usage}"
BACKEND="${4:?$usage}"
device_mode=false
check_legacy_conflict=false
require_current_coordinate=false
for option in "${@:5}"; do
    case "$option" in
        --run-on-device) device_mode=true ;;
        --check-legacy-coordinate-conflict) check_legacy_conflict=true ;;
        --require-current-coordinate) require_current_coordinate=true ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
done
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
    quickjs) artifacts=(jsbay-quickjs jsbayquickjs); legacy_artifact=jsbayquickjs ;;
    quickjs_ng) artifacts=(jsbay-quickjs-ng jsbayquickjsng); legacy_artifact=jsbayquickjsng ;;
    *) echo "unsupported backend: $BACKEND" >&2; exit 2 ;;
esac
if [[ -n "${ANDROID_MAVEN_CONSUMER_OUT:-}" ]]; then
    OUT=$ANDROID_MAVEN_CONSUMER_OUT
    remove_out=false
else
    OUT=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-maven-consumer.XXXXXX")
    remove_out=true
fi
LOG="$OUT/gradle.log"
mkdir -p "$OUT"
cleanup() {
    local status=$?
    trap - EXIT
    if [[ $status != 0 && -f "$LOG" ]]; then cat "$LOG" >&2 || true; fi
    rm -f "$OUT/curl-auth"
    if [[ "$installed" == true ]]; then "$adb_bin" uninstall "$application_id" >&2 || true; fi
    if [[ "$remove_out" == true ]]; then rm -rf "$OUT"; fi
    exit "$status"
}
trap cleanup EXIT

artifact=
for candidate in "${artifacts[@]}"; do
    path="io/jsbay/$candidate/$VERSION/$candidate-$VERSION.pom"
    if [[ -d "$MAVEN_REPO" ]]; then
        if [[ -s "$MAVEN_REPO/$path" ]]; then artifact=$candidate; break; fi
        if [[ "$require_current_coordinate" == true && "$candidate" == "${artifacts[0]}" ]]; then
            echo "Current Maven coordinate io.jsbay:$candidate:$VERSION is missing; legacy fallback is disabled for remote verification" >&2
            exit 1
        fi
        continue
    fi
    auth_option=()
    if [[ $repository_auth_mode == github-packages ]]; then
        credentials="$GITHUB_ACTOR$GITHUB_TOKEN"
        if [[ $credentials == *[[:cntrl:]]* || $credentials == *'"'* || $credentials == *\\* ]]; then
            echo 'Invalid GitHub Packages credentials' >&2
            exit 2
        fi
        curl_auth="$OUT/curl-auth"
        (umask 077; printf 'user = "%s:%s"\n' "$GITHUB_ACTOR" "$GITHUB_TOKEN" > "$curl_auth")
        auth_option=(--config "$curl_auth")
    fi
    status=$(curl --disable --silent --show-error --location --proto '=http,https' --proto-redir '=https' \
        "${auth_option[@]}" --output /dev/null --write-out '%{http_code}' "${MAVEN_REPO%/}/$path") || {
        echo 'Could not check published Maven coordinates' >&2
        exit 1
    }
    rm -f "$OUT/curl-auth"
    case "$status" in
        200) artifact=$candidate; break ;;
        404)
            if [[ "$require_current_coordinate" == true && "$candidate" == "${artifacts[0]}" ]]; then
                echo "Current Maven coordinate io.jsbay:$candidate:$VERSION is missing; legacy fallback is disabled for remote verification" >&2
                exit 1
            fi
            ;;
        *) echo "Could not check Maven coordinate (HTTP $status)" >&2; exit 1 ;;
    esac
done
if [[ -z $artifact ]]; then
    echo "No published Maven artifact found for $BACKEND $VERSION" >&2
    exit 1
fi
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

dependencies {
    implementation("io.jsbay:${System.getenv("JSBAY_MAVEN_ARTIFACT")}:${System.getenv("JSBAY_MAVEN_VERSION")}")
    if (System.getenv("JSBAY_MAVEN_LEGACY_CONFLICT_CHECK") == "true") {
        implementation("io.jsbay.test:legacy-client:1.0")
    }
}
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

JSBAY_MAVEN_REPO="$MAVEN_REPO" JSBAY_MAVEN_REPOSITORY_AUTH="$repository_auth_mode" JSBAY_MAVEN_BACKEND="$BACKEND" \
JSBAY_MAVEN_VERSION="$VERSION" JSBAY_MAVEN_ARTIFACT="$artifact" \
    "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" \
    :app:dependencies --configuration debugRuntimeClasspath >"$LOG" 2>&1
grep -Eq 'org\.jetbrains\.kotlin:kotlin-stdlib(:|[^[:space:]]*:)1\.9\.22' "$LOG"

JSBAY_MAVEN_REPO="$MAVEN_REPO" JSBAY_MAVEN_REPOSITORY_AUTH="$repository_auth_mode" JSBAY_MAVEN_BACKEND="$BACKEND" \
JSBAY_MAVEN_VERSION="$VERSION" JSBAY_MAVEN_ARTIFACT="$artifact" \
    "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" :app:assembleDebug >>"$LOG" 2>&1
APK="$OUT/app/build/outputs/apk/debug/app-debug.apk"
test -f "$APK"
for abi in arm64-v8a x86_64; do
    for library in libjsbay.so libjsbay_android.so; do
        unzip -Z1 "$APK" | grep -Fx "lib/$abi/$library" >/dev/null
    done
done

if [[ "$check_legacy_conflict" == true ]]; then
    [[ -d "$MAVEN_REPO" ]] || { echo 'Legacy coordinate conflict check requires a local Maven repository' >&2; exit 2; }
    conflict_repo="$OUT/legacy-conflict-repository"
    new_module="$MAVEN_REPO/io/jsbay/$artifact/$VERSION"
    test -s "$new_module/$artifact-$VERSION.module"
    node "$script_dir/check-maven-capabilities.mjs" \
        "$new_module/$artifact-$VERSION.module" "$artifact" "$legacy_artifact" "$VERSION"
    mkdir -p "$conflict_repo/io/jsbay" "$conflict_repo/io/jsbay/$legacy_artifact/$VERSION" \
        "$conflict_repo/io/jsbay/test/legacy-client/1.0"
    cp -R "$MAVEN_REPO/io/jsbay/$artifact" "$conflict_repo/io/jsbay/"
    cp "$new_module/$artifact-$VERSION.aar" \
        "$conflict_repo/io/jsbay/$legacy_artifact/$VERSION/$legacy_artifact-$VERSION.aar"
    cat > "$conflict_repo/io/jsbay/$legacy_artifact/$VERSION/$legacy_artifact-$VERSION.pom" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.jsbay</groupId>
  <artifactId>$legacy_artifact</artifactId>
  <version>$VERSION</version>
  <packaging>aar</packaging>
  <dependencies>
    <dependency><groupId>org.jetbrains.kotlin</groupId><artifactId>kotlin-stdlib</artifactId><version>1.9.22</version><scope>compile</scope></dependency>
  </dependencies>
</project>
EOF
    cat > "$conflict_repo/io/jsbay/test/legacy-client/1.0/legacy-client-1.0.pom" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.jsbay.test</groupId>
  <artifactId>legacy-client</artifactId>
  <version>1.0</version>
  <packaging>pom</packaging>
  <dependencies>
    <dependency><groupId>io.jsbay</groupId><artifactId>$legacy_artifact</artifactId><version>$VERSION</version><type>aar</type></dependency>
  </dependencies>
</project>
EOF
    if JSBAY_MAVEN_REPO="$conflict_repo" JSBAY_MAVEN_REPOSITORY_AUTH='' \
        JSBAY_MAVEN_VERSION="$VERSION" JSBAY_MAVEN_ARTIFACT="$artifact" \
        JSBAY_MAVEN_LEGACY_CONFLICT_CHECK=true \
        "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" :app:assembleDebug \
        >"$OUT/legacy-conflict.log" 2>&1; then
        echo 'Expected Gradle to reject mixed legacy and current Maven coordinates' >&2
        exit 1
    fi
    if ! grep -Fq "Both provide capability 'io.jsbay:$legacy_artifact:$VERSION'" "$OUT/legacy-conflict.log"; then
        cat "$OUT/legacy-conflict.log" >&2
        echo 'Gradle failed for a reason other than the expected legacy coordinate capability conflict' >&2
        exit 1
    fi
    printf 'PASS: Gradle rejected mixed Maven coordinates through capability %s\n' "io.jsbay:$legacy_artifact:$VERSION"
fi

printf 'PASS: Maven consumer assembled %s\n' "$APK"
if [[ "$device_mode" == true ]]; then
    "$adb_bin" install "$APK"
    installed=true
    "$adb_bin" shell am instrument -w -r -e backend "$BACKEND" \
        "$application_id/.MavenConsumerInstrumentation" > "$OUT/instrumentation.log" 2>&1
    cat "$OUT/instrumentation.log"
    grep -Eq "^INSTRUMENTATION_RESULT: jsbayResult=$BACKEND:42[[:space:]]*$" "$OUT/instrumentation.log"
    grep -Eq '^INSTRUMENTATION_CODE: -1[[:space:]]*$' "$OUT/instrumentation.log"
    printf 'PASS: installed Maven consumer ran %s on ART\n' "$BACKEND"
fi
