#!/usr/bin/env bash
# test_canvas_exit_invariant — guards the single static invariant that
# makes the dashboard Esc / Super+Shift+Esc bind reachable.
#
# Why a separate test: the eww `defwindow dashboard :focusable` setting
# and the Hyprland canvas-open submap binds live in different files, but
# silently depend on each other. When :focusable is true the gtk-layer-
# shell surface gets keyboard-interactivity=exclusive, the compositor
# routes Esc to eww instead of Hyprland's dispatcher, and BOTH binds
# (regular Esc + Super+Shift+Esc panic key) become unreachable. That
# was the cause of two reboot incidents in June 2026. This test fails
# loudly on any future regression of the same line.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
YUCK="$ROOT/widgets/eww/eww.yuck"
BINDS="$ROOT/hypr/modules/Binds.conf"

pass=0; fail=0
check() {
    local name="$1" cond="$2"
    if eval "$cond"; then
        echo "PASS $name"; ((++pass))
    else
        echo "FAIL $name"; ((++fail))
    fi
}

# 1. The defwindow block exists and explicitly sets :focusable false.
#    Look only within the `(defwindow dashboard ... (canvas))` form.
window_block=$(awk '/\(defwindow dashboard/,/\(canvas\)\)\)/' "$YUCK")
check "dashboard defwindow present" '[[ -n "$window_block" ]]'
check "dashboard :focusable is false" \
    'grep -qE ":focusable[[:space:]]+false" <<<"$window_block"'
check "dashboard :focusable is NOT true" \
    '! grep -qE ":focusable[[:space:]]+true" <<<"$window_block"'

# 2. The canvas-open submap still has both Esc binds (reachability is
#    only meaningful if the binds themselves exist).
check "canvas-open submap declared" \
    'grep -qE "^submap = canvas-open" "$BINDS"'
check "submap Esc bind present" \
    'grep -qE "^bind = , ESCAPE, exec, .*/canvas-close" "$BINDS"'
check "submap panic bind present" \
    'grep -qE "^bind = .*SHIFT, ESCAPE, exec, .*/canvas-panic" "$BINDS"'

echo
echo "passed: $pass, failed: $fail"
exit "$fail"
