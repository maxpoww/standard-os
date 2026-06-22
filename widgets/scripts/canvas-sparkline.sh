#!/usr/bin/env bash
# canvas-sparkline.sh -- collect time-series readings + render SVG
# sparklines for the User-section history row.
#
# Usage: canvas-sparkline.sh tick
#   Reads current values for CPU, MEMORY, BATTERY, NET DOWN, NET UP.
#   Appends to ring buffers at /tmp/canvas-spark-data/<metric>.dat
#   (capped at 60 readings, ~5 min at the 5s defpoll interval).
#   Renders SVG polylines + area-fill to /tmp/canvas-sparks/<metric>.<tick>.svg
#   Prints the tick so eww's defpoll var changes (forces image re-render).

set -uo pipefail

DATA=/tmp/canvas-spark-data
OUT=/tmp/canvas-sparks
mkdir -p "$DATA" "$OUT"

BUF=60
W=400
H=36
PAD=2

collect() {
    local metric=$1 value=$2
    [[ -z $value || $value == "null" ]] && value=0
    value=${value%%.*}
    case "$value" in '' | *[!0-9-]*) value=0 ;; esac
    local file="$DATA/$metric.dat"
    echo "$value" >>"$file"
    if (($(wc -l <"$file") > BUF)); then
        tail -n "$BUF" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
    fi
}

render() {
    local metric=$1 color=$2 fixed_max=$3 tick=$4
    local file="$DATA/$metric.dat"
    [[ ! -f $file ]] && return

    local -a vals
    mapfile -t vals <"$file"
    local n=${#vals[@]}
    ((n == 0)) && return

    # Determine y-axis max.
    local max=0 v
    if [[ -n $fixed_max ]]; then
        max=$fixed_max
    else
        for v in "${vals[@]}"; do
            v=${v%%.*}
            case "$v" in '' | *[!0-9]*) v=0 ;; esac
            ((v > max)) && max=$v
        done
        ((max == 0)) && max=1
    fi

    # Generate point list. x scales across [PAD, W-PAD]; y inverts so
    # higher values draw higher in the chart.
    local points="" i x y
    local denom=$((n > 1 ? n - 1 : 1))
    local span=$((W - 2 * PAD))
    local h_span=$((H - 2 * PAD))
    for ((i = 0; i < n; i++)); do
        v=${vals[i]%%.*}
        case "$v" in '' | *[!0-9]*) v=0 ;; esac
        x=$((PAD + i * span / denom))
        y=$((PAD + h_span - v * h_span / max))
        ((y < PAD)) && y=$PAD
        ((y > H - PAD)) && y=$((H - PAD))
        points+="$x,$y "
    done

    # Area-fill polygon: bottom-left, all points, bottom-right.
    local last_x=$((PAD + span))
    local area="$PAD,$((H - PAD)) $points$last_x,$((H - PAD))"

    # Atomic write -- tmp then mv so eww's image read never sees half-written.
    local tmp="$OUT/$metric.$tick.svg.tmp"
    cat >"$tmp" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H" preserveAspectRatio="none">
  <polygon points="$area" fill="$color" opacity="0.20"/>
  <polyline points="$points" fill="none" stroke="$color" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF
    mv -f "$tmp" "$OUT/$metric.$tick.svg"
}

get_net_bytes() {
    # Sum rx (col 2) and tx (col 10) across all non-loopback interfaces.
    awk '/^[[:space:]]*[^l]/ && /:/ && !/lo:/ {
        gsub(":", " ", $1)
        sum_rx += $2
        sum_tx += $10
    } END { print sum_rx, sum_tx }' /proc/net/dev
}

collect_net_rates() {
    # Track cumulative byte counters; emit KB/s delta since last call.
    local prev_file="$DATA/net-cum"
    local now_t
    now_t=$(date +%s)
    read -r now_rx now_tx <<<"$(get_net_bytes)"
    local prev_rx=0 prev_tx=0 prev_t=0
    if [[ -f $prev_file ]]; then
        read -r prev_rx prev_tx prev_t <"$prev_file"
    fi
    echo "$now_rx $now_tx $now_t" >"$prev_file"
    if ((prev_t > 0)); then
        local dt=$((now_t - prev_t))
        ((dt < 1)) && dt=1
        local rate_rx=$(((now_rx - prev_rx) / dt / 1024))
        local rate_tx=$(((now_tx - prev_tx) / dt / 1024))
        ((rate_rx < 0)) && rate_rx=0
        ((rate_tx < 0)) && rate_tx=0
        collect net-down "$rate_rx"
        collect net-up "$rate_tx"
    fi
}

