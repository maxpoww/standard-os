#!/usr/bin/env bash
# notif-hypr-test.sh — unit tests for lib/notif-hypr.sh (mocked hyprctl)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Mocks — must be defined BEFORE sourcing the lib so its functions
# resolve through bash's function table (not PATH).
HYPRCTL_LOG=$(mktemp)
HYPRCTL_CLIENTS_JSON='[]'

hyprctl() {
    # Calls of the form: hyprctl -j clients         → echo $HYPRCTL_CLIENTS_JSON
    # Calls of the form: hyprctl dispatch focuswindow ...  → log args
    if [[ "$1" == "-j" && "${2:-}" == "clients" ]]; then
        printf '%s' "$HYPRCTL_CLIENTS_JSON"
        return 0
    fi
    printf 'hyprctl %s\n' "$*" >> "$HYPRCTL_LOG"
    return 0
}
export -f hyprctl 2>/dev/null || true

# shellcheck source=../scripts/lib/notif-hypr.sh
source "$HERE/../scripts/lib/notif-hypr.sh"

# Override _pid_subtree_cmdlines with a test-controlled mock so the lib's
# multi-match scoring path doesn't depend on real /proc state. Tests set
# PID_SUBTREE_<PID>=... to register canned cmdlines for a given pid.
declare -A PID_SUBTREE=()
_pid_subtree_cmdlines() {
    local pid="$1"
    printf '%s' "${PID_SUBTREE[$pid]:-}"
}

trap 'rm -f "$HYPRCTL_LOG"' EXIT

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

# ── hypr_focus_by_class: empty clients → returns 1, no dispatch ─────────
HYPRCTL_CLIENTS_JSON='[]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[empty clients: returns 1]" test $? -eq 1
check "[empty clients: no dispatch logged]" test ! -s "$HYPRCTL_LOG"

# ── exact class match (case-insensitive) ────────────────────────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0x123","class":"firefox","title":"Reddit"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[exact match: returns 0]" test $? -eq 0
check "[exact match: dispatch focuswindow address:0x123 logged]" \
    grep -qF 'dispatch focuswindow address:0x123' "$HYPRCTL_LOG"

# ── substring match (class contains the app-name-lowercased) ────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0x456","class":"firefox-developer-edition","title":"test"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[substring match: returns 0]" test $? -eq 0
check "[substring match: dispatch focuswindow address:0x456 logged]" \
    grep -qF 'dispatch focuswindow address:0x456' "$HYPRCTL_LOG"

# ── no match → returns 1, no dispatch ───────────────────────────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0x789","class":"kitty","title":"shell"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[no match: returns 1]" test $? -eq 1
check "[no match: no dispatch logged]" test ! -s "$HYPRCTL_LOG"

# ── multi-match, no summary/body, no descendant data — first wins ────────
# Both clients have identical focusHistoryID=0 (default), no scoring data
# differentiates them, so the first-encountered (0xAAA) is kept.
HYPRCTL_CLIENTS_JSON='[{"address":"0xAAA","class":"firefox","title":"a","pid":100,"focusHistoryID":0},{"address":"0xBBB","class":"firefox","title":"b","pid":200,"focusHistoryID":0}]'
PID_SUBTREE=()
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[multi-match no data: returns 0]" test $? -eq 0
check "[multi-match no data: dispatched 0xAAA (first encountered)]" \
    grep -qF 'dispatch focuswindow address:0xAAA' "$HYPRCTL_LOG"
check "[multi-match no data: did NOT dispatch 0xBBB]" \
    ! grep -qF '0xBBB' "$HYPRCTL_LOG"

# ── multi-match, focusHistoryID tiebreaker — lower wins ─────────────────
# Same class, no scoring data. 0xBBB has fhid=0 (most recent), 0xAAA fhid=2.
HYPRCTL_CLIENTS_JSON='[{"address":"0xAAA","class":"firefox","pid":100,"focusHistoryID":2},{"address":"0xBBB","class":"firefox","pid":200,"focusHistoryID":0}]'
PID_SUBTREE=()
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[fhid tiebreak: dispatched 0xBBB (lower fhid)]" \
    grep -qF 'dispatch focuswindow address:0xBBB' "$HYPRCTL_LOG"

