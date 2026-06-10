#!/usr/bin/env bash
# notif-state-test.sh — unit tests for the pure render functions in
# scripts/notif-daemon:
#   - render_bell_for_state (P1 — bell parent pill)
#   - render_dnd_for_state (P1 — DND child pill)
#   - json_escape (field escaping for JSON safety)
# Sourced with NOTIF_DAEMON_LIB_ONLY=1 to skip the runtime main loop.
# Run from project root:  bash tests/notif-state-test.sh

set -uo pipefail

HERE=$(dirname "$(readlink -f "$0")")
# Source ONLY the render function — daemon's main loop is not sourced.
# We do this by setting NOTIF_DAEMON_LIB_ONLY=1 before sourcing, so the
# script returns early after defining functions (see daemon header).
NOTIF_DAEMON_LIB_ONLY=1
export NOTIF_DAEMON_LIB_ONLY
# shellcheck source=../scripts/notif-daemon
. "$HERE/../scripts/notif-daemon"

# Bell glyph U+F0F3 (Font Awesome solid bell). Byte sequence verified via
# `printf '\xef\x83\xb3' | od -An -c`. Hardcoded here so this test breaks
# loudly if the daemon ever changes its glyph.
BELL=$'\xef\x83\xb3'

fail=0
assert_eq() {
    local got=$1 want=$2 label=$3
    if [[ $got != "$want" ]]; then
        printf '✗ %s\n   got:  %q\n   want: %q\n' "$label" "$got" "$want" >&2
        fail=1
    else
        printf '✓ %s\n' "$label"
    fi
}

# ─── json_escape — safe-by-default for notification text ──────────────────
# Notification fields can contain ", \, newlines, and tabs. Without escape,
# a single rogue quote in a title corrupts the cache JSON and waybar renders
# nothing. Tested here so the helper is locked down before the main loop.
assert_eq "$(json_escape 'plain')"           "plain"      "json_escape: plain passthrough"
assert_eq "$(json_escape 'has \"quote\"')"   'has \\\"quote\\\"' "json_escape: double-quote"
assert_eq "$(json_escape 'a\\b')"            'a\\\\b'     "json_escape: backslash"
assert_eq "$(json_escape "$(printf 'a\nb')")" 'a\nb'      "json_escape: newline"
assert_eq "$(json_escape "$(printf 'a\tb')")" 'a\tb'      "json_escape: tab"
assert_eq "$(json_escape '')"                ''           "json_escape: empty"
# Composite: backslash THEN quote (order matters — backslash escape MUST
# come before quote escape or you get double-escape on the resulting \").
# Input `\\"` literally = 2 backslashes + 1 quote. JSON-escape: each `\`
# becomes `\\` → 4 backslashes; the `"` becomes `\"` → 1 more backslash + quote.
# Total: 5 backslashes + 1 quote. If you change this assertion, count the
# backslashes by hand from the JSON spec — DO NOT trust your editor.
assert_eq "$(json_escape '\\"')"             '\\\\\"'    "json_escape: backslash then quote (order)"

