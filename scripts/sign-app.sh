#!/usr/bin/env bash
# Signs Plamonic.app from the inside out for distribution, with the hardened runtime and a secure timestamp, as
# notarization requires: Sparkle's helpers (as Sparkle's documentation lists them), then every framework and library
# in Contents/Frameworks, then the app with its entitlements.
#
#   scripts/sign-app.sh APP IDENTITY ENTITLEMENTS [KEYCHAIN]
#
# IDENTITY "-" signs ad hoc, without the hardened runtime or a timestamp, to try the script and the signed app without a
# certificate: under the hardened runtime, macOS loads no ad-hoc-signed framework into an ad-hoc-signed app.
set -euo pipefail

fail() {
  echo "sign-app.sh: $*" >&2
  exit 1
}

(($# == 3 || $# == 4)) || fail "usage: scripts/sign-app.sh APP IDENTITY ENTITLEMENTS [KEYCHAIN]"
app="$1"
identity="$2"
entitlements="$3"
keychain="${4:-}"
[[ -d "$app/Contents/MacOS" ]] || fail "$app is not an app"
[[ -f "$entitlements" ]] || fail "no entitlements file $entitlements"

options=(--force --sign "$identity")
if [[ "$identity" == - ]]; then
  options+=(--timestamp=none)
else
  options+=(--options runtime --timestamp)
fi
if [[ -n "$keychain" ]]; then
  options+=(--keychain "$keychain")
fi

# sign PATH [OPTION...]
sign() {
  echo "Signing ${1#"$(dirname "$app")"/}"
  codesign "${options[@]}" "${@:2}" "$1"
}

frameworks="$app/Contents/Frameworks"
sparkle="$frameworks/Sparkle.framework/Versions/B"
[[ -d "$sparkle" ]] || fail "no Sparkle.framework (Versions/B) in $app"
sign "$sparkle/XPCServices/Installer.xpc"
sign "$sparkle/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"

while IFS= read -r -d '' item; do
  sign "$item"
done < <(find "$frameworks" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0)

sign "$app" --entitlements "$entitlements"
codesign --verify --deep --strict --verbose=2 "$app"
