#!/usr/bin/env bash
# Deterministic unit tests for scripts/lib/colors.sh.
# Run from project root:  bash tests/colors-test.sh

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=../scripts/lib/colors.sh
. "$HERE/../scripts/lib/colors.sh"

fail=0
assert_eq() {
    local got=$1 want=$2 label=$3
    if [[ $got != "$want" ]]; then
        printf '✗ %s: got %q, want %q\n' "$label" "$got" "$want" >&2
        fail=1
    else
        printf '✓ %s\n' "$label"
    fi
}

# hex_to_rgb / rgb_to_hex roundtrip
read -r r g b < <(hex_to_rgb aabbcc)
assert_eq "$r $g $b" "170 187 204" "hex_to_rgb aabbcc"
assert_eq "$(rgb_to_hex 170 187 204)" "aabbcc" "rgb_to_hex roundtrip"

# luma BT.601
assert_eq "$(luma 255 255 255)" "255" "luma white"
assert_eq "$(luma 0 0 0)" "0" "luma black"

# rgb_dist_sq
assert_eq "$(rgb_dist_sq 0 0 0 0 0 0)" "0" "dist same"
assert_eq "$(rgb_dist_sq 10 0 0 0 0 0)" "100" "dist 10 channel"

# mismatch dark theme on → darken, clamped
m=$(mismatch_hex aabbcc 1 40 30 225)
read -r mr mg mb < <(hex_to_rgb "$m")
ml=$(luma "$mr" "$mg" "$mb")
ol=$(luma 170 187 204)
[[ $ml -lt $ol ]] || {
    echo "✗ dark mismatch should reduce luma" >&2
    fail=1
}
[[ $ml -ge 30 ]] || {
    echo "✗ dark mismatch should respect lower clamp" >&2
    fail=1
}
echo "✓ mismatch dark theme reduces luma"

# mismatch light theme → lighten, clamped
m=$(mismatch_hex 332244 0 40 30 225)
read -r mr mg mb < <(hex_to_rgb "$m")
ml=$(luma "$mr" "$mg" "$mb")
ol=$(luma 51 34 68)
[[ $ml -gt $ol ]] || {
    echo "✗ light mismatch should raise luma" >&2
    fail=1
}
[[ $ml -le 225 ]] || {
    echo "✗ light mismatch should respect upper clamp" >&2
    fail=1
}
echo "✓ mismatch light theme raises luma"

# mixed: 50% red 100x100 + 50% blue 100x100 → purple
mix_init
mix_add ff0000 10000
mix_add 0000ff 10000
assert_eq "$(mix_finalize)" "7f007f" "mix red+blue equal area"

# mixed: 75% red, 25% blue → reddish
mix_init
mix_add ff0000 30000
mix_add 0000ff 10000
out=$(mix_finalize)
read -r mr mg mb < <(hex_to_rgb "$out")
[[ $mr -gt $mb ]] || {
    echo "✗ red-weighted mix should be redder than blue" >&2
    fail=1
}
echo "✓ mixed area-weighted favors larger window"

exit "$fail"
