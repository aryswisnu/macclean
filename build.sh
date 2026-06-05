#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="MacClean"
APP_DIR="${APP_NAME}.app"
BIN_NAME="${APP_NAME}"
BUNDLE_ID="com.local.macclean"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Build icon if missing
if [ ! -f MacClean.icns ]; then
    ./make_icon.sh
fi
cp MacClean.icns "${APP_DIR}/Contents/Resources/MacClean.icns"

# Compile
swiftc -O \
    -parse-as-library \
    -target arm64-apple-macos13 \
    -framework SwiftUI \
    -framework AppKit \
    -o "${APP_DIR}/Contents/MacOS/${BIN_NAME}" \
    MacClean.swift

# Info.plist
cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>MacClean</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

# Sign with the stable local identity so the code signature (and thus its
# Designated Requirement) stays constant across rebuilds. macOS TCC keys
# privacy grants (e.g. Full Disk Access) on that DR, so granting access once
# sticks across rebuilds. Falls back to ad-hoc if the cert is missing.
SIGN_ID="MacClean Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_ID}"; then
    codesign --force --deep --sign "${SIGN_ID}" "${APP_DIR}" 2>/dev/null \
        && echo "Signed with: ${SIGN_ID}" \
        || codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true
else
    echo "Note: '${SIGN_ID}' identity not found — ad-hoc signing (TCC grants won't persist)."
    codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true
fi

echo "Built: $(pwd)/${APP_DIR}"
echo "Run:   open ${APP_DIR}"
