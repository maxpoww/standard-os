#!/usr/bin/env bash
# pref.sh -- get / set / cycle user preferences in
# ~/.config/standardos/preferences.json. Each key is a flat string.
#
# Usage:
#   pref.sh get   <key> [default]
#   pref.sh set   <key> <value>
#   pref.sh cycle <key> <val1> <val2> [val3 ...]
#
# Atomic writes via tmp+mv so a concurrent read never sees half-written.
# The Preferences rows in the canvas's User section read via `get` and
# fire `cycle` on click.

set -uo pipefail

CFG_DIR="$HOME/.config/standardos"
CFG="$CFG_DIR/preferences.json"

mkdir -p "$CFG_DIR"
[[ -f $CFG ]] || echo '{}' >"$CFG"

write_atomic() {
    local content=$1
    local tmp
    tmp=$(mktemp "$CFG.XXXXXX")
    printf '%s\n' "$content" >"$tmp"
    mv -f "$tmp" "$CFG"
}

case "${1:-}" in
get)
    key=${2:?missing key}
    default=${3:-}
    val=$(jq -r --arg k "$key" '.[$k] // ""' "$CFG" 2>/dev/null || echo "")
    if [[ -z $val && -n $default ]]; then
        echo "$default"
    else
        echo "$val"
    fi
    ;;
set)
    key=${2:?missing key}
    value=${3:?missing value}
    new=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$CFG")
    write_atomic "$new"
    echo "$value"
    ;;
cycle)
    key=${2:?missing key}
    shift 2
    if (($# < 2)); then
        echo "pref.sh cycle needs at least 2 values" >&2
        exit 1
    fi
    cur=$(jq -r --arg k "$key" '.[$k] // ""' "$CFG" 2>/dev/null || echo "")
    args=("$@")
    next=${args[0]}
    for i in "${!args[@]}"; do
        if [[ ${args[i]} == "$cur" ]]; then
            next_idx=$(((i + 1) % ${#args[@]}))
            next=${args[next_idx]}
            break
        fi
    done
    new=$(jq --arg k "$key" --arg v "$next" '.[$k] = $v' "$CFG")
    write_atomic "$new"
    echo "$next"
    ;;
*)
    echo "Usage: $0 get|set|cycle ..." >&2
    exit 1
    ;;
esac
