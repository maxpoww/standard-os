#!/usr/bin/env bash
# warm-cycle.sh — Cycles through color temperature levels via hyprsunset.
# Trigger of the screen-type-group drawer → parent pill (opt-pill).
# Off → baseline parent. On (any warmth > 0) → opt-yes.
#
# Usage:
#   warm-cycle.sh exec   → emits OPTIONS-shaped JSON for waybar
#   warm-cycle.sh click  → cycles to next level

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

STATE_FILE="/tmp/warm-cycle-level"

# Levels: off, warm, warmer, very warm, night
TEMPS=(6500 5500 4500 3500 2700)
LABELS=("Off" "Warm (5500K)" "Warmer (4500K)" "Very Warm (3500K)" "Night (2700K)")
ICONS=("󰃞" "󰃟" "󰃟" "󰃠" "󰃠")

get_level() {
    local l
    l=$(cat "$STATE_FILE" 2>/dev/null) || l=0
    (( l >= 0 && l < ${#TEMPS[@]} )) || l=0
    echo "$l"
}

apply_level() {
    local level="$1"
    local temp="${TEMPS[$level]}"
    pkill -x hyprsunset 2>/dev/null || true
    sleep 0.1
    if (( level > 0 )); then
        hyprsunset -t "$temp" &
        disown $! 2>/dev/null || true
    fi
    printf '%s' "$level" > "$STATE_FILE"
}

case "${1:-exec}" in
    exec)
        level=$(get_level)
        m="$(pill_theme)"
        state=""
        (( level > 0 )) && state="opt-yes"
        classes="$(pill_class "opt-pill" "$m" "$state")"
        pill_emit "${ICONS[$level]}" "$classes" "Warmth: ${LABELS[$level]}"
        ;;
    click)
        level=$(get_level)
        next=$(( (level + 1) % ${#TEMPS[@]} ))
        apply_level "$next"
        pkill -RTMIN+10 waybar 2>/dev/null || true
        ;;
    *)
        echo "Usage: warm-cycle.sh [exec|click]" >&2
        exit 1
        ;;
esac
