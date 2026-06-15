#!/usr/bin/env bash
# notif-journal-test.sh — unit tests for lib/notif-journal.sh
# Pure-function tests; uses a temp file for the journal path.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/notif-journal.sh
source "$HERE/../scripts/lib/notif-journal.sh"

JOURNAL=$(mktemp)
trap 'rm -f "$JOURNAL" "$JOURNAL".tmp.* /tmp/notif-journal-does-not-exist.jsonl.* 2>/dev/null' EXIT

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

# append: writes one line
journal_append "$JOURNAL" "2026-06-10T10:00:00-03:00" 1 "Slack" "Hello" "body text" 1
check "[1 line after one append]" test "$(wc -l < "$JOURNAL")" -eq 1

# append: each line is one valid JSON object
line=$(head -1 "$JOURNAL")
echo "$line" | jq -e . >/dev/null
check "[line is valid JSON]" test $? -eq 0

# append: round-trip fields
check "[id round-trips]" test "$(echo "$line" | jq -r '.id')" = "1"
check "[app round-trips]" test "$(echo "$line" | jq -r '.app')" = "Slack"
check "[summary round-trips]" test "$(echo "$line" | jq -r '.summary')" = "Hello"
check "[body round-trips]" test "$(echo "$line" | jq -r '.body')" = "body text"
check "[urgency round-trips]" test "$(echo "$line" | jq -r '.urgency')" = "1"
check "[dismissed_at empty at start]" test "$(echo "$line" | jq -r '.dismissed_at')" = ""

# append: special chars don't break JSON
journal_append "$JOURNAL" "2026-06-10T10:01:00-03:00" 2 "weird" "has \"quote\"" $'multi\nline' 0
line2=$(sed -n 2p "$JOURNAL")
echo "$line2" | jq -e . >/dev/null
check "[quoted/newline body still valid JSON]" test $? -eq 0
check "[body with quote round-trips]" test "$(echo "$line2" | jq -r '.summary')" = 'has "quote"'

# mark_dismissed: sets dismissed_at on matching id
journal_mark_dismissed "$JOURNAL" 1 "2026-06-10T10:05:00-03:00"
updated=$(head -1 "$JOURNAL")
check "[mark_dismissed sets dismissed_at]" test "$(echo "$updated" | jq -r '.dismissed_at')" = "2026-06-10T10:05:00-03:00"

# mark_dismissed: leaves other entries alone
other=$(sed -n 2p "$JOURNAL")
check "[mark_dismissed doesn't touch other ids]" test "$(echo "$other" | jq -r '.dismissed_at')" = ""

# mark_dismissed: idempotent (same id called twice = single update of same entry)
journal_mark_dismissed "$JOURNAL" 1 "2026-06-10T10:06:00-03:00"
check "[journal still has 2 lines after dup dismiss]" test "$(wc -l < "$JOURNAL")" -eq 2
preserved=$(head -1 "$JOURNAL" | jq -r '.dismissed_at')
check "[mark_dismissed idempotent: first ts preserved]" \
  test "$preserved" = "2026-06-10T10:05:00-03:00"

# prune: trims to max_lines (tail-n semantics)
for i in $(seq 3 10); do
    journal_append "$JOURNAL" "2026-06-10T10:0$i:00-03:00" "$i" "App$i" "Sum$i" "Body$i" 1
done
check "[10 lines before prune]" test "$(wc -l < "$JOURNAL")" -eq 10
journal_prune "$JOURNAL" 5
check "[5 lines after prune to 5]" test "$(wc -l < "$JOURNAL")" -eq 5
# Newest survives
last=$(tail -1 "$JOURNAL")
check "[newest line survives prune]" test "$(echo "$last" | jq -r '.id')" = "10"
# Oldest is gone
check "[oldest pruned]" ! grep -q '"id":1,' "$JOURNAL"

# read: returns last N entries newest-first
out=$(journal_read "$JOURNAL" 3)
n=$(echo "$out" | wc -l)
check "[journal_read N=3 returns 3 lines]" test "$n" -eq 3
first=$(echo "$out" | head -1 | jq -r '.id')
check "[journal_read returns newest first]" test "$first" = "10"

# C1 regression: mark_dismissed on an empty file must NOT wipe it
empty_journal=$(mktemp)
: > "$empty_journal"      # truncate to 0 bytes (exists but empty)
journal_mark_dismissed "$empty_journal" 1 "TS"
check "[C1: mark_dismissed on empty file leaves it 0-bytes (no wipe-then-empty file race)]" test "$(stat -c %s "$empty_journal" 2>/dev/null)" -eq 0
# And confirm no stale tmp files left
check "[C1: no stale tmp files after empty-file mark_dismissed]" test -z "$(echo "$empty_journal".tmp.* 2>/dev/null | grep -v '\*')"
rm -f "$empty_journal"

# mark_dismissed on a non-existent file is a clean no-op
journal_mark_dismissed "/tmp/notif-journal-does-not-exist.jsonl.$$" 99 "TS"
check "[mark_dismissed no-op on missing file]" test $? -eq 0

# empty journal: read handles missing/empty file
empty=$(mktemp)
out=$(journal_read "$empty" 5)
check "[empty journal read returns empty string]" test -z "$out"
rm -f "$empty"

# ─── journal_remove (id+ts keyed) ─────────────────────────────────────────
# Reset to a known state: 2-line journal where line 1 has dismissed_at set.
# Then add a third line with id=1 again (recycled id, different ts) to test
# the two-arg key semantics.
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-10T10:00:00-03:00" 1 "appA" "sumA" "bodyA" 1
journal_append "$JOURNAL" "2026-06-10T10:01:00-03:00" 2 "appB" "sumB" "bodyB" 1
journal_mark_dismissed "$JOURNAL" 1 "2026-06-10T10:05:00-03:00"
journal_append "$JOURNAL" "2026-06-10T11:00:00-03:00" 1 "appA" "sumA2" "bodyA2" 1
before_lines=$(wc -l < "$JOURNAL")
check "[journal_remove: pre-state has multiple lines]" test "$before_lines" -gt 1

# Remove the original id=1 line (ts=10:00:00). Same-id later-ts line and id=2 line stay.
journal_remove "$JOURNAL" 1 "2026-06-10T10:00:00-03:00"
check "[journal_remove: dropped line count by 1]" test "$(wc -l < "$JOURNAL")" -eq $((before_lines - 1))
check "[journal_remove: targeted ts gone]" ! grep -qF '"ts":"2026-06-10T10:00:00-03:00"' "$JOURNAL"
check "[journal_remove: same-id later-ts preserved]" grep -qF '"ts":"2026-06-10T11:00:00-03:00"' "$JOURNAL"
check "[journal_remove: untouched id=2 preserved]" grep -qF '"id":2' "$JOURNAL"

# No-match → no-op
post_lines=$(wc -l < "$JOURNAL")
journal_remove "$JOURNAL" 999 "anything"
check "[journal_remove: no-match leaves file intact]" test "$(wc -l < "$JOURNAL")" -eq "$post_lines"

# Missing file → no-op (no error)
journal_remove "/tmp/notif-journal-remove-missing.$$.jsonl" 1 "ts"
check "[journal_remove: missing file is clean no-op]" test $? -eq 0

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
