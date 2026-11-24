#!/usr/bin/env bash
# Package the notarized app into a DMG. Usage: ./scripts/package_dmg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_DIR/build/MacTranslator.app"
STAGE_DIR="$PROJECT_DIR/build/dmg_stage"
DMG_PATH="$PROJECT_DIR/build/划译-1.0.0.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH. Run scripts/sign_notarize.sh first." >&2
  exit 1
fi

echo "==> Preparing DMG staging directory"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
if command -v create-dmg >/dev/null 2>&1; then
  echo "==> Creating DMG with create-dmg"
  create-dmg \
    --volname "划译" \
    --window-pos 200 120 \
    --window-size 640 420 \
    --icon-size 96 \
    --app-drop-link 460 200 \
    --hide-extension "MacTranslator.app" \
    "$DMG_PATH" "$STAGE_DIR"
else
  echo "==> create-dmg unavailable, falling back to hdiutil"
  hdiutil create -volname "划译" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
fi

echo "==> Done: $DMG_PATH"
