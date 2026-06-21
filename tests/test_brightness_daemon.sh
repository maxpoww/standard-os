#!/usr/bin/env bash
# test_brightness_daemon — TDD for the sysfs read + JSON derive path.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/brightness-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BRIGHTNESS_DAEMON_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

FAKE_DEV="$TMP/intel_backlight"
mkdir -p "$FAKE_DEV"

# Case 1: 84/1200 → pct=7 (rounded)
echo 1200 > "$FAKE_DEV/max_brightness"
echo 84   > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000000)
check "84/1200 pct=7"        "$(printf '%s' "$out" | jq -r .pct)"     "7"
check "84/1200 raw=84"       "$(printf '%s' "$out" | jq -r .raw)"     "84"
check "84/1200 max=1200"     "$(printf '%s' "$out" | jq -r .max)"     "1200"
check "84/1200 device"       "$(printf '%s' "$out" | jq -r .device)"  "intel_backlight"
check "84/1200 updated"      "$(printf '%s' "$out" | jq -r .updated)" "1782000000"

# Case 2: 600/1200 → pct=50
echo 600 > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000001)
check "600/1200 pct=50"      "$(printf '%s' "$out" | jq -r .pct)"     "50"

# Case 3: 1200/1200 → pct=100
echo 1200 > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000002)
check "1200/1200 pct=100"    "$(printf '%s' "$out" | jq -r .pct)"     "100"

# Case 4: 0/1200 → pct=0
echo 0 > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000003)
check "0/1200 pct=0"         "$(printf '%s' "$out" | jq -r .pct)"     "0"

# Case 5: missing actual_brightness → graceful null (no crash)
rm -f "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000004)
check "missing actual → null" "$(printf '%s' "$out" | jq -r '.pct // "null"')" "null"

# Case 6: missing max_brightness → graceful null (no div-by-zero)
echo 84 > "$FAKE_DEV/actual_brightness"
rm -f "$FAKE_DEV/max_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000005)
check "missing max → null"    "$(printf '%s' "$out" | jq -r '.pct // "null"')" "null"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
