#!/usr/bin/env bash
# Pill click handler for custom/rebuild-pending: opens a rofi dialog with
# rebuild-now / view-commits / dismiss. Called when the user clicks the
# orange-pin sync-glyph pill in SYSTEM zone.
set -euo pipefail

if ! [ -f /run/standard-os/activated-commit ]; then
    notify-send "Standard-OS" "No activated-commit tracking; nothing to prompt."
    exit 0
fi

activated=$(cat /run/standard-os/activated-commit)
head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$activated" = "$head" ]; then
    notify-send "Standard-OS" "Working tree already matches activated generation."
    exit 0
fi

ahead=$(git -C /etc/nixos/home rev-list --count "$activated..HEAD" 2>/dev/null || echo "?")
last=$(git -C /etc/nixos/home log -1 --format='%h %s' HEAD)
prompt="$ahead commit(s) ahead\nLast: $last"

choice=$(printf '%s\n' \
    "Rebuild now (terminal)" \
    "View commits ahead" \
    "Dismiss" \
    | rofi -dmenu -p "rebuild" -mesg "$prompt" -theme-str 'window {width: 600px;}')

case "$choice" in
    "Rebuild now (terminal)")
        kitty --hold sh -c "sudo nixos-rebuild switch"
        ;;
    "View commits ahead")
        kitty --hold sh -c "git -C /etc/nixos/home log --oneline $activated..HEAD"
        ;;
    *) exit 0 ;;
esac
