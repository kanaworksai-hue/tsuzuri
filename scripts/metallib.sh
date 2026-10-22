#!/bin/bash
# Compiles MLX's Metal kernels into mlx.metallib. `swift build` does not do this,
# so every binary that runs MLX needs mlx.metallib next to it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SRC=.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal
OUT=.build/mlx.metallib
if [ -f "$OUT" ] && [ -z "$(find "$SRC" -name '*.metal' -newer "$OUT" | head -1)" ]; then
  exit 0
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
