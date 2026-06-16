#!/usr/bin/env bash
# pill-geom-test.sh — unit tests for pill.sh geometry helpers
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Set cache dir to a temp location so we don't clobber the live cache.
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export PILL_CACHE_DIR="$TEST_TMP/waybar-cache"
export PILL_GLASS_FILE="$TEST_TMP/glass-mode"
export PILL_GEOM_HYPR_CTX="$TEST_TMP/hypr-context.json"
mkdir -p "$PILL_CACHE_DIR"
echo "dark" > "$PILL_GLASS_FILE"
cat > "$PILL_GEOM_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":1600,"h":1000,"scale":2.0,"focused_ws":1}]}
EOF

# shellcheck source=../waybar/scripts/lib/pill.sh
source "$HERE/../waybar/scripts/lib/pill.sh"

pass=0; fail=0
check() {
    local label="$1"; shift
    if "$@"; then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else          fail=$((fail+1)); printf '✗ %s\n' "$label"
    fi
}

# pill_estimate_width: padding + (chars * font advance)
# Defaults: PILL_PAD_X=8, FONT_ADVANCE_PX=8
w=$(pill_estimate_width "")
check "[empty text width = PILL_PAD_X]" test "$w" -eq 8

w=$(pill_estimate_width "abc")
check "[3 chars width = 8 + 3*8 = 32]" test "$w" -eq 32

w=$(pill_estimate_width "hello world")
check "[11 chars width = 8 + 11*8 = 96]" test "$w" -eq 96

# pill_emit_geom <name> <width> [monitor] — writes pill-geom/<name>.json
pill_emit_geom "notif-bell" 28
check "[geom file created]" test -r "$PILL_GEOM_DIR/notif-bell.json"
check "[width recorded]" test -n "$(grep -F '"w":28' "$PILL_GEOM_DIR/notif-bell.json")"
check "[monitor defaulted from hypr-context]" test -n "$(grep -F '"monitor":"eDP-1"' "$PILL_GEOM_DIR/notif-bell.json")"

# Explicit monitor override
pill_emit_geom "notif-bell" 30 "DP-1"
check "[explicit monitor overrides]" test -n "$(grep -F '"monitor":"DP-1"' "$PILL_GEOM_DIR/notif-bell.json")"

# .empty pill emits w:0 even when text length suggests otherwise
pill_emit_geom "notif-action-1" 0
check "[empty pill w=0]" test -n "$(grep -F '"w":0' "$PILL_GEOM_DIR/notif-action-1.json")"

# Atomic write — tmp file does not linger after a successful write
check "[no .tmp leftover]" test ! -e "$PILL_GEOM_DIR/notif-bell.json.tmp"

# pill_write must also emit geometry. Width estimated from the text.
rm -f "$PILL_GEOM_DIR"/*.json 2>/dev/null
pill_write "notif-bell" "" "opt-pill dark opt-yes"
check "[pill_write emits geom even with empty text]" test -r "$PILL_GEOM_DIR/notif-bell.json"
check "[empty-text width = PILL_PAD_X]" test -n "$(grep -F '"w":8' "$PILL_GEOM_DIR/notif-bell.json")"

pill_write "ws-current" "5" "opt-pill dark"
check "[1-char text width = 16]" test -n "$(grep -F '"w":16' "$PILL_GEOM_DIR/ws-current.json")"

# .empty class → width 0 in the geom file
pill_write "notif-action-1" "Mute" "opt-pill empty"
check "[.empty pill w=0 in geom]" test -n "$(grep -F '"w":0' "$PILL_GEOM_DIR/notif-action-1.json")"

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit $(( fail > 0 ))
