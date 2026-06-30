#!/usr/bin/env bash
# test_cal_source_daemon — TDD for the ICS parse and emit path.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/cal-source-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CAL_SOURCE_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Fixture: a single ICS file with 3 events, one in the past, one today,
# one tomorrow. Tests use a fixed reference now so the time math is
# deterministic.

NOW_FIXED=1718884800  # 2024-06-20 12:00 UTC — before both future events
FIXTURE_DIR="$TMP/calendars"
mkdir -p "$FIXTURE_DIR"
cat > "$FIXTURE_DIR/test.ics" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
SUMMARY:Past event
DTSTART:20240601T100000Z
DTEND:20240601T110000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:Today event
DTSTART:20240620T140000Z
DTEND:20240620T150000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:Tomorrow event
DTSTART:20240621T090000Z
DTEND:20240621T100000Z
END:VEVENT
END:VCALENDAR
EOF

out=$(CAL_NOW="$NOW_FIXED" derive_agenda_json "$FIXTURE_DIR")

# Past event should be dropped; future 2 should remain.
check "events.length = 2"           "$(printf '%s' "$out" | jq -r '.events | length')"  "2"
check "first event = Today event"    "$(printf '%s' "$out" | jq -r '.events[0].summary')" "Today event"
check "second event = Tomorrow"      "$(printf '%s' "$out" | jq -r '.events[1].summary')" "Tomorrow event"
check "today_count = 1"              "$(printf '%s' "$out" | jq -r .today_count)"        "1"

# Empty directory.
EMPTY_DIR="$TMP/empty"
mkdir -p "$EMPTY_DIR"
out=$(CAL_NOW="$NOW_FIXED" derive_agenda_json "$EMPTY_DIR")
check "empty dir → 0 events"        "$(printf '%s' "$out" | jq -r '.events | length')"  "0"
check "empty dir → today_count 0"   "$(printf '%s' "$out" | jq -r .today_count)"        "0"

# Missing directory.
out=$(CAL_NOW="$NOW_FIXED" derive_agenda_json "$TMP/does-not-exist")
check "missing dir → 0 events"      "$(printf '%s' "$out" | jq -r '.events | length')"  "0"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
