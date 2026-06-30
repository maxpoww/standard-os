#!/usr/bin/env bash
# night-dimmer.sh — Waybar module for extra-dim levels below 2% hardware.
# Standalone pill in SYSTEM zone → opt-pill.
# Off (level 0 or hidden) → emits empty class so CSS collapses the pill.
# On (level >= 1) → opt-pushed (a toggle is engaged; the level differential
# is communicated by the icon, not by a state color).
#
# Routes through shader-stack.sh so the dim level stays composed with any
# active texture (paper / newspaper) rather than stomping the global
# decoration:screen_shader.
#
# Usage:
#   night-dimmer.sh exec   → emits OPTIONS-shaped JSON (or empty pill if !at floor)
#   night-dimmer.sh click  → cycles through dim levels

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

DEVICE="intel_backlight"
STATE_FILE="/tmp/night-dim-level"   # waybar UI state; level in {0,1,2,3}
STACK="$HOME/.config/waybar/scripts/shader-stack.sh"

ICONS=("󰃚" "󰃛" "󰃜" "󰃝")
TOOLTIPS=("Night Dimmer: Off" "Night Dimmer: Level 1 (50%)" "Night Dimmer: Level 2 (25%)" "Night Dimmer: Level 3 (10%)")
DIM_FRACTIONS=("" "0.5" "0.25" "0.1")

get_level() {
    cat "$STATE_FILE" 2>/dev/null || echo 0
}

is_at_floor() {
    local max_val cur_val pct
    max_val=$(brightnessctl -d "$DEVICE" max)
    cur_val=$(brightnessctl -d "$DEVICE" get)
    pct=$(( cur_val * 100 / max_val ))
    (( pct <= 2 ))
}

apply_level() {
    local level="$1"
    if (( level == 0 )); then
        "$STACK" clear dim
    else
        "$STACK" set dim "${DIM_FRACTIONS[$level]}"
    fi
    printf '%s' "$level" > "$STATE_FILE"
}

case "${1:-exec}" in
    exec)
        if ! is_at_floor; then
            # Safety net: tear down dim if backlight rose externally.
            level=$(get_level)
            (( level > 0 )) && apply_level 0
            # Not at 2% → collapsed pill. Emitting an empty-class pill
            # (rather than literally empty stdout) keeps waybar happy
            # and the .empty CSS handles the visual collapse.
            pill_emit "" "opt-pill empty"
            exit 0
        fi
        level=$(get_level)
        m="$(pill_theme)"
        state=""
        (( level > 0 )) && state="opt-pushed"
        classes="$(pill_class "opt-pill" "$m" "$state")"
        pill_emit "${ICONS[$level]}" "$classes" "${TOOLTIPS[$level]}"
        ;;
    click)
        level=$(get_level)
        next_level=$(( (level + 1) % 4 ))
        apply_level "$next_level"
        pkill -RTMIN+10 waybar 2>/dev/null || true
        ;;
    *)
        echo "Usage: night-dimmer.sh [exec|click]" >&2
        exit 1
        ;;
esac
