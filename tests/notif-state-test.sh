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

    # Rest face — empty bell, silence off
    out=$(render_bell_for_state 0 0 "none" "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | contains(["opt-pin-green","opt-pin-orange","opt-pushed"])')" \
        "false" \
        "bell: 0 unread, silence none → plain bell, no pin"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.tooltip')" \
        "Notifications" \
        "bell: 0 unread → tooltip Notifications"

    # Rest face — empty bell, silence on (opt-pushed now dropped; glyph swap carries signal)
    out=$(render_bell_for_state 0 0 "transient" "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pushed") == null')" \
        "true" \
        "bell: 0 unread, silence transient → no opt-pushed (P3: glyph swap carries signal)"

    # Rest face — N unread normal
    out=$(render_bell_for_state 3 0 "none" "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pin-green") != null')" \
        "true" \
        "bell: 3 unread, no critical → opt-pin-green"

    # Rest face — N unread with critical
    out=$(render_bell_for_state 3 1 "none" "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pin-orange") != null')" \
        "true" \
        "bell: critical pinned → opt-pin-orange"

    # Composes silence mode + pin (opt-pushed dropped; only pin-orange present)
    out=$(render_bell_for_state 3 1 "transient" "" "" "" "")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pin-orange") != null')" \
        "true" \
        "bell: silence transient + critical → opt-pin-orange (no opt-pushed in P3)"

    # Transient face — normal (silent, no opt-flash, no animation)
    out=$(render_bell_for_state 1 0 "none" "normal" "Slack" "PR review" "body")
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
    out=$(render_bell_for_state 1 1 "none" "critical" "systemd" "foo.service" "failed")
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

    # Transient face — silence mode critical (opt-pushed dropped; only pulse-orange)
    out=$(render_bell_for_state 1 1 "transient" "critical" "systemd" "foo.service" "failed")
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | index("opt-pulse-orange") != null')" \
        "true" \
        "bell transient critical+silence: pulse-orange present (no opt-pushed in P3)"

    # class is JSON array
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.class | type')" \
        "array" \
        "bell: class is array"

fi

# ─── C1 regression — JSON injection via quote/backslash in notification fields
# render_bell_for_state must JSON-escape app/title/body internally.
# A raw " or \ in any field previously produced broken JSON and waybar rendered
# an empty pill. Verify with jq — if the output parses, the escaping is correct.
if command -v jq >/dev/null 2>&1; then
    out=$(render_bell_for_state 1 0 "none" "normal" 'Quote"App' 'Title with "quotes"' 'body with "more quotes" and \backslash')
    assert_eq \
        "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1 && echo VALID || echo BROKEN)" \
        "VALID" \
        "C1 regression: transient with quotes in fields → emits valid JSON"
    assert_eq \
        "$(printf '%s' "$out" | jq -r '.text' | sed 's|^<b>||; s|</b>.*||')" \
        'Quote"App' \
        "C1 regression: transient with quotes — app round-trips through JSON"
fi

# ─── pango_escape ─────────────────────────────────────────────────────────
assert_eq \
    "$(pango_escape "Hello world")" "Hello world" \
    "[pango_escape passthrough plain]"
assert_eq \
    "$(pango_escape "<script>")" "&lt;script&gt;" \
    "[pango_escape <]"
assert_eq \
    "$(pango_escape "a>b")" "a&gt;b" \
    "[pango_escape >]"
assert_eq \
    "$(pango_escape "Tom & Jerry")" "Tom &amp; Jerry" \
    "[pango_escape &]"
assert_eq \
    "$(pango_escape "<a href=\"x\">&go</a>")" "&lt;a href=\"x\"&gt;&amp;go&lt;/a&gt;" \
    "[pango_escape combined]"
assert_eq \
    "$(pango_escape "<&>")" "&lt;&amp;&gt;" \
    "[pango_escape order: & before < (avoid double-escape)]"

# ─── detect_otp ───────────────────────────────────────────────────────────
# Args: summary body — returns the first matching 4-8 digit code, or empty.

# Positive cases — keyword + code present
assert_eq \
    "$(detect_otp "Verification" "Your code is 1234")" "1234" \
    "[OTP: 'code 1234']"
assert_eq \
    "$(detect_otp "Login" "Your verification code: 348291")" "348291" \
    "[OTP: 6-digit common]"
assert_eq \
    "$(detect_otp "PIN" "Use PIN 5678 to confirm")" "5678" \
    "[OTP: PIN keyword]"
assert_eq \
    "$(detect_otp "" "Your OTP is 90210")" "90210" \
    "[OTP: OTP keyword caps]"
assert_eq \
    "$(detect_otp "" "Auth token: 1357924")" "1357924" \
    "[OTP: token keyword]"
