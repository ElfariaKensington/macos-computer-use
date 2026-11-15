#!/bin/bash
# macos_interact.sh - Fast desktop interaction runner
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCU="$SCRIPT_DIR/bin/mcu"

if [[ ! -x "$MCU" ]]; then
  "$SCRIPT_DIR/build.sh"
fi

ACTION="$1"
shift || true

case "$ACTION" in
  click)
    X="$1"
    Y="$2"
    "$MCU" mouse click "$X" "$Y" --button left --count 1
    ;;
  rightclick)
    X="$1"
    Y="$2"
    "$MCU" mouse click "$X" "$Y" --button right --count 1
    ;;
  doubleclick)
    X="$1"
    Y="$2"
    "$MCU" mouse click "$X" "$Y" --button left --count 2
    ;;
  tripleclick)
    X="$1"
    Y="$2"
    "$MCU" mouse click "$X" "$Y" --button left --count 3
    ;;
  move)
    X="$1"
    Y="$2"
    "$MCU" mouse move "$X" "$Y" --smooth
    ;;
  drag)
    X1="$1"; Y1="$2"; X2="$3"; Y2="$4"
    "$MCU" mouse drag "$X1" "$Y1" "$X2" "$Y2"
    ;;
  scroll)
    DX="${1:-0}"
    DY="${2:--5}"
    "$MCU" mouse scroll "$DX" "$DY"
    ;;
  type)
    TEXT="$*"
    "$MCU" keyboard type "$TEXT"
    ;;
  hotkey)
    COMBO="$1"
    "$MCU" keyboard hotkey "$COMBO"
    ;;
  key)
    KEYNAME="$1"
    "$MCU" keyboard key "$KEYNAME"
    ;;
  paste)
    TEXT="$*"
    "$MCU" clipboard set "$TEXT"
    "$MCU" keyboard hotkey "cmd+v"
    ;;
  focus)
    TARGET="$1"
    "$MCU" window focus "$TARGET"
    ;;
  pos)
    "$MCU" mouse pos
    ;;
  *)
    echo "Usage: $0 {click|rightclick|doubleclick|tripleclick|move|drag|scroll|type|hotkey|key|paste|focus|pos} [args...]"
    exit 1
    ;;
esac
