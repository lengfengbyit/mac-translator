#!/usr/bin/env bash
# Build MacTranslator, install it into /Applications, refresh TCC registrations, launch it.
#
# Usage:
#   ./scripts/install.sh             # auto signing (certificate when available, else ad-hoc)
#   SIGN=adhoc ./scripts/install.sh  # force ad-hoc signing
#   SIGN=cert  ./scripts/install.sh  # force certificate signing (root must be trusted)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacTranslator"
BUNDLE_ID="com.mactranslator.app"
DEST="/Applications/$APP_NAME.app"
BUILT="$ROOT/build/$APP_NAME.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SIGN_KC="$HOME/Library/Keychains/vtsign.keychain-db"

echo "==> Quitting running instances"
pkill -f "$DEST/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "$BUILT/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.6

echo "==> Building"
"$ROOT/build.sh"

echo "==> Installing to $DEST"
BACKUP="$HOME/.mactranslator-backup/$(date +%Y%m%d-%H%M%S)"
if [ -d "$DEST" ]; then
  mkdir -p "$BACKUP"
  cp -R "$DEST" "$BACKUP/$APP_NAME.app"
  echo "    previous version backed up to: $BACKUP/$APP_NAME.app"
  rm -rf "$DEST"
fi
cp -R "$BUILT" "$DEST"

echo "==> Removing quarantine attribute"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Re-signing at final path"
SIGN_MODE="${SIGN:-auto}"
CERT_ID="${MT_SIGN_IDENTITY:-}"
if [ "$SIGN_MODE" = "auto" ]; then
  if [ -z "$CERT_ID" ] && security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null \
      | grep -q "view-timer Dev"; then
    CERT_ID="view-timer Dev"
  fi
  SIGN_MODE="adhoc"
  [ -n "$CERT_ID" ] && SIGN_MODE="cert"
fi

if [ "$SIGN_MODE" = "cert" ]; then
  [ -n "$CERT_ID" ] || CERT_ID="view-timer Dev"
  KC_PASS="${MT_SIGNING_KC_PASS:-}"
  if [ -z "$KC_PASS" ] && [ -f "$HOME/.viewtimer-sign/keychain.pass" ]; then
    KC_PASS="$(tr -d '\r\n' < "$HOME/.viewtimer-sign/keychain.pass")"
  fi
  if [ -n "$KC_PASS" ]; then
    security unlock-keychain -p "$KC_PASS" "$SIGN_KC" >/dev/null 2>&1 || true
  fi
  if codesign --force --deep --sign "$CERT_ID" --keychain "$SIGN_KC" "$DEST" 2>/dev/null; then
    codesign --verify --strict --verbose=2 "$DEST"
    echo "    certificate signature ($CERT_ID); grants persist across rebuilds"
  else
    echo "    [warning] certificate signing failed; falling back to ad-hoc"
    codesign --force --deep --sign - "$DEST"
    SIGN_MODE="adhoc"
  fi
else
  codesign --force --deep --sign - "$DEST"
  codesign --verify --strict --verbose=2 "$DEST"
  echo "    ad-hoc signature (re-authorize after every rebuild)"
fi

# Only ad-hoc needs a TCC reset: its requirement is the binary cdhash, which
# changes on every rebuild. A certificate requirement is identifier + root,
# so resetting it would throw away a working grant.
if [ "$SIGN_MODE" = "adhoc" ]; then
  echo "==> Resetting TCC records for $BUNDLE_ID"
  tccutil reset Accessibility "$BUNDLE_ID" 2>&1 | tail -1 || true
  tccutil reset ScreenCapture "$BUNDLE_ID" 2>&1 | tail -1 || true
fi

echo "==> Refreshing LaunchServices registration"
for stale in "$HOME/.Trash/$APP_NAME.app" "$BUILT"; do
  [ -d "$stale" ] && "$LSREG" -u "$stale" 2>/dev/null || true
done
"$LSREG" -f "$DEST" 2>/dev/null || true

echo "==> Launching"
open "$DEST"

cat <<'TIP'

────────────────────────────────────────────────
Installation complete.

First run, grant these in System Settings > Privacy & Security:
  1. Accessibility      -> add /Applications/MacTranslator.app
  2. Screen Recording   -> add /Applications/MacTranslator.app
  3. Automation         -> confirm when a browser AppleScript prompt appears

With ad-hoc signing, re-add the app (remove with '-' then add with '+') after
each rebuild. Certificate-signed builds keep their grants.
────────────────────────────────────────────────
TIP
