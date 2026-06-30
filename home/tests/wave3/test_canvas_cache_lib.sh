#!/usr/bin/env bash
# test_canvas_cache_lib — unit tests for scripts/lib/canvas-cache.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/lib/canvas-cache.sh"
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((++pass))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((++fail))
    fi
}

# --- cache_write_atomic ---
TARGET="$TMP/foo.json"
cache_write_atomic "$TARGET" '{"a":1}'
check "write_atomic creates file" "$(cat "$TARGET")" '{"a":1}'

cache_write_atomic "$TARGET" '{"a":2}'
check "write_atomic overwrites" "$(cat "$TARGET")" '{"a":2}'

# No partial .tmp file left over
check "write_atomic cleans tmp" \
    "$(ls "$TMP"/*.tmp.* 2>/dev/null | wc -l)" "0"

# --- cache_read_or_default ---
check "read existing" "$(cache_read_or_default "$TARGET" 'fallback')" '{"a":2}'
check "read missing → default" \
    "$(cache_read_or_default "$TMP/does-not-exist" 'fallback')" 'fallback'

# --- cache_signal_if_changed (no signal counted; just file behavior) ---
SIG_TARGET="$TMP/sig.json"
cache_write_atomic "$SIG_TARGET" 'A'
# Same content → no write side-effect we can observe other than mtime; mtime
# IS the observable: if cache_signal_if_changed skips on equal content, mtime
# stays. If it writes, mtime advances.
orig_mtime=$(stat -c %Y "$SIG_TARGET")
sleep 1.1  # advance clock past 1 s mtime granularity floor
cache_signal_if_changed "$SIG_TARGET" 'A' 99 >/dev/null 2>&1 || true
new_mtime=$(stat -c %Y "$SIG_TARGET")
check "signal_if_changed: equal content → no rewrite" \
    "$new_mtime" "$orig_mtime"

cache_signal_if_changed "$SIG_TARGET" 'B' 99 >/dev/null 2>&1 || true
check "signal_if_changed: new content → file updated" \
    "$(cat "$SIG_TARGET")" "B"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
