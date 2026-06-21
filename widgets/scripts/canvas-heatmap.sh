#!/usr/bin/env bash
# Emits JSON for the current month's 6×7 heatmap grid.
# Each cell: {day, klass} where klass ∈ {"muted","",t1,t2,t3,today}.
# Future: wire intensity to notif/commit/calendar density per day.
set -uo pipefail

# Year-month
Y=$(date +%Y)
M=$(date +%-m)
TODAY=$(date +%-d)

# First weekday of month (0=Sun..6=Sat) — match the mockup grid (S M T W T F S)
FIRST_WD=$(date -d "$Y-$M-01" +%w)
DAYS_IN_MONTH=$(LC_ALL=C date -d "$Y-$M-01 +1 month -1 day" +%-d)

# Previous month tail
PREV_DAYS_IN_MONTH=$(LC_ALL=C date -d "$Y-$M-01 -1 day" +%-d)

cells=()
# Leading muted cells from previous month
for ((i = FIRST_WD; i > 0; i--)); do
    d=$((PREV_DAYS_IN_MONTH - i + 1))
    cells+=("{\"day\":$d,\"klass\":\"muted\"}")
done

# Current month days; pseudo-intensity from day-hash so the heatmap reads dense
for ((d = 1; d <= DAYS_IN_MONTH; d++)); do
    if [[ $d -eq $TODAY ]]; then
        k="today"
    else
        # Cheap deterministic tier: hash by day
        h=$(( (d * 13 + 7) % 11 ))
        if   (( h < 3 )); then k=""
        elif (( h < 6 )); then k="t1"
        elif (( h < 9 )); then k="t2"
        else                   k="t3"
        fi
    fi
    cells+=("{\"day\":$d,\"klass\":\"$k\"}")
done

# Trailing muted cells from next month (pad to 42 total = 6 weeks)
total=${#cells[@]}
trailing=$((42 - total))
for ((d = 1; d <= trailing; d++)); do
    cells+=("{\"day\":$d,\"klass\":\"muted\"}")
done

# Group into 6 rows of 7 for eww's nested for-loop (no GTK flex-wrap)
printf '['
row_first=1
for ((r = 0; r < 6; r++)); do
    if (( row_first )); then row_first=0; else printf ','; fi
    printf '['
    cell_first=1
    for ((c = 0; c < 7; c++)); do
        idx=$((r * 7 + c))
        if (( cell_first )); then cell_first=0; else printf ','; fi
        printf '%s' "${cells[$idx]}"
    done
    printf ']'
done
printf ']\n'
