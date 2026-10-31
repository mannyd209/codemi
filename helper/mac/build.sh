#!/bin/bash
# Builds, signs (Developer ID) and packages the macOS CodeMi Helper into ../relay/public/helper/mac.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../relay/public/helper/mac
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application: Manuel Duarte \(28SERP79H5\)/{print $2; exit}')
mkdir -p build "$OUT"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12" main.swift -o "build/codemi-helper-$arch"
done
lipo -create build/codemi-helper-arm64 build/codemi-helper-x86_64 -output build/codemi-helper
codesign --force --options runtime --timestamp --identifier com.mannydlabs.codemi.helper --sign "$IDENTITY" build/codemi-helper
codesign --verify --strict build/codemi-helper
rm -f "$OUT/codemi-helper.zip"
ditto -c -k build/codemi-helper "$OUT/codemi-helper.zip"
shasum -a 256 "$OUT/codemi-helper.zip" | cut -d' ' -f1 > "$OUT/codemi-helper.sha256"
echo "Packaged: $OUT/codemi-helper.zip ($(cut -c1-12 "$OUT/codemi-helper.sha256")…)"
