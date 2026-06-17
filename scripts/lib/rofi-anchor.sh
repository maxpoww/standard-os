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
ROFI_DEFAULT_WIDTH="${ROFI_DEFAULT_WIDTH:-480}"  # default window width in logical px

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
ROFI_ZONE_SYSTEM=(
    tray
    notif-widepill notif-dnd
    notif-bell notif-dismiss notif-action-1 notif-action-2 notif-action-3
    # group/group-2 children — fill as needed
    # group/group-power children — fill as needed
    update-pending waybar-self-test power-resume
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

# Resolve focused monitor's (x, w) from hypr-context.json. Falls back
# to (0, 1920) when context is missing — better than blank.
_rofi_focused_monitor() {
    local ctx focused mon_blob mon_x mon_w scale_str sx100
    [ -r "$ROFI_HYPR_CTX" ] || { printf '0 1920'; return; }
    ctx=$(cat "$ROFI_HYPR_CTX" 2>/dev/null) || { printf '0 1920'; return; }
    focused=$(_rofi_json_str "$ctx" monitor_focused)
    if [[ $ctx =~ \{\"name\":\"${focused}\"[^}]*\} ]]; then
        mon_blob="${BASH_REMATCH[0]}"
    else
        printf '0 1920'; return
    fi
    mon_x=$(_rofi_json_int "$mon_blob" x)
    mon_w=$(_rofi_json_int "$mon_blob" w)
    # hypr-context publishes raw pixel dimensions; rofi positions in
    # LOGICAL pixels (compositor surface units). Divide x and w by scale.
    # Scale is parsed as integer percent (2.00 → 200, 1.25 → 125, 1 → 100)
    # so we can do integer arithmetic. If scale is missing, treat as 1.0.
    if [[ $mon_blob =~ \"scale\":[[:space:]]*([0-9]+)(\.[0-9]+)? ]]; then
        scale_str="${BASH_REMATCH[1]}${BASH_REMATCH[2]:-.00}"
        # Convert "2.00" → 200, "1.5" → 150, "1" → 100 without forking.
        local int_part="${scale_str%%.*}" dec_part="${scale_str#*.}"
        [ "$int_part" = "$scale_str" ] && dec_part="00"   # no dot
        # Pad/truncate dec_part to exactly 2 chars.
        case ${#dec_part} in
            0) dec_part="00" ;;
            1) dec_part="${dec_part}0" ;;
            2) : ;;
            *) dec_part="${dec_part:0:2}" ;;
        esac
        sx100=$(( 10#$int_part * 100 + 10#$dec_part ))
        [ "$sx100" -lt 1 ] && sx100=100
    else
        sx100=100
    fi
    mon_x=$(( mon_x * 100 / sx100 ))
    mon_w=$(( mon_w * 100 / sx100 ))
    printf '%d %d' "$mon_x" "$mon_w"
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

# Print a rofi -theme-str fragment that anchors rofi's top-center to
# the target pill's bottom-center + ROFI_GAP_PX. Fallback: a
# zone-center anchor (monitor center of SYSTEM zone, approximated as
# monitor right - DEFAULT_WIDTH).
rofi_anchor_for() {
    local pill="$1"
    local mon mon_x mon_w
    mon=$(_rofi_focused_monitor); read -r mon_x mon_w <<<"$mon"
    local cx
    if cx=$(_rofi_pill_center_x "$pill" "$mon_x" "$mon_w"); then
        :  # cx set
    else
        cx=$(( mon_x + mon_w - ROFI_DEFAULT_WIDTH ))
    fi
    local x_offset=$(( cx - ROFI_DEFAULT_WIDTH / 2 ))
    local y_offset=$(( ROFI_BAR_HEIGHT + ROFI_GAP_PX ))
    printf -- '-theme-str window{location:northwest;anchor:north;x-offset:%dpx;y-offset:%dpx;}' \
        "$x_offset" "$y_offset"
}

# rofi_launch <pill-id> [extra-rofi-args...] — sources theme + anchor
# and invokes rofi -dmenu. Stdin is piped to rofi (rows). Stdout is
# rofi's selected entry (whatever the caller asks for via -format).
# Callers should pass -p/-format/-no-custom/etc. themselves; this
# wrapper only injects -theme and the anchor -theme-str.
rofi_launch() {
    local pill="$1"; shift
    local theme anchor
    theme=$(rofi_theme_for_mode)
    anchor=$(rofi_anchor_for "$pill")
    # $anchor expands to multiple shell words; intentional — it must be
    # split into ("-theme-str", "window{...}"). Use word-splitting here.
    rofi -theme "$theme" $anchor -dmenu "$@"
}
