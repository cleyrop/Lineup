# shellcheck shell=bash
# apple-codesign.sh — sourced helpers for Developer ID signing + notarization.
#
# Single source of truth for the keychain/notary plumbing shared by:
#   - sign-and-notarize-macos.sh  (signs + notarizes + staples Lineup.app)
#   - package-dmg-macos.sh        (signs + notarizes + staples Lineup-*.dmg)
#
# Callers provide the SAME six CI variables (see sign-and-notarize header):
#   APPLE_DEVELOPER_ID_APPLICATION_P12  APPLE_DEVELOPER_ID_PASSWORD  APPLE_TEAM_ID
#   APPLE_NOTARY_KEY_ID  APPLE_NOTARY_KEY_ISSUER  APPLE_NOTARY_KEY_P8
#
# Typical use:
#   source "$(dirname "$0")/lib/apple-codesign.sh"
#   gate_rc=0; apple_codesign_gate "$STRICT" "${CI_COMMIT_TAG:-}" || gate_rc=$?
#   [[ $gate_rc == 77 ]] && exit 0       # no creds, non-strict -> skip cleanly
#   [[ $gate_rc != 0  ]] && exit $gate_rc # partial / strict-missing -> already logged
#   trap apple_codesign_cleanup EXIT
#   apple_codesign_setup                 # sets APPLE_SIGN_IDENTITY
#   codesign ... --keychain "$APPLE_KEYCHAIN" --sign "$APPLE_SIGN_IDENTITY" ...
#   apple_notarize "$ARTIFACT"           # .app (zipped) or .dmg, submits + waits

APPLE_CODESIGN_REQUIRED_VARS=(
  APPLE_DEVELOPER_ID_APPLICATION_P12
  APPLE_DEVELOPER_ID_PASSWORD
  APPLE_TEAM_ID
  APPLE_NOTARY_KEY_ID
  APPLE_NOTARY_KEY_ISSUER
  APPLE_NOTARY_KEY_P8
)

