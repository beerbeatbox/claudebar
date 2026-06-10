#!/usr/bin/env bash
#
# Package ClaudeBar.app into a drag-to-/Applications DMG installer.
#
# Usage:
#   rps dist            # builds the app first, then packages
#   scripts/make_dmg.sh # packages an existing release build
#
# Prefers `create-dmg` (brew install create-dmg) for the classic installer
# window — app icon on the left, /Applications drop link on the right.
# Falls back to plain `hdiutil` (app + /Applications symlink, default Finder
# layout) when create-dmg isn't installed.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeBar"
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
VERSION="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' pubspec.yaml)"
DMG_DIR="build/dist"
DMG_PATH="${DMG_DIR}/${APP_NAME}-${VERSION}.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH not found — run 'rps build' first." >&2
  exit 1
fi

mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
  # create-dmg exits 2 when the app is unsigned but the DMG is still written;
  # tolerate that and verify the file afterwards.
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 150 185 \
    --app-drop-link 450 185 \
    --hide-extension "${APP_NAME}.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" || true
  [[ -f "$DMG_PATH" ]] || { echo "error: create-dmg failed." >&2; exit 1; }
else
  echo "create-dmg not found (brew install create-dmg) — using hdiutil fallback."
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  cp -R "$APP_PATH" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    "$DMG_PATH"
fi

echo "Created $DMG_PATH"
