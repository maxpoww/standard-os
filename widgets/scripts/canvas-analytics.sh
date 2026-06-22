#!/usr/bin/env bash
# canvas-analytics.sh -- single dispatcher for User-section analytics
# tiles. Each metric returns one short string ready for an
# analytics-tile :value. Keep ASCII-only output -- the tile renders
# inside an eww label and avoids the grass-rs @charset hazard at the
# scss layer, but stays portable to other surfaces too.
#
# Usage: canvas-analytics.sh <metric>
#   session     time since current session login ("Xh Ym" / "Xd Yh")
#   uptime      time since system boot
#   active-app  focused window's class (clipped to 16 chars)
#   win-count   total open windows across all workspaces
#   ws-count    total workspaces with at least one window

set -uo pipefail

fmt_duration() {
    local e=$1
    [[ $e -lt 0 ]] && { echo "--"; return; }
    local d=$((e / 86400))
    local h=$(((e % 86400) / 3600))
    local m=$(((e % 3600) / 60))
    if ((d > 0)); then
        printf '%dd %dh' "$d" "$h"
    else
        printf '%dh %dm' "$h" "$m"
    fi
}

case "${1:-}" in
session)
    sid="${XDG_SESSION_ID:-}"
    if [[ -z $sid ]]; then
        sid=$(loginctl --no-legend 2>/dev/null | awk -v u="$USER" '$3 == u {print $1; exit}')
    fi
    [[ -z $sid ]] && { echo "--"; exit 0; }
    start=$(loginctl show-session "$sid" -p Timestamp --value 2>/dev/null)
    [[ -z $start ]] && { echo "--"; exit 0; }
    start_epoch=$(date -d "$start" +%s 2>/dev/null) || { echo "--"; exit 0; }
    fmt_duration $(($(date +%s) - start_epoch))
    ;;
uptime)
    read -r up _ </proc/uptime
    fmt_duration "${up%.*}"
    ;;
active-app)
    cls=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // "--"' 2>/dev/null)
    [[ -z $cls || $cls == "null" ]] && cls="--"
    printf '%.16s' "$cls"
    ;;
win-count)
    hyprctl clients -j 2>/dev/null | jq 'length' 2>/dev/null || echo 0
    ;;
ws-count)
    hyprctl workspaces -j 2>/dev/null | jq 'length' 2>/dev/null || echo 0
    ;;
*)
    echo "--"
    ;;
esac
