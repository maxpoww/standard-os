#!/usr/bin/env bash
# pomodoro-daemon — focus-block state machine.
#
# Reads commands from a FIFO at /run/user/$UID/standardos-pomodoro.fifo
# and writes state JSON to /tmp/waybar-cache/pomodoro.json on every
# state change AND every tick during an active block. Signal: RTMIN+19
# (dedup at writer; ticks that don't change the rendered text don't
# fire the signal — that's what cache_signal_if_changed already does).
#
# State machine:
#   idle ──(start [N])──→ running (focus)
#   running ──(time elapses)──→ break (short or long)
#   running ──(skip)──→ break
#   running ──(stop)──→ idle
#   break ──(skip)──→ running (focus)
#   break ──(stop)──→ idle
#   any ──(reset)──→ idle, BLOCKS_TODAY = 0
#
# Long break after every 4th focus block (Pomodoro classic).
# Block kinds:
#   focus       — 25 min default (caller overridable via `start N`)
#   short_break — 5 min
#   long_break  — 15 min
#
# Library mode: POMODORO_DAEMON_LIB_ONLY=1 source defines state +
# cmd_* + tick + emit_json without entering the loop.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CACHE=/tmp/waybar-cache/pomodoro.json
SIG=19
FIFO="/run/user/${UID:-$(id -u)}/standardos-pomodoro.fifo"
mkdir -p "$(dirname "$CACHE")"

FOCUS_DEFAULT=$((25 * 60))
SHORT_BREAK=$((5 * 60))
LONG_BREAK=$((15 * 60))
BLOCKS_TARGET=4

STATE=idle
BLOCK_KIND=focus
REMAINING_S=0
BLOCKS_TODAY=0

state_reset() {
    STATE=idle
    BLOCK_KIND=focus
    REMAINING_S=0
    BLOCKS_TODAY=0
}

cmd_start() {
    local seconds="${1:-$FOCUS_DEFAULT}"
    STATE=running
    BLOCK_KIND=focus
    REMAINING_S=$seconds
}

cmd_stop() {
    STATE=idle
    REMAINING_S=0
}

cmd_skip() {
    # If we were in focus → completed → next is break (short or long).
    # If we were in break → next is focus.
    if [[ "$BLOCK_KIND" == focus && "$STATE" == running ]]; then
        BLOCKS_TODAY=$((BLOCKS_TODAY + 1))
        if (( BLOCKS_TODAY % BLOCKS_TARGET == 0 )); then
            BLOCK_KIND=long_break
            REMAINING_S=$LONG_BREAK
        else
            BLOCK_KIND=short_break
            REMAINING_S=$SHORT_BREAK
        fi
        STATE=break
    elif [[ "$BLOCK_KIND" == short_break || "$BLOCK_KIND" == long_break ]]; then
        BLOCK_KIND=focus
        REMAINING_S=$FOCUS_DEFAULT
        STATE=running
    fi
}

cmd_reset() {
    state_reset
}

tick() {
    local dt="${1:-1}"
    if [[ "$STATE" == running || "$STATE" == break ]]; then
        REMAINING_S=$((REMAINING_S - dt))
        if (( REMAINING_S <= 0 )); then
            REMAINING_S=0
            cmd_skip
        fi
    fi
}

emit_json() {
    local text
    if (( REMAINING_S > 0 )); then
        text=$(printf '%d:%02d' $((REMAINING_S / 60)) $((REMAINING_S % 60)))
    else
        text="—:—"
    fi
    jq -nc --arg state "$STATE" \
       --argjson rs "$REMAINING_S" \
       --arg rt "$text" \
       --arg kind "$BLOCK_KIND" \
       --argjson bt "$BLOCKS_TODAY" \
       --argjson tg "$BLOCKS_TARGET" \
       '{state:$state, remaining_seconds:$rs, remaining_text:$rt,
         block_kind:$kind, blocks_completed_today:$bt, blocks_target:$tg}'
}

[[ -n "${POMODORO_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# Make the FIFO if it doesn't exist. Open it for read+write on the same
# FD so the open call doesn't block waiting for a writer.
[[ -p "$FIFO" ]] || mkfifo -m 600 "$FIFO"
exec {FIFO_FD}<>"$FIFO"

cache_signal_if_changed "$CACHE" "$(emit_json)" "$SIG"

while true; do
    # Non-blocking read with 1 s timeout — drives the tick.
    if read -r -t 1 -u "$FIFO_FD" cmd args; then
        case "$cmd" in
            start)  cmd_start "${args:-}" ;;
            stop)   cmd_stop ;;
            skip)   cmd_skip ;;
            reset)  cmd_reset ;;
            status) : ;; # falls through to emit
            *) ;;
        esac
    else
        tick 1
    fi
    cache_signal_if_changed "$CACHE" "$(emit_json)" "$SIG"
done
