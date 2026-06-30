#!/usr/bin/env bash
# notif-os-test.sh — unit tests for lib/notif-os.sh (mocked busctl)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Mocks — defined BEFORE sourcing the lib so its functions resolve through
# bash's function table (not PATH).
BUSCTL_LOG=$(mktemp)
LIST_PAYLOAD='[]'

busctl() {
    # ListNotifications path: when args contain ListNotifications, return the
    # canned LIST_PAYLOAD wrapped in busctl --json=short shape.
    local args="$*"
    if [[ "$args" == *ListNotifications* ]]; then
        # busctl --json=short wraps the return string as: {"type":"s","data":["..."]}
        # The lib unwraps via `jq -r '.data[0]? // "[]"'`. To match: emit
        # {"type":"s","data":[<the JSON string escaped>]}
        printf '{"type":"s","data":[%s]}' "$(printf '%s' "$LIST_PAYLOAD" | jq -Rs .)"
        return 0
    fi
    # All other calls (InvokeAction, CloseNotification, etc) — just log.
    printf 'busctl %s\n' "$args" >> "$BUSCTL_LOG"
    return 0
}
export -f busctl 2>/dev/null || true

# shellcheck source=../scripts/lib/notif-os.sh
source "$HERE/../scripts/lib/notif-os.sh"

trap 'rm -f "$BUSCTL_LOG"' EXIT

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

# ── mako_list_live: empty store → no output ─────────────────────────────
LIST_PAYLOAD='[]'
out=$(mako_list_live)
check "[list_live empty → no output]" test -z "$out"

# ── mako_list_live: one notif → one line ────────────────────────────────
LIST_PAYLOAD='[{"id":42,"app":"kitty","summary":"Hi","body":"b","urgency":1,"actions":[],"sender_pid":1234,"source_window":"0xABC","ts":"2026-06-15T10:00:00-03:00"}]'
out=$(mako_list_live)
check "[list_live 1 notif → 1 line]" test "$(wc -l <<<"$out")" -eq 1
check "[list_live emits id\\turg]" test "$out" = $'42\t1'

# ── mako_list_live: three notifs, different urgencies ───────────────────
LIST_PAYLOAD='[{"id":10,"urgency":0,"actions":[]},{"id":11,"urgency":1,"actions":[]},{"id":12,"urgency":2,"actions":[]}]'
out=$(mako_list_live)
check "[list_live 3 notifs → 3 lines]" test "$(wc -l <<<"$out")" -eq 3
check "[list_live has critical urg row]" test -n "$(grep -F $'12\t2' <<<"$out")"

# ── mako_list_actions: with default + reply, default hoisted ────────────
LIST_PAYLOAD='[{"id":42,"actions":[["reply","Reply"],["default","Open"],["markread","Mark as read"]]}]'
out=$(mako_list_actions 42)
first_key=$(head -1 <<<"$out" | cut -f1)
first_label=$(head -1 <<<"$out" | cut -f2)
check "[actions: default hoisted (by key)]" test "$first_key" = "default"
check "[actions: default hoisted (by label)]" test "$first_label" = "Open"
check "[actions: 3 rows total]" test "$(wc -l <<<"$out")" -eq 3

# ── mako_list_actions: empty actions → no output ────────────────────────
LIST_PAYLOAD='[{"id":42,"actions":[]}]'
out=$(mako_list_actions 42)
check "[actions empty → no output]" test -z "$out"

# ── mako_list_actions: notif missing the actions field → no output ──────
LIST_PAYLOAD='[{"id":42}]'
out=$(mako_list_actions 42)
check "[actions missing field → no output]" test -z "$out"

# ── mako_list_actions: id not present in store → no output ──────────────
LIST_PAYLOAD='[{"id":99,"actions":[["default","Open"]]}]'
out=$(mako_list_actions 42)
check "[actions id miss → no output]" test -z "$out"

# ── mako_has_default_action ────────────────────────────────────────────
LIST_PAYLOAD='[{"id":42,"actions":[["default","Open"],["reply","Reply"]]}]'
mako_has_default_action 42
check "[has_default with default key → returns 0]" test $? -eq 0

LIST_PAYLOAD='[{"id":42,"actions":[["reply","Reply"]]}]'
mako_has_default_action 42
check "[has_default without default → returns 1]" test $? -eq 1

LIST_PAYLOAD='[{"id":42,"actions":[]}]'
mako_has_default_action 42
check "[has_default empty actions → returns 1]" test $? -eq 1

# ── mako_invoke: call shape ─────────────────────────────────────────────
: > "$BUSCTL_LOG"
mako_invoke 42 reply
check "[mako_invoke logs InvokeAction call with id+key]" \
    grep -qF 'InvokeAction us 42 reply' "$BUSCTL_LOG"

# ── mako_dismiss: call shape ────────────────────────────────────────────
: > "$BUSCTL_LOG"
mako_dismiss 42
check "[mako_dismiss logs CloseNotification call]" \
    grep -qF 'CloseNotification u 42' "$BUSCTL_LOG"

# ── mako_dismiss_all: iterates current list ─────────────────────────────
LIST_PAYLOAD='[{"id":10,"urgency":1,"actions":[]},{"id":11,"urgency":1,"actions":[]}]'
: > "$BUSCTL_LOG"
mako_dismiss_all
check "[dismiss_all closes id 10]" grep -qF 'CloseNotification u 10' "$BUSCTL_LOG"
check "[dismiss_all closes id 11]" grep -qF 'CloseNotification u 11' "$BUSCTL_LOG"

# ── mako_dismiss_all on empty store: no calls ───────────────────────────
LIST_PAYLOAD='[]'
: > "$BUSCTL_LOG"
mako_dismiss_all
check "[dismiss_all empty: no CloseNotification calls]" \
    ! grep -qF 'CloseNotification' "$BUSCTL_LOG"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
