#!/bin/sh
# Builds Contents/MacOS/juxu-qwen-asr and the MLX shader library that sits next to it.
# MLX's prebuilt, hash-pinned shaders are used so the build does not need Xcode's Metal toolchain.
set -eu

MLX_TAG=0.31.6
MLX_COMMIT=0bb916c67f4b9e5c682cbe02a42c701c93ab5021
WHEEL=mlx_metal-0.31.1-py3-none-macosx_14_0_arm64.whl
WHEEL_URL=https://files.pythonhosted.org/packages/39/66/2313497fdbc7fbadf8e026c09366e3f049f9114e65ca4edc23cdb8699186/$WHEEL
WHEEL_SHA=70741174131dbf7fdd479cb730e06e08c358eac3bf7905d9e884e7960cfdd5b8

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEPS="$ROOT/build/qwen-deps"
OUT="$ROOT/build/qwen"
mkdir -p "$DEPS" "$OUT"

# JUXU_MLX_SWIFT_PATH may point at an already prepared source tree for offline builds.
MLX_DIR="${JUXU_MLX_SWIFT_PATH:-$DEPS/mlx-swift}"
if [ ! -f "$MLX_DIR/Package.swift" ]; then
    git clone --quiet --depth 1 --branch "$MLX_TAG" --recurse-submodules --shallow-submodules \
        https://github.com/ml-explore/mlx-swift.git "$MLX_DIR"
    [ "$(git -C "$MLX_DIR" rev-parse HEAD)" = "$MLX_COMMIT" ] || { echo "mlx-swift commit mismatch" >&2; exit 1; }
fi
if ! grep -q '"mlx-generated/metal"' "$MLX_DIR/Package.swift"; then
    sed -i '' 's|exclude: platformExcludes + \[|exclude: platformExcludes + [ "mlx-generated/metal",|' "$MLX_DIR/Package.swift"
fi

WHL="${JUXU_MLX_METAL_WHEEL:-$DEPS/$WHEEL}"
if [ "$(shasum -a 256 "$WHL" 2>/dev/null | cut -d' ' -f1)" != "$WHEEL_SHA" ]; then
    curl -fsSL --retry 5 --retry-delay 3 -o "$WHL" "$WHEEL_URL"
fi
[ "$(shasum -a 256 "$WHL" | cut -d' ' -f1)" = "$WHEEL_SHA" ] || { echo "MLX shader wheel checksum mismatch" >&2; exit 1; }

JUXU_MLX_SWIFT_PATH="$MLX_DIR" MACOSX_DEPLOYMENT_TARGET=14.0 \
    swift build -c release --package-path "$ROOT/Helpers/JuxuQwenASR" --build-path "$OUT"
unzip -o -q -j "$WHL" mlx/lib/mlx.metallib -d "$OUT/release/"
