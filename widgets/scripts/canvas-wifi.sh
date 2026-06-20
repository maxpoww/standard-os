#!/usr/bin/env bash
# canvas-wifi.sh — emit Wi-Fi signal as a 4-bar glyph.
# Mode "bars" (default): ▮▮▮▮ / ▮▮▮▯ / ▮▮▯▯ / ▮▯▯▯ / ▯▯▯▯
# Mode "pct": integer percent.

set -uo pipefail
mode="${1:-bars}"

# Try IN-USE first (the connected SSID), else first available.
sig=$(nmcli -t -f IN-USE,SIGNAL device wifi list 2>/dev/null | awk -F: '/^\*/{print $2; exit}')
[ -z "$sig" ] && sig=$(nmcli -t -f SIGNAL device wifi list 2>/dev/null | awk -F: 'NR==1{print $1}')
[ -z "$sig" ] && sig=0

case "$mode" in
  pct)  echo "$sig" ;;
  bars)
    if   [ "$sig" -ge 75 ]; then echo "▮▮▮▮"
    elif [ "$sig" -ge 50 ]; then echo "▮▮▮▯"
    elif [ "$sig" -ge 25 ]; then echo "▮▮▯▯"
    elif [ "$sig" -gt  0 ]; then echo "▮▯▯▯"
    else                         echo "▯▯▯▯"; fi
    ;;
  *) echo "0" ;;
esac
exit 0
