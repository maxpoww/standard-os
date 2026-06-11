#!/usr/bin/env bash
# notif-schedule-test.sh — unit tests for lib/notif-schedule.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/notif-schedule.sh
source "$HERE/../scripts/lib/notif-schedule.sh"

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

out=$(parse_schedule "22:00-08:00 Mon-Fri")
IFS=$'\t' read -r s e m <<< "$out"
check "[parse: 22:00-08:00 Mon-Fri start=2200]" test "$s" -eq 2200
check "[parse: 22:00-08:00 Mon-Fri end=800]" test "$e" -eq 800
check "[parse: Mon-Fri mask=0x1F]" test "$m" -eq 31

out=$(parse_schedule "09:00-17:00 *")
IFS=$'\t' read -r s e m <<< "$out"
check "[parse: * → all-day mask 0x7F]" test "$m" -eq 127

out=$(parse_schedule "00:00-23:59")
IFS=$'\t' read -r s e m <<< "$out"
check "[parse: bare HH:MM-HH:MM → mask 0x7F]" test "$m" -eq 127

check "[match: 10:00 in 09:00-17:00 Mon-Fri on Mon]" schedule_matches 900 1700 31 1 1000
check "[no-match: 18:00 in 09:00-17:00 Mon-Fri on Mon]" ! schedule_matches 900 1700 31 1 1800
check "[no-match: 10:00 on Sat in Mon-Fri]" ! schedule_matches 900 1700 31 6 1000

check "[match: 23:30 in 22:00-08:00 * on Mon]" schedule_matches 2200 800 127 1 2330
check "[match: 03:00 in 22:00-08:00 * on Tue]" schedule_matches 2200 800 127 2 300
check "[no-match: 09:00 in 22:00-08:00 * on Mon]" ! schedule_matches 2200 800 127 1 900
check "[match: 22:00 sharp]" schedule_matches 2200 800 127 1 2200
check "[no-match: 08:00 sharp (end-exclusive)]" ! schedule_matches 2200 800 127 1 800

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
OVERRIDE="$TMPDIR/override"
PROFILES="$TMPDIR/profiles.json"
cat > "$PROFILES" << 'JSON'
{
    "off":   {"silenceMode":"none"},
    "dnd":   {"silenceMode":"transient"},
    "sleep": {"silenceMode":"all-but-critical-silent","schedule":"22:00-08:00 *"},
    "work":  {"silenceMode":"non-allowed","schedule":"09:00-17:00 Mon-Fri","allowedApps":[]},
    "gaming":{"silenceMode":"all"},
    "media": {"silenceMode":"all-but-critical-silent"}
}
JSON

epoch_of() { date -d "$1" +%s; }

EPOCH=$(epoch_of "2026-06-08 23:30")
out=$(resolve_active_profile "" "$PROFILES" "$EPOCH")
IFS=$'\t' read -r prof until_iso <<< "$out"
check "[resolve: Mon 23:30 → sleep]" test "$prof" = "sleep"

EPOCH=$(epoch_of "2026-06-08 10:00")
out=$(resolve_active_profile "" "$PROFILES" "$EPOCH")
IFS=$'\t' read -r prof _ <<< "$out"
check "[resolve: Mon 10:00 → work]" test "$prof" = "work"

EPOCH=$(epoch_of "2026-06-13 10:00")
out=$(resolve_active_profile "" "$PROFILES" "$EPOCH")
IFS=$'\t' read -r prof _ <<< "$out"
check "[resolve: Sat 10:00 → off (no match)]" test "$prof" = "off"

printf 'profile=gaming\nvalid_until=2030-01-01T00:00:00-03:00\n' > "$OVERRIDE"
EPOCH=$(epoch_of "2026-06-08 10:00")
out=$(resolve_active_profile "$OVERRIDE" "$PROFILES" "$EPOCH")
IFS=$'\t' read -r prof _ <<< "$out"
check "[resolve: manual override 'gaming' beats Mon 10:00 work]" test "$prof" = "gaming"

EPOCH=$(epoch_of "2030-01-01 00:00:01")
printf 'profile=gaming\nvalid_until=2030-01-01T00:00:00-03:00\n' > "$OVERRIDE"
out=$(resolve_active_profile "$OVERRIDE" "$PROFILES" "$EPOCH")
IFS=$'\t' read -r prof _ <<< "$out"
check "[resolve: expired override → no longer gaming]" test "$prof" != "gaming"
check "[resolve: expired override → file removed]" test ! -f "$OVERRIDE"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
