#!/usr/bin/env bash
# Prints Plamonic's version and build number for a build of HEAD, as `version=…` and `build=…` lines for
# $GITHUB_OUTPUT (docs/DEVELOPMENT.md, "Releases"):
#
#   scripts/version.sh release v1.2.3   the release of that tag: version 1.2.3
#   scripts/version.sh beta             a beta build: a prerelease of the next version, 1.2.4-beta.N
#
# The next version is the last release tag merged into HEAD (vX.Y.Z) with its patch raised, or MARKETING_VERSION in
# project.yml when that is higher (raise it there before a minor or a major release). N counts the commits since that
# tag, or all commits when there is no tag yet. The build number (CFBundleVersion, which Sparkle compares) counts the
# commits of HEAD, so it grows with every build of either kind. It needs the whole history: a shallow clone is refused.
set -euo pipefail

fail() {
  echo "version.sh: $*" >&2
  exit 1
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

semver='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'

[[ "$(git rev-parse --is-shallow-repository)" == false ]] ||
  fail "the clone is shallow: fetch the whole history (actions/checkout with fetch-depth: 0)"
build="$(git rev-list --count HEAD)"

case "${1:-}" in
release)
  tag="${2:-}"
  [[ "$tag" =~ ^v${semver}$ ]] || fail "a release needs a tag vX.Y.Z, not '$tag'"
  commit="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")" || fail "there is no tag $tag"
  [[ "$commit" == "$(git rev-parse HEAD)" ]] || fail "$tag is not HEAD"
  version="${tag#v}"
  ;;
beta)
  configured="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml)"
  [[ "$configured" =~ ^${semver}$ ]] ||
    fail "project.yml needs exactly one MARKETING_VERSION: \"X.Y.Z\", not '$configured'"
  IFS=. read -r major minor patch <<<"$configured"
  last="$(git tag --merged HEAD --list 'v*' | { grep -E "^v${semver}$" || true; } |
    sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
  if [[ -n "$last" ]]; then
    IFS=. read -r a b c <<<"$last"
    c=$((c + 1))
    if ((a > major || (a == major && (b > minor || (b == minor && c > patch))))); then
      major=$a minor=$b patch=$c
    fi
    count="$(git rev-list --count "v$last..HEAD")"
  else
    count="$build"
  fi
  version="$major.$minor.$patch-beta.$count"
  ;;
*)
  fail "usage: scripts/version.sh release vX.Y.Z | scripts/version.sh beta"
  ;;
esac

echo "version=$version"
echo "build=$build"
