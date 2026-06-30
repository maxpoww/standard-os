#!/usr/bin/env bash
# test_notif_history_channel — TDD for the derivation that turns the
# JSONL journal into a canvas-shaped JSON cache.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/notif-history-channel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NOTIF_HISTORY_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Fixture: 12 lines, top 10 should appear in entries.
JOURNAL="$TMP/journal.jsonl"
for i in $(seq 1 12); do
    jq -nc --arg app "App$i" --arg title "T$i" --arg body "B$i" \
       --argjson ts $((1718908000 + i)) \
       --arg urgency normal \
       '{app:$app, title:$title, body:$body, ts:$ts, urgency:$urgency}' >> "$JOURNAL"
done

out=$(derive_history_json "$JOURNAL")

check "count = total lines"        "$(printf '%s' "$out" | jq -r .count)"      "12"
check "entries length = 10"        "$(printf '%s' "$out" | jq -r '.entries | length')" "10"
check "first entry is newest (T12)" "$(printf '%s' "$out" | jq -r '.entries[0].title')" "T12"
check "last entry is T3"           "$(printf '%s' "$out" | jq -r '.entries[9].title')"  "T3"

# Empty journal → empty entries, count 0.
echo -n "" > "$JOURNAL"
out=$(derive_history_json "$JOURNAL")
check "empty: count 0"     "$(printf '%s' "$out" | jq -r .count)"               "0"
check "empty: entries []"  "$(printf '%s' "$out" | jq -r '.entries | length')"  "0"

# Missing journal → empty.
out=$(derive_history_json "$TMP/does-not-exist.jsonl")
check "missing: count 0"   "$(printf '%s' "$out" | jq -r .count)"               "0"
check "missing: entries []" "$(printf '%s' "$out" | jq -r '.entries | length')"  "0"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
