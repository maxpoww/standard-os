#!/usr/bin/env bash
# canvas-media.sh — best-effort media metadata via playerctl.
# Argument selects field: title | artist | album | status | source | pos | len | pct
# Returns empty string (and exits 0) if no player.

set -uo pipefail

field="${1:-title}"

# Fail soft if playerctl unavailable.
command -v playerctl >/dev/null 2>&1 || { echo ""; exit 0; }

# Fail soft if no active player.
playerctl status >/dev/null 2>&1 || { echo ""; exit 0; }

case "$field" in
  title)  playerctl metadata --format '{{title}}'  2>/dev/null || echo "" ;;
  artist) playerctl metadata --format '{{artist}}' 2>/dev/null || echo "" ;;
  album)  playerctl metadata --format '{{album}}'  2>/dev/null || echo "" ;;
  status)
    s=$(playerctl status 2>/dev/null || echo "Stopped")
    case "$s" in Playing) echo "⏸" ;; Paused) echo "⏵" ;; *) echo "⏵" ;; esac
    ;;
  source)
    # Player name → uppercase tag.
    p=$(playerctl -l 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]')
    echo "${p:-—} · NOW PLAYING"
    ;;
  pos)
    secs=$(playerctl position 2>/dev/null | awk '{printf "%d", $1}')
    [ -z "$secs" ] && { echo "—:—"; exit 0; }
    printf '%d:%02d\n' $((secs / 60)) $((secs % 60))
    ;;
  len)
    secs=$(playerctl metadata --format '{{ mpris:length }}' 2>/dev/null)
    [ -z "$secs" ] && { echo "—:—"; exit 0; }
    secs=$((secs / 1000000))
    printf '%d:%02d\n' $((secs / 60)) $((secs % 60))
    ;;
  pct)
    pos=$(playerctl position 2>/dev/null | awk '{printf "%d", $1}')
    len=$(playerctl metadata --format '{{ mpris:length }}' 2>/dev/null)
    if [ -z "$pos" ] || [ -z "$len" ] || [ "$len" = "0" ]; then echo "0"; exit 0; fi
    len_sec=$((len / 1000000))
    [ "$len_sec" -eq 0 ] && { echo "0"; exit 0; }
    echo $(( (pos * 100) / len_sec ))
    ;;
  *) echo "" ;;
esac
exit 0
