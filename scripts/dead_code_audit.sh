#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
APP_DIR="$ROOT/Pangolin"

echo "== Dead Code Audit (Pangolin) =="
echo "Root: $ROOT"
echo

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required for this script."
  exit 1
fi

echo "-- Key library view call sites --"
rg -n "struct (FolderContentView|FolderOutlinePane|SmartFolderTablePane|HierarchicalContentView|SearchResultsView|SearchDetailView)\\b|\\b(FolderContentView|FolderOutlinePane|SmartFolderTablePane|HierarchicalContentView|SearchResultsView|SearchDetailView)\\(" \
  "$APP_DIR" -g'*.swift' || true
echo

echo "-- Routing entrypoints --"
rg -n "currentDetailSurface|DetailColumnView|SearchResultsView\\(|FolderContentView\\(|DetailView\\(" \
  "$APP_DIR/Views" -g'*.swift' || true
echo

echo "-- Sidebar destination usage --"
rg -n "LibrarySidebarDestination|SidebarSelection|smartCollection\\(" \
  "$APP_DIR" -g'*.swift' || true
echo

if command -v periphery >/dev/null 2>&1; then
  echo "-- Periphery detected --"
  echo "Run manually (recommended to review config/false positives first):"
  echo "periphery scan --project Pangolin.xcodeproj --schemes Pangolin"
else
  echo "-- Periphery not installed (optional) --"
  echo "Install if you want deeper unused-declaration detection: https://github.com/peripheryapp/periphery"
fi
