#!/usr/bin/env bash
# rofi-anchor-test.sh — unit tests for lib/rofi-anchor.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_TMP=$(mktemp -d); trap 'rm -rf "$TEST_TMP"' EXIT

export ROFI_THEME_DIR="$TEST_TMP/rofi-themes"
export ROFI_GLASS_FILE="$TEST_TMP/glass-mode"
export ROFI_GEOM_DIR="$TEST_TMP/pill-geom"
export ROFI_HYPR_CTX="$TEST_TMP/hypr-context.json"
mkdir -p "$ROFI_THEME_DIR" "$ROFI_GEOM_DIR"
: > "$ROFI_THEME_DIR/options-light.rasi"
: > "$ROFI_THEME_DIR/options-dark.rasi"

# shellcheck source=../scripts/lib/rofi-anchor.sh
source "$HERE/../scripts/lib/rofi-anchor.sh"

pass=0; fail=0
check() {
    local label="$1"; shift
    if "$@"; then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else          fail=$((fail+1)); printf '✗ %s\n' "$label"
    fi
}

# rofi_theme_for_mode — reads /tmp/glass-mode, prints absolute theme path.
echo "light" > "$ROFI_GLASS_FILE"
out=$(rofi_theme_for_mode)
check "[light glass → light theme]" test "$out" = "$ROFI_THEME_DIR/options-light.rasi"

echo "dark" > "$ROFI_GLASS_FILE"
out=$(rofi_theme_for_mode)
check "[dark glass → dark theme]" test "$out" = "$ROFI_THEME_DIR/options-dark.rasi"

# Missing glass-mode file defaults to dark
rm -f "$ROFI_GLASS_FILE"
out=$(rofi_theme_for_mode)
check "[missing glass → dark theme]" test "$out" = "$ROFI_THEME_DIR/options-dark.rasi"

# rofi_anchor_for <pill-id> — reads pill-geom + hypr-context and prints
# a rofi -theme-str fragment that positions rofi's top-center under the
# pill's bottom-center + ROFI_GAP_PX.

# Set up a fake monitor + a minimal SYSTEM zone for the test:
# [tray=60, notif-widepill=0, notif-dnd=0, notif-bell=28].
# total_zone_width = 60 + 0 + 0 + 28 = 88
# zone_left_edge = 1600 - 88 = 1512
# bell cumulative_before = 60 + 0 + 0 = 60
# bell start X = 1512 + 60 = 1572
# bell center X = 1572 + 14 = 1586
# rofi x_offset (window width 480) = 1586 - 240 = 1346
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":1600,"h":1000,"scale":2.0,"focused_ws":1}]}
EOF
printf '{"w":0,"monitor":"eDP-1"}'  > "$ROFI_GEOM_DIR/notif-widepill.json"
printf '{"w":0,"monitor":"eDP-1"}'  > "$ROFI_GEOM_DIR/notif-dnd.json"
printf '{"w":28,"monitor":"eDP-1"}' > "$ROFI_GEOM_DIR/notif-bell.json"

# The test config sets only [tray, widepill, dnd, bell] in the SYSTEM
# zone — narrower than production but exercises the same algorithm.
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd notif-bell"
# tray's width is a fixed constant (no pill-geom entry).
export ROFI_TRAY_WIDTH=60

out=$(rofi_anchor_for notif-bell)
check "[anchor output non-empty]" test -n "$out"
check "[anchor contains x-offset 1346]" test -n "$(echo "$out" | grep -Eo 'x-offset:1346px')"
check "[anchor contains y-offset]" test -n "$(echo "$out" | grep -Eo 'y-offset:29px')"
check "[anchor sets location northwest]" test -n "$(echo "$out" | grep -F 'location:northwest')"
check "[anchor sets anchor north]" test -n "$(echo "$out" | grep -F 'anchor:north')"

# Pill not in any zone array → fallback path.
# Fallback cx = monitor_right - DEFAULT_WIDTH = 1600 - 480 = 1120.
# x_offset = cx - DEFAULT_WIDTH/2 = 1120 - 240 = 880.
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd"
out=$(rofi_anchor_for notif-bell)
check "[fallback anchor still set]" test -n "$out"
check "[fallback x-offset = (mon_w - default - default/2) = 880]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:880px')"
# Restore for any later tests
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd notif-bell"

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit $(( fail > 0 ))
