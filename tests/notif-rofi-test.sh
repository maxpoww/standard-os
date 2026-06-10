#!/usr/bin/env bash
# notif-rofi-test.sh — unit tests for lib/notif-rofi-format.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/notif-rofi-format.sh
source "$HERE/../scripts/lib/notif-rofi-format.sh"

pass=0; fail=0
check() {
    local label="$1"; shift
    local negate=0
    if [[ ${1:-} == "!" ]]; then negate=1; shift; fi
    if "$@"; then
        if (( negate )); then fail=$((fail+1)); printf '✗ %s\n' "$label"; else pass=$((pass+1)); printf '✓ %s\n' "$label"; fi
    else
        if (( negate )); then pass=$((pass+1)); printf '✓ %s\n' "$label"; else fail=$((fail+1)); printf '✗ %s\n' "$label"; fi
    fi
}

# format_rofi_header LABEL — produces a non-selectable rofi separator row
hdr=$(format_rofi_header "Unread (3)")
check "[header contains the label]" test -n "$(echo "$hdr" | grep -F 'Unread (3)')"

# format_rofi_entry TS APP SUMMARY URGENCY UNREAD CRITICAL
# Format: HH:MM  app · summary  [ · unread[ · critical]]
out=$(format_rofi_entry "2026-06-10T10:42:00-03:00" "Slack" "PR review requested" 1 1 0)
check "[entry has HH:MM]" test -n "$(echo "$out" | grep -F '10:42')"
check "[entry has 'Slack · PR review requested']" test -n "$(echo "$out" | grep -F 'Slack · PR review')"
check "[unread tag present when unread=1]" test -n "$(echo "$out" | grep -F 'unread')"
check "[no 'critical' tag when urgency!=2]" test -z "$(echo "$out" | grep -F 'critical')"

# unread=1, critical=1 → unread + critical tag
out=$(format_rofi_entry "2026-06-10T11:00:00-03:00" "systemd" "foo.service failed" 2 1 1)
check "[critical tag present when urgency=2]" test -n "$(echo "$out" | grep -F 'critical')"

# unread=0 → no unread tag, no critical tag (historical entry)
out=$(format_rofi_entry "2026-06-09T09:00:00-03:00" "firefox" "Download complete" 1 0 0)
check "[no unread tag when unread=0]" test -z "$(echo "$out" | grep -F 'unread')"
check "[historical: HH:MM still present]" test -n "$(echo "$out" | grep -F '09:00')"

# Summary with quotes / special chars doesn't break the row
out=$(format_rofi_entry "2026-06-10T11:00:00-03:00" "weird" 'has "quote"' 1 1 0)
check "[quoted summary passes through]" test -n "$(echo "$out" | grep -F 'has "quote"')"

# Empty app / empty summary still produce a non-empty line
out=$(format_rofi_entry "2026-06-10T11:00:00-03:00" "" "" 1 0 0)
check "[empty app/summary still produces a row]" test -n "$out"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
