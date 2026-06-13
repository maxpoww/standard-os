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

# ---- rebuild-pending check ----

check_rebuild_pending() {
  [ -f /run/standard-os/activated-commit ] || return 1
  local activated head
  activated=$(cat /run/standard-os/activated-commit 2>/dev/null) || return 1
  head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null) || return 1
  [ "$activated" = "$head" ] && return 1   # up to date

  git -C /etc/nixos/home merge-base --is-ancestor "$activated" HEAD 2>/dev/null
  case $? in
    0|1) return 0 ;;   # ahead OR exotic divergence → pending
    *)   return 1 ;;   # bad SHA or other failure → fail open
  esac
}

emit_rebuild_pending() {
  if check_rebuild_pending; then
    local activated ahead last
    activated=$(cat /run/standard-os/activated-commit)
    ahead=$(git -C /etc/nixos/home rev-list --count "$activated..HEAD" 2>/dev/null || echo "?")
    last=$(git -C /etc/nixos/home log -1 --format=%s HEAD 2>/dev/null || echo "?")
    pill_write rebuild-pending "$(printf '\xef\x80\xa1')" "opt-pill opt-pin-orange" \
      "Pending rebuild: $ahead commit(s) ahead — last: $last"
  else
    pill_write rebuild-pending "" "opt-pill" ""
  fi
}

emit_rebuild_pending
