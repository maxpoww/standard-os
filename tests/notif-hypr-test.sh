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

# ── multiple matches → picks the first (head -1) ────────────────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0xAAA","class":"firefox","title":"a"},{"address":"0xBBB","class":"firefox","title":"b"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[multiple matches: returns 0]" test $? -eq 0
check "[multiple matches: dispatched first address (0xAAA)]" \
    grep -qF 'dispatch focuswindow address:0xAAA' "$HYPRCTL_LOG"
check "[multiple matches: did NOT dispatch second address (0xBBB)]" \
    ! grep -qF '0xBBB' "$HYPRCTL_LOG"

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
