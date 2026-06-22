#!/usr/bin/env bash
# canvas-power.sh -- power-related data for the Power section.
#
# Usage: canvas-power.sh <metric>
#   state      -- AC | Battery | Unknown
#   bat-state  -- Charging | Discharging | Full | Unknown

set -uo pipefail

case "${1:-}" in
state)
    online=0
    for ac in /sys/class/power_supply/A{C,DP,CAD}*/online; do
        [[ -r $ac ]] || continue
        v=$(<"$ac")
        [[ "$v" == "1" ]] && online=1
    done
    if ((online == 1)); then
        echo "AC"
    elif compgen -G '/sys/class/power_supply/BAT*' >/dev/null 2>&1; then
        echo "Battery"
    else
        echo "Unknown"
    fi
    ;;
bat-state)
    for f in /sys/class/power_supply/BAT*/status; do
        [[ -r $f ]] || continue
        s=$(<"$f")
        echo "$s"
        exit 0
    done
    echo "Unknown"
    ;;
*)
    echo "--"
    ;;
esac
