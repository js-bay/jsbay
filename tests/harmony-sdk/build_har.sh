#!/usr/bin/env bash
set -euo pipefail

test_root=$(cd "$(dirname "$0")/../.." && pwd)
: "${DEVECO_SDK_HOME:?set DEVECO_SDK_HOME to the DevEco SDK directory}"
: "${JSBAY_LIBRARY:?set JSBAY_LIBRARY to the matching OpenHarmony libjsbay.a}"
: "${HVIGORW:?set HVIGORW to the DevEco hvigorw executable}"
: "${OHPM:?set OHPM to the Harmony ohpm executable}"

# Hvigor compiles every ArkTS source in the HAR. Copy the device-callable conformance fixture into that source set for this build only, so this script proves it typechecks with the real ArkTS checker without shipping test code.
fixture_sources=()
temporary_fixture=''
created_links=()
created_dirs=()
cleanup_sources() {
  if ((${#fixture_sources[@]})); then rm -f "${fixture_sources[@]}"; fi
}
cleanup() {
  cleanup_sources
  if ((${#created_links[@]})); then
    for link in "${created_links[@]}"; do rm -f "$link"; done
  fi
  for ((index = ${#created_dirs[@]} - 1; index >= 0; index -= 1)); do rmdir "${created_dirs[index]}" 2>/dev/null || true; done
  if [[ -n "$temporary_fixture" ]]; then rm -rf "$temporary_fixture"; fi
}
trap cleanup EXIT

package_root() {
  local package_file
  package_file=$(NODE_PATH="$NODE_PATH" "${NODE_BIN:-node}" -e 'process.stdout.write(require.resolve(process.argv[1] + "/package.json"))' "$1")
  test -f "$package_file"
  printf '%s\n' "${package_file%/package.json}"
}
link_global_package() {
  local project_root=$1 package_name=$2 package_source package_scope package_target
  package_source=$(package_root "$package_name")
  package_scope="$project_root/node_modules/@ohos"
  if [[ ! -e "$project_root/node_modules" ]]; then mkdir "$project_root/node_modules"; created_dirs+=("$project_root/node_modules"); fi
  if [[ ! -e "$package_scope" ]]; then mkdir "$package_scope"; created_dirs+=("$package_scope"); fi
  package_target="$package_scope/${package_name#@ohos/}"
  if [[ ! -e "$package_target" && ! -L "$package_target" ]]; then ln -s "$package_source" "$package_target"; created_links+=("$package_target"); fi
}
if [[ -n ${NODE_PATH:-} ]]; then
  for package_name in @ohos/hvigor @ohos/hvigor-ohos-plugin; do
    link_global_package "$test_root/sdk/harmony" "$package_name"
    link_global_package "$test_root/tests/harmony-sdk/fixture" "$package_name"
  done
fi
for source in tests/harmony-sdk/conformance.ets tests/harmony-sdk/recursive_callback.ets tests/harmony-sdk/CrashIsolation.ets tests/harmony-sdk/CrashIsolationWorker.ets sdk/harmony/examples/Worker.ets; do
  fixture_source="$test_root/sdk/harmony/src/main/ets/Quality$(basename "$source")"
  if [[ -e "$fixture_source" ]]; then
    echo "Refusing to overwrite $fixture_source" >&2
    exit 1
  fi
  fixture_sources+=("$fixture_source")
  sed "s|'@js-bay/harmony'|'./JsBay'|" "$test_root/$source" > "$fixture_source"
  echo "ArkTS consumer fixture: $source"
done

# A caller can prove an additional device-facing ArkTS entry with the same first-build, clean, and production-package sequence. Keep it out of the final HAR just like the SDK conformance fixtures above.
if [[ -n ${HARMONY_EXTRA_ARKTS_FIXTURE:-} ]]; then
  test -f "$HARMONY_EXTRA_ARKTS_FIXTURE"
  fixture_source="$test_root/sdk/harmony/src/main/ets/Quality$(basename "$HARMONY_EXTRA_ARKTS_FIXTURE")"
  if [[ -e "$fixture_source" ]]; then
    echo "Refusing to overwrite $fixture_source" >&2
    exit 1
  fi
  fixture_sources+=("$fixture_source")
  cp "$HARMONY_EXTRA_ARKTS_FIXTURE" "$fixture_source"
  echo "ArkTS consumer fixture: $HARMONY_EXTRA_ARKTS_FIXTURE"
fi

cd "$test_root/sdk/harmony"
rm -rf "$test_root/sdk/harmony/oh_modules"
"$OHPM" install --no-link

# Hvigor only reads JSBAY_LIBRARY when CMake first configures this directory. Remove its generated cache so every HAR build links the archive selected by the caller.
rm -rf "$test_root/sdk/harmony/.cxx"

fixture_root="$test_root/tests/harmony-sdk/fixture"
# The default fixture targets API 20 and remains unchanged. An explicitly requested SDK variant gets its own project and Hvigor caches outside the repo.
if [[ -n ${HARMONY_TARGET_SDK_VERSION:-} ]]; then
  temporary_fixture=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-fixture.XXXXXX")
  cp -R "$fixture_root/." "$temporary_fixture"
  rm -rf "$temporary_fixture/.hvigor" "$temporary_fixture/build" "$temporary_fixture/node_modules" "$temporary_fixture/oh_modules"
  variant_profile=$temporary_fixture/build-profile.json5
  jq --arg target "$HARMONY_TARGET_SDK_VERSION" --arg source "$test_root/sdk/harmony" \
    '.app.products |= map(.targetSdkVersion = $target) | .modules[0].srcPath = $source' \
    "$variant_profile" > "$variant_profile.next"
  mv "$variant_profile.next" "$variant_profile"
  if [[ -d "$fixture_root/node_modules" ]]; then ln -s "$fixture_root/node_modules" "$temporary_fixture/node_modules"; fi
  fixture_root=$temporary_fixture
  echo "Explicit Harmony target variant: $HARMONY_TARGET_SDK_VERSION"
fi
cd "$fixture_root"
run_hvigor() {
  if [[ -n ${HVIGOR_NODE:-} ]]; then
    "$HVIGOR_NODE" "$HVIGORW" "$@"
  else
    "$HVIGORW" "$@"
  fi
}
run_hvigor --mode module -p module=jsbay_harmony@default assembleHar

# The first archive proves the fixture compiles. Delete it, clean generated declarations, then package the distributable HAR without test exports.
cleanup_sources
run_hvigor --mode module -p module=jsbay_harmony@default clean
run_hvigor --mode module -p module=jsbay_harmony@default assembleHar

test -f "$test_root/sdk/harmony/build/default/outputs/default/jsbay_harmony.har"
