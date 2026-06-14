#!/usr/bin/env bash
# hypr-bg-daemon — single-rule background painter.
#
# Trigger rule (paint solid color sampled from bg_window's top edge):
#   bg_window != null    (context-daemon picks the fullscreen window if any,
#                         else the lone non-floating non-pseudo tile)
# Else: restore waypaper image.
#
# bg_window is a topology check — fullscreen window OR lone non-floating
# non-pseudo tile — which matches the layout states that
# hypr/modules/Workspace_Rules.conf collapses gaps for (`f[1]` and `w[tv1]`).
# We do NOT check `workspace.gaps_out` because `hyprctl getoption
# general:gaps_out` returns the GLOBAL config, not the per-workspace
# effective value Hyprland applies via workspace selectors (the 2026-06-13
# unification kept this check as "a guard" but it was always false in
# practice and the painter never fired — fix landed 2026-06-14).
#
# bg_window — not focused — is sampled so a floating window focused on top of
# a tile in a `w[tv1]` workspace doesn't break the sample (the bg sticks with
# the underlying tile).
#
# Also owns /tmp/glass-mode (replacing glass-text-daemon).
# Spec: docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
set -euo pipefail

# shellcheck source=../../scripts/lib/colors.sh
. /etc/nixos/home/scripts/lib/colors.sh

PILL_CACHE_DIR=${PILL_CACHE_DIR:-/tmp/waybar-cache}
SNAPSHOT="$PILL_CACHE_DIR/hypr-context.json"
GLASS_MODE_FILE=${GLASS_MODE_FILE:-/tmp/glass-mode}
BG_CACHE_DIR=${BG_CACHE_DIR:-/tmp/hypr-edge-bg}
WAYPAPER_CFG=${WAYPAPER_CFG:-$HOME/.config/waypaper/config.ini}
WAYPAPER_LUM_CACHE="$BG_CACHE_DIR/waypaper-luminance.json"

SAMPLE_H=${HYPR_BG_SAMPLE_H:-2}
SAMPLE_W_MAX=${HYPR_BG_SAMPLE_W_MAX:-300}
DIST_THRESHOLD=${HYPR_BG_DIST_THRESHOLD:-25}
CACHE_SIZE=${HYPR_BG_CACHE_SIZE:-16}
GLASS_THRESHOLD=128

mkdir -p "$BG_CACHE_DIR"

LAST_APPLIED=""     # "image:/path" or "color-img:/path"
LAST_HEX=""
LAST_MODE=""
WAYPAPER_IMG=""
WAYPAPER_LUM=""
MON_NAMES=""
LAST_MONITORS=""

# ----- helpers (lifted from hypr-edge-bg + glass-text-daemon) -----

ensure_solid_png() {
    local hex=$1
    local f="$BG_CACHE_DIR/bg_${hex}.png"
    if [[ ! -s $f ]]; then
        magick -size 100x100 "xc:#$hex" "$f"
    fi
    touch "$f"
    printf '%s' "$f"
}

prune_cache() {
    local count
    count=$(find "$BG_CACHE_DIR" -maxdepth 1 -type f -name 'bg_*.png' | wc -l)
    if ((count <= CACHE_SIZE)); then return; fi
    local extra=$((count - CACHE_SIZE))
    find "$BG_CACHE_DIR" -maxdepth 1 -type f -name 'bg_*.png' -printf '%T@ %p\n' |
        sort -n | head -n "$extra" | awk '{ $1=""; sub(/^ /,""); print }' |
        xargs -r rm -f
}

sample_top_edge() {
    local x=$1 y=$2 w=$3
    local sw=$((w < SAMPLE_W_MAX ? w : SAMPLE_W_MAX))
    ((sw < 1)) && sw=1
    local sx=$((x + (w - sw) / 2))
    local geom="${sx},${y} ${sw}x${SAMPLE_H}"
    grim -g "$geom" - 2>/dev/null |
        magick - -depth 8 -resize '1x1!' txt:- 2>/dev/null |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^#[0-9A-Fa-f]+$/) {
                    sub(/^#/, "", $i)
                    print substr($i, 1, 6)
                    exit
                }
            }
        }'
}

set_glass_mode() {
    local mode=$1
    [[ $mode == "$LAST_MODE" ]] && return 0
    printf '%s' "$mode" >"$GLASS_MODE_FILE.tmp" && mv -f "$GLASS_MODE_FILE.tmp" "$GLASS_MODE_FILE"
    LAST_MODE=$mode
}

