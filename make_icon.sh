#!/bin/bash
set -e
cd "$(dirname "$0")"

ICONSET="MacClean.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Render base 1024 PNG via Swift
swift make_icon.swift "$ICONSET/icon_512x512@2x.png"

# Generate all required sizes from base
sips -z 16 16     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_512x512.png" >/dev/null

# Package into .icns
iconutil --convert icns "$ICONSET" --output MacClean.icns

echo "Built MacClean.icns"
