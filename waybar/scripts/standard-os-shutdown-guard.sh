#!/usr/bin/env bash
# standard-os-shutdown-guard: gates user-initiated power actions on
# rebuild-pending state. If working tree at /etc/nixos/home is ahead of
# the activated generation, surface a rofi modal letting the user choose
# (rebuild+action / action-anyway / cancel). Otherwise forward immediately.
#
# usage: standard-os-shutdown-guard <action>
#   action ∈ {sleep, hibernate, reboot, poweroff}
#
# DRY_RUN=1 prints "would-exec: <cmd>" instead of running. Used by tests.
set -euo pipefail

action="${1:-}"
case "$action" in
    sleep)     cmd=(systemctl suspend) ;;
    hibernate) cmd=(systemctl hibernate) ;;
    reboot)    cmd=(systemctl reboot) ;;
    poweroff)  cmd=(systemctl poweroff) ;;
    *) echo "usage: $0 <sleep|hibernate|reboot|poweroff>" >&2; exit 2 ;;
esac

check_rebuild_pending() {
    [ -f /run/standard-os/activated-commit ] || return 1
    local activated head
    activated=$(cat /run/standard-os/activated-commit 2>/dev/null) || return 1
    head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null) || return 1
    [ "$activated" = "$head" ] && return 1
    git -C /etc/nixos/home merge-base --is-ancestor "$activated" HEAD 2>/dev/null
    case $? in
        0|1) return 0 ;;
        *)   return 1 ;;
    esac
}

run_or_dry() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "would-exec: $*"
    else
        exec "$@"
    fi
}

# Reboot click: never prompt. Click intent is authoritative; rebuild
# handling belongs to the UPDATE pipeline (background, no user
# interaction), not the click path. Any uncompiled commits past
# activated-commit ride the next rebuild cycle.
if [ "$action" = "reboot" ]; then
    run_or_dry "${cmd[@]}"
    exit 0
fi

if ! check_rebuild_pending; then
    run_or_dry "${cmd[@]}"
    exit 0
fi

# Pending: rofi modal.
activated=$(cat /run/standard-os/activated-commit)
ahead=$(git -C /etc/nixos/home rev-list --count "$activated..HEAD" 2>/dev/null || echo "?")
last=$(git -C /etc/nixos/home log -1 --format='%h %s' HEAD)
prompt="Pending rebuild: $ahead commit(s) ahead\nLast: $last"

choice=$(printf '%s\n' \
    "Rebuild + then $action" \
    "$action anyway" \
    "Cancel" \
    | rofi -dmenu -p "shutdown" -mesg "$prompt" -theme-str 'window {width: 600px;}')

case "$choice" in
    "Rebuild + then $action")
        if [ "${DRY_RUN:-0}" = "1" ]; then
            echo "would-exec: terminal: sudo nixos-rebuild switch && ${cmd[*]}"
        else
            kitty --hold sh -c "sudo nixos-rebuild switch && ${cmd[*]}"
        fi
        ;;
    "$action anyway")
        run_or_dry "${cmd[@]}"
        ;;
    *)  # Cancel or empty
        exit 0
        ;;
esac
