#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/notif-profile-format.sh
source "$HERE/../scripts/lib/notif-profile-format.sh"

pass=0; fail=0
check() {
    local label="$1"; shift
    if "$@"; then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else fail=$((fail+1)); printf '✗ %s\n' "$label"; fi
}

# format_profile_header "Work" "17:00" → header row showing active+until
hdr=$(format_profile_header "Work" "17:00")
check "[header: contains 'Work']" test -n "$(echo "$hdr" | grep -F 'Work')"
check "[header: contains '17:00']" test -n "$(echo "$hdr" | grep -F '17:00')"

# format_profile_header "Off" "" → no "until" suffix
hdr=$(format_profile_header "Off" "")
check "[header: no until when empty]" test -z "$(echo "$hdr" | grep -F 'until')"
check "[header: 'Off' present]" test -n "$(echo "$hdr" | grep -F 'Off')"

# format_profile_row "work" "Work" "" "1" → marker + name
row=$(format_profile_row "work" "Work" "" "1")
check "[row: active marker present]" test -n "$(echo "$row" | grep -F '✓')"
check "[row: 'Work' name present]" test -n "$(echo "$row" | grep -F 'Work')"

# Non-active row → no marker
row=$(format_profile_row "sleep" "Sleep" "" "0")
check "[row: inactive has no marker]" test -z "$(echo "$row" | grep -F '✓')"

# Row with schedule annotation
row=$(format_profile_row "sleep" "Sleep" "" "0" "22:00-08:00 *")
check "[row: schedule annotation appended]" test -n "$(echo "$row" | grep -F '22:00')"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d failed\n' "$fail"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
