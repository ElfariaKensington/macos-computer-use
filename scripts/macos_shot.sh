#!/bin/bash
# macos_shot.sh - Quick, normalized screenshot tool for Computer Use
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCU="$SCRIPT_DIR/bin/mcu"

OUTPUT="/tmp/mcu_screen.png"
GRID_FLAG=""
SCALE_FLAG="--scale-1x"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      OUTPUT="$2"
      shift 2
      ;;
    --grid)
      GRID_FLAG="--grid"
      shift
      ;;
    --no-scale)
      SCALE_FLAG=""
      shift
      ;;
    --window)
      EXTRA_ARGS+=(--window "$2")
      shift 2
      ;;
    --rect)
      EXTRA_ARGS+=(--rect "$2")
      shift 2
      ;;
    --cursor)
      EXTRA_ARGS+=(--cursor)
      shift
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -x "$MCU" ]]; then
  "$SCRIPT_DIR/build.sh"
fi

"$MCU" screen capture --output "$OUTPUT" $SCALE_FLAG $GRID_FLAG "${EXTRA_ARGS[@]}"

echo "FILE_PATH: $OUTPUT"
if command -v sips >/dev/null 2>&1; then
  WIDTH=$(sips -g pixelWidth "$OUTPUT" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  HEIGHT=$(sips -g pixelHeight "$OUTPUT" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  echo "DIMENSIONS: ${WIDTH}x${HEIGHT} (logical points space: 1px = 1pt)"
fi
