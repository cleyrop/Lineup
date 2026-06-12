#!/usr/bin/env bash
# sign-and-notarize-macos.sh — Developer ID sign + notarize + staple Lineup.app.
#
# Adapted from cleyrop-sdk/scripts/notarize-macos.sh. The signing mechanics
# (ephemeral keychain, bundled Apple intermediates, find-identity, notarytool
# Accepted-grep) live in scripts/lib/apple-codesign.sh, shared with the DMG
# packaging step. The .app specifics handled here:
#   - nested code is signed inner-first, then the bundle, with entitlements;
#   - a bundle CAN be stapled (xcrun stapler) and assessed (spctl --type
#     execute), unlike the bare CLI the SDK ships.
#
# Reuses the SAME six GitLab CI variables already provisioned on apps/internal
# for the Cleyrop CLI — provision them for this project (or at the cleyrop-org
# group level) to enable signing here:
#
#   APPLE_DEVELOPER_ID_APPLICATION_P12   base64 .p12 (Developer ID Application cert + key)
#   APPLE_DEVELOPER_ID_PASSWORD          .p12 export password
#   APPLE_TEAM_ID                        10-char team ID (4SKW2Z97A2)
#   APPLE_NOTARY_KEY_ID                  App Store Connect API key ID
#   APPLE_NOTARY_KEY_ISSUER              API key issuer UUID
#   APPLE_NOTARY_KEY_P8                  base64 .p8 private key
#
# Inputs:
#   $1 = path to Lineup.app (default: build/Build/Products/Release/Lineup.app)
#
# STRICT=1 turns a missing/partial cred set into a hard failure (release tags).
# STRICT=0 (default) skips signing with a warning when ZERO Apple vars are set,
# so feature branches still produce an unsigned .app.

set -euo pipefail

APP="${1:-build/Build/Products/Release/Lineup.app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/../Lineup/Lineup/Lineup.entitlements"

if [[ ! -d "$APP" ]]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements not found: $ENTITLEMENTS" >&2
  exit 1
fi

# shellcheck source=lib/apple-codesign.sh
source "${SCRIPT_DIR}/lib/apple-codesign.sh"

# ─── Feature gate ─────────────────────────────────────────────────────────
STRICT="${STRICT:-0}"
gate_rc=0
apple_codesign_gate "$STRICT" "${CI_COMMIT_TAG:+tag ${CI_COMMIT_TAG}}" || gate_rc=$?
[[ $gate_rc == 77 ]] && exit 0
[[ $gate_rc != 0 ]] && exit "$gate_rc"

# ─── Ephemeral keychain ───────────────────────────────────────────────────
trap apple_codesign_cleanup EXIT
trap 'trap - EXIT; apple_codesign_cleanup; exit 130' INT
trap 'trap - EXIT; apple_codesign_cleanup; exit 143' TERM
apple_codesign_setup

# ─── Sign (inner code first, then the bundle) ─────────────────────────────
# A SwiftUI menu-bar app usually has no nested helpers, but sign any embedded
# frameworks/dylibs before the outer bundle so the seal is valid either way.
# --deep is intentionally avoided (Apple-discouraged; misses fresh entitlements).
echo "→ codesign nested code (if any)"
while IFS= read -r -d '' nested; do
  codesign --force --options=runtime --timestamp \
    --keychain "$APPLE_KEYCHAIN" --sign "$APPLE_SIGN_IDENTITY" "$nested"
done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' \) -print0 2>/dev/null)

echo "→ codesign $APP"
codesign --force --options=runtime --timestamp \
  --keychain "$APPLE_KEYCHAIN" \
  --sign "$APPLE_SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

codesign --verify --strict --verbose=2 "$APP"

# ─── Notarize ─────────────────────────────────────────────────────────────
apple_notarize "$APP"

# Unlike a bare CLI, a .app bundle can (and should) be stapled so Gatekeeper
# accepts it offline; spctl assessment also works on bundles.
echo "→ Stapling notary ticket"
xcrun stapler staple "$APP"
echo "→ Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

echo "✓ Signed, notarized and stapled $APP"
