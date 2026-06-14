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

# ===== Merged flush =====
# Single hyprctl --batch call fetches activewindow + monitors + workspaces +
# clients in ONE RTT (~10 ms instead of 4× ~15 ms sequential). The output
# is parsed by jq --slurp, which then emits TWO lines: the snapshot JSON
# (consumed by inotify subscribers — bg-daemon) and a TSV row carrying
# the pill-extraction fields (class, title, addr, ws_current, ws_list_csv)
# so the bash side does NO further jq parsing. Measured flush time:
# ~20 ms (was ~150 ms in the legacy 9-hyprctl / 22-jq design, then
# ~70 ms after the first merge). The gaps_in / gaps_out fields were
# dropped from the snapshot because no consumer reads them and
# `hyprctl getoption` returned the global config anyway (see hazard).
flush() {
    local raw ts snap pill_tsv
    raw=$(hyprctl --batch "j/activewindow;j/monitors;j/workspaces;j/clients" 2>/dev/null) || return 0
    ts=$(date +%s%3N)

    # Single jq: slurp 4 inputs → emit snapshot (line 1) + pill TSV (line 2).
    {
        IFS= read -r snap
        IFS= read -r pill_tsv
    } < <(
        jq -src --argjson ts "$ts" '
            .[0] as $active | .[1] as $monitors | .[2] as $workspaces | .[3] as $clients |
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
            },
            ([
              ($active.class // ""),
              ($active.title // ""),
              ($active.address // ""),
              (($wsid // 0) | tostring),
              ($workspaces | [.[].id | tostring] | join(","))
            ] | @tsv)
        ' <<<"$raw" 2>/dev/null
    )

    # ----- Snapshot dedup + atomic write -----
    if [[ -n $snap && $snap != "$LAST_SNAPSHOT" ]]; then
        printf '%s' "$snap" >"$SNAPSHOT.tmp" && mv -f "$SNAPSHOT.tmp" "$SNAPSHOT"
        LAST_SNAPSHOT=$snap
    fi

    # ----- Per-pill caches (bash-only, NO jq beyond the single slurp above) -----
    local class title addr ws_current ws_list_csv hw=""
    IFS=$'\t' read -r class title addr ws_current ws_list_csv <<<"$pill_tsv"
    ws_current=${ws_current:-0}
    local ws_list=",${ws_list_csv},"

    [[ -n $class && -n $addr && $addr != "0x" ]] && hw="1"

    # ws-current: opt-plus opt-swap face (canonical "+" hover).
    pill_write "ws-current" "$ws_current" "opt-pill dark opt-plus opt-swap"

    # ws-1..9: drawer siblings. Current and occupied both render the number on
    # a parent surface; .inactive on non-current occupied slots dims them;
    # empty slots collapse via .empty.
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
        if [[ $ws_list == *",$i,"* ]]; then
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
    pill_write "window" "${title:-}" "opt-pill dark opt-swap-switch"

    # has-window: raw "1" or "" (empty when no window) — gate for per-window pills.
    local hw_path="$PILL_CACHE_DIR/has-window"
    local hw_prev=""
    [[ -r $hw_path ]] && hw_prev=$(<"$hw_path")
    if [[ "$hw" != "$hw_prev" ]]; then
        printf '%s' "$hw" >"$hw_path.tmp" && mv -f "$hw_path.tmp" "$hw_path"
        pkill -RTMIN+10 waybar 2>/dev/null || true
    fi

    # win-* action pills (visible only when has-window).
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

    # win-move-1..9: valid targets (has-window AND exists AND not current).
    for i in 1 2 3 4 5 6 7 8 9; do
        if [[ $hw == "1" && $i -ne $ws_current ]] && [[ $ws_list == *",$i,"* ]]; then
            pill_write "win-move-$i" "$i" "opt-pill-child dark opt-yes"
        else
            pill_write "win-move-$i" "" "opt-pill-child empty"
        fi
    done
}

# ===== Event loop =====

# Interesting events fire the flush. `openlayer` / `closelayer` are included
# because Hyprland's `pseudo` dispatcher emits ONLY hyprpaper layer events
# (no movewindow / no activewindow / no changefloatingmode), so quiet
# windows would otherwise leave the snapshot stale on pseudo toggle and
# the painter would keep painting with the old non-pseudo geometry.
is_interesting() {
    case "${1%%>>*}" in
        activewindow|activewindowv2|openwindow|closewindow|movewindow|\
        windowtitlev2|fullscreen|workspace|workspacev2|focusedmon|\
        changefloatingmode|configreloaded|monitoradded|monitorremoved|\
        openlayer|closelayer)
            return 0
            ;;
    esac
    return 1
}

exec {SOCK_FD}< <(socat -u "UNIX-CONNECT:$HYPR_SOCK2" - 2>/dev/null)

# Initial emit at startup (cold cache).
flush

# Drain-flush loop (NO fixed debounce): block on the first event, drain
# anything else that buffered during the read, then flush ONCE. Workspace
# switches that fire 3 events in <5 ms naturally coalesce into one flush
# via the drain step. The legacy 16 ms read timeout was a fixed latency
# penalty on every transition; under drain-flush the worst case is one
# extra flush per burst (when the burst spans across our ~30 ms flush
# window) and pill_write / snapshot dedupe absorbs the cost.
while IFS= read -r -u "$SOCK_FD" line; do
    NEED_FLUSH=0
    is_interesting "$line" && NEED_FLUSH=1
    # `read -t 0` is a non-consuming PEEK in bash (returns 0 if input is
    # available but does NOT actually read), which leaves $extra unset and
    # trips `set -u`. Use a 1 ms timeout instead — real reads on every
    # available line, 1 ms penalty on the drain-exit iteration.
    while IFS= read -r -t 0.001 -u "$SOCK_FD" extra; do
        is_interesting "$extra" && NEED_FLUSH=1
    done
    (( NEED_FLUSH )) && flush
done
