#!/usr/bin/env bash
# canvas-anchor.sh — fullscreen-over-waybar geometry for the
# StandardOS Dashboard. Reads hypr-context.json (written by
# hypr-context-daemon) to compute the focused monitor's logical
# dimensions.
#
# Used by scripts/canvas-open as the wrapper around `eww open dashboard`.

CANVAS_HYPR_CTX="${CANVAS_HYPR_CTX:-/tmp/waybar-cache/hypr-context.json}"

# Print "x y w h" in LOGICAL pixels for `eww open --pos / --size`.
#
# The canvas covers the FULL monitor (over the waybar). The defwindow
# uses anchor "center" so Hyprland does not apply the bar's exclusive-
# zone offset, but anchor-center positions the surface on the WORKAREA
# center (below the bar), not the monitor center. To still cover the
# bar at the top, the surface height must be monitor_h + bar_h, which
# equals (2 * monitor_h_logical - workarea_h). The extra bar_h ends up
# overflowing the monitor bottom — clipped by the compositor, invisible.
#
# Fallback (context missing): 1600x1025 — better than blank on first
# boot before hypr-context-daemon writes its first cache.
canvas_geometry_for_open() {
    local geom
    geom=$(jq -r '
      .monitor_focused as $f
      | (.monitors[] | select(.name == $f)) as $m
      | (($m.w / $m.scale) | floor) as $lw
      | (($m.h / $m.scale) | floor) as $lh
      | "0 0 \($lw) \(2 * $lh - .bg_window.h)"
    ' "$CANVAS_HYPR_CTX" 2>/dev/null)
    printf '%s' "${geom:-0 0 1600 1025}"
}
