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
: > "$CALL_LOG"; printf '1\n' > "$ROFI_QUEUE"
MAKO_LIVE_PAYLOAD=""
main
check "[t1: mako_dismiss_all called]" grep -qF 'mako_dismiss_all' "$CALL_LOG"

# ── Test 2: L1 unread → L2 non-default app action ────────────────────────
# L1 row order: 0 Actions header, 1 dismiss_all, 2 Unread header, 3 unread
# L2 row order with default+reply actions: 0 view (default hidden),
#   1 app_action Reply, 2 noop sep, 3 dismiss, 4 noop sep, 5 back.
# Pick L1 idx 3 then L2 idx 1 (Reply).
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=$'default\tOpen\nreply\tReply\n'
journal_append "$JOURNAL" "2026-06-14T10:00:00-03:00" 42 "Slack" "Hi" "body text" 1
printf '3\n1\n' > "$ROFI_QUEUE"
main
check "[t2: mako_invoke 42 reply called]" grep -qF 'mako_invoke 42 reply' "$CALL_LOG"
check "[t2: mako_dismiss 42 called after invoke]" grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 3: View with default action ─────────────────────────────────────
# Same L1 layout. L2 row 0 is View. Pick L1 idx 3 → L2 idx 0.
# Mocked mako_has_default_action returns 0 so do_view step 1 fires.
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=$'default\tOpen\n'
mako_has_default_action() { return 0; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t3: mako_invoke 42 default called]" grep -qF 'mako_invoke 42 default' "$CALL_LOG"
check "[t3: mako_dismiss 42 called after default invoke]" grep -qF 'mako_dismiss 42' "$CALL_LOG"
check "[t3: hyprctl NOT called]" ! grep -qF 'hyprctl' "$CALL_LOG"

# ── Test 4: View without default but matching Hyprland window ────────────
# Mocked mako_has_default_action returns 1, hypr_focus_by_class returns 0.
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""
mako_has_default_action() { return 1; }
hypr_focus_by_class() { printf 'hypr_focus_by_class %s\n' "$*" >> "$CALL_LOG"; return 0; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t4: hypr_focus_by_class called with app name]" grep -qF 'hypr_focus_by_class Slack' "$CALL_LOG"
check "[t4: mako_dismiss 42 called after focus]" grep -qF 'mako_dismiss 42' "$CALL_LOG"
check "[t4: mako_invoke NOT called]" ! grep -qF 'mako_invoke' "$CALL_LOG"

# ── Test 5: View with nothing matching (fallback notify-send) ────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""
mako_has_default_action() { return 1; }
hypr_focus_by_class() { return 1; }
notify-send() { printf 'notify-send %s\n' "$*" >> "$CALL_LOG"; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t5: notify-send fallback fired with -a notif-menu]" \
    grep -qF 'notify-send -a notif-menu' "$CALL_LOG"
check "[t5: original mako_dismiss NOT called (fallback returns 1)]" \
    ! grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 6: View on a fallback notif (recursion guard) ──────────────────
# Journal seeds app="notif-menu". do_view step 2 short-circuits before step 4.
: > "$CALL_LOG"
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-14T10:30:00-03:00" 99 "notif-menu" "View couldn't open" "no default action" 0
MAKO_LIVE_PAYLOAD=$'99\t0\n'
MAKO_ACTIONS_PAYLOAD=""
mako_has_default_action() { return 1; }
hypr_focus_by_class() { printf 'hypr_focus_by_class %s\n' "$*" >> "$CALL_LOG"; return 0; }
notify-send() { printf 'notify-send %s\n' "$*" >> "$CALL_LOG"; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t6: mako_dismiss 99 called (recursion guard ok)]" grep -qF 'mako_dismiss 99' "$CALL_LOG"
check "[t6: hypr_focus_by_class NOT called (step 2 short-circuited)]" \
    ! grep -qF 'hypr_focus_by_class' "$CALL_LOG"
check "[t6: notify-send NOT called (no cascading fallback)]" \
    ! grep -qF 'notify-send' "$CALL_LOG"

# Restore default mocks for subsequent tests
mako_has_default_action() { mako_list_actions "$1" | grep -q $'^default\t'; }
hypr_focus_by_class() { return 1; }
notify-send() { :; }

# ── Test 7: History row → Remove from history ───────────────────────────
# L1 row order with no live + 1 history entry:
#   0 Actions header, 1 dismiss_all, 2 History header, 3 history (id=99)
# History L2 with View at top: 0 view, 1 copy_summary, 2 copy_body,
#   3 remove_history, 4 noop sep, 5 back. Pick L1 idx 3 then L2 idx 3.
: > "$CALL_LOG"
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-14T11:00:00-03:00" 99 "TestApp" "old notif" "old body" 1
MAKO_LIVE_PAYLOAD=""
MAKO_ACTIONS_PAYLOAD=""
printf '3\n3\n' > "$ROFI_QUEUE"
main
check "[t7: journal line removed]" ! grep -qF '"id":99' "$JOURNAL"

# ── Test 8: Esc at L1 → no side effects ─────────────────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
journal_append "$JOURNAL" "2026-06-14T11:30:00-03:00" 42 "Slack" "Hi again" "" 1
printf 'ESC\n' > "$ROFI_QUEUE"
main || true
non_rofi_calls=$(grep -vF 'rofi prompt=' "$CALL_LOG" || true)
check "[t8: Esc at L1 produces no side-effect calls]" test -z "$non_rofi_calls"

# ── Test 9: Vanished fallback (live → gone between L1 and L2) ───────────
# populate_l1's mako_list_live first call returns id=42. populate_l2_live's
# re-query (second call) returns empty — fallback to history-only L2.
# Vanished-fallback L2 row order with View at top (body non-empty from journal):
#   0 header "── no longer live ──", 1 view, 2 copy_summary, 3 copy_body,
#   4 remove_history, 5 noop sep, 6 back. Pick L2 idx 4 (remove_history).
: > "$CALL_LOG"
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-14T12:00:00-03:00" 42 "Slack" "Hi" "body text" 1
mako_list_live_calls=$(mktemp)
echo 0 > "$mako_list_live_calls"
mako_list_live() {
    local n; n=$(<"$mako_list_live_calls"); n=$((n+1)); echo "$n" > "$mako_list_live_calls"
    if (( n == 1 )); then
        printf '42\t1\n'
    else
        return 0
    fi
}
MAKO_ACTIONS_PAYLOAD=""
printf '3\n4\n' > "$ROFI_QUEUE"
main
check "[t9: no mako_invoke during vanished fallback]" ! grep -qF 'mako_invoke' "$CALL_LOG"
check "[t9: journal entry removed via remove_history]" ! grep -qF '"id":42' "$JOURNAL"
rm -f "$mako_list_live_calls"

# Restore default mako_list_live for any future tests
mako_list_live() { printf '%s' "$MAKO_LIVE_PAYLOAD"; }

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
