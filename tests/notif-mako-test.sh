#!/usr/bin/env bash
# notif-mako-test.sh — unit tests for lib/notif-mako.sh (mocked busctl/makoctl)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Mocks — must be defined BEFORE sourcing the lib so the lib uses our versions
# when its functions call `busctl ...` / `makoctl ...` (bash resolves through
# the function table before PATH for command lookup).
MAKOCTL_LOG=$(mktemp)
BUSCTL_PAYLOAD=""

busctl() { printf '%s' "$BUSCTL_PAYLOAD"; }
makoctl() { printf 'makoctl %s\n' "$*" >> "$MAKOCTL_LOG"; }
export -f busctl makoctl 2>/dev/null || true

# shellcheck source=../scripts/lib/notif-mako.sh
source "$HERE/../scripts/lib/notif-mako.sh"
# shellcheck source=../scripts/lib/notif-journal.sh
source "$HERE/../scripts/lib/notif-journal.sh"

trap 'rm -f "$MAKOCTL_LOG"' EXIT

pass=0; fail=0
check() {
    local label="$1"; shift
    local negate=0
    if [[ "${1-}" == "!" ]]; then negate=1; shift; fi
    local rc=0; "$@" || rc=$?
    local ok=0; (( negate ? rc != 0 : rc == 0 )) && ok=1
    if (( ok )); then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else fail=$((fail+1)); printf '✗ %s\n' "$label"; fi
}

# ── mako_list_live: empty ────────────────────────────────────────────────
BUSCTL_PAYLOAD='{"data":[[]]}'
out=$(mako_list_live)
check "[mako_list_live empty → no output]" test -z "$out"

# ── mako_list_live: one notif ────────────────────────────────────────────
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"urgency":{"data":1}}]]}'
out=$(mako_list_live)
check "[mako_list_live 1 notif → 1 line]" test "$(wc -l <<<"$out")" -eq 1
check "[mako_list_live emits id\turg]" test "$out" = $'42\t1'

# ── mako_list_live: three notifs, different urgencies ────────────────────
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":10},"urgency":{"data":0}},{"id":{"data":11},"urgency":{"data":1}},{"id":{"data":12},"urgency":{"data":2}}]]}'
out=$(mako_list_live)
check "[mako_list_live 3 notifs → 3 lines]" test "$(wc -l <<<"$out")" -eq 3
check "[mako_list_live has critical urg row]" test -n "$(grep -F $'12\t2' <<<"$out")"

# ── mako_list_actions: object payload (mako 1.10) with default action ────
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{"reply":"Reply","markread":"Mark as read","default":"Open"}}}]]}'
out=$(mako_list_actions 42)
first_label=$(head -1 <<<"$out" | cut -f2)
check "[actions object: default action hoisted to top]" test "$first_label" = "Open"
check "[actions object: 3 rows total]" test "$(wc -l <<<"$out")" -eq 3

# ── mako_list_actions: array payload (legacy mako) ───────────────────────
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":["reply","Reply","markread","Mark as read"]}}]]}'
out=$(mako_list_actions 42)
check "[actions array: 2 rows]" test "$(wc -l <<<"$out")" -eq 2
check "[actions array: has reply\tReply]" test -n "$(grep -F $'reply\tReply' <<<"$out")"

# ── mako_list_actions: empty actions ─────────────────────────────────────
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{}}}]]}'
out=$(mako_list_actions 42)
check "[actions empty → no output]" test -z "$out"

# ── mako_list_actions: id not present ────────────────────────────────────
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":99},"actions":{"data":{"default":"Open"}}}]]}'
out=$(mako_list_actions 42)
check "[actions id miss → no output]" test -z "$out"

# ── mako_invoke / mako_dismiss / mako_dismiss_all: makoctl arg shape ─────
: > "$MAKOCTL_LOG"
mako_invoke 42 reply
check "[mako_invoke calls makoctl invoke -n 42 reply]" test -n "$(grep -F 'makoctl invoke -n 42 reply' "$MAKOCTL_LOG")"

: > "$MAKOCTL_LOG"
mako_dismiss 42
check "[mako_dismiss calls makoctl dismiss -n 42]" test -n "$(grep -F 'makoctl dismiss -n 42' "$MAKOCTL_LOG")"

: > "$MAKOCTL_LOG"
mako_dismiss_all
check "[mako_dismiss_all calls makoctl dismiss --all]" test -n "$(grep -F 'makoctl dismiss --all' "$MAKOCTL_LOG")"

# ── journal_remove ───────────────────────────────────────────────────────
J=$(mktemp)
journal_append "$J" "2026-06-10T10:00:00-03:00" 1 "appA" "sumA" "bodyA" 1
journal_append "$J" "2026-06-10T10:01:00-03:00" 2 "appB" "sumB" "bodyB" 1
journal_append "$J" "2026-06-10T10:02:00-03:00" 1 "appA" "sumA2" "bodyA2" 1   # same id 1, later ts
check "[setup: journal has 3 lines]" test "$(wc -l < "$J")" -eq 3

journal_remove "$J" 1 "2026-06-10T10:00:00-03:00"
check "[journal_remove: line count drops to 2]" test "$(wc -l < "$J")" -eq 2
check "[journal_remove: targeted line gone]" ! grep -qF '"ts":"2026-06-10T10:00:00-03:00"' "$J"
check "[journal_remove: same-id later-ts line preserved]" grep -qF '"ts":"2026-06-10T10:02:00-03:00"' "$J"
check "[journal_remove: untouched line preserved]" grep -qF '"id":2' "$J"

journal_remove "$J" 99 "anything"   # no-match → no-op, no wipe
check "[journal_remove: no-match leaves file intact]" test "$(wc -l < "$J")" -eq 2

journal_remove "/tmp/notif-nonexistent.$$.jsonl" 1 "ts"
check "[journal_remove: missing file is clean no-op]" test $? -eq 0

rm -f "$J"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
