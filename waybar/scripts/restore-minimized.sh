#!/usr/bin/env bash
# Show minimized windows (special workspace) in rofi; restore selected to current workspace.
# Theme + anchor: shared OPTIONS treatment via scripts/lib/rofi-anchor.sh.
source ~/.config/rofi/window-helper.sh
# shellcheck source=../../scripts/lib/rofi-anchor.sh
source /etc/nixos/home/scripts/lib/rofi-anchor.sh

mapfile -t windows < <(
    hyprctl clients -j | jq -r '
        .[] | select(.workspace.name | startswith("special"))
        | "\(.address)\t\(.class)\t\(.title)"
    '
)

if [[ ${#windows[@]} -eq 0 ]]; then
    theme=$(rofi_theme_for_mode)
    anchor=$(rofi_anchor_at_cursor)
    rofi -theme "$theme" $anchor -e "No minimized windows"
    exit 0
fi

declare -A addr_map
entries=()
for entry in "${windows[@]}"; do
    IFS=$'\t' read -r addr class title <<< "$entry"
    label=$(format_label "$class" "$title")
    addr_map["$label"]="$addr"
    entries+=("$label\0icon\x1f$class")
done

theme=$(rofi_theme_for_mode)
anchor=$(rofi_anchor_at_cursor)
chosen=$(printf '%b\n' "${entries[@]}" | rofi -theme "$theme" $anchor \
    -dmenu -i -p "Minimized" -show-icons)

[[ -z "$chosen" ]] && exit 0

addr="${addr_map["$chosen"]}"
hyprctl dispatch movetoworkspace "e+0,address:$addr"
hyprctl dispatch focuswindow "address:$addr"
