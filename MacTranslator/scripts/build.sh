#!/usr/bin/env bash
# Build and archive MacTranslator. Usage: ./scripts/build.sh [Debug|Release]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-Release}"
DERIVED_DATA="$PROJECT_DIR/.build"
ARCHIVE_PATH="$PROJECT_DIR/build/MacTranslator.xcarchive"

echo "==> Building MacTranslator ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT_DIR/MacTranslator.xcodeproj" \
  -scheme MacTranslator \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  clean build

echo "==> Archiving to $ARCHIVE_PATH"
mkdir -p "$(dirname "$ARCHIVE_PATH")"
xcodebuild \
  -project "$PROJECT_DIR/MacTranslator.xcodeproj" \
  -scheme MacTranslator \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  archive \
  -archivePath "$ARCHIVE_PATH"

echo "==> Done: $ARCHIVE_PATH"
