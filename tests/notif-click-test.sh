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
REST_GREEN='{"text":"x","class":["opt-pill","dark","opt-pin-green"],"tooltip":"Notifications"}'
REST_ORANGE='{"text":"x","class":["opt-pill","dark","opt-pin-orange"],"tooltip":"Notifications"}'
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
assert_eq "$(notif_click_decide bell '{"text":"","class":["opt-pill","dark","opt-pin-green"],"tooltip":"Notifications"}')" "open-rofi" \
    "bell on rest → open-rofi"

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
# dnd always → toggle-dnd (mako handles direction)
assert_eq "$(notif_click_decide dnd '{"text":"X","class":["opt-pill-child","dark"]}')" "toggle-dnd" \
    "dnd → toggle-dnd"

assert_eq "$(notif_click_decide dnd '')" "toggle-dnd" \
    "dnd with empty cache still toggle-dnd"

# ─── unknown subcommand → noop ────────────────────────────────────────────
assert_eq "$(notif_click_decide unknown '')" "noop" \
    "unknown subcommand → noop"

if [[ $fail -eq 0 ]]; then
    printf '\n✓ all tests passed\n'; exit 0
else
    printf '\n✗ %d failure(s)\n' "$fail" >&2; exit 1
fi
