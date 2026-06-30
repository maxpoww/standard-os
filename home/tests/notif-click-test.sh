#!/usr/bin/env bash
# Tests for notif-click.sh's pure decision function.
# Source the script with NOTIF_CLICK_LIB_ONLY=1 to skip the action runner.

set -uo pipefail

HERE=$(dirname "$(readlink -f "$0")")
NOTIF_CLICK_LIB_ONLY=1
export NOTIF_CLICK_LIB_ONLY
# shellcheck source=../scripts/notif-click
. "$HERE/../scripts/notif-click"

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

# Cache strings matching what notif-daemon writes (see notif-state-test.sh).
EMPTY='{"text":""}'
BELL=$'\xef\x83\xb3'
REST_GREEN='{"text":"'"$BELL"'","class":["opt-pill","dark","opt-pin-green"],"tooltip":"Notifications"}'
REST_ORANGE='{"text":"'"$BELL"'","class":["opt-pill","dark","opt-pin-orange"],"tooltip":"Notifications"}'
TRANSIENT_NORMAL='{"text":" Firefox · Download complete","class":["opt-pill","dark","opt-flash"],"tooltip":"file.tar.gz"}'
TRANSIENT_CRIT='{"text":" Slack · PAGE","class":["opt-pill","dark","opt-no","opt-pulse-orange","opt-flash"],"tooltip":"Wake up"}'
ACKED_CRIT='{"text":" Slack · PAGE","class":["opt-pill","dark","opt-no","opt-pin-orange"],"tooltip":"Wake up"}'

# ─── invoke action ─────────────────────────────────────────────────────────
# Transient face → invoke the latest unread's default action
assert_eq "$(notif_click_decide invoke "$TRANSIENT_NORMAL")" "invoke-latest" \
    "invoke on transient-normal → invoke-latest"
assert_eq "$(notif_click_decide invoke "$TRANSIENT_CRIT")" "invoke-latest" \
    "invoke on transient-critical → invoke-latest"
assert_eq "$(notif_click_decide invoke "$ACKED_CRIT")" "invoke-latest" \
    "invoke on acked-critical (still wide) → invoke-latest"

# Rest faces → dismiss-all (interim until drawer ships)
assert_eq "$(notif_click_decide invoke "$REST_GREEN")" "dismiss-all" \
    "invoke on rest-green → dismiss-all (interim)"
assert_eq "$(notif_click_decide invoke "$REST_ORANGE")" "dismiss-all" \
    "invoke on rest-orange → dismiss-all (interim)"

# Empty cache → no-op (nothing to click)
assert_eq "$(notif_click_decide invoke "$EMPTY")" "noop" \
    "invoke on empty cache → noop"

# Garbage / missing → no-op (defensive)
assert_eq "$(notif_click_decide invoke "")" "noop" \
    "invoke on empty string → noop"
assert_eq "$(notif_click_decide invoke "not json at all")" "noop" \
    "invoke on garbage → noop"

# ─── drawer action ─────────────────────────────────────────────────────────
# Always noop until the drawer follow-up ships.
assert_eq "$(notif_click_decide drawer "$TRANSIENT_NORMAL")" "noop" \
    "drawer always noop (placeholder)"
assert_eq "$(notif_click_decide drawer "$REST_GREEN")" "noop" \
    "drawer always noop on rest"
assert_eq "$(notif_click_decide drawer "$EMPTY")" "noop" \
    "drawer always noop on empty"

# ─── Unknown action ────────────────────────────────────────────────────────
assert_eq "$(notif_click_decide nonsense "$TRANSIENT_NORMAL")" "noop" \
    "unknown action → noop (defensive)"

# ─── bell subcommand ──────────────────────────────────────────────────────
# bell on rest-face cache → open-rofi
out=$(notif_click_decide bell "$REST_GREEN")
assert_eq "$out" "open-rofi" "bell on rest (pin-green) → open-rofi"

# bell on rest with critical pin → also open-rofi
out=$(notif_click_decide bell "$REST_ORANGE")
assert_eq "$out" "open-rofi" "bell on rest (pin-orange) → open-rofi"

