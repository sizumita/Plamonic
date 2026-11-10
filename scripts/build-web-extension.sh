#!/usr/bin/env bash
# Puts the web extension (BrowserExtension/) into what Xcode is building, as a build phase:
#
#   scripts/build-web-extension.sh safari DESTINATION   dist/safari, into PlamonicSafariExtension.appex's Resources
#   scripts/build-web-extension.sh chrome DESTINATION   dist/chrome-unpacked, into the app's Resources/ChromeExtension,
#                                                       which a beta offers to load unpacked in Chrome (DESIGN §9.1)
#
# CI and releases build the web extension first (npm ci && npm run build). On a Mac, when the built files are missing
# or older than the sources, this builds them with Node if Node and BrowserExtension/node_modules are there, and fails
# otherwise rather than ship stale files.
set -euo pipefail

fail() {
  echo "error: build-web-extension.sh: $*" >&2
  exit 1
}

(($# == 2)) || fail "usage: scripts/build-web-extension.sh safari|chrome DESTINATION"
destination="$2"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web="${root}/BrowserExtension"
# Only ever into these folders: --delete removes files the web extension no longer has.
case "$1" in
safari)
  built="${web}/dist/safari"
  [[ "${destination}" == *.appex/Contents/Resources ]] || fail "unexpected destination ${destination}"
  ;;
chrome)
  built="${web}/dist/chrome-unpacked"
  [[ "${destination}" == *.app/Contents/Resources/ChromeExtension ]] || fail "unexpected destination ${destination}"
  ;;
*) fail "usage: scripts/build-web-extension.sh safari|chrome DESTINATION" ;;
esac

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
  node="$(find_node)" || fail "BrowserExtension/dist/${built##*/} is missing or out of date, and Node was not found. Run: cd BrowserExtension && npm ci && npm run build"
  [[ -d "${web}/node_modules" ]] || fail "BrowserExtension/node_modules is missing. Run: cd BrowserExtension && npm ci"
  echo "Building the web extension with ${node}"
  (cd "${web}" && "${node}" scripts/build.mjs)
fi

mkdir -p "${destination}"
rsync -a --delete "${built}/" "${destination}/"
echo "Copied the web extension into ${destination}"
