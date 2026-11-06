#!/usr/bin/env bash
# Prints the directory of Sparkle's command-line tools (sign_update, generate_keys…) of the Sparkle release that
# Plamonic.xcodeproj pins. It reads the archive's URL and SHA-256 from Sparkle's Package.swift at the revision that the
# app's Package.resolved pins, downloads the archive into DIR, checks it against that checksum and unpacks it, as
# SwiftPM does for the app. (swift package resolve, in a package of its own, wrote no Package.resolved on the runner.)
#
#   scripts/sparkle-tools.sh DIR
set -euo pipefail

fail() {
  echo "sparkle-tools.sh: $*" >&2
  exit 1
}

dir="${1:-}"
[[ -n "$dir" ]] || fail "usage: scripts/sparkle-tools.sh DIR"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolved="$root/Plamonic.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f "$resolved" ]] || fail "no $resolved"

pin() { jq -r --arg key "$1" '.pins[] | select(.identity == "sparkle") | .[$key] // .state[$key] // empty' "$resolved"; }
location="$(pin location)"
version="$(pin version)"
revision="$(pin revision)"
[[ "$location" =~ ^https://github\.com/sparkle-project/Sparkle(\.git)?$ ]] || fail "Package.resolved pins no Sparkle"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Sparkle is not pinned to a release: '$version'"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "Sparkle is not pinned to a revision: '$revision'"

mkdir -p "$dir"
manifest="$dir/Package.swift"
curl -fsSL --retry 3 -o "$manifest" "https://raw.githubusercontent.com/sparkle-project/Sparkle/$revision/Package.swift" \
  || fail "could not download Sparkle's Package.swift at $revision"

# The manifest's constant NAME: let NAME = "VALUE"
constant() { sed -nE "s/^let $1 = \"([^\"]*)\"\$/\\1/p" "$manifest"; }
tag="$(constant tag)"
checksum="$(constant checksum)"
[[ "$tag" == "$version" ]] || fail "Sparkle's Package.swift at $revision is for '$tag', not $version"
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || fail "no checksum in Sparkle's Package.swift at $revision"
# shellcheck disable=SC2016 # The manifest's own Swift interpolation, matched as it is written.
grep -qxF 'let url = "https://github.com/sparkle-project/Sparkle/releases/download/\(tag)/Sparkle-for-Swift-Package-Manager.zip"' \
  "$manifest" || fail "Sparkle's Package.swift at $revision takes its archive from somewhere else"

archive="$dir/Sparkle-for-Swift-Package-Manager.zip"
curl -fsSL --retry 3 -o "$archive" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$tag/Sparkle-for-Swift-Package-Manager.zip" \
  || fail "could not download Sparkle $version"
got="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$got" == "$checksum" ]] || fail "Sparkle $version's archive has the SHA-256 $got, but its Package.swift says $checksum"

out="$dir/Sparkle"
rm -rf "$out"
ditto -x -k "$archive" "$out"
bin="$out/bin"
[[ -x "$bin/sign_update" ]] || fail "no sign_update in $bin"
echo "$bin"
