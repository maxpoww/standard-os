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
