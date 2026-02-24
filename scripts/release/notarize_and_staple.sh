#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  NOTARY_KEYCHAIN_PROFILE="<profile>" [NOTARY_TEAM_ID="<team-id>"] ./scripts/release/notarize_and_staple.sh <path-to-app|pkg|dmg>

Examples:
  NOTARY_KEYCHAIN_PROFILE="pangolin-notary" ./scripts/release/notarize_and_staple.sh build/release/developerid/Pangolin.app
  NOTARY_KEYCHAIN_PROFILE="pangolin-notary" ./scripts/release/notarize_and_staple.sh build/release/developerid/Pangolin.pkg
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

if [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  echo "error: NOTARY_KEYCHAIN_PROFILE is required"
  exit 1
fi

TARGET_PATH="$1"
if [[ ! -e "$TARGET_PATH" ]]; then
  echo "error: target not found: $TARGET_PATH"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/build/release/notary}"
mkdir -p "$WORK_DIR"

submit_target=""
staple_target=""
assess_type=""
target_extension="${TARGET_PATH##*.}"

case "$target_extension" in
  app)
    app_name="$(basename "$TARGET_PATH" .app)"
    zip_path="$WORK_DIR/$app_name.zip"
    echo "==> Packaging app for notarization: $zip_path"
    rm -f "$zip_path"
    ditto -c -k --sequesterRsrc --keepParent "$TARGET_PATH" "$zip_path"
    submit_target="$zip_path"
    staple_target="$TARGET_PATH"
    assess_type="exec"
    ;;
  pkg)
    submit_target="$TARGET_PATH"
    staple_target="$TARGET_PATH"
    assess_type="install"
    ;;
  dmg)
    submit_target="$TARGET_PATH"
    staple_target="$TARGET_PATH"
    assess_type="open"
    ;;
  *)
    echo "error: unsupported target type '$target_extension' (expected .app, .pkg, or .dmg)"
    exit 1
    ;;
esac

notary_args=(submit "$submit_target" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait)
if [[ -n "${NOTARY_TEAM_ID:-}" ]]; then
  notary_args+=(--team-id "$NOTARY_TEAM_ID")
fi

echo "==> Submitting for notarization"
xcrun notarytool "${notary_args[@]}"

echo "==> Stapling ticket to $staple_target"
xcrun stapler staple "$staple_target"

echo "==> Validating stapled ticket"
xcrun stapler validate "$staple_target"

echo "==> Running Gatekeeper assessment"
spctl -a -vv -t "$assess_type" "$staple_target"

echo "==> Notarization + stapling succeeded for $staple_target"
