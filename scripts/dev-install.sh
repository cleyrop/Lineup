#!/usr/bin/env bash
# dev-install.sh — build and install the Debug app as a SEPARATE app from the
# release, so the two never fight over one TCC grant or LaunchServices entry.
#
# The Debug config builds with bundle id `com.cleyrop.lineup.dev` and display
# name "Lineup Dev" (the release is `com.cleyrop.lineup` / "Lineup"). macOS therefore
# tracks them as two distinct apps: granting Accessibility / Screen Recording to
# "Lineup Dev" is independent of the release's grant and survives dev rebuilds
# (as long as the same Apple Development cert signs them).
#
# Installs to ~/Applications/Lineup Dev.app and relaunches it. The release
# (/Applications/Lineup.app, installed via `brew install --cask cleyrop/lineup/lineup`)
# is left untouched.
#
# Override the signing identity with LINEUP_DEV_SIGN_IDENTITY if needed.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DERIVED="/tmp/lineup-dev-build"
DEST="$HOME/Applications/Lineup Dev.app"
SIGN_ID="${LINEUP_DEV_SIGN_IDENTITY:-Apple Development: jeanhumann@icloud.com (G5KV523U79)}"

echo "→ building Debug (com.cleyrop.lineup.dev)"
xcodebuild -project Lineup/Lineup.xcodeproj -scheme Lineup -configuration Debug \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

APP="$DERIVED/Build/Products/Debug/Lineup.app"
[[ -d "$APP" ]] || { echo "error: build produced no app at $APP" >&2; exit 1; }

# Guard against ever shipping the dev workflow onto the release identity.
bid="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$bid" != "com.cleyrop.lineup.dev" ]]; then
  echo "error: Debug bundle id is '$bid', expected com.cleyrop.lineup.dev" >&2
  exit 1
fi

# Quit only the dev instance (matched by its install path) — the release keeps
# running. Both executables are named "Lineup", so match on the bundle path.
pkill -f "Lineup Dev.app/Contents/MacOS/Lineup" 2>/dev/null || true
sleep 0.5

rm -rf "$DEST"
cp -R "$APP" "$DEST"
codesign --force --sign "$SIGN_ID" \
  --entitlements Lineup/Lineup/Lineup.entitlements "$DEST" >/dev/null

# Keep LaunchServices pointed only at the installed copy, not the DerivedData
# build output (which shares the dev bundle id and would otherwise duplicate it).
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -u "$APP" 2>/dev/null || true
"$LSREG" -f "$DEST" 2>/dev/null || true

echo "✓ installed → $DEST  ($bid)"
open "$DEST"
