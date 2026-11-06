#!/usr/bin/env bash
# Prints the directory of Sparkle's command-line tools (sign_update, generate_keys…) of the Sparkle release that
# Plamonic.xcodeproj pins. SwiftPM resolves Sparkle alone into DIR, with the release's archive checked against the
# checksum in Sparkle's manifest, and the revision must match the app's Package.resolved.
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

mkdir -p "$dir"
cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SparkleTools",
    dependencies: [.package(url: "$location", exact: "$version")]
)
EOF
(cd "$dir" && swift package resolve >&2)

got="$(jq -r '.pins[] | select(.identity == "sparkle") | .state.revision' "$dir/Package.resolved")"
[[ "$got" == "$revision" ]] || fail "Sparkle $version resolved to $got, but Package.resolved pins $revision"
bin="$dir/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$bin/sign_update" ]] || fail "no sign_update in $bin"
echo "$bin"
