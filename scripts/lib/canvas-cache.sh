#!/usr/bin/env bash
# canvas-cache.sh — shared cache primitives for Wave 3 canvas daemons.
#
# Source from any daemon: `source /etc/nixos/home/scripts/lib/canvas-cache.sh`.
# Provides three functions:
#
#   cache_write_atomic <abs-path> <content>
#       Atomic write via tmp + mv -f. Avoids half-written-file races
#       (a waybar/eww reader picking up an empty file mid-write).
#
#   cache_signal_if_changed <abs-path> <new-content> <signal-num>
#       Writes only when <new-content> differs from on-disk bytes;
#       fires `pkill -RTMIN+<signal-num> waybar` on change. The dedup
#       is the central anti-CPU-burn pattern (see waybar/CLAUDE.md
#       "Known hazards" — the mpris 130 % CPU regression).
#
#   cache_read_or_default <abs-path> <default>
#       cat or default. Always exits 0 — never propagates a missing
#       file as a script failure (defpoll would emit empty otherwise).
#
# Hazards:
#   - The tmp file uses $$ + a per-call counter so concurrent writes
#     from the same daemon don't race each other (a single daemon
#     should not call this concurrently, but the safety is cheap).
#   - mv -f on the same filesystem is atomic on Linux ext4/btrfs/xfs;
#     /tmp/waybar-cache/ MUST be on the same filesystem as the tmp
#     write target. tmpfs on /tmp covers this on a standard NixOS box.

_CANVAS_CACHE_COUNTER=0

cache_write_atomic() {
    local target="$1"
    local content="$2"
    _CANVAS_CACHE_COUNTER=$((_CANVAS_CACHE_COUNTER + 1))
    local tmp="${target}.tmp.$$.${_CANVAS_CACHE_COUNTER}"
    printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    return 0
}

cache_signal_if_changed() {
    local target="$1"
    local new="$2"
    local sig="$3"
    local existing=""
    if [[ -r "$target" ]]; then
        existing="$(cat "$target" 2>/dev/null || true)"
    fi
    if [[ "$existing" == "$new" ]]; then
        return 0
    fi
    cache_write_atomic "$target" "$new" || return 1
    pkill -RTMIN+"$sig" waybar 2>/dev/null || true
    return 0
}

cache_read_or_default() {
    local target="$1"
    local fallback="$2"
    if [[ -r "$target" ]]; then
        cat "$target" 2>/dev/null || printf '%s' "$fallback"
    else
        printf '%s' "$fallback"
    fi
}
