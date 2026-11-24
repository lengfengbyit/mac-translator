#!/usr/bin/env bash
# Sign with Developer ID, notarize and staple the archived app.
# Required env: SIGN_IDENTITY, APPLE_ID, APP_PASSWORD, TEAM_ID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_DIR/build/MacTranslator.xcarchive}"
APP_PATH="$PROJECT_DIR/build/MacTranslator.app"
ENTITLEMENTS="$PROJECT_DIR/Sources/MacTranslator/Resources/MacTranslator.entitlements"
ZIP_PATH="$PROJECT_DIR/build/MacTranslator-notarize.zip"

: "${SIGN_IDENTITY:?set SIGN_IDENTITY, e.g. Developer ID Application: Name (TEAMID)}"
: "${APPLE_ID:?set APPLE_ID}"
: "${APP_PASSWORD:?set APP_PASSWORD (app-specific password)}"
: "${TEAM_ID:?set TEAM_ID}"

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "Archive not found: $ARCHIVE_PATH. Run scripts/build.sh Release first." >&2
  exit 1
fi

echo "==> Copying app from archive"
rm -rf "$APP_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/MacTranslator.app" "$APP_PATH"

echo "==> Signing with Hardened Runtime"
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Creating notarization zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting for notarization"
xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

echo "==> Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Verifying Gatekeeper assessment"
spctl -a -vv "$APP_PATH" || true

echo "==> Done: $APP_PATH"
