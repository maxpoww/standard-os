#!/usr/bin/env bash
# cal-source-daemon — local ICS files → agenda cache for the canvas.
#
# v0 source: ~/.config/standardos/calendars/*.ics (manually exported
# from Google/Apple/Outlook, or symlinked from a CalDAV sync tool
# the user runs separately). CalDAV/Google direct sync = Wave 4+
# follow-up.
#
# Cache:  /tmp/waybar-cache/agenda.json
# Signal: RTMIN+20 (free pool — registered in waybar/ARCHITECTURE.md).
#
# Library mode: CAL_SOURCE_LIB_ONLY=1 source defines derive_agenda_json
# without entering the loop. CAL_NOW env var overrides "now" for tests.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CAL_DIR="${HOME}/.config/standardos/calendars"
CACHE=/tmp/waybar-cache/agenda.json
SIG=20
POLL_INTERVAL="${CAL_POLL_INTERVAL:-300}"  # 5 min
mkdir -p "$(dirname "$CACHE")" "$CAL_DIR"

# parse_one_ics <file> — emit lines of "<unix_ts>\t<summary>" for each
# VEVENT with a valid DTSTART. Only handles UTC + local timestamp forms.
parse_one_ics() {
    local f="$1"
    [[ -r "$f" ]] || return 0
    awk '
        BEGIN { in_event = 0; sum = ""; start = "" }
        /^BEGIN:VEVENT/  { in_event = 1; sum = ""; start = ""; next }
        /^END:VEVENT/    {
            if (in_event && start != "") {
                cmd = "date -d \"" start "\" +%s 2>/dev/null"
                cmd | getline ts
                close(cmd)
                if (ts ~ /^[0-9]+$/) {
                    print ts "\t" sum
                }
            }
            in_event = 0; sum = ""; start = ""
            next
        }
        in_event && /^SUMMARY[:;]/  { sub(/^SUMMARY[^:]*:/, ""); sum = $0; next }
        in_event && /^DTSTART[:;]/  {
            sub(/^DTSTART[^:]*:/, "")
            if (length($0) == 8) {
                start = substr($0,1,4) "-" substr($0,5,2) "-" substr($0,7,2)
            } else if (length($0) >= 15) {
                start = substr($0,1,4) "-" substr($0,5,2) "-" substr($0,7,2) \
                        "T" substr($0,10,2) ":" substr($0,12,2) ":" substr($0,14,2) \
                        (substr($0,16,1) == "Z" ? "Z" : "")
            }
            next
        }
    ' "$f"
}

derive_agenda_json() {
    local dir="$1"
    local now="${CAL_NOW:-$(date +%s)}"
    local today_start
    today_start=$(date -d "@$now" +%Y-%m-%d)
    today_start=$(date -d "${today_start}T00:00:00" +%s)
    local today_end=$((today_start + 86400))

    if [[ ! -d "$dir" ]]; then
        jq -nc --argjson updated "$now" \
           '{events:[], today_count:0, next_minutes_until:null, updated:$updated}'
        return
    fi

    local tmp; tmp=$(mktemp)
    trap "rm -f $tmp" RETURN
    local f
    for f in "$dir"/*.ics; do
        [[ -e "$f" ]] || continue
        parse_one_ics "$f" >> "$tmp"
    done

    local events_json today_count next_minutes
    events_json=$(awk -F'\t' -v now="$now" '
        $1 >= now { print $0 }
    ' "$tmp" | sort -n | head -8 | awk -F'\t' -v now="$now" -v today_end="$today_end" '
        {
            ts=$1; sum=$2
            mins = int((ts - now) / 60)
            cmd = "date -d \"@" ts "\" +%H:%M"; cmd | getline hm; close(cmd)
            if (ts < today_end) {
                start_text = hm
            } else {
                cmd2 = "date -d \"@" ts "\" \"+%a %H:%M\""; cmd2 | getline st; close(cmd2)
                start_text = st
            }
            printf "{\"summary\":\"%s\",\"start\":%d,\"start_text\":\"%s\",\"minutes_until\":%d}\n",
                   sum, ts, start_text, mins
        }
    ' | jq -s '.')

    today_count=$(awk -F'\t' -v now="$now" -v today_end="$today_end" '
        $1 >= now && $1 < today_end { c++ } END { print c+0 }
    ' "$tmp")

    next_minutes=$(printf '%s' "$events_json" | jq -r '.[0].minutes_until // null')

    jq -nc --argjson events "$events_json" \
       --argjson today_count "$today_count" \
       --argjson next "${next_minutes:-null}" \
       --argjson updated "$now" \
       '{events:$events, today_count:$today_count, next_minutes_until:$next, updated:$updated}'
}

[[ -n "${CAL_SOURCE_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
while true; do
    cache_signal_if_changed "$CACHE" "$(derive_agenda_json "$CAL_DIR")" "$SIG"
    sleep "$POLL_INTERVAL"
done
