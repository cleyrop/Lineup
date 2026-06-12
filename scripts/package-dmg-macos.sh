#!/usr/bin/env bash
# package-dmg-macos.sh — wrap a (signed, stapled) Lineup.app into a DMG.
#
# Uses only hdiutil (no create-dmg dependency). The app inside is already
# notarized + stapled by sign-and-notarize-macos.sh, so Gatekeeper validates
# it on first launch even though the DMG itself is not separately notarized.
#
# Usage: ./scripts/package-dmg-macos.sh [path/to/Lineup.app] [output-dir]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

# Sign the DMG with Developer ID when a cert is available (optional polish;
# the notarized+stapled app inside is what Gatekeeper actually validates).
if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$MACOS_SIGN_IDENTITY" "$DMG"
fi

echo "✓ Packaged $DMG"
