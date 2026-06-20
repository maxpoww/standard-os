#!/usr/bin/env bash
# canvas-mem.sh — emit memory metric.
# Mode "pct" (default): integer percent
# Mode "used": "9.7G" style
# Mode "total": "16G" style

set -uo pipefail
mode="${1:-pct}"

# /proc/meminfo values are in kB.
total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 1)
avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
used=$((total - avail))

case "$mode" in
  pct)   echo $(( (used * 100) / total )) ;;
  used)  awk -v u="$used"   'BEGIN { printf "%.1fG\n", u/1024/1024 }' ;;
  total) awk -v t="$total"  'BEGIN { printf "%.0fG\n", t/1024/1024 }' ;;
  *) echo "0" ;;
esac
exit 0
