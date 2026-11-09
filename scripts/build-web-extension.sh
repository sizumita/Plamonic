#!/usr/bin/env bash
# Puts the web extension (BrowserExtension/, built to dist/safari) into the Safari extension being built. Xcode runs
# it as a build phase of PlamonicSafariExtension.
#
#   scripts/build-web-extension.sh DESTINATION
#
# CI and releases build the web extension first (npm ci && npm run build). On a Mac, when dist/safari is missing or
# older than the sources, this builds it with Node if Node and BrowserExtension/node_modules are there, and fails
# otherwise rather than ship stale files.
set -euo pipefail

fail() {
  echo "error: build-web-extension.sh: $*" >&2
  exit 1
}

(($# == 1)) || fail "usage: scripts/build-web-extension.sh DESTINATION"
destination="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web="${root}/BrowserExtension"
built="${web}/dist/safari"

# The newest source file, compared with the built manifest.
stale() {
  [[ -f "${built}/manifest.json" ]] || return 0
  [[ -n "$(find "${web}/src" "${web}/static" "${web}/scripts/build.mjs" "${web}/package.json" \
    -newer "${built}/manifest.json" -type f -print -quit)" ]]
}

# Xcode runs build phases with a minimal PATH.
find_node() {
  local candidate
  for candidate in "$(command -v node || true)" /opt/homebrew/bin/node /usr/local/bin/node \
    "${HOME}/.volta/bin/node" "${HOME}/.vite-plus/bin/node" "${HOME}"/.nvm/versions/node/*/bin/node; do
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

if stale; then
  node="$(find_node)" || fail "BrowserExtension/dist/safari is missing or out of date, and Node was not found. Run: cd BrowserExtension && npm ci && npm run build"
  [[ -d "${web}/node_modules" ]] || fail "BrowserExtension/node_modules is missing. Run: cd BrowserExtension && npm ci"
  echo "Building the web extension with ${node}"
  (cd "${web}" && "${node}" scripts/build.mjs)
fi

# Only ever into a Safari extension's Resources: --delete removes files the web extension no longer has.
[[ "${destination}" == *.appex/Contents/Resources ]] || fail "unexpected destination ${destination}"
mkdir -p "${destination}"
rsync -a --delete "${built}/" "${destination}/"
echo "Copied the web extension into ${destination}"
