#!/usr/bin/env bash
# Builds the spike host app (with its Safari extension and Chrome native host) signed with the team's
# Developer ID, so Safari treats the extension as signed.
#
#   Tools/extension-spike/build.sh [IDENTITY]
#
# IDENTITY defaults to the first "Developer ID Application" identity in the keychain. The Safari extension
# packages ../../BrowserExtension/dist/safari when it has been built (npm run build:dev there), else Extension/.
set -euo pipefail
cd "$(dirname "$0")"

identity="${1:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$identity" ]] || { echo "build.sh: no Developer ID Application identity" >&2; exit 1; }

# Clean every time: Xcode does not re-sign the extension when only the copied web extension files changed.
rm -rf build/DD
mkdir -p build
xcodegen generate --quiet
# SPIKE_EXTENSION_DIR=Extension keeps the spike's own files (Plamonic itself now carries the real extension).
extension_dir="${SPIKE_EXTENSION_DIR:-}"
if [[ -z "$extension_dir" ]]; then
  extension_dir=Extension
  [[ -f ../../BrowserExtension/dist/safari/manifest.json ]] && extension_dir=../../BrowserExtension/dist/safari
fi
echo "Safari extension: $extension_dir"
xcodebuild -project PlamonicSpike.xcodeproj -scheme PlamonicSpike -configuration Release \
  -derivedDataPath build/DD SPIKE_SIGN_IDENTITY="$identity" SPIKE_EXTENSION_DIR="$extension_dir" build -quiet

app="build/DD/Build/Products/Release/PlamonicSpike.app"
codesign --verify --deep --strict --verbose=2 "$app"

# Safari ignores extensions of apps inside hidden folders (this worktree is under .claude/), so run it from
# ~/Applications.
pkill -x PlamonicSpike || true
mkdir -p ~/Applications
rm -rf ~/Applications/PlamonicSpike.app
ditto "$app" ~/Applications/PlamonicSpike.app
open ~/Applications/PlamonicSpike.app
echo "Installed ~/Applications/PlamonicSpike.app"
