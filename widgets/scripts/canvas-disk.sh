#!/usr/bin/env bash
# canvas-disk.sh — emit integer percent used for a mount point.
# Arg: mount point (e.g. "/" or "/home"). Default "/". Silent on error → "0".

set -uo pipefail
mount="${1:-/}"
pct=$(df --output=pcent "$mount" 2>/dev/null | tail -1 | tr -d ' %') || pct=0
[ -z "$pct" ] && pct=0
echo "$pct"
exit 0
