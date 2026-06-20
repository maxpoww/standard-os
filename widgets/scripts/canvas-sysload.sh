#!/usr/bin/env bash
# canvas-sysload.sh — compact 1/5/15-min load average string for the menubar.
# Emits e.g. "LOAD 0.42 0.38 0.31". Silent on read error.

set -uo pipefail

read -r one five fifteen _rest < /proc/loadavg 2>/dev/null || exit 0
printf 'LOAD %s %s %s\n' "$one" "$five" "$fifteen"
exit 0
