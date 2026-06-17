#!/usr/bin/env bash
# waybar-self-test: verify the bar's runtime invariants and surface
# failures via a SYSTEM-zone pill. Kicked by waybar-self-test.timer
# every 60s and on demand via click handler.
#
# Exit code contract (consumed by the update pipeline's phase_verify):
#   0 — all invariants satisfied (bar healthy)
#   1 — one or more invariants failed (bar unhealthy)
#
# Both branches also run the reboot-pending check so that pill stays
# accurate regardless of health state.
set -euo pipefail

# Resolve lib path. When invoked via makeWrapper, $0 is the wrapper;
# the libexec script's source line is substituted to absolute path
# at build time.
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

REQUIRED_UNITS=(waybar waybar-hypr-context-daemon waybar-hypr-bg-daemon)
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

# ---- exit with appropriate code ----
# Self-test failure pill retired 2026-06-17 (user: error pills are not
# attractive). Failures are visible only via journalctl -u waybar-self-test
# and as the non-zero exit code consumed by the update pipeline's pre-flight
# and post-switch verify phases. emit_reboot_pending still runs because the
# reboot-pending cache feeds the power-pill helper, not an error pill.
if [ "${#failures[@]}" -eq 0 ]; then
  emit_reboot_pending
  exit 0
else
  printf 'waybar-self-test failures:\n' >&2
  printf '  • %s\n' "${failures[@]}" >&2
  emit_reboot_pending
  exit 1
fi
