#!/usr/bin/env bash
# standardos-pending — waybar custom-module backend for the canvas
# Apply flow's bar pill. Reads the user-side state files and emits
# a single JSON line:
#   empty   : {"text":"","tooltip":"","class":["empty"]}
#   pending : {"text":"Apply (N)","tooltip":"<keys>","class":["pending"]}
#   error   : {"text":"Error","tooltip":"<reason>","class":["error"]}
#
# Invoked by waybar as a custom module's exec, refreshed via RTMIN+23
# (see waybar/config.jsonc + ARCHITECTURE.md signal table).
set -euo pipefail

STAGED="${STAGED_PREFS_FILE:-$HOME/.config/standardos/staged-prefs.json}"
ERR="${LAST_ERROR_FILE:-$HOME/.config/standardos/last-error.json}"

# Error state takes priority.
if [ -s "$ERR" ]; then
    reason="$(jq -r '.reason // "rebuild failed"' "$ERR")"
    jq -nc --arg t "Error" --arg tt "$reason" '{text:$t, tooltip:$tt, class:["error"]}'
    exit 0
fi

# Pending state.
if [ -s "$STAGED" ]; then
    # Count keys excluding *_display sidecars.
    n="$(jq '[keys[] | select(endswith("_display") | not)] | length' "$STAGED")"
    if [ "$n" -gt 0 ]; then
        tt="$(jq -r '[keys[] | select(endswith("_display") | not)] | join(", ")' "$STAGED")"
        jq -nc --arg t "Apply ($n)" --arg tt "$tt" '{text:$t, tooltip:$tt, class:["pending"]}'
        exit 0
    fi
fi

# Empty state.
jq -nc '{text:"", tooltip:"", class:["empty"]}'