# bell on transient cache (has · separator) → invoke-and-dismiss
assert_eq "$(notif_click_decide bell '{"text":" Slack · PR review","class":["opt-pill","dark"],"tooltip":""}')" "invoke-and-dismiss" \
    "bell on transient → invoke-and-dismiss"

# bell on empty cache → noop
assert_eq "$(notif_click_decide bell '{"text":""}')" "noop" \
    "bell on empty cache → noop"

# bell on garbage → noop
assert_eq "$(notif_click_decide bell 'not json')" "noop" \
    "bell on garbage → noop"

# ─── dnd subcommand ───────────────────────────────────────────────────────
# DND toggle is content-agnostic — the cache is irrelevant; the decision
# only depends on the subcommand. Always returns "toggle-dnd".
assert_eq "$(notif_click_decide dnd "$EMPTY")" "toggle-dnd" \
    "[dnd → toggle-dnd regardless of cache (empty)]"
assert_eq "$(notif_click_decide dnd "$REST_GREEN")" "toggle-dnd" \
    "[dnd → toggle-dnd regardless of cache (rest)]"
assert_eq "$(notif_click_decide dnd '')" "toggle-dnd" \
    "[dnd → toggle-dnd with bare empty-string (≠ EMPTY sentinel)]"

# ─── dismiss subcommand ───────────────────────────────────────────────────
# Dismiss-all is content-agnostic — the cache is irrelevant; the decision
# only depends on the subcommand. Always returns "dismiss-all".
assert_eq "$(notif_click_decide dismiss "$EMPTY")" "dismiss-all" \
    "[dismiss → dismiss-all regardless of cache (empty)]"
assert_eq "$(notif_click_decide dismiss "$REST_GREEN")" "dismiss-all" \
    "[dismiss → dismiss-all regardless of cache (rest)]"
assert_eq "$(notif_click_decide dismiss '')" "dismiss-all" \
    "[dismiss → dismiss-all with bare empty-string (≠ EMPTY sentinel)]"

# ─── unknown subcommand → noop ────────────────────────────────────────────
assert_eq "$(notif_click_decide unknown '')" "noop" \
    "unknown subcommand → noop"

# ─── bell on transient with otp_code → 'invoke-otp' (P2) ──────────────────
out=$(notif_click_decide bell '{"text":"<b>Bank</b> · Code 1234","class":["opt-pill","dark","opt-glow-green"],"tooltip":"","otp_code":"1234"}')
assert_eq "$out" "invoke-otp" "[bell on transient + otp_code → invoke-otp]"

# Bell transient WITHOUT otp_code → still invoke-and-dismiss
out=$(notif_click_decide bell '{"text":"<b>App</b> · regular","class":["opt-pill","dark"],"tooltip":"","otp_code":""}')
assert_eq "$out" "invoke-and-dismiss" "[bell on transient + no otp_code → invoke-and-dismiss]"

# Bell transient with otp_code="" (empty string) → invoke-and-dismiss
out=$(notif_click_decide bell '{"text":"<b>App</b> · t","class":["opt-pill","dark"],"otp_code":""}')
assert_eq "$out" "invoke-and-dismiss" "[bell transient otp_code empty → invoke-and-dismiss]"

# ─── action subcommand ───────────────────────────────────────────────────
out=$(notif_click_decide action '{"text":"Reply","class":["opt-pill-child","dark","opt-yes"],"key":"reply"}')
assert_eq "$out" "invoke-action" "[action on populated cache → invoke-action]"

# Action on empty cache → noop
out=$(notif_click_decide action '{"text":""}')
assert_eq "$out" "noop" "[action on empty cache → noop]"

# Action with no key field → noop
out=$(notif_click_decide action '{"text":"Reply","class":["opt-pill-child","dark","opt-yes"]}')
assert_eq "$out" "noop" "[action without key field → noop]"

# Action with empty string key → noop
out=$(notif_click_decide action '{"text":"Reply","key":""}')
assert_eq "$out" "noop" "[action with empty key → noop]"

if [[ $fail -eq 0 ]]; then
    printf '\n✓ all tests passed\n'; exit 0
else
    printf '\n✗ %d failure(s)\n' "$fail" >&2; exit 1
fi
