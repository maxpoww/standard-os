#!/usr/bin/env bash
# test_landscape_exit_invariant -- guards the static invariant that makes
# the Landscape Esc / Super+Shift+Esc binds reachable.
#
# Mirror of test_canvas_exit_invariant. Both surfaces share the same
# failure mode: :focusable true on the eww defwindow leaks
# keyboard-interactivity=exclusive to the compositor, which routes Esc
# to eww and bypasses Hyprland's keybind dispatcher. Both submap binds
# silently never fire and the user is trapped on the surface until
# external recovery (Super+Shift+Esc only works because it is ALSO
# bound here -- breaking that invariant retraps the user).
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

# 1. defwindow landscape block exists and explicitly sets :focusable false.
# Stop the range at `(landscape-grid))` -- the actual close of the
# defwindow landscape form. See test_canvas_exit_invariant.sh for the
# latent-pattern story; same lesson applies to peer-defwindow tests.
window_block=$(awk '/\(defwindow landscape/,/\(landscape-grid\)\)/' "$YUCK")
check "landscape defwindow present" '[[ -n "$window_block" ]]'
check "landscape :focusable is false" \
    'grep -qE ":focusable[[:space:]]+false" <<<"$window_block"'
check "landscape :focusable is NOT true" \
    '! grep -qE ":focusable[[:space:]]+true" <<<"$window_block"'

# 2. landscape-open submap still has both Esc binds.
check "landscape-open submap declared" \
    'grep -qE "^submap = landscape-open" "$BINDS"'
check "submap Esc bind present" \
    'grep -qE "^bind = , ESCAPE, exec, .*/landscape-close" "$BINDS"'
check "submap panic bind present" \
    'grep -qE "^bind = .*SHIFT, ESCAPE, exec, .*/landscape-panic" "$BINDS"'

echo
echo "passed: $pass, failed: $fail"
exit "$fail"
