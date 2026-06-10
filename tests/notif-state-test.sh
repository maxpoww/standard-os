#!/usr/bin/env bash
# notif-state-test.sh — unit tests for the pure render functions in
# scripts/notif-daemon:
#   - render_cache_for_state (legacy spine renderer; removed in task 6)
#   - render_bell_for_state (P1 — bell parent pill)
#   - render_dnd_for_state (P1 — DND child pill)
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

# ─── State 1: empty (no unread, no transient) ──────────────────────────────
# Daemon emits text="" so waybar hides the module. No class needed.
assert_eq \
    "$(render_cache_for_state 0 0 0 '' '' '' '')" \
    '{"text":""}' \
    "empty: no unread, no transient → hidden"

# ─── State 2: rest, normal unread (≥1 unread, 0 critical) ──────────────────
# Bell glyph at rest, opt-pin-green (correlated to opt-yes/blue state).
# Tooltip names what the pill IS, per OPTIONS tooltip rule.
assert_eq \
    "$(render_cache_for_state 1 0 0 '' '' '' '')" \
    "{\"text\":\"$BELL\",\"class\":[\"opt-pill\",\"dark\",\"opt-pin-green\"],\"tooltip\":\"Notifications\"}" \
    "rest: 1 normal unread → bell + opt-pin-green"

assert_eq \
    "$(render_cache_for_state 7 0 0 '' '' '' '')" \
    "{\"text\":\"$BELL\",\"class\":[\"opt-pill\",\"dark\",\"opt-pin-green\"],\"tooltip\":\"Notifications\"}" \
    "rest: 7 normal unread → same rest face (no count in vocab)"

# ─── State 3: rest, critical unread (≥1 critical) ──────────────────────────
# opt-pin-orange — correlated to opt-no/red state. Critical present at rest
# even when no transient is showing — the pin persists until dismissed.
assert_eq \
    "$(render_cache_for_state 1 1 0 '' '' '' '')" \
    "{\"text\":\"$BELL\",\"class\":[\"opt-pill\",\"dark\",\"opt-pin-orange\"],\"tooltip\":\"Notifications\"}" \
    "rest: 1 critical unread → bell + opt-pin-orange"

assert_eq \
    "$(render_cache_for_state 3 1 0 '' '' '' '')" \
    "{\"text\":\"$BELL\",\"class\":[\"opt-pill\",\"dark\",\"opt-pin-orange\"],\"tooltip\":\"Notifications\"}" \
    "rest: 3 unread (1 critical) → critical pin wins over green"

# ─── State 4: transient — normal/low arrival ───────────────────────────────
# Wide pill showing 'bell App · Title'. opt-flash on arrival, no state color.
# Tooltip carries the body. DND off (this state can't fire while DND on).
assert_eq \
    "$(render_cache_for_state 1 0 0 normal Firefox 'Download complete' 'See ~/Downloads/file.tar.gz')" \
    "{\"text\":\"$BELL Firefox · Download complete\",\"class\":[\"opt-pill\",\"dark\",\"opt-flash\"],\"tooltip\":\"See ~/Downloads/file.tar.gz\"}" \
    "transient normal: Firefox · Download complete → opt-flash"

# Even with DND on, the daemon should never construct a normal-transient
# state — but defend the rendering layer: kind=normal + dnd=1 still emits
# what the table says (the suppression happens upstream in the daemon).
# This documents the contract: render is pure, never inspects DND.
assert_eq \
    "$(render_cache_for_state 1 0 1 normal App 'Title' 'Body')" \
    "{\"text\":\"$BELL App · Title\",\"class\":[\"opt-pill\",\"dark\",\"opt-flash\"],\"tooltip\":\"Body\"}" \
    "transient normal: render is pure — DND check is daemon's job"

# ─── State 5: transient — critical arrival ─────────────────────────────────
# opt-pulse-orange motion + opt-no red state + opt-flash on entry.
# Stays animating until ack-timer expires (4s — auto-calm, not hover-detect).
assert_eq \
    "$(render_cache_for_state 1 1 0 critical Slack 'Server is down!' 'Production alert')" \
    "{\"text\":\"$BELL Slack · Server is down!\",\"class\":[\"opt-pill\",\"dark\",\"opt-no\",\"opt-pulse-orange\",\"opt-flash\"],\"tooltip\":\"Production alert\"}" \
    "transient critical: opt-no + opt-pulse-orange + opt-flash"

# Critical pierces DND.
assert_eq \
    "$(render_cache_for_state 1 1 1 critical Slack 'PAGE' 'Wake up')" \
    "{\"text\":\"$BELL Slack · PAGE\",\"class\":[\"opt-pill\",\"dark\",\"opt-no\",\"opt-pulse-orange\",\"opt-flash\"],\"tooltip\":\"Wake up\"}" \
    "transient critical: pierces DND (same render)"

# ─── State 6: critical acked (auto-calm after 4s of visible critical) ──────
# Wide pill stays, motion stops. opt-pulse-orange & opt-flash dropped;
# opt-pin-orange added. Still showing the App · Title text.
assert_eq \
    "$(render_cache_for_state 1 1 0 critical_acked Slack 'Server is down!' 'Production alert')" \
    "{\"text\":\"$BELL Slack · Server is down!\",\"class\":[\"opt-pill\",\"dark\",\"opt-no\",\"opt-pin-orange\"],\"tooltip\":\"Production alert\"}" \
    "acked critical: motion stopped, opt-pin-orange held"

# ─── Edge: empty inputs but transient kind set (defensive) ─────────────────
# Daemon should NEVER call with kind set and empty app — but if it does,
# render should produce a sensible string rather than mangled JSON.
assert_eq \
    "$(render_cache_for_state 0 0 0 normal '' '' '')" \
    "{\"text\":\"$BELL  · \",\"class\":[\"opt-pill\",\"dark\",\"opt-flash\"],\"tooltip\":\"\"}" \
    "edge: kind=normal with empty app/title → still well-formed JSON"

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

# ─── Class field is always a JSON ARRAY when present (project hazard) ──────
# A space-separated string is treated as a single GTK class. Smoke-check
# with jq if available — if not, this assertion is informational only.
if command -v jq >/dev/null 2>&1; then
    cache_json=$(render_cache_for_state 1 0 0 '' '' '' '')
    class_type=$(printf '%s' "$cache_json" | jq -r '.class | type')
    assert_eq "$class_type" "array" "class field is JSON array, not string"
fi

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
