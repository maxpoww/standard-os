#!/usr/bin/env bash
# canvas-chart.sh -- larger SVG bar charts for User-section history rows.
#
# Usage: canvas-chart.sh tick
#   Reads source data and writes one chart SVG per metric to
#   /tmp/canvas-charts/<metric>.<tick>.svg. Prints the tick.
#
# Chart types:
#   notifs-7d    notifications received per day, last 7 days
#   pomodoros-7d pomodoros completed per day, last 7 days (today only)

set -uo pipefail

OUT=/tmp/canvas-charts
mkdir -p "$OUT"

# Wide chart sized to fill section width on common monitors. Card padding
# at the eww layer trims the visible area on smaller screens.
W=1500
H=120
PAD_X=20
PAD_Y=14
LABEL_H=14
BAR_AREA_H=$((H - PAD_Y * 2 - LABEL_H))

render_bar_chart() {
    local metric=$1 tick=$2 color=$3
    shift 3

    local -a labels=() values=()
    local max=0 v lbl arg
    for arg in "$@"; do
        lbl=${arg%%:*}
        v=${arg#*:}
        v=${v%%.*}
        case "$v" in '' | *[!0-9]*) v=0 ;; esac
        labels+=("$lbl")
        values+=("$v")
        ((v > max)) && max=$v
    done
    ((max == 0)) && max=1

    local n=${#values[@]}
    ((n == 0)) && return

    local bar_area_w=$((W - PAD_X * 2))
    local slot_w=$((bar_area_w / n))
    local bar_w=$((slot_w * 7 / 10))
    local bar_gap=$((slot_w - bar_w))
    local bar_x_offset=$((bar_gap / 2))

    local content="" i x y h_val text_y label_y center_x
    label_y=$((PAD_Y + BAR_AREA_H + LABEL_H + 2))
    for ((i = 0; i < n; i++)); do
        v=${values[i]}
        x=$((PAD_X + i * slot_w + bar_x_offset))
        h_val=$((v * BAR_AREA_H / max))
        ((h_val < 2 && v > 0)) && h_val=2
        y=$((PAD_Y + BAR_AREA_H - h_val))
        center_x=$((x + bar_w / 2))
        content+="<rect x=\"$x\" y=\"$y\" width=\"$bar_w\" height=\"$h_val\" fill=\"$color\" rx=\"4\"/>"
        text_y=$((y - 6))
        ((text_y < 14)) && text_y=14
        content+="<text x=\"$center_x\" y=\"$text_y\" text-anchor=\"middle\" font-size=\"11\" font-family=\"MesloLGS NF, monospace\" fill=\"rgba(255,255,255,0.85)\">$v</text>"
        content+="<text x=\"$center_x\" y=\"$label_y\" text-anchor=\"middle\" font-size=\"10\" font-family=\"MesloLGS NF, monospace\" fill=\"rgba(255,255,255,0.45)\" letter-spacing=\"1\">${labels[i]}</text>"
    done

    content="<line x1=\"$PAD_X\" y1=\"$((PAD_Y + BAR_AREA_H))\" x2=\"$((W - PAD_X))\" y2=\"$((PAD_Y + BAR_AREA_H))\" stroke=\"rgba(255,255,255,0.08)\" stroke-width=\"1\"/>$content"

    local tmp="$OUT/$metric.$tick.svg.tmp"
    cat >"$tmp" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H">
$content
</svg>
EOF
    mv -f "$tmp" "$OUT/$metric.$tick.svg"
}

render_trend_from_buffer() {
    # Reads the last 14 readings of a canvas-sparkline.sh ring buffer and
    # renders them as a wide bar chart via render_bar_chart. Used for
    # battery / net-down / net-up trends.
    local source=$1 tick=$2 color=$3 metric=$4
    local buf="/tmp/canvas-spark-data/$source.dat"
    [[ -r $buf ]] || return
    local -a vals
    mapfile -t vals <"$buf"
    local n=${#vals[@]}
    ((n == 0)) && return
    local start=$((n > 14 ? n - 14 : 0))
    local -a args=() i offset label
    for ((i = start; i < n; i++)); do
        offset=$(((n - 1) - i))
        if ((offset == 0)); then
            label="now"
        else
            label="-${offset}"
        fi
        args+=("$label:${vals[i]}")
    done
    render_bar_chart "$metric" "$tick" "$color" "${args[@]}"
}

write_placeholder() {
    local metric
    for metric in notifs-7d pomodoros-7d battery-trend net-down-trend net-up-trend; do
        local f="$OUT/$metric.0.svg"
        [[ -f $f ]] && continue
        cat >"$f" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H">
  <line x1="$PAD_X" y1="$((H - PAD_Y - LABEL_H))" x2="$((W - PAD_X))" y2="$((H - PAD_Y - LABEL_H))" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>
  <text x="$((W / 2))" y="$((H / 2))" text-anchor="middle" font-size="11" font-family="MesloLGS NF, monospace" fill="rgba(255,255,255,0.30)">awaiting data</text>
</svg>
EOF
    done
}

write_placeholder

case "${1:-}" in
tick)
    TICK=$(date +%s)

    # NOTIFS 7-DAY
    if [[ -r /tmp/waybar-cache/notif-history.json ]]; then
        labels=()
        counts=()
        for ((d = 6; d >= 0; d--)); do
            day_label=$(date -d "$d days ago" +%a)
            day_prefix=$(date -d "$d days ago" +%Y-%m-%d)
            count=$(jq -r --arg p "$day_prefix" '
                (.entries // [])
                | map(select((.ts // "") | startswith($p)))
                | length' /tmp/waybar-cache/notif-history.json 2>/dev/null || echo 0)
            labels+=("$day_label")
            counts+=("$count")
        done
        args=()
        for ((i = 0; i < 7; i++)); do
            args+=("${labels[i]}:${counts[i]}")
        done
        render_bar_chart notifs-7d "$TICK" "rgba(110,150,255,0.85)" "${args[@]}"
    fi

    # POMODOROS 7-DAY -- placeholder until a daily-persisted journal exists.
    pom_today=$(jq -r '.blocks_completed_today // 0' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo 0)
    args=()
    for ((d = 6; d >= 0; d--)); do
        day_label=$(date -d "$d days ago" +%a)
        if ((d == 0)); then
            args+=("$day_label:$pom_today")
        else
            args+=("$day_label:0")
        fi
    done
    render_bar_chart pomodoros-7d "$TICK" "rgba(217,179,255,0.85)" "${args[@]}"

    # BATTERY TREND -- reuse the sparkline buffer (last 14 readings).
    render_trend_from_buffer battery "$TICK" "rgba(179,255,179,0.85)" battery-trend

    # NET DOWN/UP TREND -- same pattern, KB/s deltas from spark buffer.
    render_trend_from_buffer net-down "$TICK" "rgba(110,150,255,0.85)" net-down-trend
    render_trend_from_buffer net-up   "$TICK" "rgba(217,179,255,0.85)" net-up-trend

    find "$OUT" -maxdepth 1 -name '*.svg' -mmin +5 -delete 2>/dev/null || true
    echo "$TICK"
    ;;
*)
    echo "Usage: $0 tick" >&2
    exit 1
    ;;
esac
