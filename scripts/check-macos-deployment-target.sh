#!/usr/bin/env bash
set -euo pipefail

minimum=${1:?minimum macOS version required}
shift
if [[ ! $minimum =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ || $# -eq 0 ]]; then
  echo "Usage: check-macos-deployment-target.sh <minimum-version> <Mach-O artifact>..." >&2
  exit 2
fi
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

check_macho() {
  local artifact=$1
  local versions
  test -s "$artifact"
  versions=$(otool -l "$artifact" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build_version = 1; platform = 0; next }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy_macos = 1; next }
    build_version && $1 == "platform" { platform = $2; next }
    build_version && platform == 1 && $1 == "minos" { print $2; build_version = 0; next }
    legacy_macos && $1 == "version" { print $2; legacy_macos = 0 }
  ')
  if [[ -z $versions ]]; then
    echo "ERROR: no macOS deployment target found in $artifact" >&2
    exit 1
  fi
  while IFS= read -r version; do
    if ! awk -v actual="$version" -v expected="$minimum" 'BEGIN {
      split(actual, a, ".")
      split(expected, e, ".")
      for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (e[i] + 0)) exit 0
        if ((a[i] + 0) > (e[i] + 0)) exit 1
      }
      exit 0
    }'; then
      echo "ERROR: $artifact requires macOS $version, above the declared minimum $minimum" >&2
      exit 1
    fi
  done <<< "$versions"
  checked_load_commands=$((checked_load_commands + $(printf '%s\n' "$versions" | wc -l | tr -d ' ')))
}

for artifact in "$@"; do
  checked_load_commands=0
  if [[ $artifact == *.a ]]; then
    member_index=0
    while IFS= read -r member; do
      [[ $member == __.SYMDEF* ]] && continue
      member_index=$((member_index + 1))
      member_path="$temporary_directory/member-$member_index"
      ar -p "$artifact" "$member" > "$member_path"
      check_macho "$member_path"
    done < <(ar -t "$artifact")
    if (( member_index == 0 )); then
      echo "ERROR: no object members found in $artifact" >&2
      exit 1
    fi
  else
    check_macho "$artifact"
  fi
  printf 'macOS deployment target <= %s: %s (%s load commands checked)\n' "$minimum" "$artifact" "$checked_load_commands"
done