write_placeholder() {
    # SVGs at the initial defpoll tick (0) so eww doesn't error on the
    # first render before the first real tick fires.
    local metric color
    for metric in cpu mem battery net-down net-up \
        user-notifs-today user-poms-today user-events-today user-session-min; do
        case "$metric" in
        cpu) color="rgba(255,191,179,0.95)" ;;
        mem | user-poms-today) color="rgba(217,179,255,0.95)" ;;
        battery | user-events-today) color="rgba(179,255,179,0.95)" ;;
        net-down | net-up | user-notifs-today) color="rgba(110,150,255,0.95)" ;;
        user-session-min) color="rgba(255,191,179,0.95)" ;;
        esac
        local f="$OUT/$metric.0.svg"
        [[ -f $f ]] && continue
        cat >"$f" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H" preserveAspectRatio="none">
  <line x1="$PAD" y1="$((H / 2))" x2="$((W - PAD))" y2="$((H / 2))" stroke="$color" stroke-width="1.0" opacity="0.30"/>
</svg>
EOF
    done
}

# Always make sure tick=0 placeholders exist before any other mode runs.
write_placeholder

case "${1:-}" in
tick)
    cpu=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-cpu 2>/dev/null || echo 0)
    mem=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-mem 2>/dev/null || echo 0)
    bat=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-battery 2>/dev/null || echo 0)

    collect cpu "$cpu"
    collect mem "$mem"
    collect battery "$bat"
    collect_net_rates

    # USER metrics -- collect current values into ring buffers; the
    # sparkline becomes a slowly-rising/flat trend for now until we
    # add per-day persistence elsewhere.
    poms=$(jq -r '.blocks_completed_today // 0' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo 0)
    events=$(jq -r '.today_count // 0' /tmp/waybar-cache/agenda.json 2>/dev/null || echo 0)
    collect user-poms-today "$poms"
    collect user-events-today "$events"

    session_sec=0
    sid="${XDG_SESSION_ID:-}"
    if [[ -z $sid ]]; then
        sid=$(loginctl --no-legend 2>/dev/null | awk -v u="$USER" '$3 == u {print $1; exit}')
    fi
    if [[ -n $sid ]]; then
        start=$(loginctl show-session "$sid" -p Timestamp --value 2>/dev/null)
        if [[ -n $start ]]; then
            start_epoch=$(date -d "$start" +%s 2>/dev/null || echo 0)
            ((start_epoch > 0)) && session_sec=$(($(date +%s) - start_epoch))
        fi
    fi
    collect user-session-min "$((session_sec / 60))"

    # NOTIFS HOURLY (today) -- 24 buckets from notif-history.json
    # written to a fake buffer file each tick (24 values per cycle).
    if [[ -r /tmp/waybar-cache/notif-history.json ]]; then
        today=$(date +%Y-%m-%d)
        jq -r --arg t "$today" '
            (.entries // [])
            | map(select(.ts | startswith($t)) | .ts[11:13] | tonumber)
            | . as $hrs
            | [range(0;24) | . as $h | ($hrs | map(select(. == $h)) | length)]
            | .[]
        ' /tmp/waybar-cache/notif-history.json >"$DATA/user-notifs-today.dat.tmp" 2>/dev/null
        if [[ -s "$DATA/user-notifs-today.dat.tmp" ]]; then
            mv -f "$DATA/user-notifs-today.dat.tmp" "$DATA/user-notifs-today.dat"
        else
            rm -f "$DATA/user-notifs-today.dat.tmp"
        fi
    fi

    # Single tick for all SVGs so the path eww interpolates resolves.
    TICK=$(date +%s)

    render cpu      "rgba(255,191,179,0.95)" 100 "$TICK"
    render mem      "rgba(217,179,255,0.95)" 100 "$TICK"
    render battery  "rgba(179,255,179,0.95)" 100 "$TICK"
    render net-down "rgba(110,150,255,0.95)" ""  "$TICK"
    render net-up   "rgba(110,150,255,0.95)" ""  "$TICK"

    render user-notifs-today "rgba(110,150,255,0.95)" "" "$TICK"
    render user-poms-today   "rgba(217,179,255,0.95)" "" "$TICK"
    render user-events-today "rgba(179,255,179,0.95)" "" "$TICK"
    render user-session-min  "rgba(255,191,179,0.95)" "" "$TICK"

    # GC old SVGs (keep last 5 min worth).
    find "$OUT" -maxdepth 1 -name '*.svg' -mmin +5 -delete 2>/dev/null || true

    echo "$TICK"
    ;;
*)
    echo "Usage: $0 tick" >&2
    exit 1
    ;;
esac
