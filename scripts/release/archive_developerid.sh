#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-Pangolin.xcodeproj}"
SCHEME="${SCHEME:-Pangolin}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/release/Pangolin.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/release/developerid}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/scripts/release/ExportOptions-DeveloperID.plist}"
REUSE_ARCHIVE="${REUSE_ARCHIVE:-1}"

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  echo "error: export options plist not found at $EXPORT_OPTIONS_PLIST"
  exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"

if [[ "$REUSE_ARCHIVE" == "1" ]]; then
  if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "error: archive does not exist at $ARCHIVE_PATH (set REUSE_ARCHIVE=0 to build one)"
    exit 1
  fi
  echo "==> Reusing archive: $ARCHIVE_PATH"
else
  echo "==> Archiving ($CONFIGURATION) for Developer ID"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    archive \
    -archivePath "$ARCHIVE_PATH"
fi

echo "==> Exporting Developer ID package/app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

echo "==> Export complete: $EXPORT_PATH"
find "$EXPORT_PATH" -maxdepth 2 -mindepth 1 -print
