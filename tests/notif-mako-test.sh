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

# ── mako_list_actions: array payload with default — hoist must work too ──
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":["reply","Reply","default","Open"]}}]]}'
out=$(mako_list_actions 42)
first_key=$(head -1 <<<"$out" | cut -f1)
first_label=$(head -1 <<<"$out" | cut -f2)
check "[actions array: default action hoisted to top (by key)]" test "$first_key" = "default"
check "[actions array: default action hoisted to top (by label)]" test "$first_label" = "Open"

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

# ── mako_has_default_action ──────────────────────────────────────────────
# Object payload containing default → returns 0
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{"default":"Open","reply":"Reply"}}}]]}'
mako_has_default_action 42
check "[has_default object: returns 0]" test $? -eq 0

# Object payload without default → returns 1
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{"reply":"Reply"}}}]]}'
mako_has_default_action 42
check "[has_default object missing default: returns 1]" test $? -eq 1

# Empty actions → returns 1
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{}}}]]}'
mako_has_default_action 42
check "[has_default empty: returns 1]" test $? -eq 1

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
