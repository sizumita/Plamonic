#!/bin/bash
# Builds build/ax-probe from Core + Accessibility + Extraction + Tools/ax-probe (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc \
    -swift-version 5 \
    -target arm64-apple-macos15.0 \
    -Onone \
    -module-name AXProbe \
    Plamonic/Core/*.swift \
    Plamonic/Accessibility/*.swift \
    Plamonic/Extraction/*.swift \
    Tools/ax-probe/*.swift \
    -o build/ax-probe
echo "built build/ax-probe"
