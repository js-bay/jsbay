#!/usr/bin/env bash
set -euo pipefail

package_dir=${1:?generated Swift package directory required}
version=${2:?release version required}
source_sha=${3:?source commit SHA required}
operation=${4:-stage}
[[ $operation == stage || $operation == verify-only ]] || { echo 'invalid package staging operation' >&2; exit 2; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo 'invalid release version' >&2; exit 2; }
package_dir=$(cd "$package_dir" && pwd)
repo=$(git rev-parse --show-toplevel)
tag="v$version"
tag_ref=${JSBAY_PACKAGE_REF:-"refs/tags/$tag"}
if [[ $tag_ref != "refs/tags/$tag" && $tag_ref != refs/heads/jsbay-package-staging-* ]]; then
  echo "invalid package staging ref: $tag_ref" >&2
  exit 2
fi

[[ $source_sha =~ ^[0-9a-fA-F]{7,64}$ ]] || { echo 'invalid source commit SHA' >&2; exit 2; }
git -C "$repo" cat-file -e "$source_sha^{commit}" || { echo 'source commit is unavailable' >&2; exit 1; }
test -s "$package_dir/Package.swift" || { echo 'generated Package.swift is missing' >&2; exit 1; }
test -d "$package_dir/Sources" || { echo 'generated Sources directory is missing' >&2; exit 1; }
top_level=$(find "$package_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
test "$top_level" = $'Package.swift\nSources' || { echo 'generated package may contain only Package.swift and Sources' >&2; exit 1; }
if find "$package_dir" -type l -print -quit | grep -q .; then
  echo 'generated package must not contain symbolic links' >&2
  exit 1
fi

expected_files=$(cd "$package_dir" && find Package.swift Sources -type f -print | LC_ALL=C sort)
test -n "$expected_files" || { echo 'generated package is empty' >&2; exit 1; }

temporary=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-swift-tag.XXXXXX")
worktree="$temporary/worktree"
recovery_ref="refs/jsbay/swift-package-recovery/$tag"
# shellcheck disable=SC2329
cleanup() {
  if git -C "$repo" worktree list --porcelain | grep -Fqx "worktree $worktree"; then
    git -C "$repo" worktree remove --force "$worktree" || true
  fi
  git -C "$repo" update-ref -d "$recovery_ref" 2>/dev/null || true
  rm -rf "$temporary"
}
trap 'cleanup' EXIT

verify_package_commit() {
  local commit=$1
  local parents actual_files changed_files path
  parents=$(git -C "$repo" show -s --format=%P "$commit") || { echo 'tagged package commit is unavailable' >&2; return 1; }
  if [[ $parents != "$source_sha" ]]; then
    echo 'existing package tag has a different source parent' >&2
    return 1
  fi
  actual_files=$(git -C "$repo" ls-tree -r --name-only "$commit" -- Package.swift Sources | LC_ALL=C sort)
  if [[ $actual_files != "$expected_files" ]]; then
    echo 'existing package tag has a different generated file set' >&2
    return 1
  fi
  changed_files=$(git -C "$repo" diff --name-only "$source_sha" "$commit" | LC_ALL=C sort)
  if [[ $changed_files != "$expected_files" ]]; then
    echo 'existing package tag changes files outside the generated Swift package' >&2
    return 1
  fi
  while IFS= read -r path; do
    if ! git -C "$repo" show "$commit:$path" | cmp -s - "$package_dir/$path"; then
      echo "existing package tag has different generated contents: $path" >&2
      return 1
    fi
  done <<< "$expected_files"
}

verify_remote_tag() {
  local remote_ref commit
  remote_ref=$(git -C "$repo" ls-remote --refs origin "$tag_ref")
  [[ -n $remote_ref ]] || return 1
  git -C "$repo" update-ref -d "$recovery_ref" 2>/dev/null || true
  git -C "$repo" fetch --quiet --no-tags origin "$tag_ref:$recovery_ref"
  commit=$(git -C "$repo" rev-parse "$recovery_ref^{commit}")
  verify_package_commit "$commit" || return 1
  printf '%s\n' "$commit"
}

existing=$(git -C "$repo" ls-remote --refs origin "$tag_ref")
if [[ -n $existing ]]; then
  if commit=$(verify_remote_tag); then
    if [[ $operation == verify-only ]]; then
      printf '%s\n' "$commit"
    else
      echo "Reusing existing matching package tag $tag at $commit"
    fi
    exit 0
  fi
  echo "existing release tag cannot be reused: $tag" >&2
  exit 1
fi
if [[ $operation == verify-only ]]; then
  echo "missing package staging ref: $tag_ref" >&2
  exit 1
fi

git -C "$repo" worktree add --detach "$worktree" "$source_sha"
if [[ -e $worktree/Package.swift || -e $worktree/Sources ]]; then
  echo 'source commit already contains a root Package.swift or Sources directory' >&2
  exit 1
fi
cp "$package_dir/Package.swift" "$worktree/Package.swift"
cp -R "$package_dir/Sources" "$worktree/Sources"
git -C "$worktree" add -- Package.swift Sources
git -C "$worktree" -c user.name='JsBay Release Automation' -c user.email='release@example.invalid' commit -m "Release $version Swift package"
package_commit=$(git -C "$worktree" rev-parse HEAD)
verify_package_commit "$package_commit"
if [[ $tag_ref == refs/tags/* ]]; then
  git -C "$worktree" tag -a "$tag" -m "Release $version" "$package_commit"
  push_ref=$tag_ref
else
  push_ref="HEAD:$tag_ref"
fi

if git -C "$worktree" push origin "$push_ref"; then
  echo "Created package tag $tag at $package_commit"
  exit 0
fi

if commit=$(verify_remote_tag); then
  echo "Reusing concurrently created matching package tag $tag at $commit"
  exit 0
fi
echo "could not create immutable package tag: $tag" >&2
exit 1
