#!/bin/bash
# Builds build/Tsuzuri.app (release) and tsuzuri-cli, each with mlx.metallib where TsuzuriCore finds it.
#
#   scripts/build-app.sh            # sign with the first "Apple Development" identity, else ad-hoc
#   SIGN_IDENTITY=- scripts/build-app.sh
#
# A stable signing identity matters: macOS ties the Accessibility / Microphone
# grants to the signature, so ad-hoc builds lose them on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release
scripts/metallib.sh
cp .build/mlx.metallib .build/release/mlx.metallib

APP=build/Tsuzuri.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tsuzuri "$APP/Contents/MacOS/"
# Resources, not MacOS: codesign treats everything in Contents/MacOS as code.
cp .build/mlx.metallib "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# UI strings: English keys in the source, one table per language here (scripts/check-l10n.py).
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
# License notices: ours, THIRD_PARTY.md and the license of every resolved Swift package
# (MIT / Apache-2.0 require shipping them with the binary).
cp THIRD_PARTY.md "$APP/Contents/Resources/"
{
  cat LICENSE
  for dir in .build/checkouts/*; do
    file=$(ls "$dir" | grep -i -E '^(license|copying)' | head -1 || true)
    [ -n "$file" ] || continue
    printf '\n\n===== %s =====\n\n' "$(basename "$dir")"
    cat "$dir/$file"
  done
} > "$APP/Contents/Resources/Licenses.txt"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed: $SIGN_IDENTITY)"
