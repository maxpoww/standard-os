#!/usr/bin/env bash
# test_pomodoro_daemon — TDD for the state machine and tick logic.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/pomodoro-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

POMODORO_DAEMON_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Initial state = idle.
state_reset
check "initial state idle"      "$STATE"            "idle"
check "initial blocks_today 0"  "$BLOCKS_TODAY"     "0"

# Start a focus block.
cmd_start 1500
check "after start state=running" "$STATE"          "running"
check "after start kind=focus"    "$BLOCK_KIND"     "focus"
check "after start remaining=1500" "$REMAINING_S"   "1500"

# Tick 30 seconds.
tick 30
check "after tick remaining=1470" "$REMAINING_S"    "1470"

# Skip to break (block completed).
cmd_skip
check "after skip kind=short_break" "$BLOCK_KIND"   "short_break"
check "after skip blocks_today=1"   "$BLOCKS_TODAY" "1"

# Stop.
cmd_stop
check "after stop state=idle"      "$STATE"         "idle"

# emit_json
state_reset
cmd_start 1500
tick 60
out=$(emit_json)
check "emit_json state"     "$(printf '%s' "$out" | jq -r .state)"             "running"
check "emit_json remaining" "$(printf '%s' "$out" | jq -r .remaining_seconds)" "1440"
check "emit_json text"      "$(printf '%s' "$out" | jq -r .remaining_text)"    "24:00"

# After 4 focus blocks, next break should be long_break.
state_reset
for i in 1 2 3 4; do
    cmd_start 1500
    cmd_skip
done
check "4 focus → long break"  "$BLOCK_KIND"  "long_break"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
