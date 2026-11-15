#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/macos_control.swift"
BIN_DIR="$SCRIPT_DIR/bin"
OUT="$BIN_DIR/mcu"

mkdir -p "$BIN_DIR"
echo "Compiling native macOS Computer Use CLI (mcu) with swiftc -O..."
PLIST_FLAGS=()
if [ -f "$SCRIPT_DIR/Info.plist" ]; then
    PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SCRIPT_DIR/Info.plist")
fi
swiftc -O "$SRC" -o "$OUT" "${PLIST_FLAGS[@]}" -framework Cocoa -framework ScreenCaptureKit -framework Vision -framework CoreImage -framework CoreMedia
chmod +x "$OUT"

echo "Build successful! Binary created at: $OUT"
"$OUT" screen info > /dev/null && echo "Self-test passed: Display info query OK."
