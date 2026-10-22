#!/bin/bash
# Builds a signed and notarized release:
#   build/release/Tsuzuri-<version>.dmg   download for users (signed, notarized, stapled)
#   build/release/Tsuzuri-<version>.zip   stapled app, for Sparkle / Homebrew
#
#   scripts/release.sh 1.0.0
#
# Needs a "Developer ID Application" identity in the login keychain and a notarytool
# keychain profile (default "tsuzuri-notary"; create it with
# `xcrun notarytool store-credentials tsuzuri-notary --key AuthKey_XXX.p8 --key-id XXX --issuer ...`).
#
#   SKIP_NOTARIZE=1   sign only (quick local check)
#   ALLOW_DIRTY=1     allow uncommitted changes
#   NOTARY_PROFILE / RELEASE_IDENTITY override the defaults.
#
# The release app is signed with a different identity than local builds, so macOS asks
# for Microphone / Accessibility again the first time it runs.
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the selected Xcode; only fall back to /Applications/Xcode.app when xcode-select points at the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" != *.app/* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION=${1:?usage: scripts/release.sh VERSION}
BUILD=$(git rev-list --count HEAD)
PROFILE=${NOTARY_PROFILE:-tsuzuri-notary}
IDENTITY=${RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
if [ -z "$IDENTITY" ]; then
  echo "No \"Developer ID Application\" identity in the keychain." >&2
  exit 1
fi
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes (set ALLOW_DIRTY=1 to build anyway)." >&2
  exit 1
fi

OUT=build/release
APP=$OUT/Tsuzuri.app
DMG=$OUT/Tsuzuri-$VERSION.dmg
ZIP=$OUT/Tsuzuri-$VERSION.zip

# Build with an ad-hoc signature, then re-sign a copy so build/Tsuzuri.app stays a dev build.
DEBUG_HOOKS=0 SIGN_IDENTITY=- scripts/build-app.sh
if grep -q "tsuzuri.debug" build/Tsuzuri.app/Contents/MacOS/Tsuzuri; then
  echo "debug hooks found in the release binary" >&2; exit 1
fi
rm -rf "$OUT" && mkdir -p "$OUT"
ditto build/Tsuzuri.app "$APP"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

echo "Signing with $IDENTITY"
codesign --force --options runtime --timestamp --entitlements Resources/Tsuzuri.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

notarize() {
  echo "Notarizing $(basename "$1")..."
  local result id status
  result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
  id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$result")
  status=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")
  if [ "$status" != "Accepted" ]; then
    echo "Notarization $status ($id):" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  # Notarize the app itself first so the copy inside the DMG carries its own ticket.
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
fi
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE=$OUT/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tsuzuri.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Tsuzuri $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo
echo "Tsuzuri $VERSION (build $BUILD)"
shasum -a 256 "$DMG" "$ZIP"
