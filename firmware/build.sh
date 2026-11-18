#!/bin/bash
# Build Keychron K5 Max (K5M-H3 = ANSI + RGB) firmware from Keychron's QMK fork.
#
# Prerequisites (one-time, no sudo needed for the toolchain):
#   git clone --depth 1 --branch 2025q3 https://github.com/Keychron/qmk_firmware /tmp/qmk_firmware
#   cd /tmp/qmk_firmware
#   git submodule update --init --depth 1 lib/chibios lib/chibios-contrib lib/printf lib/lufa
#
#   python3 -m venv /tmp/qmkvenv && /tmp/qmkvenv/bin/pip install qmk
#
#   ARM GNU toolchain 13.3.rel1 (has newlib; Homebrew's arm-none-eabi-gcc formula does NOT):
#   curl -L -o /tmp/armtc.tar.xz \
#     "https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi.tar.xz"
#   mkdir -p /tmp/armtc && tar -xf /tmp/armtc.tar.xz -C /tmp/armtc --strip-components=1
#
# Usage:  ./firmware/build.sh [kb] [km] [outdir]
set -euo pipefail

KB="${1:-keychron/k5_max/ansi/rgb}"     # K5M-H3 is ANSI + RGB
KM="${2:-keychron}"
OUT="${3:-$(cd "$(dirname "$0")" && pwd)/builds}"

QMK_HOME="${QMK_HOME:-/tmp/qmk_firmware}"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-/tmp/armtc/bin}"
QMK_VENV="${QMK_VENV:-/tmp/qmkvenv}"

[ -d "$QMK_HOME" ] || { echo "missing QMK checkout at $QMK_HOME"; exit 1; }
[ -x "$TOOLCHAIN_BIN/arm-none-eabi-gcc" ] || { echo "missing ARM toolchain at $TOOLCHAIN_BIN"; exit 1; }
[ -x "$QMK_VENV/bin/qmk" ] || { echo "missing qmk CLI at $QMK_VENV"; exit 1; }

export PATH="$TOOLCHAIN_BIN:$QMK_VENV/bin:/opt/homebrew/bin:$PATH"
export QMK_HOME

# Refuse to build the wrong SKU silently.
case "$KB" in
  keychron/k5_max/ansi/rgb) ;;
  *) echo "note: building $KB — K5M-H3 is keychron/k5_max/ansi/rgb" ;;
esac

cd "$QMK_HOME"
qmk compile -kb "$KB" -km "$KM"

name="$(basename "$KB" | tr '/' '_')_${KM}"
built="$QMK_HOME/keychron_k5_max_$(echo "$KB" | sed 's#keychron/k5_max/##; s#/#_#g')_${KM}.bin"
[ -f "$built" ] || built="$(ls -t "$QMK_HOME"/*.bin | head -1)"

mkdir -p "$OUT"
cp "$built" "$OUT/last-built.bin"
echo "built: $OUT/last-built.bin"
shasum -a 256 "$OUT/last-built.bin"
