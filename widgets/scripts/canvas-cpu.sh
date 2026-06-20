#!/usr/bin/env bash
# canvas-cpu.sh — emit CPU info.
# Arg: pct | temp | fan | uptime | procs | boot
# pct = busy % over 1 s window from /proc/stat.

set -uo pipefail
field="${1:-pct}"

case "$field" in
  pct)
    read -r _ u1 n1 s1 i1 _ < /proc/stat
    sleep 1
    read -r _ u2 n2 s2 i2 _ < /proc/stat
    busy1=$((u1 + n1 + s1))
    busy2=$((u2 + n2 + s2))
    idle1=$i1
    idle2=$i2
    delta_total=$((busy2 - busy1 + idle2 - idle1))
    delta_busy=$((busy2 - busy1))
    [ "$delta_total" -eq 0 ] && { echo 0; exit 0; }
    echo $(( (delta_busy * 100) / delta_total ))
    ;;
  temp)
    # Sum of zone0; fallback to "—".
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) && { echo $((t / 1000))°C; exit 0; }
    echo "—"
    ;;
  fan)
    f=$(cat /sys/class/hwmon/hwmon*/fan1_input 2>/dev/null | head -1)
    if [ -n "$f" ]; then echo "${f} RPM"; else echo "—"; fi
    ;;
  uptime)
    awk '{ s=$1; d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "%dd %dh %dm\n", d, h, m }' /proc/uptime
    ;;
  procs)
    ls -1 /proc 2>/dev/null | grep -c '^[0-9]\+$' || echo 0
    ;;
  boot)
    who -b 2>/dev/null | awk '{print $3" "$4}' || echo "—"
    ;;
  *) echo "—" ;;
esac
exit 0