apply_image() {
    local img=$1 monitors_json=$2 identity=$3
    [[ $identity == "$LAST_APPLIED" ]] && return 0
    if [[ $monitors_json != "$LAST_MONITORS" || -z $MON_NAMES ]]; then
        MON_NAMES=$(jq -r '.[].name' <<<"$monitors_json")
        LAST_MONITORS="$monitors_json"
    fi
    hyprctl hyprpaper preload "$img" >/dev/null 2>&1 || true
    local mon
    while IFS= read -r mon; do
        [[ -z $mon ]] && continue
        hyprctl hyprpaper wallpaper "$mon,$img" >/dev/null 2>&1 || true
    done <<<"$MON_NAMES"
    if [[ -n $LAST_APPLIED && $LAST_APPLIED != "$identity" ]]; then
        local prev=${LAST_APPLIED#image:}
        prev=${prev#color-img:}
        if [[ $prev != "$img" && $prev != "$WAYPAPER_IMG" ]]; then
            hyprctl hyprpaper unload "$prev" >/dev/null 2>&1 || true
        fi
    fi
    LAST_APPLIED="$identity"
}

apply_color() {
    local hex=$1 monitors_json=$2
    [[ $hex == "$LAST_HEX" ]] && return 0
    if [[ -n $LAST_HEX ]]; then
        local r1 g1 b1 r2 g2 b2 d
        read -r r1 g1 b1 < <(hex_to_rgb "$hex")
        read -r r2 g2 b2 < <(hex_to_rgb "$LAST_HEX")
        d=$(rgb_dist_sq "$r1" "$g1" "$b1" "$r2" "$g2" "$b2")
        if ((d < DIST_THRESHOLD)); then return 0; fi
    fi
    local img lum mode
    img=$(ensure_solid_png "$hex")
    apply_image "$img" "$monitors_json" "color-img:$img"
    LAST_HEX="$hex"
    lum=$(hex_luminance "$hex")
    if ((lum > GLASS_THRESHOLD)); then mode="light"; else mode="dark"; fi
    set_glass_mode "$mode"
    prune_cache
}

apply_waypaper() {
    local monitors_json=$1
    [[ -z $WAYPAPER_IMG || ! -r $WAYPAPER_IMG ]] && return 0
    apply_image "$WAYPAPER_IMG" "$monitors_json" "image:$WAYPAPER_IMG"
    LAST_HEX=""
    if [[ -n $WAYPAPER_LUM ]]; then
        local mode
        if ((WAYPAPER_LUM > GLASS_THRESHOLD)); then mode="light"; else mode="dark"; fi
        set_glass_mode "$mode"
    fi
}

# ----- waypaper config tracking -----

read_waypaper_config() {
    local img
    img=$(grep -E '^\s*wallpaper\s*=' "$WAYPAPER_CFG" 2>/dev/null | sed -E 's/^\s*wallpaper\s*=\s*//' | head -1)
    img=${img//\"/}
    img=${img%$'\r'}
    # Expand leading ~ to $HOME (waypaper writes paths with literal tilde).
    [[ $img == "~/"* ]] && img="$HOME/${img#"~/"}"
    [[ $img == "~" ]]   && img="$HOME"
    if [[ -n $img && $img != "$WAYPAPER_IMG" ]]; then
        WAYPAPER_IMG=$img
        compute_waypaper_luminance
    fi
}

compute_waypaper_luminance() {
    if [[ -z $WAYPAPER_IMG || ! -r $WAYPAPER_IMG ]]; then
        WAYPAPER_LUM=""
        return
    fi
    local hex
    hex=$(magick "$WAYPAPER_IMG" -depth 8 -resize '1x1!' txt:- 2>/dev/null |
          awk '{ for (i=1;i<=NF;i++) if ($i ~ /^#[0-9A-Fa-f]+$/) { sub(/^#/,"",$i); print substr($i,1,6); exit } }')
    if [[ -z $hex ]]; then
        WAYPAPER_LUM=""
        return
    fi
    WAYPAPER_LUM=$(hex_luminance "$hex")
    printf '{"img":"%s","hex":"%s","lum":%s}\n' "$WAYPAPER_IMG" "$hex" "$WAYPAPER_LUM" \
        >"$WAYPAPER_LUM_CACHE.tmp" && mv -f "$WAYPAPER_LUM_CACHE.tmp" "$WAYPAPER_LUM_CACHE"
}

# ----- rule evaluation + dispatch -----

evaluate_and_apply() {
    [[ -r $SNAPSHOT ]] || return 0
    local snap
    snap=$(cat "$SNAPSHOT" 2>/dev/null) || return 0

    # Single topology check: bg_window != null (context-daemon picks the
    # fullscreen window if any, else the lone non-floating non-pseudo
    # tile). Geometry comes from bg_window, NOT focused, so a float-on-top
    # doesn't perturb the sample. See header comment on why we don't check
    # gaps_out.
    local vals
    vals=$(jq -r '
        [
          (.bg_window == null),
          (.bg_window.x // 0),
          (.bg_window.y // 0),
          (.bg_window.w // 0)
        ] | @tsv
    ' <<<"$snap" 2>/dev/null) || return 0

    local bgnull bx by bw
    IFS=$'\t' read -r bgnull bx by bw <<<"$vals"

    local monitors_json
    monitors_json=$(jq -c '.monitors | map({name})' <<<"$snap")

    if [[ $bgnull == "false" ]]; then
        local hex
        hex=$(sample_top_edge "$bx" "$by" "$bw")
        if [[ -n $hex ]]; then
            apply_color "$hex" "$monitors_json"
        fi
    else
        apply_waypaper "$monitors_json"
    fi
}

# ----- main loop -----

read_waypaper_config
evaluate_and_apply

inotifywait -m -q \
    --format '%w%f' \
    -e close_write,moved_to \
    "$PILL_CACHE_DIR" "$(dirname "$WAYPAPER_CFG")" 2>/dev/null |
while IFS= read -r path; do
    case "$path" in
        "$SNAPSHOT")
            evaluate_and_apply
            ;;
        "$WAYPAPER_CFG")
            read_waypaper_config
            evaluate_and_apply
            ;;
    esac
done
