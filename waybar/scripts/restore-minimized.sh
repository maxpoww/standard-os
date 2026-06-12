#!/usr/bin/env bash
# Show minimized windows (special workspace) in rofi; restore selected to current workspace.
source ~/.config/rofi/window-helper.sh

mapfile -t windows < <(
    hyprctl clients -j | jq -r '
        .[] | select(.workspace.name | startswith("special"))
        | "\(.address)\t\(.class)\t\(.title)"
    '
)

[[ ${#windows[@]} -eq 0 ]] && { rofi -e "No minimized windows"; exit 0; }

declare -A addr_map
entries=()
for entry in "${windows[@]}"; do
    IFS=$'\t' read -r addr class title <<< "$entry"
    label=$(format_label "$class" "$title")
    addr_map["$label"]="$addr"
    entries+=("$label\0icon\x1f$class")
done

chosen=$(printf '%b\n' "${entries[@]}" | rofi -dmenu -i -p "Minimized" -show-icons \
    -theme-str 'window {padding: 35px 30% 40%;}')

[[ -z "$chosen" ]] && exit 0

addr="${addr_map["$chosen"]}"
hyprctl dispatch movetoworkspace "e+0,address:$addr"
hyprctl dispatch focuswindow "address:$addr"
