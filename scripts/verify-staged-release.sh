#!/usr/bin/env bash
set -euo pipefail

operation=${1:?verify or publish required}
version=${2:?release version required}
source_sha=${3:?source commit required}
run_id=${4:?original release run ID required}
assets=${5:?release assets directory required}
package_dir=${6:?Swift package directory required}
release_id=${7:-}
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $operation == verify || $operation == publish ]]
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
[[ $source_sha =~ ^[a-f0-9]{40}$ && $run_id =~ ^[1-9][0-9]*$ ]]

if ! git cat-file -e "$source_sha^{commit}" 2>/dev/null; then
  git fetch --quiet --no-tags origin "$source_sha"
fi
source_version=$(git show "$source_sha:build.zig.zon" | awk -F '"' '/^[[:space:]]*\.version[[:space:]]*=/ && !seen { version=$2; seen=1 } END { print version }')
if [[ $source_version != "$version" ]]; then
  echo 'original release source version differs from the requested version' >&2
  exit 1
fi

stage="jsbay-package-staging-$run_id"
sha=$(JSBAY_PACKAGE_REF="refs/heads/$stage" bash "$root/scripts/create-swift-package-tag.sh" "$package_dir" "$version" "$source_sha" verify-only)
tag="refs/tags/v$version"
tag_commit() {
  git ls-remote origin "$tag" "$tag^{}" | awk 'END { print $1 }'
}
existing=$(tag_commit)
if [[ -n $existing && $existing != "$sha" ]]; then
  echo 'existing release tag does not match the staged package commit' >&2
  exit 1
fi

node "$root/scripts/github-release.mjs" "$operation" "$version" "$stage" "$assets" "$package_dir" "$release_id"
if [[ $operation == publish && $(tag_commit) != "$sha" ]]; then
  echo 'published release tag does not match the staged package commit' >&2
  exit 1
fi
