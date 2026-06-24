#!/usr/bin/env bash
# canvas-cal.sh — emit current month as a flat 42-cell JSON array,
# Monday-first, with klass per cell.
#
#   k = "muted"  — day belongs to previous or next month
#   k = "today"  — today's date in the current month
#   k = ""       — ordinary day in the current month
#
# Used by the Max section's CALENDAR card. Cell shape is {"d":"23","k":"today"}.
# 42 cells = 6 weeks × 7 days, the standard "month with surrounding context"
# grid the v31 mockup specifies.
#
# A future pass should add klass="has" when the day carries an agenda event;
# that lookup needs the cal-source-daemon to write per-day counts.

set -eu

today_y=$(date +%Y)
today_m=$(date +%-m)
today_d=$(date +%-d)

# First day of this month, as weekday 1..7 with Monday=1, Sunday=7.
first_dow=$(date -d "${today_y}-${today_m}-01" +%u)

# Days in this month + prev month.
days_this=$(date -d "${today_y}-${today_m}-01 +1 month -1 day" +%-d)
days_prev=$(date -d "${today_y}-${today_m}-01 -1 day" +%-d)

# How many trailing days of the previous month fill the first row.
lead=$(( first_dow - 1 ))

cells=()

# Previous-month tail (muted).
for (( i = lead; i > 0; i-- )); do
  cells+=("{\"d\":\"$(( days_prev - i + 1 ))\",\"k\":\"muted\"}")
done

# Current-month days.
for (( d = 1; d <= days_this; d++ )); do
  if [ "$d" = "$today_d" ]; then
    cells+=("{\"d\":\"$d\",\"k\":\"today\"}")
  else
    cells+=("{\"d\":\"$d\",\"k\":\"\"}")
  fi
done

# Next-month head (muted) to pad to 42 cells.
filled=$(( lead + days_this ))
pad=$(( 42 - filled ))
for (( d = 1; d <= pad; d++ )); do
  cells+=("{\"d\":\"$d\",\"k\":\"muted\"}")
done

# Emit as {"rows":[[...7...],[...7...],...,6 rows]} — yuck iterates rows
# directly, no array-slicing needed in the widget.
out='{"rows":['
for (( r = 0; r < 6; r++ )); do
  if [ $r -gt 0 ]; then out+=','; fi
  out+='['
  for (( c = 0; c < 7; c++ )); do
    if [ $c -gt 0 ]; then out+=','; fi
    out+="${cells[$(( r * 7 + c ))]}"
  done
  out+=']'
done
out+=']}'
printf '%s\n' "$out"
