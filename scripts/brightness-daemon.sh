#!/usr/bin/env bash
# brightness-daemon — sole writer of /tmp/waybar-cache/brightness.json.
#
# Reads /sys/class/backlight/intel_backlight/{actual,max}_brightness on a
# 1 s tick. Writes via canvas-cache.sh:cache_signal_if_changed so the cache
# touches AND the RTMIN+21 signal fire only when pct actually changes.
#
# Cache shape:
#   { "pct": <int 0..100|null>,
#     "raw": <int|null>,
#     "max": <int|null>,
#     "device": "intel_backlight",
#     "updated": <unix_ts> }
#
# Library mode: BRIGHTNESS_DAEMON_LIB_ONLY=1 source defines
# derive_brightness_json without entering the loop.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

DEVICE="${BRIGHTNESS_DEVICE:-intel_backlight}"
SYSFS_DIR="/sys/class/backlight/${DEVICE}"
CACHE=/tmp/waybar-cache/brightness.json
SIG=21
POLL_INTERVAL="${BRIGHTNESS_POLL_INTERVAL:-1}"
mkdir -p "$(dirname "$CACHE")"

# derive_brightness_json <sysfs_dir> <device_name> <unix_ts>
#   sysfs_dir must contain actual_brightness + max_brightness files.
#   Missing/unreadable files → pct/raw/max emit as JSON null (no crash,
#   no division-by-zero).
derive_brightness_json() {
    local dir="$1" device="$2" now="$3"
    local raw_str max_str raw max pct_arg raw_arg max_arg

    raw_str=$(cat "$dir/actual_brightness" 2>/dev/null || true)
    max_str=$(cat "$dir/max_brightness" 2>/dev/null || true)

    if [[ "$raw_str" =~ ^[0-9]+$ ]]; then raw="$raw_str"; else raw=""; fi
    if [[ "$max_str" =~ ^[0-9]+$ && "$max_str" -gt 0 ]]; then max="$max_str"; else max=""; fi

    if [[ -n "$raw" && -n "$max" ]]; then
        local pct=$(( (raw * 100 + max / 2) / max ))   # rounded
        pct_arg="--argjson pct $pct"
        raw_arg="--argjson raw $raw"
        max_arg="--argjson max $max"
    else
        pct_arg="--argjson pct null"
        if [[ -n "$raw" ]]; then raw_arg="--argjson raw $raw"; else raw_arg="--argjson raw null"; fi
        if [[ -n "$max" ]]; then max_arg="--argjson max $max"; else max_arg="--argjson max null"; fi
    fi

    # shellcheck disable=SC2086
    jq -nc $pct_arg $raw_arg $max_arg \
       --arg device "$device" \
       --argjson updated "$now" \
       '{pct:$pct, raw:$raw, max:$max, device:$device, updated:$updated}'
}

[[ -n "${BRIGHTNESS_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# SIGUSR1 → set POKE flag so the next iteration writes immediately
# without waiting for sleep. The wrapper sends SIGUSR1 right after
# brightnessctl returns to push the cache forward sub-second.
POKE=0
trap 'POKE=1' USR1

while true; do
    cache_signal_if_changed "$CACHE" \
        "$(derive_brightness_json "$SYSFS_DIR" "$DEVICE" "$(date +%s)")" \
        "$SIG"
    if (( POKE )); then
        POKE=0
        continue
    fi
    sleep "$POLL_INTERVAL"
done
