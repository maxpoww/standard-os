#!/usr/bin/env bash
# canvas-anchor.sh — workarea geometry for full-surface canvas windows
# (currently the StandardOS Dashboard). Reads `bg_window` from
# hypr-context.json — the same source of truth used by rofi-anchor.sh
# for popup positioning. hypr-context-daemon pre-computes bg_window as
# the focused monitor's workarea in LOGICAL pixels (below waybar's
# exclusive zone, full remaining width and height), so consumers do
# not re-derive scale / bar-height / multi-monitor math here.
#
# Used by:
#   scripts/canvas-open  — wraps `eww open dashboard`, passing the
#     computed --pos / --size so the canvas fills the workarea on any
#     monitor / resolution / scale.

CANVAS_HYPR_CTX="${CANVAS_HYPR_CTX:-/tmp/waybar-cache/hypr-context.json}"

# Print "x y w h" in LOGICAL pixels, ready to pass to `eww open --pos`
# and `--size`. The y is intentionally always 0 because Hyprland already
# offsets layer-shell windows by the reserved-zone size of the bar above
# them — passing the bg_window.y (typically 25) would double-offset the
# surface, leaving a visible gap (verified on 2026-06-17, same constant
# captured by rofi-anchor.sh's ROFI_BAR_HEIGHT=0 default).
#
# Width / height come from bg_window — the workarea size below the bar
# on the focused monitor, in logical pixels, so the canvas adapts to any
# resolution / scale / multi-monitor layout without per-machine tuning.
#
# Fallback (context missing): a reasonable 1080p layout. Better than
# blank — the canvas still opens on first boot before
# hypr-context-daemon has written its first cache.
canvas_geometry_for_open() {
    local ctx focused mon_w mon_h scale bg_h lw lh bar_h
    [ -r "$CANVAS_HYPR_CTX" ] || { printf '0 0 1600 1025'; return; }
    ctx=$(cat "$CANVAS_HYPR_CTX" 2>/dev/null) || { printf '0 0 1600 1025'; return; }
    # Canvas covers the FULL monitor (over the waybar). The defwindow
    # uses anchor "center" so Hyprland does not apply the bar's
    # exclusive-zone offset, but anchor-center centers the surface on
    # the WORKAREA (below the bar), not the monitor. To make a
    # workarea-centered surface still cover the bar at the top, the
    # surface must be (monitor_h + bar_h) tall — the extra bar_h ends
    # up overflowing the monitor bottom (clipped by compositor, fine).
    focused=""
    if [[ $ctx =~ \"monitor_focused\":\"([^\"]+)\" ]]; then focused="${BASH_REMATCH[1]}"; fi
    mon_w=1600; mon_h=1000; scale=1
    if [ -n "$focused" ]; then
        local pat="\"name\":\"$focused\"[^}]*\"w\":([0-9]+)[^}]*\"h\":([0-9]+)[^}]*\"scale\":([0-9.]+)"
        if [[ $ctx =~ $pat ]]; then
            mon_w="${BASH_REMATCH[1]}"
            mon_h="${BASH_REMATCH[2]}"
            scale="${BASH_REMATCH[3]}"
        fi
    fi
    bg_h=975
    if [[ $ctx =~ \"bg_window\"[[:space:]]*:[[:space:]]*\{[^}]*\"h\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then bg_h="${BASH_REMATCH[1]}"; fi
    lw=$(awk "BEGIN { printf \"%d\", $mon_w / $scale }")
    lh=$(awk "BEGIN { printf \"%d\", $mon_h / $scale }")
    bar_h=$((lh - bg_h))
    lh=$((lh + bar_h))
    printf '0 0 %d %d' "$lw" "$lh"
}
