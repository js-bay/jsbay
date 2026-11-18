#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-swift-tag-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

remote="$work/remote.git"
source="$work/source"
clone="$work/clone"
output="$work/package"
version=1.2.3
tag="v$version"
git init --bare -q "$remote"
git init -q "$source"
git -C "$source" config user.name 'Package Tag Test'
git -C "$source" config user.email 'package-tag-test@example.invalid'
printf 'source one\n' > "$source/source.txt"
git -C "$source" add source.txt
git -C "$source" commit -qm 'Source one'
source_sha=$(git -C "$source" rev-parse HEAD)
git -C "$source" remote add origin "$remote"
git -C "$source" push -q origin HEAD:refs/heads/main
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
git clone -q "$remote" "$clone"
git -C "$clone" config user.name 'Package Tag Test'
git -C "$clone" config user.email 'package-tag-test@example.invalid'
git -C "$clone" config protocol.file.allow always

mkdir -p "$output/Sources/JsBaySDK"
cat > "$output/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "JsBay")
EOF
printf 'public struct JsBay {}\n' > "$output/Sources/JsBaySDK/JsBay.swift"

run_publisher_at() {
  local repository=$1 release_version=$2 source_commit=$3
  (cd "$repository" && bash "$root/scripts/create-swift-package-tag.sh" "$output" "$release_version" "$source_commit")
}

run_publisher() {
  run_publisher_at "$clone" "$version" "$1"
}

tag_commit() {
  git --git-dir="$remote" rev-parse "refs/tags/$tag^{commit}"
}

run_publisher "$source_sha"
first_commit=$(tag_commit)
test "$(git --git-dir="$remote" rev-parse "$first_commit^")" = "$source_sha"
git --git-dir="$remote" show "$tag:Package.swift" > "$work/first-manifest"
cmp "$output/Package.swift" "$work/first-manifest"
git --git-dir="$remote" show "$tag:Sources/JsBaySDK/JsBay.swift" > "$work/first-source"
cmp "$output/Sources/JsBaySDK/JsBay.swift" "$work/first-source"

run_publisher "$source_sha"
test "$(tag_commit)" = "$first_commit"

printf 'source two\n' > "$clone/source-two.txt"
git -C "$clone" add source-two.txt
git -C "$clone" commit -qm 'Source two'
other_source=$(git -C "$clone" rev-parse HEAD)
if run_publisher "$other_source"; then
  echo 'existing tag was accepted for a different source commit' >&2
  exit 1
fi
test "$(tag_commit)" = "$first_commit"

printf 'different package metadata\n' >> "$output/Package.swift"
if run_publisher "$source_sha"; then
  echo 'existing tag was accepted for different generated metadata' >&2
  exit 1
fi
test "$(tag_commit)" = "$first_commit"
cp "$work/first-manifest" "$output/Package.swift"
printf 'public struct ChangedJsBay {}\n' > "$output/Sources/JsBaySDK/JsBay.swift"
if run_publisher "$source_sha"; then
  echo 'existing tag was accepted for different generated source content' >&2
  exit 1
fi
test "$(tag_commit)" = "$first_commit"
git --git-dir="$remote" show "$tag:Package.swift" > "$work/final-manifest"
cmp "$work/first-manifest" "$work/final-manifest"
git --git-dir="$remote" show "$tag:Sources/JsBaySDK/JsBay.swift" > "$work/final-source"
cmp "$work/first-source" "$work/final-source"

malicious_clone="$work/malicious-clone"
git clone -q "$remote" "$malicious_clone"
git -C "$malicious_clone" config user.name 'Package Tag Test'
git -C "$malicious_clone" config user.email 'package-tag-test@example.invalid'
git -C "$malicious_clone" checkout -q --detach "$source_sha"
cp "$output/Package.swift" "$malicious_clone/Package.swift"
cp -R "$output/Sources" "$malicious_clone/Sources"
printf 'unexpected source modification\n' > "$malicious_clone/source.txt"
git -C "$malicious_clone" add -- Package.swift Sources source.txt
git -C "$malicious_clone" commit -qm 'Tampered package commit'
git -C "$malicious_clone" tag -a v1.2.4 -m 'Tampered release'
git -C "$malicious_clone" push -q origin refs/tags/v1.2.4
malicious_tag=$(git --git-dir="$remote" rev-parse 'refs/tags/v1.2.4^{commit}')
if run_publisher_at "$malicious_clone" 1.2.4 "$source_sha"; then
  echo 'existing tag with an unrelated source change was accepted' >&2
  exit 1
fi
test "$(git --git-dir="$remote" rev-parse 'refs/tags/v1.2.4^{commit}')" = "$malicious_tag"

stage_version=1.2.5
stage_ref=refs/heads/jsbay-package-staging-test
(cd "$clone" && JSBAY_PACKAGE_REF="$stage_ref" bash "$root/scripts/create-swift-package-tag.sh" "$output" "$stage_version" "$source_sha")
test -z "$(git --git-dir="$remote" show-ref --verify refs/tags/v1.2.5 || true)"
stage_commit=$(git --git-dir="$remote" rev-parse "$stage_ref^{commit}")
test "$(git --git-dir="$remote" rev-parse "$stage_commit^")" = "$source_sha"
(cd "$clone" && JSBAY_PACKAGE_REF="$stage_ref" bash "$root/scripts/create-swift-package-tag.sh" "$output" "$stage_version" "$source_sha")
test "$(git --git-dir="$remote" rev-parse "$stage_ref^{commit}")" = "$stage_commit"