# Directory holding the bundled Apple intermediate certs (this lib lives in
# scripts/lib, the .cer files in scripts/).
APPLE_CODESIGN_CERTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# apple_codesign_gate STRICT [CONTEXT]
#   return 0  -> all six vars present, proceed
#   return 77 -> ZERO vars present and STRICT!=1, caller should skip (exit 0)
#   return 1  -> partial set, or missing under STRICT=1 (message already on stderr)
apple_codesign_gate() {
  local strict="${1:-0}" context="${2:-}"
  local missing=()
  local v
  for v in "${APPLE_CODESIGN_REQUIRED_VARS[@]}"; do
    [[ -z "${!v:-}" ]] && missing+=("$v")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "$strict" == "1" ]]; then
    {
      echo "error: STRICT=1 but missing Apple credentials${context:+ on ${context}}:"
      for v in "${missing[@]}"; do echo "       - $v"; done
      echo "       Refusing to publish an unsigned artifact for a release."
    } >&2
    return 1
  fi

  if [[ ${#missing[@]} -eq ${#APPLE_CODESIGN_REQUIRED_VARS[@]} ]]; then
    cat <<'EOF' >&2
::warning:: APPLE_* CI variables not set — skipping codesign + notarization.
The resulting artifact will trigger a Gatekeeper warning on other Macs.
Provision the six APPLE_* variables (see sign-and-notarize-macos.sh header) to
enable signing — no code changes are needed; this auto-enables when present.
EOF
    return 77
  fi

  {
    echo "error: APPLE_* CI variables are partially provisioned:"
    for v in "${missing[@]}"; do echo "       - missing: $v"; done
    echo "       Provision all six, or unset them all (skip path when STRICT=0)."
  } >&2
  return 1
}

# apple_codesign_setup
#   Creates an ephemeral keychain, imports the Developer ID Application cert and
#   both Apple intermediates, and resolves the signing identity. Exports:
#     APPLE_SIGN_IDENTITY  the identity hash to pass to `codesign --sign`
#     APPLE_KEYCHAIN       the keychain to pass to `codesign --keychain`
#   Register apple_codesign_cleanup on EXIT before calling this.
apple_codesign_setup() {
  APPLE_CODESIGN_WORKDIR="$(mktemp -d -t cleyrop-sign)"
  APPLE_KEYCHAIN="${APPLE_CODESIGN_WORKDIR}/build.keychain-db"
  APPLE_CODESIGN_P8_PATH="${APPLE_CODESIGN_WORKDIR}/notary.p8"
  local keychain_password p12_path
  keychain_password="$(openssl rand -base64 24)"
  p12_path="${APPLE_CODESIGN_WORKDIR}/cert.p12"

  echo "→ Creating ephemeral keychain"
  security create-keychain -p "$keychain_password" "$APPLE_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$APPLE_KEYCHAIN"
  security unlock-keychain -p "$keychain_password" "$APPLE_KEYCHAIN"

  # find-identity walks the search list to validate the chain, so prepend ours.
  APPLE_CODESIGN_ORIGINAL_KEYCHAINS=$(security list-keychains -d user | sed -e 's/"//g' | xargs)
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$APPLE_KEYCHAIN" $APPLE_CODESIGN_ORIGINAL_KEYCHAINS

  echo "→ Importing Developer ID Application cert"
  echo "$APPLE_DEVELOPER_ID_APPLICATION_P12" | base64 --decode > "$p12_path"
  security import "$p12_path" \
    -k "$APPLE_KEYCHAIN" \
    -P "$APPLE_DEVELOPER_ID_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

  # Both in-rotation Apple Developer ID intermediates so the leaf chains to the
  # Apple Root regardless of which one signed it.
  local ca
  for ca in AppleDeveloperIDCA.cer AppleDeveloperIDG2CA.cer; do
    security import "${APPLE_CODESIGN_CERTS_DIR}/${ca}" -k "$APPLE_KEYCHAIN" -t cert
  done

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$keychain_password" \
    "$APPLE_KEYCHAIN" >/dev/null

  echo "→ Keychain contents (diagnostics)"
  security find-identity "$APPLE_KEYCHAIN" || true

  local identities
  identities=$(security find-identity -v -p codesigning "$APPLE_KEYCHAIN")
  APPLE_SIGN_IDENTITY=$(printf '%s\n' "$identities" | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
  if [[ -z "$APPLE_SIGN_IDENTITY" ]]; then
    {
      echo "error: no valid Developer ID Application identity in keychain"
      echo "$identities"
    } >&2
    return 1
  fi
}

# apple_codesign_cleanup — restore the user keychain list and delete ours.
apple_codesign_cleanup() {
  if [[ -n "${APPLE_CODESIGN_ORIGINAL_KEYCHAINS:-}" ]]; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $APPLE_CODESIGN_ORIGINAL_KEYCHAINS 2>/dev/null || true
  fi
  [[ -n "${APPLE_KEYCHAIN:-}" ]] && security delete-keychain "$APPLE_KEYCHAIN" 2>/dev/null || true
  [[ -n "${APPLE_CODESIGN_WORKDIR:-}" ]] && rm -rf "$APPLE_CODESIGN_WORKDIR"
}

# apple_notarize PATH
#   Submits PATH to the Apple notary service and waits. A .app is zipped first
#   (notarytool needs an archive); a .dmg is submitted as-is. Returns nonzero
#   (with the notary log on stderr) when the result is not Accepted.
apple_notarize() {
  local artifact="$1"
  local submit_path="$artifact"

  if [[ -z "${APPLE_CODESIGN_WORKDIR:-}" ]]; then
    echo "error: apple_notarize called before apple_codesign_setup" >&2
    return 1
  fi
  echo "$APPLE_NOTARY_KEY_P8" | base64 --decode > "$APPLE_CODESIGN_P8_PATH"

  if [[ "$artifact" == *.app ]]; then
    submit_path="${APPLE_CODESIGN_WORKDIR}/$(basename "${artifact%.app}").zip"
    ditto -c -k --keepParent "$artifact" "$submit_path"
  fi

  echo "→ Submitting $(basename "$artifact") to Apple notary service (waits up to 90m)"
  local output
  output="$(xcrun notarytool submit "$submit_path" \
    --key "$APPLE_CODESIGN_P8_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_KEY_ISSUER" \
    --wait \
    --timeout 90m 2>&1)" || true
  echo "$output"

  if ! grep -q "status: Accepted" <<<"$output"; then
    echo "error: notarization was not Accepted for $(basename "$artifact")" >&2
    local submission_id
    submission_id="$(awk '$1 == "id:" { print $2; exit }' <<<"$output")"
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --key "$APPLE_CODESIGN_P8_PATH" --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_KEY_ISSUER" >&2 || true
    fi
    return 1
  fi
}
