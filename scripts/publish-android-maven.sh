#!/usr/bin/env bash
set -euo pipefail

usage='usage: publish-android-maven.sh <maven.zip> <version> <backend> <repository-url> [repository-id]'
archive=${1:?$usage}
version=${2:?$usage}
backend=${3:?$usage}
repository_url=${4:?$usage}
repository_id=${5:-github}

root=$(cd "$(dirname "$0")/.." && pwd)
case "$backend" in
    quickjs) artifact_new=jsbay-quickjs; artifact_legacy=jsbayquickjs ;;
    quickjs_ng) artifact_new=jsbay-quickjs-ng; artifact_legacy=jsbayquickjsng ;;
    *) echo "unsupported Android backend: $backend" >&2; exit 2 ;;
esac
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "invalid version: $version" >&2
    exit 2
fi
test -s "$archive"
command -v unzip >/dev/null
command -v zig >/dev/null
maven=${MVN:-mvn}
command -v "$maven" >/dev/null

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-maven-publish.XXXXXX")
trap 'rm -rf "$work"' EXIT
members="$work/archive-members.txt"
unzip -Z1 "$archive" > "$members"
while IFS= read -r member; do
    case "$member" in
        ''|/*|../*|*/../*|*/..|..|*\\*) echo "unsafe archive member: $member" >&2; exit 2 ;;
        io|io/*|LICENSE|THIRD_PARTY_NOTICES.md) ;;
        *) echo "unexpected archive member: $member" >&2; exit 2 ;;
    esac
done < "$members"

artifact=
for candidate in "$artifact_new" "$artifact_legacy"; do
    if grep -Fq "io/jsbay/$candidate/$version/$candidate-$version.aar" "$members"; then
        if [[ -n $artifact ]]; then
            echo 'Maven archive contains multiple artifact coordinates for this backend' >&2
            exit 2
        fi
        artifact=$candidate
    fi
done
if [[ -z $artifact ]]; then
    echo 'Maven archive does not contain the expected backend coordinate' >&2
    exit 2
fi

package="$work/package"
mkdir -p "$package"
unzip -q "$archive" -d "$package"
module_dir="$package/io/jsbay/$artifact/$version"
aar="$module_dir/$artifact-$version.aar"
pom="$module_dir/$artifact-$version.pom"
gradle_module="$module_dir/$artifact-$version.module"
sources="$module_dir/$artifact-$version-sources.jar"
for required in "$aar" "$pom" "$gradle_module" "$sources" "$package/LICENSE" "$package/THIRD_PARTY_NOTICES.md"; do
    test -s "$required" || { echo "missing required Maven package file: $required" >&2; exit 1; }
done
grep -Fqx '  <groupId>io.jsbay</groupId>' "$pom"
grep -Fqx "  <artifactId>$artifact</artifactId>" "$pom"
grep -Fqx "  <version>$version</version>" "$pom"
grep -Fq '<artifactId>kotlin-stdlib</artifactId>' "$pom"
zig build --build-file "$root/build.zig" tool -- check-maven "$module_dir" "$version" "$backend" "$artifact"

publication=("$aar" "$pom" "$gradle_module" "$sources")
coordinate="io.jsbay:$artifact:$version"
curl_options=(--disable --silent --show-error --location --proto '=http,https' --proto-redir '=https' --connect-timeout 10 --max-time 120)

check_published_files() {
    local file filename remote status
    local matching=0
    remote="${repository_url%/}/io/jsbay/$artifact/$version"
    for file in "${publication[@]}"; do
        filename=$(basename "$file")
        status=$(curl "${curl_options[@]}" --output "$work/remote-file" --write-out '%{http_code}' -- "$remote/$filename") || return 2
        case "$status" in
            200)
                if ! cmp -s "$file" "$work/remote-file"; then
                    echo "Published $coordinate file $filename differs from staged contents" >&2
                    return 2
                fi
                matching=$((matching + 1))
                ;;
            404) ;;
            *) echo "Could not read $coordinate file $filename (HTTP $status)" >&2; return 2 ;;
        esac
    done
    if (( matching == 0 )); then return 1; fi
    if (( matching != ${#publication[@]} )); then
        echo "Found an incomplete Maven version for $coordinate ($matching/${#publication[@]} files)" >&2
        return 2
    fi
}

if [[ $repository_url != file://* ]]; then
    command -v curl >/dev/null
    case "$repository_url" in
        https://maven.pkg.github.com/*)
            username=${GITHUB_ACTOR:?GITHUB_ACTOR required for GitHub Packages}
            password=${GITHUB_TOKEN:?GITHUB_TOKEN required for GitHub Packages}
            ;;
        *)
            username=${MAVEN_REPOSITORY_USERNAME:-}
            password=${MAVEN_REPOSITORY_PASSWORD:-}
            ;;
    esac
    if [[ -n $username || -n $password ]]; then
        if [[ -z $username || -z $password || $username == *:* || $username$password == *[[:cntrl:]]* ]]; then
            echo 'Invalid Maven repository credentials' >&2
            exit 2
        fi
        credentials="$username:$password"
        credentials=${credentials//\\/\\\\}
        credentials=${credentials//\"/\\\"}
        (umask 077; printf 'user = "%s"\n' "$credentials" > "$work/curl-auth")
        curl_options+=(--config "$work/curl-auth")
    fi
    if check_published_files; then
        printf '%s already published with matching contents\n' "$coordinate"
        exit 0
    elif [[ $? != 1 ]]; then
        exit 1
    fi
fi

"$maven" -B org.apache.maven.plugins:maven-deploy-plugin:3.1.3:deploy-file \
    -Dfile="$aar" \
    -DpomFile="$pom" \
    -Durl="$repository_url" \
    -DrepositoryId="$repository_id" \
    -Dfiles="$gradle_module,$sources" \
    -Dclassifiers=,sources \
    -Dtypes=module,jar \
    -DgeneratePom=false \
    -DretryFailedDeploymentCount=3

if [[ $repository_url == file://* ]]; then
    target="${repository_url#file://}"
    for file in "${publication[@]}"; do
        cmp "$file" "${target%/}/io/jsbay/$artifact/$version/$(basename "$file")"
    done
elif ! check_published_files; then
    echo "Could not verify deployed Maven version $coordinate" >&2
    exit 1
fi

printf 'Published %s to %s\n' "$coordinate" "$repository_url"
