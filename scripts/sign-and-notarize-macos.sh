#!/usr/bin/env bash
# sign-and-notarize-macos.sh — Developer ID sign + notarize + staple Lineup.app.
#
# Adapted from cleyrop-sdk/scripts/notarize-macos.sh. The signing mechanics
# (ephemeral keychain, bundled Apple intermediates, find-identity, notarytool
# Accepted-grep) are identical; the differences are bundle-specific:
#   - the artifact is a .app, so nested code is signed inner-first, then the
#     bundle, with the app's own entitlements;
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

# ─── Feature gate ─────────────────────────────────────────────────────────
STRICT="${STRICT:-0}"
REQUIRED_APPLE_VARS=(
  APPLE_DEVELOPER_ID_APPLICATION_P12
  APPLE_DEVELOPER_ID_PASSWORD
  APPLE_TEAM_ID
  APPLE_NOTARY_KEY_ID
  APPLE_NOTARY_KEY_ISSUER
  APPLE_NOTARY_KEY_P8
)
MISSING_APPLE_VARS=()
for v in "${REQUIRED_APPLE_VARS[@]}"; do
  [[ -z "${!v:-}" ]] && MISSING_APPLE_VARS+=("$v")
done

if [[ ${#MISSING_APPLE_VARS[@]} -gt 0 ]]; then
  if [[ "$STRICT" == "1" ]]; then
    {
      echo "error: STRICT=1 but missing Apple credentials${CI_COMMIT_TAG:+ on tag ${CI_COMMIT_TAG}}:"
      for v in "${MISSING_APPLE_VARS[@]}"; do echo "       - $v"; done
      echo "       Refusing to publish an unsigned app for a release."
    } >&2
    exit 1
  fi
  if [[ ${#MISSING_APPLE_VARS[@]} -eq ${#REQUIRED_APPLE_VARS[@]} ]]; then
    cat <<'EOF' >&2
::warning:: APPLE_* CI variables not set — skipping codesign + notarization.
The resulting Lineup.app will trigger a Gatekeeper warning on other Macs.
Provision the six APPLE_* variables (see this script's header) to enable
signing — no code changes are needed; this script auto-enables when present.
EOF
    exit 0
  fi
  {
    echo "error: APPLE_* CI variables are partially provisioned:"
    for v in "${MISSING_APPLE_VARS[@]}"; do echo "       - missing: $v"; done
    echo "       Provision all six, or unset them all (skip path when STRICT=0)."
  } >&2
  exit 1
fi

# ─── Ephemeral keychain ───────────────────────────────────────────────────
WORKDIR="$(mktemp -d -t cleyrop-sign)"
KEYCHAIN="${WORKDIR}/build.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
P12_PATH="${WORKDIR}/cert.p12"
P8_PATH="${WORKDIR}/notary.p8"

cleanup() {
  if [[ -n "${ORIGINAL_KEYCHAINS:-}" ]]; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $ORIGINAL_KEYCHAINS 2>/dev/null || true
  fi
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM

echo "→ Creating ephemeral keychain"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# find-identity walks the search list to validate the chain, so prepend ours.
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | sed -e 's/"//g' | xargs)
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_KEYCHAINS

echo "→ Importing Developer ID Application cert"
echo "$APPLE_DEVELOPER_ID_APPLICATION_P12" | base64 --decode > "$P12_PATH"
security import "$P12_PATH" \
  -k "$KEYCHAIN" \
  -P "$APPLE_DEVELOPER_ID_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# Both in-rotation Apple Developer ID intermediates so the leaf chains to the
# Apple Root regardless of which one signed it (see cleyrop-sdk for the history).
for ca in AppleDeveloperIDCA.cer AppleDeveloperIDG2CA.cer; do
  security import "${SCRIPT_DIR}/${ca}" -k "$KEYCHAIN" -t cert
done

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null

echo "→ Keychain contents (diagnostics)"
security find-identity "$KEYCHAIN" || true

IDENTITIES=$(security find-identity -v -p codesigning "$KEYCHAIN")
IDENTITY=$(printf '%s\n' "$IDENTITIES" | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [[ -z "$IDENTITY" ]]; then
  {
    echo "error: no valid Developer ID Application identity in keychain"
    echo "$IDENTITIES"
  } >&2
  exit 1
fi

# ─── Sign (inner code first, then the bundle) ─────────────────────────────
# A SwiftUI menu-bar app usually has no nested helpers, but sign any embedded
# frameworks/dylibs before the outer bundle so the seal is valid either way.
# --deep is intentionally avoided (Apple-discouraged; misses fresh entitlements).
echo "→ codesign nested code (if any)"
while IFS= read -r -d '' nested; do
  codesign --force --options=runtime --timestamp \
    --keychain "$KEYCHAIN" --sign "$IDENTITY" "$nested"
done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' \) -print0 2>/dev/null)

echo "→ codesign $APP"
codesign --force --options=runtime --timestamp \
  --keychain "$KEYCHAIN" \
  --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

codesign --verify --strict --verbose=2 "$APP"

# ─── Notarize ─────────────────────────────────────────────────────────────
ZIP_PATH="${WORKDIR}/Lineup.zip"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "$APPLE_NOTARY_KEY_P8" | base64 --decode > "$P8_PATH"

echo "→ Submitting to Apple notary service (waits up to 90m)"
NOTARY_OUTPUT="$(xcrun notarytool submit "$ZIP_PATH" \
  --key "$P8_PATH" \
  --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_KEY_ISSUER" \
  --wait \
  --timeout 90m 2>&1)" || true
echo "$NOTARY_OUTPUT"

if ! grep -q "status: Accepted" <<<"$NOTARY_OUTPUT"; then
  echo "error: notarization was not Accepted" >&2
  SUBMISSION_ID="$(awk '$1 == "id:" { print $2; exit }' <<<"$NOTARY_OUTPUT")"
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$P8_PATH" --key-id "$APPLE_NOTARY_KEY_ID" \
      --issuer "$APPLE_NOTARY_KEY_ISSUER" >&2 || true
  fi
  exit 1
fi

# Unlike a bare CLI, a .app bundle can (and should) be stapled so Gatekeeper
# accepts it offline; spctl assessment also works on bundles.
echo "→ Stapling notary ticket"
xcrun stapler staple "$APP"
echo "→ Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

echo "✓ Signed, notarized and stapled $APP"
