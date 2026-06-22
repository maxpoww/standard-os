#!/usr/bin/env bash
# canvas-pie.sh -- generate donut SVG charts for User-section pie row.
#
# Usage: canvas-pie.sh tick
#   Reads source data + writes /tmp/canvas-pies/<metric>.<tick>.svg.
#   Prints the tick for eww's defpoll var.
#
# Metrics:
#   memory       used / cached / free (from /proc/meminfo)
#   ws-dist      windows per workspace (hyprctl clients)
#   app-dist     windows per class, top 5 (hyprctl clients)
#   pomodoro     done / remaining of today's target
#   notif-dist   notifications per app, top 5

set -uo pipefail

OUT=/tmp/canvas-pies
mkdir -p "$OUT"

R=18        # ring radius
SW=8        # stroke width
SIZE=46
CX=23
CY=23
TOTAL_LEN=113 # 2 * pi * 18 ~= 113.1

# Slice palette -- cycles if more slices than colors.
COLORS=(
    "rgba(110,150,255,0.95)"
    "rgba(217,179,255,0.95)"
    "rgba(179,255,179,0.95)"
    "rgba(255,191,179,0.95)"
    "rgba(255,230,179,0.95)"
    "rgba(255,179,179,0.95)"
)

write_pie() {
    # write_pie <metric> <tick> [<label1>:<value1> ...]
    local metric=$1 tick=$2
    shift 2

    local -a values=()
    local total=0 v
    for arg in "$@"; do
        v=${arg#*:}
        v=${v%%.*}
        case "$v" in '' | *[!0-9]*) v=0 ;; esac
        values+=("$v")
        ((total += v))
    done
    ((total == 0)) && total=1

    # Background track + foreground arcs.
    local arcs="<circle cx=\"$CX\" cy=\"$CY\" r=\"$R\" fill=\"none\" stroke=\"rgba(255,255,255,0.10)\" stroke-width=\"$SW\"/>"
    local acc_angle=0 i n=${#values[@]}
    for ((i = 0; i < n; i++)); do
        v=${values[i]}
        ((v == 0)) && continue
        local arc_len=$((v * TOTAL_LEN / total))
        local gap=$((TOTAL_LEN - arc_len))
        local color=${COLORS[i % ${#COLORS[@]}]}
        arcs+="<circle cx=\"$CX\" cy=\"$CY\" r=\"$R\" fill=\"none\" stroke=\"$color\" stroke-width=\"$SW\" stroke-linecap=\"butt\" stroke-dasharray=\"$arc_len $gap\" transform=\"rotate(-90 $CX $CY) rotate($acc_angle $CX $CY)\"/>"
        local angle_inc=$((v * 360 / total))
        ((acc_angle += angle_inc))
    done

    local tmp="$OUT/$metric.$tick.svg.tmp"
    cat >"$tmp" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$SIZE" height="$SIZE" viewBox="0 0 $SIZE $SIZE">
$arcs
</svg>
EOF
    mv -f "$tmp" "$OUT/$metric.$tick.svg"
}

write_placeholder() {
    local metric
    for metric in memory ws-dist app-dist pomodoro notif-dist; do
        local f="$OUT/$metric.0.svg"
        [[ -f $f ]] && continue
        cat >"$f" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$SIZE" height="$SIZE" viewBox="0 0 $SIZE $SIZE">
  <circle cx="$CX" cy="$CY" r="$R" fill="none" stroke="rgba(255,255,255,0.15)" stroke-width="$SW"/>
</svg>
EOF
    done
}

write_placeholder

case "${1:-}" in
tick)
    TICK=$(date +%s)

    # MEMORY pie -- used / cached / free
    if [[ -r /proc/meminfo ]]; then
        total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
        avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
        cached_kb=$(awk '/^Cached:/ {print $2; exit}' /proc/meminfo)
        used_kb=$((total_kb - avail_kb))
        ((used_kb < 0)) && used_kb=0
        free_kb=$((avail_kb - cached_kb))
        ((free_kb < 0)) && free_kb=0
        write_pie memory "$TICK" \
            "used:$used_kb" \
            "cached:$cached_kb" \
            "free:$free_kb"
    fi

    if command -v hyprctl >/dev/null && command -v jq >/dev/null; then
        # WS-DIST pie -- count windows per workspace id.
        ws_pairs=$(hyprctl clients -j 2>/dev/null |
            jq -r 'group_by(.workspace.id) | map("ws\(.[0].workspace.id):\(length)") | .[]' \
                2>/dev/null || true)
        if [[ -n $ws_pairs ]]; then
            mapfile -t ws_args <<<"$ws_pairs"
            write_pie ws-dist "$TICK" "${ws_args[@]}"
        fi

        # APP-DIST pie -- top 5 window classes by count.
        app_pairs=$(hyprctl clients -j 2>/dev/null |
            jq -r 'group_by(.class) | map({c: .[0].class, n: length}) | sort_by(-.n) | .[0:5] | .[] | "\(.c):\(.n)"' \
                2>/dev/null || true)
        if [[ -n $app_pairs ]]; then
            mapfile -t app_args <<<"$app_pairs"
            write_pie app-dist "$TICK" "${app_args[@]}"
        fi
    fi

    # POMODORO pie -- done / remaining of today's target.
    pom_done=$(jq -r '.blocks_completed_today // 0' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo 0)
    pom_target=$(jq -r '.blocks_target // 4' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo 4)
    pom_left=$((pom_target - pom_done))
    ((pom_left < 0)) && pom_left=0
    write_pie pomodoro "$TICK" "done:$pom_done" "left:$pom_left"

    # NOTIF-DIST pie -- top 5 notif apps from history.
    if [[ -r /tmp/waybar-cache/notif-history.json ]]; then
        notif_pairs=$(jq -r '
            .entries // []
            | group_by(.app)
            | map({a: .[0].app, n: length})
            | sort_by(-.n)
            | .[0:5]
            | .[]
            | "\(.a):\(.n)"' /tmp/waybar-cache/notif-history.json 2>/dev/null || true)
        if [[ -n $notif_pairs ]]; then
            mapfile -t notif_args <<<"$notif_pairs"
            write_pie notif-dist "$TICK" "${notif_args[@]}"
        fi
    fi

    # GC older than 5 min.
    find "$OUT" -maxdepth 1 -name '*.svg' -mmin +5 -delete 2>/dev/null || true

    echo "$TICK"
    ;;
*)
    echo "Usage: $0 tick" >&2
    exit 1
    ;;
esac
