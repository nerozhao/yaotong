#!/bin/bash
#
# Build the Yaotong.app bundle. Local-only build, no signing, no distribution.
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Yaotong"
APP_DISPLAY_NAME="腰痛"
BUNDLE_ID="local.yaotong.app"

echo "==> Building Swift package (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
APP_DIR="build/${APP_DISPLAY_NAME}.app"

if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Build failed: ${BIN_PATH} not found" >&2
    exit 1
fi

echo "==> Assembling ${APP_DISPLAY_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Generate the Dock icon and drop it into Resources. The Swift script
# is idempotent — running it twice produces a byte-identical PNG — so
# we re-run every build and skip the cache file.
echo "==> Generating AppIcon.png"
swift Resources/generate_icon.swift
cp Resources/AppIcon.png "${APP_DIR}/Contents/Resources/AppIcon.png"

# Ad-hoc sign so the menu bar app can run on Apple Silicon without quarantine issues.
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

echo "==> Built: ${APP_DIR}"
echo "Run with: open \"${APP_DIR}\""
