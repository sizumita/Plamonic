#!/usr/bin/env bash
# For a GitHub Actions job: points xcodebuild and xcrun at the Xcode that Plamonic builds with, for the following steps
# (DEVELOPER_DIR in $GITHUB_ENV). With --metal, also installs Xcode's Metal toolchain when it is missing: MLX
# compiles Metal shaders.
#
#   scripts/select-xcode.sh /Applications/Xcode_27.0.app [--metal]
set -euo pipefail

xcode="${1:-}"
major=27

if [[ ! -x "$xcode/Contents/Developer/usr/bin/xcodebuild" ]]; then
  echo "::error::This runner has no Xcode at '$xcode'. Set XCODE in the workflow to an Xcode $major that the runner image lists (https://github.com/actions/runner-images)."
  echo "Installed:"
  ls -d /Applications/Xcode*.app || true
  exit 1
fi
export DEVELOPER_DIR="$xcode/Contents/Developer"
# Read xcodebuild's whole output before looking at it: piping it into head or grep -q closes the pipe early, and
# xcodebuild then crashes on the broken pipe.
version_output="$(xcodebuild -version)"
version="${version_output%%$'\n'*}"
if [[ ! "$version" =~ ^Xcode\ ${major}(\.|$) ]]; then
  echo "::error::$xcode is $version, not Xcode $major."
  exit 1
fi
echo "DEVELOPER_DIR=$DEVELOPER_DIR" >>"${GITHUB_ENV:-/dev/null}"
xcodebuild -version
xcrun swift --version

if [[ "${2:-}" == --metal ]]; then
  metal_status="$(xcodebuild -showComponent MetalToolchain 2>/dev/null || true)"
  if [[ "$metal_status" == *'Status: installed'* ]]; then
    echo "The Metal toolchain is installed."
  else
    xcodebuild -downloadComponent MetalToolchain
  fi
fi
