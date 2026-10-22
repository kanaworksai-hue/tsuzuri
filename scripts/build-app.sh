#!/bin/bash
# Builds build/Tsuzuri.app (release) and tsuzuri-cli, each with mlx.metallib where TsuzuriCore finds it.
#
#   scripts/build-app.sh            # sign with the first "Apple Development" identity, else ad-hoc
#   SIGN_IDENTITY=- scripts/build-app.sh
#   DEBUG_HOOKS=1 scripts/build-app.sh   # include the scripts/debug.sh hooks (screenshots; never for releases)
#
# A stable signing identity matters: macOS ties the Accessibility / Microphone
# grants to the signature, so ad-hoc builds lose them on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the selected Xcode; only fall back to /Applications/Xcode.app when xcode-select points at the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" != *.app/* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ "${DEBUG_HOOKS:-0}" = 1 ]; then
  swift build -c release -Xswiftc -DTSUZURI_DEBUG_HOOKS
else
  swift build -c release
fi
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
# License notices: ours, THIRD_PARTY.md and every license / NOTICE file of the resolved Swift
# packages, including C/C++ code vendored inside them (mlx-swift bundles MLX, mlx-c, fmt,
# nlohmann/json and metal-cpp). MIT and Apache-2.0 require shipping these with the binary.
cp THIRD_PARTY.md "$APP/Contents/Resources/"
{
  cat LICENSE
  (cd .build/checkouts && find . -maxdepth 5 -type f \( -iname 'license*' -o -iname 'notice*' -o -iname 'copying*' \) \
     -not -ipath '*test*' -not -ipath '*example*' -not -path '*/.build/*' | sed 's|^\./||' | LC_ALL=C sort) |
  while read -r file; do
    printf '\n\n===== %s =====\n\n' "$file"
    cat ".build/checkouts/$file"
  done
  # Code inside MLX whose license lives only in the source file's header comment
  # (linked into the binary or compiled into mlx.metallib).
  mlx=mlx-swift/Source/Cmlx/mlx/mlx
  for file in $mlx/3rdparty/pocketfft.h $mlx/threadpool.h $mlx/small_vector.h \
              $mlx/backend/metal/kernels/expm1f.h $mlx/backend/metal/kernels/cexpf.h; do
    [ -f ".build/checkouts/$file" ] || { echo "missing license source: $file" >&2; exit 1; }
    printf '\n\n===== %s (header) =====\n\n' "$file"
    # Every comment block that mentions a copyright.
    awk 'function flush() { if (buf ~ /[Cc]opyright/) printf "%s\n", buf; buf = "" }
         /^\/\*/ { c = 1 }
         c || /^[[:space:]]*\/\// { buf = buf $0 "\n"; if (/\*\//) c = 0; next }
         { flush() } END { flush() }' ".build/checkouts/$file"
  done
} > "$APP/Contents/Resources/Licenses.txt"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed: $SIGN_IDENTITY)"
