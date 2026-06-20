#!/usr/bin/env bash
# canvas-weather.sh — fetch current weather from wttr.in for a fixed city.
# Emits a pipe-separated string: COND|TEMP|HI|LO|HUM
# COND = one of: clear | partly-cloudy | cloudy | rain | snow | storm | clear-night
# Silent + falls back to "clear|—°|—|—|—%" on any failure.

set -uo pipefail
CITY="${STANDARDOS_WEATHER_CITY:-Mendoza}"

FALLBACK="clear|—°|—|—|—%"

# wttr.in format string:
#   %C    condition text
#   %t    current temp
#   %f    feels-like
#   %h    humidity
# We use ?format=4 wouldn't include all; use a custom format.
RAW="$(curl -fsS --max-time 10 "https://wttr.in/${CITY}?format=%C|%t|%h|%l" 2>/dev/null)" || {
  echo "$FALLBACK"
  exit 0
}

# wttr.in lo/hi requires a different endpoint; second curl with --max-time 6.
FORECAST="$(curl -fsS --max-time 6 "https://wttr.in/${CITY}?format=j1" 2>/dev/null | grep -E '"(maxtempC|mintempC)"' | head -2)" || FORECAST=""
HI=$(echo "$FORECAST" | grep maxtempC | head -1 | sed -E 's/.*"maxtempC": "([0-9-]+)".*/\1/' || echo "—")
LO=$(echo "$FORECAST" | grep mintempC | head -1 | sed -E 's/.*"mintempC": "([0-9-]+)".*/\1/' || echo "—")
[ -z "$HI" ] && HI="—"
[ -z "$LO" ] && LO="—"

IFS='|' read -r COND_TEXT TEMP HUM _LOC <<<"$RAW"

# Map condition text → canonical condition code.
shopt -s nocasematch
case "$COND_TEXT" in
  *storm*|*thunder*) COND=storm ;;
  *snow*|*sleet*|*blizzard*) COND=snow ;;
  *rain*|*shower*|*drizzle*) COND=rain ;;
  *fog*|*overcast*|*cloud*)
    case "$COND_TEXT" in
      *partly*|*sun*) COND=partly-cloudy ;;
      *) COND=cloudy ;;
    esac
    ;;
  *clear*|*sun*|*fair*)
    # Night-clear check: query time-of-day.
    H=$(date +%H)
    if [ "$H" -lt 7 ] || [ "$H" -ge 20 ]; then COND=clear-night; else COND=clear; fi
    ;;
  *) COND=clear ;;
esac
shopt -u nocasematch

printf '%s|%s|%s°|%s°|%s\n' "$COND" "$TEMP" "$HI" "$LO" "$HUM"
exit 0
