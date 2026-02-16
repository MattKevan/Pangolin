#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENTITLEMENTS_FILE="Pangolin/Pangolin.entitlements"

if rg -n "com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write" "$ENTITLEMENTS_FILE" >/dev/null; then
  echo "error: forbidden entitlement present in $ENTITLEMENTS_FILE"
  exit 1
fi

if rg -n "\bas!\b" Pangolin --glob '*.swift' >/dev/null; then
  echo "error: force cast (as!) detected in Pangolin sources"
  rg -n "\bas!\b" Pangolin --glob '*.swift'
  exit 1
fi

if rg -n "\btry!\b" Pangolin --glob '*.swift' >/dev/null; then
  echo "error: force try (try!) detected in Pangolin sources"
  rg -n "\btry!\b" Pangolin --glob '*.swift'
  exit 1
fi

SELECTED_FORCE_UNWRAP_PATTERN="video\.title!|video\.fileName!|video\.dateAdded!|subtitle\.format!|folder\.id!|outputSelection!"
SELECTED_FORCE_UNWRAP_FILES=(
  "Pangolin/Views/Components/VideoInfoView.swift"
  "Pangolin/Views/Components/VideoPlayerWithPosterView.swift"
  "Pangolin/Views/Components/TranslationView.swift"
  "Pangolin/Views/Components/ContentRowView.swift"
)
if rg -n "$SELECTED_FORCE_UNWRAP_PATTERN" "${SELECTED_FORCE_UNWRAP_FILES[@]}" >/dev/null; then
  echo "error: selected force-unwrap patterns detected in Pangolin sources"
  rg -n "$SELECTED_FORCE_UNWRAP_PATTERN" "${SELECTED_FORCE_UNWRAP_FILES[@]}"
  exit 1
fi

echo "quality gates passed"
