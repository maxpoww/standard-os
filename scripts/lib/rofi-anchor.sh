#!/usr/bin/env bash
# rofi-anchor.sh — anchor rofi popups under their trigger pill and pick
# the right light/dark theme. Sourced by launcher scripts (notif-menu,
# apps launcher wrapper, reboot prompt, etc.). The launcher invokes
# rofi with the result as extra args:
#
#   source /etc/nixos/home/scripts/lib/rofi-anchor.sh
#   ANCHOR=$(rofi_anchor_for notif-bell)
#   THEME=$(rofi_theme_for_mode)
#   rofi -theme "$THEME" $ANCHOR -dmenu ... < rows
#
# All paths are configurable via env so the test harness can sandbox.

ROFI_THEME_DIR="${ROFI_THEME_DIR:-/etc/nixos/home/rofi}"
ROFI_GLASS_FILE="${ROFI_GLASS_FILE:-/tmp/glass-mode}"
ROFI_GEOM_DIR="${ROFI_GEOM_DIR:-/tmp/waybar-cache/pill-geom}"
ROFI_HYPR_CTX="${ROFI_HYPR_CTX:-/tmp/waybar-cache/hypr-context.json}"
ROFI_BAR_HEIGHT="${ROFI_BAR_HEIGHT:-25}"     # logical px, matches monitor reserved
ROFI_GAP_PX="${ROFI_GAP_PX:-4}"               # gap between bar bottom and rofi top
ROFI_DEFAULT_WIDTH="${ROFI_DEFAULT_WIDTH:-320}"  # default window width in logical px
                                                  # MUST match `window { width: ... }` in rofi/options-base.rasi
ROFI_EDGE_MARGIN="${ROFI_EDGE_MARGIN:-8}"     # minimum gap from monitor edge

# Cursor source override for tests. When set, _rofi_cursor_xy reads the
# JSON from this file instead of running hyprctl. Production never sets it.
ROFI_CURSORPOS_FILE="${ROFI_CURSORPOS_FILE:-}"

# Pick the right theme file based on /tmp/glass-mode. Default "dark"
# when missing/unreadable (matches pill_theme's defensive default).
rofi_theme_for_mode() {
    local mode=""
    [ -r "$ROFI_GLASS_FILE" ] && mode=$(cat "$ROFI_GLASS_FILE" 2>/dev/null)
    case "$mode" in
        light) printf '%s/options-light.rasi' "$ROFI_THEME_DIR" ;;
        *)     printf '%s/options-dark.rasi'  "$ROFI_THEME_DIR" ;;
    esac
}

# SYSTEM zone layout — leaf pill names in render order (left-to-right
# as the eye scans, which matches waybar's modules-right list with
# groups expanded). Source-of-truth: waybar/config.jsonc:55-72.
# Maintenance: any time modules-right changes, update this list.
#
# This array is only consumed by rofi_anchor_for (the keyboard-trigger
# fallback path). Click-triggered popups use rofi_anchor_at_cursor and
# bypass the zone walker entirely — that path is monitor-/zone-/layout-
# agnostic, so adding pills to modules-right does NOT require touching
# this array for the click-triggered case.
ROFI_ZONE_SYSTEM=(
    tray
    notif-widepill notif-dnd
    notif-bell notif-dismiss notif-action-1 notif-action-2 notif-action-3
    # group/group-2 children — fill as needed
    # group/group-power children — fill as needed
    update-pending
    clock battery night-dimmer
    # group/screen-type-group children — fill as needed
    dictate
)

# Width constants for non-pill modules (no pill-geom entry).
# Tray width is roughly icon_count * icon_size; 60 is a reasonable
# estimate for the typical 2-4 tray icons on this system.
ROFI_TRAY_WIDTH="${ROFI_TRAY_WIDTH:-60}"

