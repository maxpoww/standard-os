#!/usr/bin/env bash
# Side-by-side: swap left, fallback right.
# Stacked: togglesplit to go side-by-side, then ensure focused is on the left.

eval "$(hyprctl activewindow -j | jq -r '@sh "addr=\(.address) ax=\(.at[0]) ay=\(.at[1]) ws=\(.workspace.id)"')"

neighbors=$(hyprctl clients -j | jq --argjson ws "$ws" --arg addr "$addr" --argjson ax "$ax" --argjson ay "$ay" \
  '{ left:  [.[] | select(.workspace.id == $ws and .address != $addr and .at[0] < $ax)] | length > 0,
     right: [.[] | select(.workspace.id == $ws and .address != $addr and .at[0] > $ax)] | length > 0,
     above: [.[] | select(.workspace.id == $ws and .address != $addr and .at[1] < $ay)] | length > 0,
     below: [.[] | select(.workspace.id == $ws and .address != $addr and .at[1] > $ay)] | length > 0 }')

has() { echo "$neighbors" | jq -r ".$1"; }

if [ "$(has above)" = "true" ] || [ "$(has below)" = "true" ]; then
  # Stacked — toggle to side-by-side
  hyprctl dispatch togglesplit
  sleep 0.1
  # If focused ended up on the right, swap left
  new_x=$(hyprctl activewindow -j | jq '.at[0]')
  [ "$new_x" -gt 5 ] 2>/dev/null && hyprctl dispatch swapwindow l
elif [ "$(has left)" = "true" ]; then
  hyprctl dispatch swapwindow l
elif [ "$(has right)" = "true" ]; then
  hyprctl dispatch swapwindow r
fi
