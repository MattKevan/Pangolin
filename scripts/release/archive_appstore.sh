#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-Pangolin.xcodeproj}"
SCHEME="${SCHEME:-Pangolin}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/release/Pangolin.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/release/appstore}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/scripts/release/ExportOptions-AppStore.plist}"

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  echo "error: export options plist not found at $EXPORT_OPTIONS_PLIST"
  exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"

echo "==> Archiving ($CONFIGURATION) for App Store/TestFlight"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  archive \
  -archivePath "$ARCHIVE_PATH"

echo "==> Exporting App Store package"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

echo "==> Export complete: $EXPORT_PATH"
find "$EXPORT_PATH" -maxdepth 2 -mindepth 1 -print