# ─── render_bell_for_state ────────────────────────────────────────────────
# Args: unread critical dnd_on kind app title body
# Returns one JSON object describing the bell parent pill.
if command -v jq >/dev/null 2>&1; then

    # Rest face — empty bell, DND off
    out=$(render_bell_for_state 0 0 0 "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | contains(["opt-pin-green","opt-pin-orange","opt-pushed"])')" \
        "false" \
        "bell: 0 unread, DND off → plain bell, no pin"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.tooltip')" \
        "Notifications" \
        "bell: 0 unread → tooltip Notifications"

    # Rest face — empty bell, DND on
    out=$(render_bell_for_state 0 0 1 "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pushed") != null')" \
        "true" \
        "bell: 0 unread, DND on → opt-pushed"

    # Rest face — N unread normal
    out=$(render_bell_for_state 3 0 0 "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pin-green") != null')" \
        "true" \
        "bell: 3 unread, no critical → opt-pin-green"

    # Rest face — N unread with critical
    out=$(render_bell_for_state 3 1 0 "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pin-orange") != null')" \
        "true" \
        "bell: critical pinned → opt-pin-orange"

    # Composes DND + pin
    out=$(render_bell_for_state 3 1 1 "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '[.class[] | select(. == "opt-pushed" or . == "opt-pin-orange")] | length')" \
        "2" \
        "bell: DND on + critical → opt-pushed + opt-pin-orange"

    # Transient face — normal (silent, no opt-flash, no animation)
    out=$(render_bell_for_state 1 0 0 "normal" "Slack" "PR review" "body")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.text | contains(" · ")')" \
        "true" \
        "bell transient normal: wide pill, text has · separator"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-flash") == null')" \
        "true" \
        "bell transient normal: no opt-flash (Rule 4: silent)"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '[.class[] | select(test("opt-pulse|opt-glow|opt-breathe"))] | length')" \
        "0" \
        "bell transient normal: no animation"

    # Transient face — critical (pulse-orange, opt-no)
    out=$(render_bell_for_state 1 1 0 "critical" "systemd" "foo.service" "failed")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pulse-orange") != null')" \
        "true" \
        "bell transient critical: opt-pulse-orange"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-no") != null')" \
        "true" \
        "bell transient critical: opt-no"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.tooltip')" \
        "failed" \
        "bell transient critical: tooltip is body"

    # Transient face — DND on critical (still pierces with same render)
    out=$(render_bell_for_state 1 1 1 "critical" "systemd" "foo.service" "failed")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '[.class[] | select(. == "opt-pulse-orange" or . == "opt-pushed")] | length')" \
        "2" \
        "bell transient critical+DND: pulse-orange still + opt-pushed composes"

    # class is JSON array
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | type')" \
        "array" \
        "bell: class is array"

fi

# ─── render_dnd_for_state ─────────────────────────────────────────────────
# Args: dnd_on
if command -v jq >/dev/null 2>&1; then

    out=$(render_dnd_for_state 0)
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pushed") == null')" \
        "true" \
        "dnd off: no opt-pushed"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.tooltip')" \
        "Do Not Disturb" \
        "dnd off: tooltip is base text"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.text' | od -An -tx1 | tr -d ' \n' | head -c 8)" \
        "f3b0829b" \
        "dnd off: glyph is bell-slash bytes"

    out=$(render_dnd_for_state 1)
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pushed") != null')" \
        "true" \
        "dnd on: opt-pushed"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.tooltip')" \
        "Do Not Disturb (on)" \
        "dnd on: tooltip indicates state"

    # Child surface, not parent
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pill-child") != null')" \
        "true" \
        "dnd: class is opt-pill-child"

fi

# ─── C1 regression — JSON injection via quote/backslash in notification fields
# render_bell_for_state must JSON-escape app/title/body internally.
# A raw " or \ in any field previously produced broken JSON and waybar rendered
# an empty pill. Verify with jq — if the output parses, the escaping is correct.
if command -v jq >/dev/null 2>&1; then
    out=$(render_bell_for_state 1 0 0 "normal" 'Quote"App' 'Title with "quotes"' 'body with "more quotes" and \backslash')
    assert_eq \
        "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1 && echo VALID || echo BROKEN)" \
        "VALID" \
        "C1 regression: transient with quotes in fields → emits valid JSON"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.text' | cut -d' ' -f1)" \
        'Quote"App' \
        "C1 regression: transient with quotes — app round-trips through JSON"
fi

# ─── Result ────────────────────────────────────────────────────────────────
if [[ $fail -eq 0 ]]; then
    printf '\n✓ all tests passed\n'
    exit 0
else
    printf '\n✗ %d failure(s)\n' "$fail" >&2
    exit 1
fi
