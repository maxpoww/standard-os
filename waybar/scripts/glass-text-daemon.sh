#!/usr/bin/env bash
# glass-text-daemon.sh — Writes background brightness mode to /tmp/glass-mode
#
# Reads the current background color from hypr-edge-bg's cache (no grim needed).
# Computes luminance from the hex in the filename.
# If luminance > THRESHOLD → "light", else → "dark".

trap '' HUP

LOCKFILE="/tmp/glass-text-daemon.lock"
MODEFILE="/tmp/glass-mode"
BG_CACHE="/tmp/hypr-edge-bg"
THRESHOLD=140
LAST_MODE=""
LAST_HEX=""
INTERVAL=0.25

# ── Prevent duplicate instances (PID-based, survives SIGKILL) ────────────────
if [[ -f "$LOCKFILE" ]]; then
    old_pid=$(cat "$LOCKFILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "Glass text daemon already running (pid $old_pid), exiting." >&2
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

cleanup() { rm -f "$LOCKFILE"; }
trap 'cleanup' EXIT

ensure_mode() {
    # Make sure $MODEFILE always exists. If it was deleted out from under us,
    # restore from LAST_MODE (or default to dark). Keeps consumers like
    # custom/clock from silently falling back to "dark" during a race.
    if [[ ! -f "$MODEFILE" ]]; then
        echo "${LAST_MODE:-dark}" > "$MODEFILE"
    fi
}

update_cache_mode() {
    # Centrally swap the dark/light token inside every cached pill's class
    # array so waybar's RTMIN+10 re-read renders the new theme immediately —
    # without waiting for each owning daemon's natural emit cadence (which is
    # never for event-driven daemons between events).
    #
    # All cache files are pill_emit's JSON array form ("class":[...]). The
    # earlier sed targeted the obsolete string form and silently no-op'd
    # for ~2 weeks after the 2026-05-28 array migration.
    local m=$1 CACHE_DIR="/tmp/waybar-cache"
    [[ -d "$CACHE_DIR" ]] || return
    local f prev new
    for f in "$CACHE_DIR"/*; do
        [[ -f "$f" ]] || continue
        prev=$(cat "$f" 2>/dev/null)
        # Skip plain-text caches (has-window=numeric, mic-monitor=string).
        [[ "${prev:0:1}" == "{" ]] || continue
        # jq swaps just the theme token; everything else (opt-pill, state,
        # pin, swap, empty, inactive) is preserved verbatim.
        new=$(jq -c --arg m "$m" '
            if (.class | type) == "array" then
                .class |= map(if . == "dark" or . == "light" then $m else . end)
            else . end
        ' <<<"$prev" 2>/dev/null) || continue
        [[ -z "$new" || "$new" == "$prev" ]] && continue
        # Atomic write — racing daemon writes resolve "last writer wins",
        # which is fine because pill_write's dedup will skip the next emit
        # when our rewrite already matches the daemon's intended content.
        printf '%s' "$new" > "$f.tmp" && mv -f "$f.tmp" "$f"
    done
}

set_mode() {
    echo "$1" > "$MODEFILE"
    update_cache_mode "$1"
    # Signal every module whose `signal:` field is theme-relevant. RTMIN+10 is
    # the canonical theme signal (clock, battery, window, ws-*, win-*, opt-plus
    # static pills, …). RTMIN+11 wakes dictate (modules/voice-dictation.nix
    # uses signal:11 for its OPTIONS pill so the dictate-waybar binary itself
    # can re-emit on state changes independently of theme). RTMIN+12 wakes
    # notif-bell / notif-profile / notif-action-1/2/3 (the notif-center group
    # uses signal:12 so notif-daemon can drive them without theme coupling).
    # Without these extra signals, the *cache file* would be rewritten by
    # update_cache_mode above but waybar would not re-cat it until the owning
    # daemon's next natural emission — meaning notif and dictate pills could
    # carry stale theme tokens for hours until activity. Sending all three is
    # cheap (pkill matches by process, signal delivery is microsecond-scale).
    pkill -RTMIN+10 waybar 2>/dev/null || true
    pkill -RTMIN+11 waybar 2>/dev/null || true
    pkill -RTMIN+12 waybar 2>/dev/null || true
}

hex_luminance() {
    # Compute perceived luminance (0-255) from hex string
    local hex=$1
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    # ITU-R BT.601 luma
    echo $(( (r * 299 + g * 587 + b * 114) / 1000 ))
}

# ── Seed mode + pill caches before the event loop ────────────────────────────
# On fresh tmpfs /tmp (reboot, manual rm -rf), neither /tmp/glass-mode nor
# any /tmp/waybar-cache/* exist. The event loop only calls set_mode when the
# detected hex CHANGES from LAST_HEX, so pills rendered before the first change
# would show blank. self_seed runs once at startup: computes the actual mode
# from the bg-hex cache (same logic as the loop), calls set_mode to write
# /tmp/glass-mode + rewrite pill caches + signal waybar, and falls back to
# "dark" when no bg cache exists yet.
self_seed() {
    # Default "dark" — white-on-dark text is always readable, dark-on-light
    # disappears on dark wallpapers. Safe pick when bg cache is absent.
    local seed_mode="dark"
    local seed_hex
    seed_hex=$(ls -t "$BG_CACHE"/bg_??????.png 2>/dev/null | head -1)
    if [[ -n "$seed_hex" ]]; then
        seed_hex=${seed_hex##*/bg_}
        seed_hex=${seed_hex%.png}
        if [[ ${#seed_hex} -eq 6 ]]; then
            local lum
            lum=$(hex_luminance "$seed_hex")
            if (( lum > THRESHOLD )); then
                seed_mode="light"
            fi
        fi
    fi
    LAST_MODE="$seed_mode"
    LAST_HEX="${seed_hex:-}"
    set_mode "$seed_mode"
}

echo "Glass text daemon started (reading from hypr-edge-bg cache)"

# Seed before entering the loop so waybar modules are never blank on fresh /tmp.
self_seed

while true; do
    ensure_mode
    # Single subprocess: get newest bg file
    hex=$(ls -t "$BG_CACHE"/bg_??????.png 2>/dev/null | head -1)
    if [[ -n "$hex" ]]; then
        hex=${hex##*/bg_}
        hex=${hex%.png}
        # Only recompute if hex changed
        if [[ "$hex" != "$LAST_HEX" && ${#hex} -eq 6 ]]; then
            LAST_HEX=$hex
            r=$((16#${hex:0:2}))
            g=$((16#${hex:2:2}))
            b=$((16#${hex:4:2}))
            lum=$(( (r * 299 + g * 587 + b * 114) / 1000 ))
            if (( lum > THRESHOLD )); then
                mode="light"
            else
                mode="dark"
            fi
            if [[ "$mode" != "$LAST_MODE" ]]; then
                set_mode "$mode"
                LAST_MODE="$mode"
            fi
        fi
    fi
    sleep 0.5
done
