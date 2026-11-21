#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
backend=${1:?expected npm backend}
version=${2:?expected release version}
registry=${NPM_REGISTRY:-https://registry.npmjs.org}
platform=${3:?expected Node platform}
arch=${4:?expected Node architecture}
[[ $backend == quickjs || $backend == quickjsng || $backend == jsc ]]
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
node -e 'const [platform, arch] = process.argv.slice(1); if (platform !== process.platform || arch !== process.arch) throw new Error("Expected " + platform + "/" + arch + ", got " + process.platform + "/" + process.arch)' "$platform" "$arch"

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-public-npm-consumer.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
printf '%s\n' '{"name":"jsbay-public-consumer","private":true}' > package.json
: > .npmrc
node "$root/tests/node-sdk/wait-for-published-npm.mjs" "$version" "$work/npm-cache" "$work/.npmrc" "@jsbay/$backend"
npm install --registry "$registry" --userconfig "$work/.npmrc" --cache "$work/npm-cache" --prefer-offline \
    --include=optional --ignore-scripts --no-audit --no-fund --save-exact "@jsbay/$backend@$version"

JSBAY_NODE_PACKAGE_ROOT="$work/package.json" JSBAY_NODE_PACKAGE="@jsbay/$backend" JSBAY_NODE_PUBLIC_VERSION="$version" \
    env -u JSBAY_NODE_ADDON node "$root/tests/node-sdk/package_consumer.mjs"

# shellcheck disable=SC2016
addon=$(node -e 'const [backend] = process.argv.slice(1); const os = process.platform === "darwin" ? "macos" : process.platform; process.stdout.write(require.resolve(`@jsbay/${backend}${os}${process.arch}`))' "$backend")
node_include="$(dirname "$(dirname "$(command -v node)")")/include/node"
if [[ $platform == linux ]]; then
    cc -shared -fPIC -I "$root/include" -I "$node_include" "$root/tests/node-sdk/native-backend-consumer.c" -ldl -o "$work/backend-probe.node"
else
    cc -bundle -undefined dynamic_lookup -I "$root/include" -I "$node_include" "$root/tests/node-sdk/native-backend-consumer.c" -o "$work/backend-probe.node"
fi
# shellcheck disable=SC2016
node -e 'const [probe, addon, backend] = process.argv.slice(1); if (!require(probe)(addon, backend)) process.exit(1); console.log(`Installed addon backend matches ${backend}`)' "$work/backend-probe.node" "$addon" "$backend"
