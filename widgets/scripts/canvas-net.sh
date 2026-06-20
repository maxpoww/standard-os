#!/usr/bin/env bash
# canvas-net.sh — emit network info.
# Arg: down | up | ssid | ip | dns | vpn
# Down/up = MB/s over a 1 s window using /proc/net/dev (default interface).

set -uo pipefail
field="${1:-down}"

case "$field" in
  ssid)
    nmcli -t -f IN-USE,SSID device wifi 2>/dev/null | awk -F: '/^\*/{print $2; exit}' || echo "—"
    ;;
  ip)
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="src"){print $(i+1);exit}}' || echo "—"
    ;;
  dns)
    awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || echo "—"
    ;;
  vpn)
    if ip link show 2>/dev/null | grep -qE '(wg|tun|tap)'; then echo "on"; else echo "off"; fi
    ;;
  down|up)
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [ -z "$iface" ] && { echo "—"; exit 0; }
    read -r r1 _ _ _ _ _ _ _ t1 < <(awk -v i="$iface:" '$1==i{for(j=2;j<=NF;j++)printf "%s ",$j;print ""}' /proc/net/dev)
    sleep 1
    read -r r2 _ _ _ _ _ _ _ t2 < <(awk -v i="$iface:" '$1==i{for(j=2;j<=NF;j++)printf "%s ",$j;print ""}' /proc/net/dev)
    if [ "$field" = "down" ]; then
      kb=$(( (r2 - r1) / 1024 ))
    else
      kb=$(( (t2 - t1) / 1024 ))
    fi
    # >1000 KB/s → show as MB/s with one decimal.
    if [ "$kb" -ge 1000 ]; then
      awk -v k="$kb" 'BEGIN{printf "%.1f MB/s", k/1024}'
    else
      printf '%d KB/s' "$kb"
    fi
    ;;
  *) echo "—" ;;
esac
exit 0
