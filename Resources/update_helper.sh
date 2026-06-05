#!/bin/bash
#
# update_helper.sh — invoked by Yaotong at the end of the
# "下载并安装" flow, after the main app has already written the
# DMG to Application Support and is about to quit.
#
# Args (passed in this order by AppDelegate.performInstall):
#   1. <staged_dmg_path>     e.g. ~/Library/Application Support/Yaotong/Updates/Yaotong-0.3.4.dmg
#   2. <app_bundle_path>     absolute path of the currently-running .app
#   3. <mount_point>         where to attach the DMG (a temp dir we create)
#
# What it does:
#   1. Wait briefly for the main app process to fully exit
#      (NSApp.terminate is async; the previous app can still
#      hold the bundle open for a moment after we get here).
#   2. hdiutil attach the DMG read-only.
#   3. rsync the new .app bundle over the old one. We delete
#      the old bundle first because cp -R on top of an existing
#      bundle can leave stale files (e.g. a removed binary).
#   4. hdiutil detach.
#   5. open -n the new bundle to relaunch.
#
# Failure modes:
#   - Any error is logged to stderr and the script exits non-zero.
#     The user sees no auto-rerun; they can install manually
#     from the DMG they already have in ~/Library/.../Updates.
#   - The helper does NOT clean up the staged DMG on success —
#     the next update will overwrite it. Failed installs leave
#     the file in place so the user can retry.
#
set -euo pipefail

DMG="$1"
APP="$2"
MOUNT="$3"

log() { echo "[update_helper] $*" >&2; }

if [[ ! -f "$DMG" ]]; then
    log "DMG not found: $DMG"
    exit 1
fi
if [[ ! -d "$APP" ]]; then
    log "App bundle not found: $APP"
    exit 1
fi

mkdir -p "$MOUNT"

log "waiting for main app to exit"
# 1.5s is enough for a normal app exit; macOS launches the
# relaunch *after* we return, so a too-short sleep risks the
# relaunch opening the still-being-deleted old bundle.
sleep 1.5

log "attaching DMG"
if ! hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >&2; then
    log "hdiutil attach failed"
    rmdir "$MOUNT" 2>/dev/null || true
    exit 2
fi
# Ensure we detach even on early exit.
cleanup() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

# Find the .app inside the mounted DMG. We don't hardcode the
# name "腰痛" because the bundle could be renamed in a future
# release. The DMG staging layout (set up by dmg.sh) puts
# exactly one .app at the root.
APP_IN_DMG=$(find "$MOUNT" -maxdepth 2 -name "*.app" -type d | head -1)
if [[ -z "$APP_IN_DMG" ]]; then
    log "no .app found in mounted DMG at $MOUNT"
    exit 3
fi

log "replacing $APP with $APP_IN_DMG"
# `rm -rf` is the only way to guarantee stale files (e.g., a
# binary removed in the new version) are gone. The old bundle
# is no longer running — main app has quit by now.
rm -rf "$APP"
# `ditto` preserves resource forks and extended attributes that
# Finder / Gatekeeper care about; plain `cp -R` doesn't.
if ! ditto "$APP_IN_DMG" "$APP" >&2; then
    log "ditto failed"
    exit 4
fi

cleanup
trap - EXIT

log "relaunching $APP"
# `open -n` asks LaunchServices for a new instance even if a
# single-instance lock might otherwise be picked up. We want
# the new version, not a re-spawn of the old.
open -n "$APP"
log "done"
