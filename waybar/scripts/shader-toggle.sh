#!/usr/bin/env bash
# shader-toggle.sh — Toggle a texture shader (paper / newspaper) on/off.
# Child pill inside screen-type-group drawer → opt-pill-child.
# Off → baseline child. On → opt-pushed (toggle engaged; the textbook
# opt-pushed case — see waybar/CLAUDE.md "Pushed (toggle ON)").
#
# Routes through shader-stack.sh so the texture stays composed with any
# active dim level rather than stomping the global decoration:screen_shader.
#
# Usage:
#   shader-toggle.sh exec <id>    → emits OPTIONS-shaped JSON for waybar
#   shader-toggle.sh click <id>   → toggle shader

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

STATE_FILE="/tmp/shader-active"   # waybar UI state — read by `exec` branch
STACK="$HOME/.config/waybar/scripts/shader-stack.sh"

declare -A SHADER_ICON SHADER_LABEL
SHADER_ICON["paper"]="󱉟"
SHADER_ICON["newspaper"]="󰦩"
SHADER_LABEL["paper"]="Paper"
SHADER_LABEL["newspaper"]="Newspaper"

get_active() {
    cat "$STATE_FILE" 2>/dev/null || true
}

case "${1:-exec}" in
    exec)
        id="${2:?missing shader id}"
        active=$(get_active)
        m="$(pill_theme)"
        icon="${SHADER_ICON[$id]}"
        label="${SHADER_LABEL[$id]}"
        state=""
        [[ "$active" == "$id" ]] && state="opt-pushed"
        classes="$(pill_class "opt-pill-child" "$m" "$state")"
        if [[ "$active" == "$id" ]]; then
            pill_emit "$icon" "$classes" "$label: ON"
        else
            pill_emit "$icon" "$classes" "$label: OFF"
        fi
        ;;
    click)
        id="${2:?missing shader id}"
        active=$(get_active)
        if [[ "$active" == "$id" ]]; then
            "$STACK" clear texture
            printf '' > "$STATE_FILE"
        else
            "$STACK" set texture "$id"
            printf '%s' "$id" > "$STATE_FILE"
        fi
        pkill -RTMIN+10 waybar 2>/dev/null || true
        ;;
    *)
        echo "Usage: shader-toggle.sh [exec|click] <shader_id>" >&2
        exit 1
        ;;
esac
