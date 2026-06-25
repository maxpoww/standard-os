#!/usr/bin/env bash
# test_standardos_pending — TDD for the waybar custom-module backend.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/widgets/scripts/standardos-pending.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export STAGED_PREFS_FILE="$TMP/staged.json"
export LAST_ERROR_FILE="$TMP/err.json"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Empty state: no files exist.
out="$("$SCRIPT")"
check "empty class"    "$(echo "$out" | jq -rc '.class')" '["empty"]'
check "empty text"     "$(echo "$out" | jq -r '.text')" ""

# Pending state: staging non-empty.
echo '{"shell":"zsh","groups":["wheel"],"groups_display":"wheel"}' > "$STAGED_PREFS_FILE"
out="$("$SCRIPT")"
check "pending class"  "$(echo "$out" | jq -rc '.class')" '["pending"]'
check "pending text"   "$(echo "$out" | jq -r '.text')" "Apply (2)"

# Error state: error file present (takes priority over staging).
echo '{"reason":"group nope does not exist","source_prefs":["groups"]}' > "$LAST_ERROR_FILE"
out="$("$SCRIPT")"
check "error class"    "$(echo "$out" | jq -rc '.class')" '["error"]'
check "error text"     "$(echo "$out" | jq -r '.text')" "Error"
check "error tooltip"  "$(echo "$out" | jq -r '.tooltip')" "group nope does not exist"

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
