# notif-hypr.sh — Hyprland adapter for notif-menu.
#
# All hyprctl calls in the menu codebase go through here so tests can
# mock by overriding `hyprctl` as a bash function before sourcing.

# hypr_focus_by_class CLASS
# Lowercases CLASS, then finds the FIRST Hyprland window whose own class
# (lowercased) contains it as a substring. On hit, dispatches
# `focuswindow address:<addr>` (Hyprland switches workspace automatically
# if the target is elsewhere). Returns 0 on hit, 1 on miss / hyprctl
# error / malformed JSON.
hypr_focus_by_class() {
    local needle="${1,,}"   # lowercase
    local addr
    addr=$(hyprctl -j clients 2>/dev/null \
        | jq -r --arg n "$needle" '
            .[]? | select((.class // "" | ascii_downcase) | contains($n))
                 | .address' 2>/dev/null \
        | head -1)
    [[ -z $addr ]] && return 1
    hyprctl dispatch focuswindow "address:$addr" 2>/dev/null
    return 0
}
