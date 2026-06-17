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

# Set up a fake monitor + a minimal SYSTEM zone for the test.
# Raw monitor dimensions (3200x2000 at scale 2.0) → LOGICAL 1600x1000,
# matching a typical hi-DPI laptop panel. All position arithmetic
# operates in logical pixels post-scale.
# [tray=60, notif-widepill=0, notif-dnd=0, notif-bell=28].
# total_zone_width = 60 + 0 + 0 + 28 = 88
# zone_left_edge = 1600 - 88 = 1512
# bell estimated center X = 1512 + 60 + 0 + 0 + 14 = 1586
# Naive x_offset = 1586 - 160 = 1426 → popup right edge = 1746
# (overflows 1600 by 146). Clamp engages: x_offset = mon_w - W - margin
# = 1600 - 320 - 8 = 1272.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1}]}
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
check "[bell near right edge: clamped to 1272 (popup right at mon_w - margin)]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1272px')"
check "[anchor contains y-offset]" test -n "$(echo "$out" | grep -Eo 'y-offset:29px')"
check "[anchor sets location northwest]" test -n "$(echo "$out" | grep -F 'location:northwest')"
check "[anchor sets anchor north]" test -n "$(echo "$out" | grep -F 'anchor:north')"

# Pill not in any zone array → fallback path.
# Fallback cx = mon_x + mon_w - DEFAULT_WIDTH = 1600 - 320 = 1280.
# Naive x_offset = 1280 - 160 = 1120. Right edge = 1440, fits. No clamp.
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd"
out=$(rofi_anchor_for notif-bell)
check "[fallback anchor still set]" test -n "$out"
check "[fallback x-offset = 1120 (no clamp; fits on-screen)]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1120px')"
# Restore for any later tests
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd notif-bell"

# Scale=1.0 regression: same monitor logical dimensions → same clamp.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":1600,"h":1000,"scale":1.00,"focused_ws":1}]}
EOF
out=$(rofi_anchor_for notif-bell)
check "[scale=1.0: clamped to 1272 (same as hi-DPI logical case)]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1272px')"

# Fractional scale: 1.50. Raw 2400x1500 → logical 1600x1000. Same clamp.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":2400,"h":1500,"scale":1.50,"focused_ws":1}]}
EOF
out=$(rofi_anchor_for notif-bell)
check "[scale=1.5: clamped to 1272]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1272px')"

# A bell at the SYSTEM-zone right edge will ALWAYS clamp on any monitor
# (the 480-wide popup centered on a pill within ~30px of mon_right_edge
# overflows by ~210px regardless of monitor width). The clamp converts
# "centered on bell" → "right edge aligned to monitor minus margin", which
# is the visually-sensible behavior for an edge-anchored trigger.
# Unclamped zone-walker math is exercised by the [fallback x-offset = 880]
# case above and by the [anchor_at center] case below.

# ────────────────────────────────────────────────────────────────────────
# Multi-monitor: hyprctl reports monitor.x in LOGICAL coords, monitor.width
# in RAW px. Only width should be divided by scale; monitor.x is logical
# and must pass through untouched. Regression for the 2026-06-17 hi-DPI
# scale-divide patch that divided BOTH.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"DP-1","monitors":[
{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1},
{"name":"DP-1","x":1600,"y":0,"w":2560,"h":1440,"scale":1.00,"focused_ws":2}
]}
EOF
mx_mw=$(_rofi_focused_monitor)
check "[multi-monitor: focused mon.x stays logical 1600 (not divided)]" \
    test "$(echo "$mx_mw" | awk '{print $1}')" = "1600"
check "[multi-monitor: focused mon.w is raw/scale = 2560/1 = 2560]" \
    test "$(echo "$mx_mw" | awk '{print $2}')" = "2560"

# Aggressive: focused monitor on the right has scale=2 too. mon.x must
# STILL pass through as logical 3200; the bug we're fixing here divided
# it by scale and produced 1600.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"DP-1","monitors":[
{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1},
{"name":"DP-1","x":3200,"y":0,"w":5120,"h":2880,"scale":2.00,"focused_ws":2}
]}
EOF
mx_mw=$(_rofi_focused_monitor)
check "[multi-monitor scale=2 right: mon.x logical 3200 (not 1600)]" \
    test "$(echo "$mx_mw" | awk '{print $1}')" = "3200"
check "[multi-monitor scale=2 right: mon.w = 5120/2 = 2560]" \
    test "$(echo "$mx_mw" | awk '{print $2}')" = "2560"

# Reset to single-monitor scale=2 for downstream tests
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1}]}
EOF

