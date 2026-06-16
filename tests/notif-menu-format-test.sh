#!/usr/bin/env bash
# notif-menu-format-test.sh — unit tests for lib/notif-menu-format.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/notif-menu-format.sh
source "$HERE/../scripts/lib/notif-menu-format.sh"

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

# fmt_l1_header
out=$(fmt_l1_header "Unread (3)")
check "[l1 header has '── Unread (3) ──' shape]" test "$out" = "── Unread (3) ──"

# fmt_l1_row TS APP SUMMARY UNREAD CRITICAL
# Format: HH:MM  App · Summary[ · unread][ · critical]
out=$(fmt_l1_row "2026-06-10T10:42:00-03:00" "Slack" "PR review" 1 0)
check "[l1 row has HH:MM]" test -n "$(grep -F '10:42' <<<"$out")"
check "[l1 row has 'Slack · PR review']" test -n "$(grep -F 'Slack · PR review' <<<"$out")"
check "[l1 row has unread tag]" test -n "$(grep -F ' · unread' <<<"$out")"
check "[l1 row has NO critical tag when urg!=2]" test -z "$(grep -F 'critical' <<<"$out")"

# Critical
out=$(fmt_l1_row "2026-06-10T11:00:00-03:00" "systemd" "service failed" 1 1)
check "[l1 row has critical tag]" test -n "$(grep -F 'critical' <<<"$out")"

# Historical (unread=0): no tags
out=$(fmt_l1_row "2026-06-09T09:00:00-03:00" "firefox" "Done" 0 0)
check "[l1 row historical: no unread tag]" test -z "$(grep -F 'unread' <<<"$out")"
check "[l1 row historical: no critical tag]" test -z "$(grep -F 'critical' <<<"$out")"
check "[l1 row historical: HH:MM present]" test -n "$(grep -F '09:00' <<<"$out")"

# Empty summary → suppress the ' · ' separator
out=$(fmt_l1_row "2026-06-10T11:00:00-03:00" "kitty" "" 0 0)
check "[l1 row empty summary: no trailing ' · ']" test -z "$(grep -F ' · ' <<<"$out")"
check "[l1 row empty summary: HH:MM + app still present]" test -n "$(grep -F '11:00  kitty' <<<"$out")"

# NO icon-metadata suffix (v2 drops icons)
out=$(fmt_l1_row "2026-06-10T10:42:00-03:00" "Slack" "Hello" 1 0)
nul_count=$(printf '%s' "$out" | tr -cd '\0' | wc -c)
check "[l1 row has NO NUL bytes (no icon metadata)]" test "$nul_count" -eq 0

# fmt_l2_separator
out=$(fmt_l2_separator)
check "[l2 separator is '── ──']" test "$out" = "── ──"

# fmt_l2_back
out=$(fmt_l2_back)
check "[l2 back is '← Back']" test "$out" = "← Back"

# fmt_l1_action LABEL — emits a Pango-marked action row that rofi
# (with -markup-rows / pango-markup) renders bold with a leading
# chevron glyph. Visual distinction from notification rows.
out=$(fmt_l1_action "Dismiss all unread")
check "[action row contains label]" test -n "$(echo "$out" | grep -F 'Dismiss all unread')"
check "[action row has Pango bold markup]" test -n "$(echo "$out" | grep -F '<b>')"
check "[action row has leading chevron glyph]" test -n "$(echo "$out" | grep -F '▸')"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
