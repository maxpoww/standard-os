#!/usr/bin/env bash
# Regenerate per-ring SVG files for the canvas dashboard. Reads sys-*
# caches written by system-daemon, plus canvas-wifi.sh for Wi-Fi. Output:
# /tmp/canvas-rings/{disk-root,disk-home,battery,wifi,gpu,mem}.svg
# Atomic writes (tmp+mv) so eww (image) never reads a half-written file.
# Prints a counter to stdout so the eww defpoll var changes each tick,
# forcing the image widgets to re-render and re-load the SVG.
set -uo pipefail

OUT=/tmp/canvas-rings
mkdir -p "$OUT"

# Ring circumference for r=17, stroke-width=7 — 2*pi*17 ~= 106.8; round to
# 110 for clean dasharray arithmetic. Slight visual drift acceptable.
TOTAL=110

TICK=$(date +%s)

ring() {
    local name=$1 pct_raw=$2 color=$3
    local pct=${pct_raw%%.*}
    pct=${pct:-0}
    case "$pct" in ''|*[!0-9-]*) pct=0 ;; esac
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * TOTAL / 100 ))
    local gap=$(( TOTAL - filled ))
    cat > "$OUT/$name.$TICK.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="46" height="46" viewBox="0 0 46 46">
  <circle cx="23" cy="23" r="17" stroke="rgba(255,255,255,0.18)" stroke-width="7" fill="none"/>
  <circle cx="23" cy="23" r="17" stroke="$color" stroke-width="7" stroke-linecap="round" stroke-dasharray="$filled $gap" transform="rotate(-90 23 23)" fill="none"/>
</svg>
EOF
}

# Cleanup: keep last 10 ticks' worth (~50s of history) — bounded growth.
find "$OUT" -maxdepth 1 -name '*.svg' -mmin +5 -delete 2>/dev/null || true

DR=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-disk-root 2>/dev/null || echo 0)
DH=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-disk-home 2>/dev/null || echo 0)
BT=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-battery   2>/dev/null || echo 0)
WF=$(/etc/nixos/home/widgets/scripts/canvas-wifi.sh pct 2>/dev/null || echo 0)
GP=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-gpu       2>/dev/null || echo 0)
MM=$(jq -r '.pct // 0' /tmp/waybar-cache/sys-mem       2>/dev/null || echo 0)

ring disk-root "$DR" "rgba(179,255,179,0.95)"
ring disk-home "$DH" "rgba(179,255,179,0.95)"
ring battery   "$BT" "rgba(179,255,179,0.95)"
ring wifi      "$WF" "rgba(110,150,255,0.95)"
ring gpu       "$GP" "rgba(217,179,255,0.95)"
ring mem       "$MM" "rgba(255,191,179,0.95)"

# Tick = filename suffix; printed for eww defpoll to interpolate into
# image :path, forcing GTK Image to load a unique file each cycle (no
# caching). Files older than 5 min are GC'd above.
printf '%s\n' "$TICK"
