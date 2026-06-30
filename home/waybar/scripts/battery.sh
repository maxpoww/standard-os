#!/usr/bin/env bash
# battery.sh — Waybar battery pill emission.
#
# Reads /sys/class/power_supply/BAT0/{capacity,status} and emits an OPTIONS
# pill (opt-pill + opt-swap-pct + state class based on charge level/status).
# Tooltip is "<percent>% <status>".
#
# Replaces a 400-character inline exec in config.jsonc — same behavior,
# readable and editable in a real file. waybar invokes this via the
# custom/battery module's exec.
#
# KNOWN PRE-EXISTING BUG: charging/full/critical icons are empty strings
# (inherited verbatim from the old inline exec). Waybar hides any custom
# module whose text is empty, so the battery pill is invisible in those
# three states. Fixing the icons is queued as a separate decision (which
# Nerd Font / Material glyphs to use); preserving the buggy behavior here
# isolates the refactor.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

# Auto-detect the battery device. Some laptops expose BAT0, others BAT1+;
# the old inline exec hard-coded BAT0 and silently rendered "?% Unknown"
# on hardware that didn't match. Glob for the first BAT* and fall back to
# BAT0 so the script still emits something coherent if no battery exists.
BAT_DIR=""
for d in /sys/class/power_supply/BAT*; do
    [ -d "$d" ] && BAT_DIR="$d" && break
done
BAT_DIR="${BAT_DIR:-/sys/class/power_supply/BAT0}"

cap="$(cat "$BAT_DIR/capacity" 2>/dev/null || echo "?")"
st="$( cat "$BAT_DIR/status"   2>/dev/null || echo Unknown)"

# Icon — by status/level. (Three of these are intentionally empty to match
# the original inline exec; see KNOWN PRE-EXISTING BUG in the header.)
if   [ "$st" = "Charging" ];           then icon=""
elif [ "$st" = "Full" ];               then icon=""
elif [ "$cap" -le 15 ] 2>/dev/null;    then icon=""
else                                        icon="󰠠"
fi

# State class — by status/level.
if   [ "$st" = "Full" ];               then state="opt-yes opt-breathe"
elif [ "$cap" -lt 10 ] 2>/dev/null;    then state="opt-no opt-pulse"
elif [ "$cap" -lt 20 ] 2>/dev/null;    then state="opt-middle opt-glow"
elif [ "$st" = "Charging" ];           then state="opt-yes"
else                                        state=""
fi

m="$(pill_theme)"
pill_emit "$icon" "opt-pill $m $state opt-swap-pct" "$cap% $st"
