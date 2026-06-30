#!/usr/bin/env bash
# standard-os-shutdown-guard: thin dispatcher for power actions invoked
# from OPTIONS (power-pill on-click, reboot-prompt, SUPER+ESC menu).
#
# Rebuild-pending gating was retired 2026-06-13: the UPDATE pipeline now
# rebuilds in the background (silently, passwordless via pkexec), so no
# user-facing gate is needed before a power transition. Any uncompiled
# commits past activated-commit ride the next rebuild cycle.
#
# usage: standard-os-shutdown-guard <sleep|hibernate|reboot|poweroff>
#
# DRY_RUN=1 prints "would-exec: <cmd>" instead of running.
set -euo pipefail

action="${1:-}"
case "$action" in
    sleep)     cmd=(systemctl suspend) ;;
    hibernate) cmd=(systemctl hibernate) ;;
    reboot)    cmd=(systemctl reboot) ;;
    poweroff)  cmd=(systemctl poweroff) ;;
    *) echo "usage: $0 <sleep|hibernate|reboot|poweroff>" >&2; exit 2 ;;
esac

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "would-exec: ${cmd[*]}"
else
    exec "${cmd[@]}"
fi