# Extract a single integer field from a JSON object using a regex.
# Returns 0 if not found. Avoids forking jq for simple reads.
_rofi_json_int() {
    local json="$1" key="$2"
    if [[ $json =~ \"$key\":[[:space:]]*([0-9]+) ]]; then
        printf '%d' "${BASH_REMATCH[1]}"
    else
        printf '0'
    fi
}

# Extract a single string field from a JSON object using a regex.
_rofi_json_str() {
    local json="$1" key="$2"
    if [[ $json =~ \"$key\":[[:space:]]*\"([^\"]+)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Parse "scale":N.NN out of a monitor blob and return integer percent
# (200 / 150 / 100). Bash-builtin only, no fork to bc/awk on every popup
# launch (hot path).
_rofi_scale_pct() {
    local blob="$1" scale_str sx100 int_part dec_part
    if [[ $blob =~ \"scale\":[[:space:]]*([0-9]+)(\.[0-9]+)? ]]; then
        scale_str="${BASH_REMATCH[1]}${BASH_REMATCH[2]:-.00}"
        int_part="${scale_str%%.*}"
        dec_part="${scale_str#*.}"
        [ "$int_part" = "$scale_str" ] && dec_part="00"
        case ${#dec_part} in
            0) dec_part="00" ;;
            1) dec_part="${dec_part}0" ;;
            2) : ;;
            *) dec_part="${dec_part:0:2}" ;;
        esac
        sx100=$(( 10#$int_part * 100 + 10#$dec_part ))
        [ "$sx100" -lt 1 ] && sx100=100
        printf '%d' "$sx100"
    else
        printf '100'
    fi
}

# Convert one monitor blob to "logical_x logical_w".
# hyprctl conventions (verified 2026-06-17):
#   monitor.x      — LOGICAL position. Pass-through.
#   monitor.width  — RAW pixels. Divide by scale → logical.
#   monitor.scale  — float.
# Earlier patch (60839df) divided x by scale too. That was harmless on
# the single-monitor x=0 case but wrong for any monitor at non-zero x.
_rofi_monitor_logical_xy() {
    local blob="$1" mx mw sx100
    mx=$(_rofi_json_int "$blob" x)
    mw=$(_rofi_json_int "$blob" w)
    sx100=$(_rofi_scale_pct "$blob")
    mw=$(( mw * 100 / sx100 ))
    printf '%d %d' "$mx" "$mw"
}

# Resolve focused monitor's (x, w) in LOGICAL px from hypr-context.
# Used by the keyboard-trigger fallback (rofi_anchor_for) since there's
# no cursor signal in that path. Falls back to (0, 1920) when context is
# missing — better than blank.
_rofi_focused_monitor() {
    local ctx focused mon_blob
    [ -r "$ROFI_HYPR_CTX" ] || { printf '0 1920'; return; }
    ctx=$(cat "$ROFI_HYPR_CTX" 2>/dev/null) || { printf '0 1920'; return; }
    focused=$(_rofi_json_str "$ctx" monitor_focused)
    if [[ $ctx =~ \{\"name\":\"${focused}\"[^}]*\} ]]; then
        mon_blob="${BASH_REMATCH[0]}"
    else
        printf '0 1920'; return
    fi
    _rofi_monitor_logical_xy "$mon_blob"
}

# Find the monitor whose LOGICAL bounds contain target_x. Used by the
# cursor-anchor path so multi-monitor clamping uses the monitor where
# the click happened — not the focused-window monitor (those can differ
# when focus is on Mon1 and the user clicks a pill on Mon2's bar).
# Falls back to focused monitor when no match (target_x outside any
# monitor — shouldn't happen for a real cursor pos but defensive).
_rofi_monitor_containing() {
    local target_x="$1"
    local ctx mon_blobs blob mx mw
    [ -r "$ROFI_HYPR_CTX" ] || { _rofi_focused_monitor; return; }
    ctx=$(cat "$ROFI_HYPR_CTX" 2>/dev/null) || { _rofi_focused_monitor; return; }
    # Walk monitor objects via repeated regex match — the hypr-context
    # writer emits each monitor as a self-contained {...} object with no
    # nested braces, so a non-greedy match on a single line is reliable
    # enough without dragging in jq.
    local rest="$ctx"
    while [[ $rest =~ (\{\"name\":\"[^\"]+\"[^}]*\}) ]]; do
        blob="${BASH_REMATCH[1]}"
        read -r mx mw <<<"$(_rofi_monitor_logical_xy "$blob")"
        if [ "$target_x" -ge "$mx" ] && [ "$target_x" -lt "$(( mx + mw ))" ]; then
            printf '%d %d' "$mx" "$mw"
            return
        fi
        # Advance past this match; bash regex doesn't support /g.
        rest="${rest#*"$blob"}"
    done
    _rofi_focused_monitor
}

# Clamp a candidate x_offset so the popup (top-left at x_offset, width w)
# stays within [mon_x + margin, mon_x + mon_w - w - margin]. Returns the
# clamped value. Universal correctness guarantee for any monitor — even
# if the anchor source is wrong, the popup never lands off-screen.
_rofi_clamp_x_offset() {
    local x_offset="$1" mon_x="$2" mon_w="$3" popup_w="$4" margin="$5"
    local min_x=$(( mon_x + margin ))
    local max_x=$(( mon_x + mon_w - popup_w - margin ))
    # Pathological case (popup wider than monitor): pin to left edge so
    # the user sees the start of the menu rather than its tail.
    [ "$max_x" -lt "$min_x" ] && max_x="$min_x"
    [ "$x_offset" -lt "$min_x" ] && x_offset="$min_x"
    [ "$x_offset" -gt "$max_x" ] && x_offset="$max_x"
    printf '%d' "$x_offset"
}

# Read cursor position in LOGICAL pixels. Hyprland already reports
# cursorpos in logical coords (verified 2026-06-17 via movecursor probe),
# so no scale conversion is needed here.
#
# Test sandbox: ROFI_CURSORPOS_FILE points at a JSON file with the same
# shape as `hyprctl cursorpos -j` ({"x":N,"y":N}). Production never sets
# it, so the hyprctl path runs and emits live coords.
_rofi_cursor_xy() {
    local src
    if [ -n "$ROFI_CURSORPOS_FILE" ] && [ -r "$ROFI_CURSORPOS_FILE" ]; then
        src=$(cat "$ROFI_CURSORPOS_FILE" 2>/dev/null) || src=""
    else
        src=$(hyprctl cursorpos -j 2>/dev/null) || src=""
    fi
    local cx=0 cy=0
    if [[ $src =~ \"x\":[[:space:]]*([0-9]+) ]]; then cx="${BASH_REMATCH[1]}"; fi
    if [[ $src =~ \"y\":[[:space:]]*([0-9]+) ]]; then cy="${BASH_REMATCH[1]}"; fi
    printf '%d %d' "$cx" "$cy"
}

# Width of a single module: pill-geom entry if available, else a
# hardcoded constant for known non-pill modules, else 0.
_rofi_module_width() {
    local name="$1" f="$ROFI_GEOM_DIR/$1.json" content
    case "$name" in
        tray) printf '%d' "$ROFI_TRAY_WIDTH"; return ;;
    esac
    [ -r "$f" ] || { printf '0'; return; }
    content=$(cat "$f" 2>/dev/null) || { printf '0'; return; }
    _rofi_json_int "$content" w
}

# Compute the target pill's center X by walking the SYSTEM zone array
# left-to-right, accumulating widths. The zone's left edge is anchored
# to the monitor's right edge minus the zone's total width.
#
# ROFI_ZONE_SYSTEM_OVERRIDE (space-separated list) replaces the array
# for testing — production code never sets it.
_rofi_pill_center_x() {
    local target="$1" mon_x="$2" mon_w="$3"
    local -a zone
    if [ -n "${ROFI_ZONE_SYSTEM_OVERRIDE:-}" ]; then
        # shellcheck disable=SC2206
        zone=( ${ROFI_ZONE_SYSTEM_OVERRIDE} )
    else
        zone=( "${ROFI_ZONE_SYSTEM[@]}" )
    fi
    local i name w total=0 cum_before=0 target_w=0 found=0
    for name in "${zone[@]}"; do
        w=$(_rofi_module_width "$name")
        if [ "$name" = "$target" ]; then
            target_w=$w
            cum_before=$total
            found=1
        fi
        total=$(( total + w ))
    done
    [ "$found" = 0 ] && return 1
    local zone_left=$(( mon_x + mon_w - total ))
    printf '%d' $(( zone_left + cum_before + target_w / 2 ))
}

# Print a rofi -theme-str fragment centered on a given LOGICAL x.
# Clamped to the MONITOR THAT CONTAINS cx (not necessarily the focused
# one — these differ on multi-monitor when focus is on Mon1 and the
# trigger pill being clicked is on Mon2's bar). The popup never overflows
# the screen, on any monitor / resolution / scale.
rofi_anchor_at() {
    local cx="$1"
    local mon mon_x mon_w x_offset y_offset
    mon=$(_rofi_monitor_containing "$cx"); read -r mon_x mon_w <<<"$mon"
    x_offset=$(( cx - ROFI_DEFAULT_WIDTH / 2 ))
    x_offset=$(_rofi_clamp_x_offset "$x_offset" "$mon_x" "$mon_w" \
        "$ROFI_DEFAULT_WIDTH" "$ROFI_EDGE_MARGIN")
    y_offset=$(( ROFI_BAR_HEIGHT + ROFI_GAP_PX ))
    printf -- '-theme-str window{location:northwest;anchor:north;x-offset:%dpx;y-offset:%dpx;}' \
        "$x_offset" "$y_offset"
}

# Anchor the popup centered on the compositor's current cursor position.
# This is the recommended path for any click-triggered popup — at the
# moment the click handler runs, the cursor IS on the trigger pill, so
# centering on cursor.x places the popup under the pill with no need for
# a pill-geometry registry, zone layout array, or width estimator. Works
# identically across monitors, resolutions, and scales because Hyprland
# reports the cursor in logical pixels.
rofi_anchor_at_cursor() {
    local pos cx cy
    pos=$(_rofi_cursor_xy); read -r cx cy <<<"$pos"
    rofi_anchor_at "$cx"
}

# Zone-walker fallback for keyboard-triggered popups (no cursor on the
# trigger pill). Estimates the pill's center from the SYSTEM zone array;
# clamped to the focused monitor so even a wrong estimate stays on-screen.
rofi_anchor_for() {
    local pill="$1"
    local mon mon_x mon_w cx
    mon=$(_rofi_focused_monitor); read -r mon_x mon_w <<<"$mon"
    if cx=$(_rofi_pill_center_x "$pill" "$mon_x" "$mon_w"); then
        :  # cx set
    else
        cx=$(( mon_x + mon_w - ROFI_DEFAULT_WIDTH ))
    fi
    rofi_anchor_at "$cx"
}

# rofi_launch <pill-id> [extra-rofi-args...] — sources theme + anchor
# and invokes rofi -dmenu. Stdin is piped to rofi (rows). Stdout is
# rofi's selected entry (whatever the caller asks for via -format).
# Callers should pass -p/-format/-no-custom/etc. themselves; this
# wrapper only injects -theme and the anchor -theme-str.
#
# Anchor source: cursor position by default (works for any click-
# triggered popup). Callers that need the zone-walker fallback (keyboard
# triggers, scripted launches with no cursor context) should call
# rofi_anchor_for directly and assemble the rofi invocation themselves.
rofi_launch() {
    local pill="$1"; shift
    local theme anchor
    theme=$(rofi_theme_for_mode)
    anchor=$(rofi_anchor_at_cursor)
    # $anchor expands to multiple shell words; intentional — it must be
    # split into ("-theme-str", "window{...}"). Use word-splitting here.
    rofi -theme "$theme" $anchor -dmenu "$@"
}
