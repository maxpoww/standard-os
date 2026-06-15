#!/usr/bin/env bash
# notif-menu-flow-test.sh — end-to-end flow tests with mocks for rofi,
# mako, wl-copy, systemd-run. No live daemons required.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Sandbox dirs
SANDBOX=$(mktemp -d)
JOURNAL="$SANDBOX/notif-history.jsonl"
CALL_LOG="$SANDBOX/calls"
ROFI_QUEUE="$SANDBOX/rofi_queue"   # one chosen index per line; consumed in order
: > "$CALL_LOG"; : > "$ROFI_QUEUE"

trap 'rm -rf "$SANDBOX"' EXIT

MAKO_LIVE_PAYLOAD=""       # set per test
MAKO_ACTIONS_PAYLOAD=""    # set per test

export NOTIF_JOURNAL="$JOURNAL"
# Source the script — guarded main won't run because $0 is this test, not notif-menu.
# shellcheck source=../scripts/notif-menu
source "$HERE/../scripts/notif-menu"

# ── Mocks (defined AFTER sourcing notif-menu so they overwrite the lib's
# definitions of mako_list_live, mako_list_actions, mako_invoke, mako_dismiss,
# mako_dismiss_all AND notif-menu's own run_rofi) ────────────────────────
mako_list_live()    { printf '%s' "$MAKO_LIVE_PAYLOAD"; }
mako_list_actions() { printf '%s' "$MAKO_ACTIONS_PAYLOAD"; }
mako_invoke()       { printf 'mako_invoke %s %s\n' "$1" "$2" >> "$CALL_LOG"; }
mako_dismiss()      { printf 'mako_dismiss %s\n' "$1" >> "$CALL_LOG"; }
mako_dismiss_all()  { printf 'mako_dismiss_all\n' >> "$CALL_LOG"; }

wl-copy() {
    # Capture stdin bytes verbatim for byte-exact assertions.
    cat > "$SANDBOX/last_copy"
    printf 'wl-copy\n' >> "$CALL_LOG"
}

systemd-run() {
    printf 'systemd-run %s\n' "$*" >> "$CALL_LOG"
}

notify-send() { :; }  # silent — should never be called directly

run_rofi() {
    local prompt="$1"
    printf 'rofi prompt=%s\n' "$prompt" >> "$CALL_LOG"
    local idx
    idx=$(head -1 "$ROFI_QUEUE")
    sed -i '1d' "$ROFI_QUEUE"
    if [[ "$idx" == "ESC" ]]; then return 1; fi
    printf '%s' "$idx"
}

pass=0; fail=0
check() {
    local label="$1"; shift
    local negate=0
    if [[ "${1-}" == "!" ]]; then negate=1; shift; fi
    local rc=0; "$@" || rc=$?
    local ok=0; (( negate ? rc != 0 : rc == 0 )) && ok=1
    if (( ok )); then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else fail=$((fail+1)); printf '✗ %s\n' "$label"; fi
}

# ── Test 1: L1 → "Dismiss all unread" ────────────────────────────────────
: > "$CALL_LOG"; printf '1\n' > "$ROFI_QUEUE"   # idx 1 = "Dismiss all unread"
MAKO_LIVE_PAYLOAD=""
main
check "[t1: mako_dismiss_all called]" grep -qF 'mako_dismiss_all' "$CALL_LOG"

# ── Test 2: L1 unread → L2 app action ────────────────────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=$'default\tOpen\nreply\tReply\n'
# Seed journal so populate_l1 has metadata for id=42
journal_append "$JOURNAL" "2026-06-14T10:00:00-03:00" 42 "Slack" "Hi" "body text" 1
# Row order from populate_l1:
#   0 header "── Actions ──"
#   1 dismiss_all
#   2 header "── Unread (1) ──"
#   3 unread (id=42, Slack)
# So pick idx 3 in L1, then in L2 pick idx 1 ("Reply"):
#   L2 row order from populate_l2_live with 2 actions:
#     0 app_action "Open"  (default hoisted)
#     1 app_action "Reply"
#     2 noop (separator)
#     3 copy_summary
#     4 copy_body
#     5 snooze_10m
#     6 snooze_1h
#     7 dismiss
#     8 noop (separator)
#     9 back
printf '3\n1\n' > "$ROFI_QUEUE"
main
check "[t2: mako_invoke 42 reply called]" grep -qF 'mako_invoke 42 reply' "$CALL_LOG"
check "[t2: mako_dismiss 42 called after invoke]" grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 3: L2 Copy summary copies the exact bytes ───────────────────────
# Depends on Test 2's journal_append (id=42) so populate_l2_live reads
# body="body text" from the journal and emits the `copy_body` row at idx 2.
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""   # no app actions → L2 starts at separator+copy block
printf '3\n1\n' > "$ROFI_QUEUE"
# L2 with no app actions (body="body text" still in journal, so copy_body present):
#   0 noop separator
#   1 copy_summary     ← pick this
#   2 copy_body
#   3 snooze_10m
#   4 snooze_1h
#   5 dismiss
#   6 noop separator
#   7 back
main
check "[t3: wl-copy called]" grep -qF 'wl-copy' "$CALL_LOG"
check "[t3: copied bytes equal summary exactly (no trailing newline)]" \
    test "$(cat "$SANDBOX/last_copy")" = "Hi"
check "[t3: copied byte length = strlen(summary)]" \
    test "$(wc -c < "$SANDBOX/last_copy")" -eq 2

# ── Test 4: Snooze 10 minutes → systemd-run + dismiss ────────────────────
# Same journal dependency as Test 3: body is non-empty so the L2 row at
# idx 3 is snooze_10m (would shift to idx 2 if body were empty).
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""
printf '3\n3\n' > "$ROFI_QUEUE"   # L1 idx 3 (Slack), L2 idx 3 = snooze_10m
main
check "[t4: systemd-run called with --on-active=10min]" \
    grep -qF -- '--on-active=10min' "$CALL_LOG"
check "[t4: systemd-run called with --collect]" \
    grep -qF -- '--collect' "$CALL_LOG"
check "[t4: mako_dismiss 42 called after snooze]" \
    grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 5: History row → L2 has no Dismiss/Snooze ──────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=""   # nothing live
MAKO_ACTIONS_PAYLOAD=""
# Journal still has id=42; with no live notifs, that becomes a history row.
# Row order:
#   0 header Actions
#   1 dismiss_all
#   2 header "History (1)"
#   3 history (id=42)
# L2 history rows (body="body text" non-empty, so copy_body present):
#   0 copy_summary
#   1 copy_body
#   2 remove_history     ← pick
#   3 noop separator
#   4 back
printf '3\n2\n' > "$ROFI_QUEUE"
main
check "[t5: journal line removed]" ! grep -qF '"id":42' "$JOURNAL"

# ── Test 6: Esc at L1 → no side effects ──────────────────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
# Seed journal metadata for id=42 so populate_l1 can render the unread row
# without falling back to the unmocked fetch_live_meta → _mako_busctl_list path.
journal_append "$JOURNAL" "2026-06-14T11:00:00-03:00" 42 "Slack" "Hi again" "" 1
printf 'ESC\n' > "$ROFI_QUEUE"
main || true   # main returns 0 on Esc today; || true defends if that ever changes to non-zero
# After Esc no mako_* / wl-copy / systemd-run lines should have been logged
# beyond the one "rofi prompt=" line:
non_rofi_calls=$(grep -vF 'rofi prompt=' "$CALL_LOG" || true)
check "[t6: Esc at L1 produces no side-effect calls]" test -z "$non_rofi_calls"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
