#!/usr/bin/env bash
# Unit tests for standard-os-update pipeline phase functions.
# Each phase is exercised in isolation via STANDARD_OS_UPDATE_LIB_ONLY=1.
set -uo pipefail

HERE=$(dirname "$(readlink -f "$0")")
STANDARD_OS_UPDATE_LIB_ONLY=1
# shellcheck source=../waybar/scripts/standard-os-update
. "$HERE/../waybar/scripts/standard-os-update"

fail=0
assert_eq() {
    local got=$1 want=$2 label=$3
    if [[ $got != "$want" ]]; then
        printf '✗ %s\n   got:  %q\n   want: %q\n' "$label" "$got" "$want" >&2
        fail=1
    else
        printf '✓ %s\n' "$label"
    fi
}

# ─── phase_pre_flight ─────────────────────────────────────────────────────
# Stub waybar-self-test to return 0 (healthy) — phase returns 0.
fake_self_test_green() { return 0; }
fake_self_test_red()   { return 1; }

WAYBAR_SELF_TEST_CMD=fake_self_test_green
phase_pre_flight; rc=$?
assert_eq "$rc" "0" "phase_pre_flight: green self-test → 0"

WAYBAR_SELF_TEST_CMD=fake_self_test_red
phase_pre_flight; rc=$?
assert_eq "$rc" "1" "phase_pre_flight: red self-test → 1"

# ─── phase_dry_build ──────────────────────────────────────────────────────
fake_pkexec_ok()   { return 0; }
fake_pkexec_fail() { echo "fake build error" >&2; return 1; }

PKEXEC_CMD=fake_pkexec_ok
phase_dry_build; rc=$?
assert_eq "$rc" "0" "phase_dry_build: pkexec ok → 0"

PKEXEC_CMD=fake_pkexec_fail
phase_dry_build; rc=$?
assert_eq "$rc" "1" "phase_dry_build: pkexec fail → 1"

# ─── phase_switch ─────────────────────────────────────────────────────────
PKEXEC_CMD=fake_pkexec_ok
phase_switch; rc=$?
assert_eq "$rc" "0" "phase_switch: pkexec ok → 0"

PKEXEC_CMD=fake_pkexec_fail
phase_switch; rc=$?
assert_eq "$rc" "1" "phase_switch: pkexec fail → 1"

exit "$fail"
