#!/usr/bin/env bash
# power-pill — emit the JSON for one of the power-cluster pills (parent,
# reboot child, or hibernate child), branched on whether the system is in
# "reboot-pending" state (current-system != booted-system, modulo the
# user's dismiss marker for the current booted gen).
#
# Two modes per slot — six branches total, plus the `click` subcommand
# for the parent's branched on-click.
#
# usage:
#   power-pill power          # parent JSON (hibernate face / reboot face)
#   power-pill reboot         # reboot-child JSON (visible only in normal)
#   power-pill hibernate      # hibernate-child JSON (visible only when pending)
#   power-pill click power    # branch parent click → shutdown-guard {hibernate|reboot}
#
# State source is direct, not the /tmp/waybar-cache/reboot-pending file —
# the cache file's `text` field is empty in both branches today (see
# waybar-self-test.sh) which trips the "text=empty hides the module"
# hazard. readlink + string-compare costs ~nothing.

set -euo pipefail

# Canonical pill helpers — pill_emit auto-substitutes the live dark|light
# token from /tmp/glass-mode so every face below re-themes on glass flips.
# The nix install rewrites this source line to the absolute store path; see
# modules/waybar.nix installPhase.
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

DISMISS_MARKER="/run/standard-os/reboot-dismissed"

# Hibernate glyph: U+F011 (FA "power-off") — matches what custom/power
# already renders in normal mode and what waybar-self-test uses for its
# reboot-pending cache. Reboot glyph: U+F0709 (Nerd-Font "reboot") —
# matches the existing custom/reboot child face.
HIBERNATE_GLYPH=$'\xef\x80\x91'           # U+F011
REBOOT_GLYPH=$'\xf3\xb0\x9c\x89'          # U+F0709

is_reboot_pending() {
    local current booted dismissed
    current=$(readlink /run/current-system 2>/dev/null) || return 1
    booted=$(readlink /run/booted-system 2>/dev/null) || return 1
    [ "$current" = "$booted" ] && return 1
    if [ -r "$DISMISS_MARKER" ]; then
        dismissed=$(<"$DISMISS_MARKER")
        [ "$dismissed" = "$booted" ] && return 1
    fi
    return 0
}

emit_empty() {
    printf '{"text":"","class":["empty"]}\n'
}

slot="${1:?usage: power-pill <power|reboot|hibernate|click>}"

# Branched on-click for the parent. The reboot/hibernate children have
# static on-clicks in config.jsonc — they're each only visible in their
# own mode, so no branch needed there.
if [ "$slot" = "click" ]; then
    target="${2:?usage: power-pill click <power>}"
    if [ "$target" != "power" ]; then
        echo "power-pill click: only 'power' is branched" >&2
        exit 2
    fi
    if is_reboot_pending; then
        exec standard-os-shutdown-guard reboot
    else
        exec standard-os-shutdown-guard hibernate
    fi
fi

mode=normal
is_reboot_pending && mode=pending

theme="$(pill_theme)"

case "$slot:$mode" in
    power:normal)
        pill_emit "$HIBERNATE_GLYPH" \
            "$(pill_class "opt-pill" "$theme" "opt-hover-red")" \
            "Hibernate"
        ;;
    power:pending)
        pill_emit "$REBOOT_GLYPH" \
            "$(pill_class "opt-pill" "$theme" "opt-pin-yellow")" \
            "Reboot to finalize updates"
        ;;
    reboot:normal)
        pill_emit "$REBOOT_GLYPH" \
            "$(pill_class "opt-pill-child" "$theme" "opt-middle")" \
            "Reboot"
        ;;
    reboot:pending)
        emit_empty
        ;;
    hibernate:normal)
        emit_empty
        ;;
    hibernate:pending)
        pill_emit "$HIBERNATE_GLYPH" \
            "$(pill_class "opt-pill-child" "$theme" "opt-no")" \
            "Hibernate"
        ;;
    *)
        echo "power-pill: unknown slot '$slot' (want power|reboot|hibernate|click)" >&2
        exit 2
        ;;
esac