assert_eq \
    "$(detect_otp "MFA code" "12345678 expires soon")" "12345678" \
    "[OTP: MFA keyword]"
assert_eq \
    "$(detect_otp "" "Your 2FA: 4567")" "4567" \
    "[OTP: 2FA keyword]"
assert_eq \
    "$(detect_otp "Use code 2222 today" "")" "2222" \
    "[OTP: code in summary]"

# Negative cases — no keyword OR no digits
assert_eq \
    "$(detect_otp "Price drop" "Now \$1234 cheaper")" "" \
    "[OTP: no keyword → empty]"
assert_eq \
    "$(detect_otp "Verification" "Sent to your phone")" "" \
    "[OTP: no digits → empty]"
assert_eq \
    "$(detect_otp "Order" "code processed; ............................................. 1234")" "" \
    "[OTP: keyword but digits too far away (>40 chars) → empty]"

# First match wins
assert_eq \
    "$(detect_otp "" "Your code 1111, backup code 2222")" "1111" \
    "[OTP: first match wins]"

# 4-digit minimum, 8-digit maximum
assert_eq \
    "$(detect_otp "" "code 123")" "" \
    "[OTP: 3-digit ignored]"
assert_eq \
    "$(detect_otp "" "code 123456789")" "" \
    "[OTP: 9-digit ignored]"

# ─── render_bell_for_state — P2 extensions ────────────────────────────────
# New args: OTP_CODE (string), OTP_COPIED (0/1)

# Transient — pango-bold app name
out=$(render_bell_for_state 1 0 "none" "normal" "Slack" "PR review" "body" "" 0)
assert_eq \
    "$(echo "$out" | jq -r '.text')" \
    "<b>Slack</b> · PR review" \
    "[bell transient: app wrapped in <b>]"

# Pango-escape: <, >, & in app name
out=$(render_bell_for_state 1 0 "none" "normal" "<script>" "title" "" "" 0)
assert_eq \
    "$(echo "$out" | jq -r '.text')" \
    "<b>&lt;script&gt;</b> · title" \
    "[bell transient: pango-escape app <script>]"

out=$(render_bell_for_state 1 0 "none" "normal" "Tom & Jerry" "ep1" "" "" 0)
assert_eq \
    "$(echo "$out" | jq -r '.text')" \
    "<b>Tom &amp; Jerry</b> · ep1" \
    "[bell transient: pango-escape app &]"

# Title also escaped
out=$(render_bell_for_state 1 0 "none" "normal" "App" "<b>injected</b>" "" "" 0)
assert_eq \
    "$(echo "$out" | jq -r '.text')" \
    "<b>App</b> · &lt;b&gt;injected&lt;/b&gt;" \
    "[bell transient: pango-escape title <b>]"

# OTP_CODE non-empty → opt-glow-green added
out=$(render_bell_for_state 1 0 "none" "normal" "Bank" "Code 1234" "" "1234" 0)
assert_eq \
    "$(echo "$out" | jq -r '.class | index("opt-glow-green") != null')" \
    "true" \
    "[bell transient OTP: opt-glow-green present]"
assert_eq \
    "$(echo "$out" | jq -r '.otp_code')" \
    "1234" \
    "[bell transient OTP: otp_code field present]"

# OTP_CODE empty → no opt-glow-green, otp_code field empty string
out=$(render_bell_for_state 1 0 "none" "normal" "App" "title" "" "" 0)
assert_eq \
    "$(echo "$out" | jq -r '.class | index("opt-glow-green") == null')" \
    "true" \
    "[bell transient no-OTP: no opt-glow-green]"
assert_eq \
    "$(echo "$out" | jq -r '.otp_code')" \
    "" \
    "[bell transient no-OTP: otp_code is empty string]"

# OTP_COPIED=1 → text gains " · copied" suffix
out=$(render_bell_for_state 1 0 "none" "normal" "Bank" "Code 1234" "" "1234" 1)
assert_eq \
    "$(echo "$out" | jq -r '.text')" \
    "<b>Bank</b> · Code 1234 · copied" \
    "[bell transient OTP copied: text has copied suffix]"

# Critical + OTP composes: opt-pulse-orange AND opt-glow-green
out=$(render_bell_for_state 1 1 "none" "critical" "Bank" "Critical" "danger" "9999" 0)
assert_eq \
    "$(echo "$out" | jq -r '[.class[] | select(. == "opt-pulse-orange" or . == "opt-glow-green")] | length')" \
    "2" \
    "[bell critical+OTP: both opt-pulse-orange and opt-glow-green]"

# Rest face emits otp_code as empty string (schema stability)
out=$(render_bell_for_state 0 0 "none" "" "" "" "" "" 0)
assert_eq \
    "$(echo "$out" | jq -r '.otp_code')" \
    "" \
    "[bell rest: otp_code field empty string]"

