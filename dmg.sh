#!/bin/bash
#
# Package the built .app into a distributable DMG.
# - Uses hdiutil (macOS built-in), no external tools.
# - Stage layout: <staging>/腰痛.app + symlink to /Applications so users
#   can drag the app into Applications in Finder.
# - Compressed (UDZO, zlib) — typical .app shrinks 10×.
# - Output: build/腰痛-<version>.dmg
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Yaotong"
APP_DISPLAY_NAME="腰痛"
APP_BUNDLE="build/${APP_DISPLAY_NAME}.app"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "Run ./build.sh ${CONFIG} first — ${APP_BUNDLE} not found" >&2
    exit 1
fi

# Read the version from Info.plist (so the DMG filename stays in sync
# with what the app actually reports).
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "${APP_BUNDLE}/Contents/Info.plist")
# DMG filename uses the ASCII `APP_NAME` (English), not the
# Chinese `APP_DISPLAY_NAME`. GitHub's release-asset upload path
# drops / mangles non-ASCII bytes in filenames (the asset comes
# out as `-0.3.0.dmg` instead of `腰痛-0.3.0.dmg`). The .app
# bundle inside is still `腰痛.app` — only the *delivery
# filename* needs to be ASCII-safe.
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="build/${DMG_NAME}"
STAGING="build/dmg-staging"

echo "==> Packaging ${DMG_NAME}"

rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "${APP_BUNDLE}" "${STAGING}/"
# Symlink to /Applications so the user can drag-and-drop install.
ln -s /Applications "${STAGING}/Applications"

# hdiutil create:
#   -ov   overwrite any existing DMG with the same name
#   -fs HFS+  (readable by every macOS since 10.0; APFS-only DMGs
#             require 10.13+ and break older downloaders)
#   -volname  ASCII name shown when the DMG is mounted (Finder also
#             shows the original .app name in the title bar)
#   -srcfolder  bundle the directory verbatim
#   -format UDZO  zlib-compressed read-only
rm -f "${DMG_PATH}"
hdiutil create -ov -fs HFS+ -volname "Yaotong" \
    -srcfolder "${STAGING}" \
    -format UDZO \
    "${DMG_PATH}"

# Cleanup staging but keep the .app bundle — build.sh can re-run on
# top of it and `dmg.sh` should be idempotent.
rm -rf "${STAGING}"

echo "==> Wrote: ${DMG_PATH}"
ls -lh "${DMG_PATH}"
