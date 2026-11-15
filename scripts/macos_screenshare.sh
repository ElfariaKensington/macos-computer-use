#!/bin/bash
# macos_screenshare.sh - Screen sharing, remote viewing, and recording utilities
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCU="$SCRIPT_DIR/bin/mcu"

if [[ ! -x "$MCU" ]]; then
  "$SCRIPT_DIR/build.sh"
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
  status)
    echo "=== macOS Screen Sharing & Remote Management Status ==="
    "$MCU" screenshare status
    
    echo ""
    echo "=== Network Interfaces & Hostname ==="
    echo "Hostname: $(hostname)"
    echo "Local IPs:"
    ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print "  " $2}'
    
    echo ""
    echo "=== Active Displays ==="
    "$MCU" screen info | grep -E "id|isMain|bounds" || true
    ;;
  
  open)
    TARGET="${1:-localhost}"
    echo "Launching Screen Sharing connection to: $TARGET"
    "$MCU" screenshare open "$TARGET"
    ;;
  
  record-start)
    OUT="${1:-/tmp/screen_recording_$(date +%s).mp4}"
    "$MCU" record start "$OUT"
    ;;
  
  record-stop)
    "$MCU" record stop
    ;;
  
  burst)
    COUNT="${1:-5}"
    INTERVAL="${2:-1}"
    DIR="${3:-/tmp/mcu_burst_$(date +%s)}"
    mkdir -p "$DIR"
    echo "Capturing $COUNT frames at ${INTERVAL}s interval to $DIR..."
    for i in $(seq 1 "$COUNT"); do
      "$MCU" screen capture --scale-1x --output "$DIR/frame_$i.png"
      echo "Captured frame $i / $COUNT -> $DIR/frame_$i.png"
      if [[ $i -lt $COUNT ]]; then
        sleep "$INTERVAL"
      fi
    done
    echo "Burst complete: $DIR"
    ;;
  
  *)
    echo "Usage: $0 {status|open [host]|record-start [output.mp4]|record-stop|burst [count] [interval] [dir]}"
    exit 1
    ;;
esac
