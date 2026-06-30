#!/usr/bin/env bash
# weather-daemon — fetch current weather from wttr.in, cache as JSON.
#
# Replaces widgets/scripts/canvas-weather.sh, which was an eww defpoll
# shell-out. Wave 3 moves the poll into a long-running systemd-user
# service so the cache is fresh whether or not the canvas is open
# (the bar may surface weather as a pillar-6 pill in a future wave),
# and so the canvas's defpoll becomes a cheap `cat | jq -r`.
#
# Cache:  /tmp/waybar-cache/weather.json
# Signal: none (the canvas re-reads on its own 60 s defpoll; weather
#         doesn't move fast enough to justify pushing to waybar).
#
# Library mode: `WEATHER_DAEMON_LIB_ONLY=1 source weather-daemon.sh`
# defines one_fetch + condition_canonicalize without entering the
# loop, so tests can drive them with a mocked curl.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CACHE=/tmp/waybar-cache/weather.json
mkdir -p "$(dirname "$CACHE")"

POLL_INTERVAL="${WEATHER_POLL_INTERVAL:-600}"
CITY="${STANDARDOS_WEATHER_CITY:-Mendoza}"

_canvas_hour() {
    date +%-H
}

condition_canonicalize() {
    # wttr.in condition strings → canonical codes for the canvas's
    # illustration set. Order matters: "Light snow" must match snow
    # before any "cloudy"-substring rule.
    local raw="${1,,}"  # lowercase
    case "$raw" in
        *thunder*|*storm*)   echo storm ;;
        *snow*|*sleet*)      echo snow ;;
        *rain*|*shower*|*drizzle*) echo rain ;;
        *partly*cloudy*)     echo partly-cloudy ;;
        *overcast*|*cloudy*) echo cloudy ;;
        *clear*|*sunny*)
            # Day vs night: check current hour. wttr.in doesn't tell us
            # directly; rely on local clock as good-enough.
            local h
            h=$(_canvas_hour)
            if (( h < 7 || h >= 20 )); then echo clear-night
            else echo clear
            fi
            ;;
        *) echo clear ;;  # unknown — safe default
    esac
}

one_fetch() {
    # Two endpoints: %C|%t|%h|%l for the current observation, ?format=j1
    # for the day's hi/lo. Both have --max-time guards to keep the
    # daemon responsive on flaky networks.
    local raw
    raw=$(curl -fsS --max-time 10 \
          "https://wttr.in/${CITY}?format=%C|%t|%h|%l" 2>/dev/null) || return 1

    local cond_text temp hum loc
    IFS='|' read -r cond_text temp hum loc <<<"$raw"

    local forecast hi lo
    forecast=$(curl -fsS --max-time 6 \
               "https://wttr.in/${CITY}?format=j1" 2>/dev/null) || forecast=""
    hi=$(printf '%s' "$forecast" | jq -r '.weather[0].maxtempC // "—"' 2>/dev/null || echo "—")
    lo=$(printf '%s' "$forecast" | jq -r '.weather[0].mintempC // "—"' 2>/dev/null || echo "—")

    local cond
    cond=$(condition_canonicalize "$cond_text")

    jq -n \
       --arg cond "$cond" \
       --arg temp "$temp" \
       --arg hi   "$hi" \
       --arg lo   "$lo" \
       --arg hum  "$hum" \
       --arg city "${loc%%,*}" \
       --argjson fetched "$(date +%s)" \
       '{cond:$cond, temp:$temp, hi:$hi, lo:$lo, hum:$hum, city:$city, fetched:$fetched}'
}

[[ -n "${WEATHER_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ───────────────────────────────────────────────────────
while true; do
    out=$(one_fetch) || out=""
    if [[ -n "$out" ]]; then
        # No signal — canvas defpoll re-reads on its own cadence.
        cache_write_atomic "$CACHE" "$out"
    fi
    sleep "$POLL_INTERVAL"
done
