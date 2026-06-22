#!/usr/bin/env bash
# canvas-tops.sh -- emit JSON for top-N bar-fill list cards.
#
# Usage: canvas-tops.sh apps|ws|notifs
# Stdout: {"items":[{"name":"...","value":N}, ...],"max":N}
# (Items pre-sorted descending; max = first item's value so bar widths
# scale correctly. Empty data returns {"items":[],"max":1}.)

set -uo pipefail

emit_empty() {
    echo '{"items":[],"max":1}'
}

case "${1:-}" in
apps)
    if ! command -v hyprctl >/dev/null 2>&1; then
        emit_empty
        exit 0
    fi
    hyprctl clients -j 2>/dev/null |
        jq -c '
        [ .[] | select(.class != null and .class != "") ]
        | group_by(.class)
        | map({name: (.[0].class // "?"), value: length})
        | sort_by(-.value)
        | .[0:6]
        | {items: ., max: ((.[0].value // 1))}' 2>/dev/null || emit_empty
    ;;
ws)
    if ! command -v hyprctl >/dev/null 2>&1; then
        emit_empty
        exit 0
    fi
    hyprctl clients -j 2>/dev/null |
        jq -c '
        group_by(.workspace.id)
        | map({name: ("WS " + (.[0].workspace.id | tostring)), value: length})
        | sort_by(-.value)
        | .[0:6]
        | {items: ., max: ((.[0].value // 1))}' 2>/dev/null || emit_empty
    ;;
notifs)
    if [[ ! -r /tmp/waybar-cache/notif-history.json ]]; then
        emit_empty
        exit 0
    fi
    jq -c '
        (.entries // [])
        | group_by(.app // "?")
        | map({name: (.[0].app // "?"), value: length})
        | sort_by(-.value)
        | .[0:6]
        | {items: ., max: ((.[0].value // 1))}' /tmp/waybar-cache/notif-history.json 2>/dev/null || emit_empty
    ;;
*)
    emit_empty
    ;;
esac
