#!/usr/bin/env bash
# package-dmg-macos.sh — wrap a (signed, stapled) Lineup.app into a DMG, then
# Developer ID sign + notarize + staple the DMG itself.
#
# Uses only hdiutil (no create-dmg dependency). The app inside is already
# notarized + stapled by sign-and-notarize-macos.sh; this additionally signs and
# notarizes the DMG so the download itself passes Gatekeeper without a quarantine
# warning (and works offline once stapled).
#
# Signing reuses the SAME six APPLE_* CI variables and the shared plumbing in
# scripts/lib/apple-codesign.sh. As with the app step: STRICT=1 (release tags)
# makes missing/partial creds a hard failure; STRICT=0 (default) emits an
# unsigned DMG with a warning when no creds are present.
#
# Usage: ./scripts/package-dmg-macos.sh [path/to/Lineup.app] [output-dir]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

APP="${1:-build/Build/Products/Release/Lineup.app}"
OUT_DIR="${2:-dist}"

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
mkdir -p "$OUT_DIR"
DMG="${OUT_DIR}/Lineup-${VERSION}.dmg"
STAGE="$(mktemp -d -t lineup-dmg)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "→ Building $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "Lineup" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

# ─── Sign + notarize + staple the DMG ─────────────────────────────────────
# shellcheck source=lib/apple-codesign.sh
source "${SCRIPT_DIR}/lib/apple-codesign.sh"

STRICT="${STRICT:-0}"
gate_rc=0
apple_codesign_gate "$STRICT" "${CI_COMMIT_TAG:+tag ${CI_COMMIT_TAG}}" || gate_rc=$?
if [[ $gate_rc == 77 ]]; then
  echo "✓ Packaged $DMG (unsigned)"
  exit 0
fi
[[ $gate_rc != 0 ]] && exit "$gate_rc"

# Chain the DMG cleanup with the keychain cleanup (single EXIT trap).
trap 'apple_codesign_cleanup; rm -rf "$STAGE"' EXIT
trap 'trap - EXIT; apple_codesign_cleanup; rm -rf "$STAGE"; exit 130' INT
trap 'trap - EXIT; apple_codesign_cleanup; rm -rf "$STAGE"; exit 143' TERM
apple_codesign_setup

echo "→ codesign $DMG"
codesign --force --options=runtime --timestamp \
  --keychain "$APPLE_KEYCHAIN" --sign "$APPLE_SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

apple_notarize "$DMG"

echo "→ Stapling notary ticket to DMG"
xcrun stapler staple "$DMG"
echo "→ Gatekeeper assessment"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true

echo "✓ Packaged, signed, notarized and stapled $DMG"