# ── multi-match scoring by descendant cmdlines (the Claude case) ────────
# Three kitty windows; only pid 550732 has "claude" in its subtree. The
# notif summary "Claude Code" tokenizes to {"claude","code"}; pid 550732
# scores 1 (claude matches), the others score 0. 550732 wins despite
# having the LARGEST focusHistoryID (least recent).
HYPRCTL_CLIENTS_JSON='[
    {"address":"0xK1","class":"kitty","pid":1900103,"focusHistoryID":0},
    {"address":"0xK2","class":"kitty","pid":1580649,"focusHistoryID":1},
    {"address":"0xK3","class":"kitty","pid":550732,"focusHistoryID":2}
]'
PID_SUBTREE=(
    [1900103]='zsh --login'
    [1580649]='zsh --login'
    [550732]='zsh --login
claude --dangerously-skip-permissions'
)
: > "$HYPRCTL_LOG"
hypr_focus_by_class "kitty" "Claude Code" "Claude is waiting for your input"
check "[descendant scoring: dispatched 0xK3 (the Claude kitty)]" \
    grep -qF 'dispatch focuswindow address:0xK3' "$HYPRCTL_LOG"
check "[descendant scoring: did NOT dispatch 0xK1 (no claude in subtree)]" \
    ! grep -qF '0xK1' "$HYPRCTL_LOG"
check "[descendant scoring: did NOT dispatch 0xK2 (no claude in subtree)]" \
    ! grep -qF '0xK2' "$HYPRCTL_LOG"

# ── multi-match scoring: ties fall back to focusHistoryID ───────────────
# Both kitties have "claude" in subtree (score=1). 0xK2 has lower fhid.
HYPRCTL_CLIENTS_JSON='[
    {"address":"0xK1","class":"kitty","pid":100,"focusHistoryID":2},
    {"address":"0xK2","class":"kitty","pid":200,"focusHistoryID":0}
]'
PID_SUBTREE=(
    [100]='claude --help'
    [200]='claude --foo'
)
: > "$HYPRCTL_LOG"
hypr_focus_by_class "kitty" "Claude Code" ""
check "[descendant scoring tie: dispatched 0xK2 (lower fhid wins)]" \
    grep -qF 'dispatch focuswindow address:0xK2' "$HYPRCTL_LOG"

# ── short words (≤3 chars) are filtered out of scoring ──────────────────
# Summary is "an OS" — both words are ≤3 chars, filtered out, score=0 for all.
# Falls back to focusHistoryID tiebreak.
HYPRCTL_CLIENTS_JSON='[
    {"address":"0xK1","class":"kitty","pid":100,"focusHistoryID":2},
    {"address":"0xK2","class":"kitty","pid":200,"focusHistoryID":0}
]'
PID_SUBTREE=(
    [100]='something OS'
    [200]='something else'
)
: > "$HYPRCTL_LOG"
hypr_focus_by_class "kitty" "an OS" ""
check "[short-word filter: no false match, fhid tiebreak picks 0xK2]" \
    grep -qF 'dispatch focuswindow address:0xK2' "$HYPRCTL_LOG"

PID_SUBTREE=()   # reset for any later tests

# ── app-name with spaces / unusual chars: lowercased then substring ─────
HYPRCTL_CLIENTS_JSON='[{"address":"0xCCC","class":"org.telegram.desktop","title":"chat"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Telegram"
check "[telegram substring matches org.telegram.desktop]" test $? -eq 0
check "[telegram substring: dispatch focuswindow address:0xCCC logged]" \
    grep -qF 'dispatch focuswindow address:0xCCC' "$HYPRCTL_LOG"

# ── hyprctl returns malformed JSON → graceful return 1 ──────────────────
HYPRCTL_CLIENTS_JSON='not json'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[malformed JSON: returns 1]" test $? -eq 1

# ── match but no address field → returns 1, no dispatch ─────────────────
HYPRCTL_CLIENTS_JSON='[{"class":"firefox"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[match but no address: returns 1]" test $? -eq 1
check "[match but no address: no dispatch logged]" test ! -s "$HYPRCTL_LOG"

# ── empty hyprctl output (zero-byte) → returns 1 cleanly ────────────────
HYPRCTL_CLIENTS_JSON=''
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[empty hyprctl output: returns 1]" test $? -eq 1
check "[empty hyprctl output: no dispatch logged]" test ! -s "$HYPRCTL_LOG"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
