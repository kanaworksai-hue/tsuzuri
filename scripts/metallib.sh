#!/bin/bash
# Compiles MLX's Metal kernels into mlx.metallib. `swift build` does not do this,
# so every binary that runs MLX needs mlx.metallib next to it.
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the selected Xcode; only fall back to /Applications/Xcode.app when xcode-select points at the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" != *.app/* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SRC=.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal
OUT=.build/mlx.metallib
if [ -f "$OUT" ] && [ -z "$(find "$SRC" -name '*.metal' -newer "$OUT" | head -1)" ]; then
  exit 0
fi
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "The Metal compiler is missing. Install Xcode's Metal Toolchain: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi
echo "Compiling MLX Metal kernels..."
AIR=.build/mlx_air
rm -rf "$AIR" && mkdir -p "$AIR"
for f in "$SRC"/*.metal; do
  xcrun -sdk macosx metal -target air64-apple-macos14.0 \
    -I "$SRC" -I "$SRC/steel" -I "$SRC/steel/attn" -I "$SRC/steel/conv" -I "$SRC/steel/gemm" -I "$SRC/fft" \
    -c "$f" -o "$AIR/$(basename "$f" .metal).air" &
done
wait
xcrun -sdk macosx metallib "$AIR"/*.air -o "$OUT"
rm -rf "$AIR"
