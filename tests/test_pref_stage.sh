#!/usr/bin/env bash
# test_pref_stage — TDD for the staging file mutator.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/pref-stage"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export STAGED_PREFS_FILE="$TMP/staged.json"
export PREF_STAGE_SKIP_SIGNAL=1  # don't actually pkill waybar in tests

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Setting a string key creates the file with {key:value}.
"$SCRIPT" shell '"zsh"'
check "shell set"        "$(jq -r '.shell' "$STAGED_PREFS_FILE")"  "zsh"

# Setting an array key merges (does not overwrite the shell).
"$SCRIPT" groups '["wheel","audio"]'
check "shell preserved"  "$(jq -r '.shell' "$STAGED_PREFS_FILE")"  "zsh"
check "groups set"       "$(jq -rc '.groups' "$STAGED_PREFS_FILE")" '["wheel","audio"]'
check "groups_display"   "$(jq -r '.groups_display' "$STAGED_PREFS_FILE")" "wheel · audio"

# Re-setting overwrites.
"$SCRIPT" shell '"bash"'
check "shell overwritten" "$(jq -r '.shell' "$STAGED_PREFS_FILE")" "bash"

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
