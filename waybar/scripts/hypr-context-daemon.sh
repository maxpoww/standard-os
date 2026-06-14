#!/usr/bin/env bash
# hypr-context-daemon — unified Hyprland-state publisher.
#
# Subscribes ONCE to Hyprland's socket2 and emits:
#   - per-pill caches in /tmp/waybar-cache/{ws-*, window, has-window, win-*}
#     for waybar (signal RTMIN+10)
#   - /tmp/waybar-cache/hypr-context.json for inotify consumers (bg, future)
#
# Replaces workspace-daemon.sh (polling) and hypr-activities (socket-broadcast).
# See docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
set -euo pipefail

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

PILL_CACHE_DIR=${PILL_CACHE_DIR:-/tmp/waybar-cache}
mkdir -p "$PILL_CACHE_DIR"

SNAPSHOT="$PILL_CACHE_DIR/hypr-context.json"
LAST_SNAPSHOT=""

HYPR_SIG=${HYPRLAND_INSTANCE_SIGNATURE:?HYPRLAND_INSTANCE_SIGNATURE not set}
HYPR_SOCK2="${XDG_RUNTIME_DIR}/hypr/${HYPR_SIG}/.socket2.sock"

# Effective-gap parser (handles both old int form and new per-side string form).
PARSE_GAP='
    if has("int") and (.int|type)=="number" then .int
    elif has("custom") and (.custom|type)=="string" and .custom != "" then
        ((.custom | split(" ") | map(tonumber? // 0) | max) // 0)
    else 0 end
'

# Build snapshot — single jq invocation per emit.
build_snapshot() {
    local active monitors workspaces clients gaps_in gaps_out ts
    active=$(hyprctl activewindow -j 2>/dev/null) || return 1
    monitors=$(hyprctl monitors -j 2>/dev/null) || return 1
    workspaces=$(hyprctl workspaces -j 2>/dev/null) || return 1
    clients=$(hyprctl clients -j 2>/dev/null) || return 1
    gaps_in=$(hyprctl getoption general:gaps_in -j 2>/dev/null | jq -r "$PARSE_GAP" 2>/dev/null || printf 0)
    gaps_out=$(hyprctl getoption general:gaps_out -j 2>/dev/null | jq -r "$PARSE_GAP" 2>/dev/null || printf 0)
    ts=$(date +%s%3N)

    jq -nc \
        --argjson ts "$ts" \
        --argjson monitors "$monitors" \
        --argjson clients "$clients" \
        --argjson active "$active" \
        --argjson gaps_in "$gaps_in" \
        --argjson gaps_out "$gaps_out" \
        '
        ($monitors | map(select(.focused == true)) | .[0] // null) as $mf |
        ($mf.name // null) as $mfn |
        ($mf.activeWorkspace.id // null) as $wsid |
        ($clients | map(select(.workspace.id == $wsid))) as $wsc |
        ($wsc | map(select(.fullscreen > 0)) | .[0] // null) as $fs |
        ($wsc | map(select(.floating == false and .pseudo == false))) as $tiles |
        (if $fs != null then $fs
         elif ($tiles | length) == 1 then $tiles[0]
         else null end) as $bgw |
        {
          ts: $ts,
          monitor_focused: $mfn,
          monitors: ($monitors | map({
            name: .name, x: .x, y: .y, w: .width, h: .height,
            scale: .scale, focused_ws: .activeWorkspace.id
          })),
          workspace: {
            id: $wsid,
            monitor: $mfn,
            window_count: ($wsc | length),
            tiled_count: ($wsc | map(select(.floating == false)) | length),
            floating_count: ($wsc | map(select(.floating == true)) | length),
            gaps_in: $gaps_in,
            gaps_out: $gaps_out,
            has_fullscreen: (($wsc | map(select(.fullscreen > 0)) | length) > 0)
          },
          bg_window: (
            if $bgw == null then null
            else {
              address: $bgw.address,
              x: ($bgw.at[0] // 0),
              y: ($bgw.at[1] // 0),
              w: ($bgw.size[0] // 0),
              h: ($bgw.size[1] // 0)
            }
            end
          ),
          focused: (
            if ($active | type) == "object" and ($active | has("address")) then {
              address: $active.address,
              class: $active.class,
              title: $active.title,
              x: ($active.at[0] // 0),
              y: ($active.at[1] // 0),
              w: ($active.size[0] // 0),
              h: ($active.size[1] // 0),
              fullscreen: ($active.fullscreen // 0),
              floating: ($active.floating // false),
              pseudo: ($active.pseudo // false),
              workspace: ($active.workspace.id // null),
              monitor: ($active.monitor // null)
            } else null end
          )
        }'
}

emit_snapshot() {
    local snap
    snap=$(build_snapshot) || return 0
    [[ $snap == "$LAST_SNAPSHOT" ]] && return 0
    printf '%s' "$snap" >"$SNAPSHOT.tmp" && mv -f "$SNAPSHOT.tmp" "$SNAPSHOT"
    LAST_SNAPSHOT=$snap
    # No signal — snapshot consumers use inotify on $PILL_CACHE_DIR.
}

# ===== Per-pill cache writers (same content as the old workspace-daemon) =====

emit_pills() {
    local active workspaces ws_current title
    active=$(hyprctl activewindow -j 2>/dev/null) || return 0
    workspaces=$(hyprctl workspaces -j 2>/dev/null) || return 0
    ws_current=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .activeWorkspace.id // 0' 2>/dev/null)
    ws_current=${ws_current:-0}

    # has-window: "1" iff activewindow returned a populated object (with non-0x address)
    local hw="" win_class win_addr
    win_class=$(jq -r '.class   // empty' <<<"$active" 2>/dev/null)
    win_addr=$(jq  -r '.address // empty' <<<"$active" 2>/dev/null)
    if [[ -n $win_class && -n $win_addr && $win_addr != "0x" ]]; then
        hw="1"
    fi

    # ws-current: number of focused WS, opt-plus opt-swap face (canonical "+" hover)
    pill_write "ws-current" "$ws_current" "opt-pill dark opt-plus opt-swap"

    # ws-1..9: drawer siblings. Current and occupied both render the number on
    # a parent surface; the only difference is the .inactive class (opacity) on
    # non-current occupied slots so the eye is drawn to unvisited ones. Empty
    # slots collapse via .empty.
    local i exists
    for i in 1 2 3 4 5 6 7 8 9; do
        exists=$(jq --argjson n "$i" '[.[] | select(.id == $n)] | length' <<<"$workspaces")
        if [[ $exists -gt 0 ]]; then
            if [[ $i -eq $ws_current ]]; then
                pill_write "ws-$i" "$i" "opt-pill dark"
            else
                pill_write "ws-$i" "$i" "opt-pill dark inactive"
            fi
        else
            pill_write "ws-$i" "" "opt-pill empty"
        fi
    done

    # window pill: focused window TITLE (center value pill, opt-swap-switch face).
    title=$(jq -r '.title // empty' <<<"$active" 2>/dev/null)
    pill_write "window" "${title:-}" "opt-pill dark opt-swap-switch"

    # has-window: raw "1" or "" (empty string when no window) — gate for per-window pills.
    local hw_path="$PILL_CACHE_DIR/has-window"
    local hw_prev=""
    [[ -r $hw_path ]] && hw_prev=$(cat "$hw_path" 2>/dev/null)
    if [[ "$hw" != "$hw_prev" ]]; then
        printf '%s' "$hw" >"$hw_path.tmp" && mv -f "$hw_path.tmp" "$hw_path"
        pkill -RTMIN+10 waybar 2>/dev/null || true
    fi

    # win-* action pills (visible only when has-window)
    if [[ $hw == "1" ]]; then
        pill_write "win-close"        "󰅖" "opt-pill-child dark opt-no"
        pill_write "win-minimize"     "󰍶" "opt-pill-child dark opt-middle"
        pill_write "win-swap-right"   ""  "opt-pill-child dark"
        pill_write "win-move-trigger" "󰯍" "opt-pill-child dark opt-yes"
        pill_write "win-move-new"     ""  "opt-pill-child dark opt-plus"
    else
        local n
        for n in close minimize swap-right move-trigger move-new; do
            pill_write "win-$n" "" "opt-pill-child empty"
        done
    fi

    # win-move-1..9: valid targets (has-window AND exists AND not current)
    for i in 1 2 3 4 5 6 7 8 9; do
        exists=$(jq --argjson n "$i" '[.[] | select(.id == $n)] | length' <<<"$workspaces")
        if [[ $hw == "1" && $i -ne $ws_current && $exists -gt 0 ]]; then
            pill_write "win-move-$i" "$i" "opt-pill-child dark opt-yes"
        else
            pill_write "win-move-$i" "" "opt-pill-child empty"
        fi
    done
}

# ===== Event loop =====

DEBOUNCE_S=0.016
PENDING=0

flush() {
    emit_pills
    emit_snapshot
    PENDING=0
}

# Subscribe to socket2 in a coprocess so the read in the main loop has a timeout.
exec {SOCK_FD}< <(socat -u "UNIX-CONNECT:$HYPR_SOCK2" - 2>/dev/null)

# Initial emit at startup (cold cache).
flush

while IFS= read -r -t "$DEBOUNCE_S" -u "$SOCK_FD" line || true; do
    if [[ -n ${line:-} ]]; then
        case "${line%%>>*}" in
            activewindow|activewindowv2|openwindow|closewindow|movewindow|\
            windowtitlev2|fullscreen|workspace|workspacev2|focusedmon|\
            changefloatingmode|configreloaded|monitoradded|monitorremoved)
                PENDING=1
                ;;
        esac
        line=""
        continue
    fi
    # Read timed out (DEBOUNCE_S of silence). If events pending → flush.
    if (( PENDING )); then
        flush
    fi
done
