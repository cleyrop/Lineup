#!/usr/bin/env bash
# build-macos.sh — build an unsigned Lineup.app with xcodebuild.
#
# Signing is deliberately deferred to sign-and-notarize-macos.sh so the build
# never depends on a developer being logged into the Cleyrop Apple team in
# their local Xcode (and so CI can build on a runner without the cert and only
# sign on release tags). The Developer ID signature + notarization are applied
# afterwards as a separate, re-signable step.
#
# Output: build/Build/Products/Release/Lineup.app
#
# Usage: ./scripts/build-macos.sh [arm64|x86_64]   (default: host arch)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ARCH="${1:-$(uname -m)}"
DERIVED="build"

# Version is injected from the tag in CI (see .gitlab-ci.yml); falls back to the
# project's defaults for local/branch builds. MARKETING_VERSION is the
# user-facing X.Y.Z; CURRENT_PROJECT_VERSION is a monotonic build number.
VERSION_ARGS=()
[[ -n "${MARKETING_VERSION:-}" ]] && VERSION_ARGS+=("MARKETING_VERSION=${MARKETING_VERSION}")
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] && VERSION_ARGS+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")

echo "→ xcodebuild Lineup (Release, ${ARCH}, unsigned) ${VERSION_ARGS[*]:-}"
xcodebuild \
  -project Lineup/Lineup.xcodeproj \
  -scheme Lineup \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -arch "$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  "${VERSION_ARGS[@]}" \
  build

APP="${DERIVED}/Build/Products/Release/Lineup.app"
if [[ ! -d "$APP" ]]; then
  echo "error: expected app not found at $APP" >&2
  exit 1
fi

# Assert the built version matches what was requested (catches a silent
# Info.plist desync before a release ships).
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  BUILT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  if [[ "$BUILT" != "$MARKETING_VERSION" ]]; then
    echo "error: built version $BUILT != requested $MARKETING_VERSION" >&2
    exit 1
  fi
fi
echo "✓ Built $APP (version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