# ────────────────────────────────────────────────────────────────────────
# rofi_anchor_at <logical_x> — centers popup on a given logical x with
# screen-edge clamp. The universal entry point used by cursor-driven and
# explicit-coord callers.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1}]}
EOF
# logical mon = (0, 1600). popup width = 320. margin = 8.
# cursor at center (800) → x_offset = 800 - 160 = 640, fits.
out=$(rofi_anchor_at 800)
check "[anchor_at center: x_offset = cursor - W/2]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:640px')"

# cursor near right edge (1500): naive x_offset = 1340, popup right edge
# at 1660 → overflows. Clamp at mon_w - W - margin = 1600 - 320 - 8 = 1272.
out=$(rofi_anchor_at 1500)
check "[anchor_at right edge: clamped to 1272]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1272px')"

# cursor near left edge (50): naive x_offset = -110. Clamp at mon_x +
# margin = 8.
out=$(rofi_anchor_at 50)
check "[anchor_at left edge: clamped to 8]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:8px')"

# ────────────────────────────────────────────────────────────────────────
# rofi_anchor_for clamp: bell near right edge of a small monitor must NOT
# produce an off-screen x_offset. Clamp to mon_w - W - margin = 1272.
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd notif-bell"
out=$(rofi_anchor_for notif-bell)
# bell center estimated at 1586, naive x_offset = 1426, right edge 1746
# (off by 146). Expect clamp to 1272.
check "[anchor_for clamps when popup would overflow right]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1272px')"

# ────────────────────────────────────────────────────────────────────────
# rofi_anchor_at_cursor — reads cursor pos via hyprctl OR via a sandboxed
# JSON file (ROFI_CURSORPOS_FILE for tests). Cursor is reported in LOGICAL
# coords by Hyprland — no scale conversion needed.
export ROFI_CURSORPOS_FILE="$TEST_TMP/cursorpos.json"
echo '{"x":800,"y":12}' > "$ROFI_CURSORPOS_FILE"
out=$(rofi_anchor_at_cursor)
check "[anchor_at_cursor: cursor at 800 → x_offset 640]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:640px')"

echo '{"x":1500,"y":12}' > "$ROFI_CURSORPOS_FILE"
out=$(rofi_anchor_at_cursor)
check "[anchor_at_cursor: cursor near right edge → clamped to 1272]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:1272px')"

# Multi-monitor: cursor on second monitor (DP-1 at logical x=1600..3200,
# w=1600 logical at scale=1). Cursor x=2400 (mid of DP-1), focused mon=DP-1.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"DP-1","monitors":[
{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1},
{"name":"DP-1","x":1600,"y":0,"w":1600,"h":1000,"scale":1.00,"focused_ws":2}
]}
EOF
echo '{"x":2400,"y":12}' > "$ROFI_CURSORPOS_FILE"
out=$(rofi_anchor_at_cursor)
# DP-1 logical bounds = [1600, 3200]. Cursor at 2400. Naive x_offset =
# 2400 - 160 = 2240. Popup right edge = 2560 < 3200. Fits. Expect 2240.
check "[anchor_at_cursor multi-mon: cursor on DP-1 → 2240]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:2240px')"

# Cursor near right edge of DP-1: x=3150. Naive = 2990, right edge = 3310
# (overflow by 110). Clamp at mon_x + mon_w - W - margin = 1600+1600-320-8 = 2872.
echo '{"x":3150,"y":12}' > "$ROFI_CURSORPOS_FILE"
out=$(rofi_anchor_at_cursor)
check "[anchor_at_cursor multi-mon: cursor near DP-1 right → clamp 2872]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:2872px')"

# Focus on Mon1, cursor click on Mon2. The clamp must use Mon2's bounds,
# not the focused-window monitor's. Pre-fix: anchor_at used focused monitor
# (eDP-1, bounds [0, 1600]) and clamped a cursor at x=2400 to 1112 →
# popup would render on Mon1 instead of Mon2. Post-fix: monitor lookup
# is by cursor-x containment, so cursor at 2400 resolves to DP-1.
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[
{"name":"eDP-1","x":0,"y":0,"w":3200,"h":2000,"scale":2.00,"focused_ws":1},
{"name":"DP-1","x":1600,"y":0,"w":1600,"h":1000,"scale":1.00,"focused_ws":2}
]}
EOF
echo '{"x":2400,"y":12}' > "$ROFI_CURSORPOS_FILE"
out=$(rofi_anchor_at_cursor)
check "[focus≠cursor monitor: click on Mon2 → x_offset 2240 (Mon2 bounds)]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:2240px')"

unset ROFI_CURSORPOS_FILE

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit $(( fail > 0 ))
