#!/usr/bin/env bash
# Color math helpers — sourced by hypr-edge-bg. Integer arithmetic only.

hex_to_rgb() {
    local h=${1#"#"}
    printf '%d %d %d\n' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

rgb_to_hex() {
    printf '%02x%02x%02x\n' "$1" "$2" "$3"
}

clamp() {
    local v=$1 lo=$2 hi=$3
    ((v < lo)) && v=$lo
    ((v > hi)) && v=$hi
    printf '%d\n' "$v"
}

# ITU-R BT.601
luma() {
    printf '%d\n' $(((299 * $1 + 587 * $2 + 114 * $3) / 1000))
}

# Squared Euclidean distance in RGB.
rgb_dist_sq() {
    local dr=$(($1 - $4)) dg=$(($2 - $5)) db=$(($3 - $6))
    printf '%d\n' $((dr * dr + dg * dg + db * db))
}

# mismatch_hex <hex> <dark_theme:0|1> <shift_pct> <clamp_min> <clamp_max>
# Dark theme on  → darken by shift_pct.
# Dark theme off → lighten by shift_pct.
# Output luminance is clamped to [clamp_min, clamp_max] so colors never go pure black/white.
mismatch_hex() {
    local hex=$1 dark=$2 shift=$3 lo=$4 hi=$5
    read -r r g b < <(hex_to_rgb "$hex")
    local L
    L=$(luma "$r" "$g" "$b")
    local sign=1
    ((dark == 1)) && sign=-1
    local outL=$((L + sign * L * shift / 100))
    outL=$(clamp "$outL" "$lo" "$hi")
    local denom=$L
    ((denom < 1)) && denom=1
    # Multiply rgb by outL/L then clamp each channel.
    local nr=$((r * outL / denom))
    local ng=$((g * outL / denom))
    local nb=$((b * outL / denom))
    nr=$(clamp "$nr" 0 255)
    ng=$(clamp "$ng" 0 255)
    nb=$(clamp "$nb" 0 255)
    rgb_to_hex "$nr" "$ng" "$nb"
    return 0
}

# mix_init / mix_add / mix_finalize — area-weighted RGB mean accumulator.
# Caller resets MIX_R MIX_G MIX_B MIX_A to 0 before a batch via mix_init.
mix_init() {
    MIX_R=0
    MIX_G=0
    MIX_B=0
    MIX_A=0
}

# mix_add <hex> <area>
mix_add() {
    local hex=$1 area=$2 r g b
    read -r r g b < <(hex_to_rgb "$hex")
    MIX_R=$((MIX_R + r * area))
    MIX_G=$((MIX_G + g * area))
    MIX_B=$((MIX_B + b * area))
    MIX_A=$((MIX_A + area))
}

mix_finalize() {
    local denom=$MIX_A
    ((denom < 1)) && denom=1
    rgb_to_hex $((MIX_R / denom)) $((MIX_G / denom)) $((MIX_B / denom))
}
