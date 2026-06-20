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
    local ctx x w h
    [ -r "$CANVAS_HYPR_CTX" ] || { printf '0 0 1920 1055'; return; }
    ctx=$(cat "$CANVAS_HYPR_CTX" 2>/dev/null) || { printf '0 0 1920 1055'; return; }
    # Independently extract x / w / h from the bg_window object. Field
    # order inside the object is not contractually fixed, so each field
    # gets its own regex anchored to bg_window's opening brace.
    x=0; w=1920; h=1055
    if [[ $ctx =~ \"bg_window\"[[:space:]]*:[[:space:]]*\{[^}]*\"x\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]]; then x="${BASH_REMATCH[1]}"; fi
    if [[ $ctx =~ \"bg_window\"[[:space:]]*:[[:space:]]*\{[^}]*\"w\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then w="${BASH_REMATCH[1]}"; fi
    if [[ $ctx =~ \"bg_window\"[[:space:]]*:[[:space:]]*\{[^}]*\"h\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then h="${BASH_REMATCH[1]}"; fi
    printf '%d 0 %d %d' "$x" "$w" "$h"
}