# ─── render_action_for_state ──────────────────────────────────────────────
# Args: key label

# Basic shape
out=$(render_action_for_state "reply" "Reply")
assert_eq "$(echo "$out" | jq -r '.text')" "Reply" \
  "[action: text is the label]"
assert_eq \
  "$(echo "$out" | jq -r '.class | length')" "3" \
  "[action: class has 3 elements]"
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-pill-child") != null')" "true" \
  "[action: opt-pill-child present]"
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-yes") != null')" "true" \
  "[action: opt-yes present]"
assert_eq \
  "$(echo "$out" | jq -r '.key')" "reply" \
  "[action: key field is the action key]"
assert_eq \
  "$(echo "$out" | jq -r '.tooltip')" "Reply" \
  "[action: tooltip is the label]"

# JSON-injection: quotes in label and key
out=$(render_action_for_state 'key"with' 'Label "with"')
assert_eq \
  "$(echo "$out" | jq -r '.text')" 'Label "with"' \
  "[action: JSON-escapes quote in label]"
assert_eq \
  "$(echo "$out" | jq -r '.key')" 'key"with' \
  "[action: JSON-escapes quote in key]"

# ─── render_bell_for_state — P3 SILENCE_MODE arg + glyph swap ────────────

# Off (silenceMode=none) → bell glyph
out=$(render_bell_for_state 0 0 "none" "" "" "" "" "" 0)
text=$(echo "$out" | jq -r '.text' | od -An -tx1 | tr -d ' \n' | head -c 6)
assert_eq "$text" "ef83b3" "[P3 rest: Off → bell glyph (ef83b3)]"
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-pushed") == null')" "true" \
  "[P3 rest: Off → no opt-pushed]"

# Suppress modes → bell-slash glyph
for mode in transient all-but-critical-silent non-allowed all; do
    out=$(render_bell_for_state 0 0 "$mode" "" "" "" "" "" 0)
    text=$(echo "$out" | jq -r '.text' | od -An -tx1 | tr -d ' \n' | head -c 6)
    assert_eq "$text" "ef87b7" "[P3 rest: $mode → bell-slash glyph (ef87b7)]"
    assert_eq \
      "$(echo "$out" | jq -r '.class | index("opt-pushed") == null')" "true" \
      "[P3 rest: $mode → no opt-pushed]"
done

# Pin colors compose orthogonally with profile
out=$(render_bell_for_state 3 0 "transient" "" "" "" "" "" 0)
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-pin-green") != null')" "true" \
  "[P3 rest: 3 unread + transient → opt-pin-green]"

out=$(render_bell_for_state 3 1 "all-but-critical-silent" "" "" "" "" "" 0)
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-pin-orange") != null')" "true" \
  "[P3 rest: 3 unread w/ critical + media → opt-pin-orange]"

# Transient face: bold app + title remains unchanged; opt-pushed never appears.
out=$(render_bell_for_state 1 0 "none" "normal" "Slack" "PR review" "body" "" 0)
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-pushed") == null')" "true" \
  "[P3 transient: no opt-pushed regardless of silence mode]"

# ─── render_profile_for_state ────────────────────────────────────────────
# Args: profile_name display_name

# Off → neutral child surface, no opt-yes
out=$(render_profile_for_state "off" "Off")
assert_eq \
  "$(echo "$out" | jq -r '.text')" "Off" \
  "[profile Off: text]"
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-yes") == null')" "true" \
  "[profile Off: no opt-yes]"
assert_eq \
  "$(echo "$out" | jq -r '.class | index("opt-pill-child") != null')" "true" \
  "[profile Off: opt-pill-child surface]"

# Non-off → opt-yes accent
for p in dnd sleep work gaming media; do
    out=$(render_profile_for_state "$p" "$p")
    assert_eq \
      "$(echo "$out" | jq -r '.class | index("opt-yes") != null')" "true" \
      "[profile $p: opt-yes present]"
done

# Tooltip
out=$(render_profile_for_state "work" "Work")
assert_eq \
  "$(echo "$out" | jq -r '.tooltip')" "Focus profile" \
  "[profile work: tooltip is Focus profile]"

# JSON-escape display_name with quote
out=$(render_profile_for_state "dnd" 'Do "Not" Disturb')
assert_eq \
  "$(echo "$out" | jq -r '.text')" 'Do "Not" Disturb' \
  "[profile: JSON-escapes quote in display name]"

# ─── Result ────────────────────────────────────────────────────────────────
if [[ $fail -eq 0 ]]; then
    printf '\n✓ all tests passed\n'
    exit 0
else
    printf '\n✗ %d failure(s)\n' "$fail" >&2
    exit 1
fi
