#!/usr/bin/env bash
# canvas-toggle-state.sh — emit "on" or "off" for a named toggle, read from
# /tmp/waybar-cache or runtime probe. Argument: one of
#   dnd | dictate | night | warm | paper | newspaper | wifi | focus
# Silent on any error (exit 0 with "off").

set -uo pipefail
CACHE=/tmp/waybar-cache

case "${1:-}" in
  dnd)
    # The bar's notif-dnd cache emits a JSON-like blob; check for active class.
    if grep -q '"alt":"active"' "$CACHE/notif-dnd" 2>/dev/null; then echo on; else echo off; fi
    ;;
  dictate)
    if grep -q '"alt":"on"' "$CACHE/dictate" 2>/dev/null; then echo on; else echo off; fi
    ;;
  night)
    # night-dimmer state via the script's status output.
    if [ -f /tmp/night-dimmer-on ]; then echo on; else echo off; fi
    ;;
  warm)
    if [ -f /tmp/warm-cycle-on ]; then echo on; else echo off; fi
    ;;
  paper)
    if [ -f /tmp/shader-paper-on ]; then echo on; else echo off; fi
    ;;
  newspaper)
    if [ -f /tmp/shader-newspaper-on ]; then echo on; else echo off; fi
    ;;
  wifi)
    if nmcli -t -f WIFI radio 2>/dev/null | grep -q enabled; then echo on; else echo off; fi
    ;;
  focus)
    # Maps onto DND for now (no separate focus daemon in Wave 2).
    if grep -q '"alt":"active"' "$CACHE/notif-dnd" 2>/dev/null; then echo on; else echo off; fi
    ;;
  *)
    echo off
    ;;
esac
exit 0
