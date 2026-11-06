#!/bin/zsh
# Builds the overlay demo from Core + Overlay sources (and AXElement, which Core's links refer to; no Xcode
# project needed).
# Usage: Tools/overlay-demo/build.sh [output-dir]   then run <output-dir>/overlay-demo [--screenshot out.png]
#        (or <output-dir>/overlay-demo --render <dir> for off-screen PNGs, no windows)
set -euo pipefail
DIR=${0:A:h}
ROOT=${DIR:h:h}
OUT=${1:-${TMPDIR:-/tmp}/plamonic-overlay-demo}
mkdir -p "$OUT"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -O \
  -o "$OUT/overlay-demo" \
  "$ROOT"/Plamonic/Core/*.swift "$ROOT"/Plamonic/Accessibility/AXElement.swift "$ROOT"/Plamonic/Overlay/*.swift \
  "$DIR"/*.swift
echo "$OUT/overlay-demo"
