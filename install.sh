#!/bin/bash
set -euo pipefail

REPO="aryswisnu/macclean"
APP="MacClean.app"
ASSET="MacClean.zip"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

err() { echo "Error: $*" >&2; exit 1; }

# Platform guards.
[ "$(uname -s)" = "Darwin" ] || err "MacClean requires macOS."
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "${os_major:-0}" -ge 13 ] || err "MacClean requires macOS 13 or later (found $(sw_vers -productVersion))."

# Scratch space, always cleaned up.
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "Downloading MacClean..."
curl -fsSL "${URL}" -o "${work}/${ASSET}" \
    || err "Download failed. Is a release published yet? https://github.com/${REPO}/releases"

echo "Extracting..."
ditto -x -k "${work}/${ASSET}" "${work}" || err "Could not extract ${ASSET}."
[ -d "${work}/${APP}" ] || err "Archive did not contain ${APP}."

# Install to /Applications when writable, else ~/Applications.
if [ -w "/Applications" ]; then
    dest="/Applications"
else
    dest="${HOME}/Applications"
    mkdir -p "${dest}"
fi

# Replace any existing install (quit it first).
pkill -x MacClean 2>/dev/null || true
rm -rf "${dest:?}/${APP}"
mv "${work}/${APP}" "${dest}/${APP}"

# MacClean is ad-hoc signed, not notarized. Clear the quarantine flag so macOS
# opens it without the "unidentified developer" block.
xattr -dr com.apple.quarantine "${dest}/${APP}" 2>/dev/null || true

echo "Installed to ${dest}/${APP}"
open "${dest}/${APP}"
