#!/usr/bin/env bash
# Shared color helpers for hypr-bg-daemon and any other consumer.
# Pure bash + printf arithmetic; no forks per call.

hex_to_rgb() {
    local h=${1#"#"}
    printf '%d %d %d\n' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

rgb_to_hex() {
    printf '%02x%02x%02x\n' "$1" "$2" "$3"
}

rgb_dist_sq() {
    local dr=$(($1 - $4)) dg=$(($2 - $5)) db=$(($3 - $6))
    printf '%d\n' $((dr * dr + dg * dg + db * db))
}

# ITU-R BT.601 perceived luminance (0-255) from a 6-char hex (no leading #).
# Threshold ~= 128 is the natural light/dark cutoff for glass-mode.
hex_luminance() {
    local hex=$1
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    echo $(( (r * 299 + g * 587 + b * 114) / 1000 ))
}
