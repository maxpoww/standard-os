#!/usr/bin/env bash
# waybar-self-test: verify the bar's runtime invariants and surface
# failures via a SYSTEM-zone pill. Kicked by waybar-self-test.timer
# every 60s and on demand via click handler.
set -euo pipefail

# Resolve lib path. When invoked via makeWrapper, $0 is the wrapper;
# the libexec script's source line is substituted to absolute path
# at build time.
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

REQUIRED_UNITS=(waybar waybar-glass-text-daemon waybar-workspace-daemon)
REQUIRED_CACHES=(ws-current window notif-bell)
REQUIRED_FILES=(/tmp/glass-mode)

failures=()

for u in "${REQUIRED_UNITS[@]}"; do
  if ! systemctl --user is-active --quiet "$u"; then
    state=$(systemctl --user is-active "$u" 2>/dev/null || true)
    failures+=("$u: $state")
  fi
done

for f in "${REQUIRED_CACHES[@]}"; do
  [ -s "/tmp/waybar-cache/$f" ] || failures+=("cache/$f: missing-or-empty")
done

for f in "${REQUIRED_FILES[@]}"; do
  [ -e "$f" ] || failures+=("$f: missing")
done

if [ "${#failures[@]}" -eq 0 ]; then
  # Healthy: empty text → waybar hides the module entirely.
  pill_write waybar-self-test "" "opt-pill" ""
else
  tooltip=$(printf 'Self-test failures:\n%s\n' "$(printf '• %s\n' "${failures[@]}")")
  pill_write waybar-self-test "⚠ ${#failures[@]}" "opt-pill opt-no" "$tooltip"
fi

# ---- reboot-pending check ----
# Fires when /run/current-system != /run/booted-system AND the user has
# not dismissed for the current booted gen. The check runs every self-test
# tick (60s default) so the pill appears within ~1min of a successful
# update activating a new gen.

DISMISS_MARKER="/run/standard-os/reboot-dismissed"
# FA power glyph (U+F011) — 3 bytes UTF-8.
POWER_GLYPH=$'\xef\x80\x91'

check_reboot_pending() {
    local current booted
    current=$(readlink /run/current-system 2>/dev/null) || return 1
    booted=$(readlink /run/booted-system 2>/dev/null) || return 1
    [ "$current" = "$booted" ] && return 1
    # Dismissed for THIS booted gen?
    if [ -r "$DISMISS_MARKER" ]; then
        local dismissed
        dismissed=$(cat "$DISMISS_MARKER" 2>/dev/null) || dismissed=""
        [ "$dismissed" = "$booted" ] && return 1
    fi
    return 0
}

emit_reboot_pending() {
    if check_reboot_pending; then
        pill_write reboot-pending "$POWER_GLYPH" "opt-pill opt-pin-orange" \
            "Reboot recommended to finalize updates"
    else
        pill_write reboot-pending "" "opt-pill" ""
    fi
}

emit_reboot_pending
