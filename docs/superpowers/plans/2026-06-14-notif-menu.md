# notif-menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `/etc/nixos/home/scripts/notif-menu`, a fresh rofi notification
selector that surfaces per-notification actions via a two-level flow (notif list
→ action menu), alongside the existing `notif-rofi` (untouched). Manual launch
only; no bar integration this iteration.

**Architecture:** Modular Bash — one entry script (`notif-menu`) plus two new
sourced libs (`notif-mako.sh`, `notif-menu-format.sh`) under `scripts/lib/`,
reusing the existing `notif-journal.sh`. Pure libs have unit tests; the entry
script has a flow test that mocks rofi + mako + wl-copy + systemd-run. No live
daemon required to run any test.

**Tech Stack:** Bash 5, `jq`, `rofi -dmenu`, `busctl --user`, `makoctl`,
`wl-copy`, `systemd-run --user`. Tests use bash function-override mocking
(same pattern as the existing `notif-rofi-test.sh` and `notif-journal-test.sh`).

**Spec reference:** `/etc/nixos/home/docs/superpowers/specs/2026-06-14-notif-menu-design.md`

**Spec amendment baked into this plan:** add one new helper
`journal_remove PATH ID TS` to `lib/notif-journal.sh` (no change to existing
functions; needed for Remove-from-history). The spec called this out as inline
jq in the dispatcher — the helper is the same logic, cleaner placement, and
keeps all journal-mutation logic in one file.

---

## File structure

| File | Purpose | Created in |
|---|---|---|
| `scripts/lib/notif-menu-format.sh` | Pure row formatters (L1 rows, L1 headers, L2 separator, L2 back). No I/O. | Task 1 |
| `scripts/lib/notif-mako.sh` | Mako D-Bus / makoctl adapter (list live, list actions, invoke, dismiss, dismiss-all). | Task 2 |
| `scripts/lib/notif-journal.sh` | EXISTING — add one new function `journal_remove`. | Task 2 |
| `scripts/notif-menu` | Entry script: source libs, build L1, run rofi, dispatch to L2, dispatch L2 action. | Tasks 3–6 |
| `tests/notif-menu-format-test.sh` | Unit tests for the format lib. | Task 1 |
| `tests/notif-mako-test.sh` | Unit tests for the mako adapter (mocked busctl/makoctl). | Task 2 |
| `tests/notif-menu-flow-test.sh` | End-to-end flow test (mocked rofi + everything else). | Task 6 |

---

## Task 1: notif-menu-format.sh — pure formatters

**Files:**
- Create: `/etc/nixos/home/scripts/lib/notif-menu-format.sh`
- Create: `/etc/nixos/home/tests/notif-menu-format-test.sh`

- [ ] **Step 1: Write the failing test file**

Create `/etc/nixos/home/tests/notif-menu-format-test.sh`:

```bash
#!/usr/bin/env bash
# notif-menu-format-test.sh — unit tests for lib/notif-menu-format.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/notif-menu-format.sh
source "$HERE/../scripts/lib/notif-menu-format.sh"

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

# fmt_l1_header
out=$(fmt_l1_header "Unread (3)")
check "[l1 header has '── Unread (3) ──' shape]" test "$out" = "── Unread (3) ──"

# fmt_l1_row TS APP SUMMARY UNREAD CRITICAL
# Format: HH:MM  App · Summary[ · unread][ · critical]
out=$(fmt_l1_row "2026-06-10T10:42:00-03:00" "Slack" "PR review" 1 0)
check "[l1 row has HH:MM]" test -n "$(grep -F '10:42' <<<"$out")"
check "[l1 row has 'Slack · PR review']" test -n "$(grep -F 'Slack · PR review' <<<"$out")"
check "[l1 row has unread tag]" test -n "$(grep -F ' · unread' <<<"$out")"
check "[l1 row has NO critical tag when urg!=2]" test -z "$(grep -F 'critical' <<<"$out")"

# Critical
out=$(fmt_l1_row "2026-06-10T11:00:00-03:00" "systemd" "service failed" 1 1)
check "[l1 row has critical tag]" test -n "$(grep -F 'critical' <<<"$out")"

# Historical (unread=0): no tags
out=$(fmt_l1_row "2026-06-09T09:00:00-03:00" "firefox" "Done" 0 0)
check "[l1 row historical: no unread tag]" test -z "$(grep -F 'unread' <<<"$out")"
check "[l1 row historical: no critical tag]" test -z "$(grep -F 'critical' <<<"$out")"
check "[l1 row historical: HH:MM present]" test -n "$(grep -F '09:00' <<<"$out")"

# Empty summary → suppress the ' · ' separator
out=$(fmt_l1_row "2026-06-10T11:00:00-03:00" "kitty" "" 0 0)
check "[l1 row empty summary: no trailing ' · ']" test -z "$(grep -F ' · ' <<<"$out")"
check "[l1 row empty summary: HH:MM + app still present]" test -n "$(grep -F '11:00  kitty' <<<"$out")"

# NO icon-metadata suffix (v2 drops icons)
out=$(fmt_l1_row "2026-06-10T10:42:00-03:00" "Slack" "Hello" 1 0)
nul_count=$(printf '%s' "$out" | tr -cd '\0' | wc -c)
check "[l1 row has NO NUL bytes (no icon metadata)]" test "$nul_count" -eq 0

# fmt_l2_separator
out=$(fmt_l2_separator)
check "[l2 separator is '── ──']" test "$out" = "── ──"

# fmt_l2_back
out=$(fmt_l2_back)
check "[l2 back is '← Back']" test "$out" = "← Back"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
```

- [ ] **Step 2: Make it executable and run it (expect FAIL — lib doesn't exist)**

```bash
chmod +x /etc/nixos/home/tests/notif-menu-format-test.sh
/etc/nixos/home/tests/notif-menu-format-test.sh
```

Expected: error sourcing the missing lib file. That's the "red" state.

- [ ] **Step 3: Write the lib**

Create `/etc/nixos/home/scripts/lib/notif-menu-format.sh`:

```bash
# notif-menu-format.sh — pure row formatters for notif-menu.
#
# Output is plain text (no Pango, no NUL/icon metadata). The entry script
# (notif-menu) wires these formatters to the journal + mako adapter.

# fmt_l1_header LABEL
# Non-selectable section row. The entry script treats any row starting with
# '── ' as a no-op when picked.
fmt_l1_header() {
    printf '── %s ──' "$1"
}

# fmt_l1_row TS APP SUMMARY UNREAD CRITICAL
# Args:
#   TS        ISO 8601 timestamp; HH:MM extracted from chars 11-15
#   APP       app name
#   SUMMARY   notification summary; if empty, the " · " separator is suppressed
#   UNREAD    0 | 1
#   CRITICAL  0 | 1 (only meaningful when UNREAD=1)
fmt_l1_row() {
    local ts="$1" app="$2" summary="$3" unread="$4" critical="$5"
    local hhmm="${ts:11:5}"
    local body
    if [[ -n $summary ]]; then
        body="${app} · ${summary}"
    else
        body="${app}"
    fi
    local tags=""
    if (( unread )); then
        tags=" · unread"
        (( critical )) && tags+=" · critical"
    fi
    printf '%s  %s%s' "$hhmm" "$body" "$tags"
}

# fmt_l2_separator — visual divider between app actions and generic actions.
fmt_l2_separator() {
    printf '── ──'
}

# fmt_l2_back — bottom-of-L2 row that returns to L1 (the entry script
# treats this literal as a re-exec).
fmt_l2_back() {
    printf '← Back'
}
```

- [ ] **Step 4: Run the test (expect PASS)**

```bash
/etc/nixos/home/tests/notif-menu-format-test.sh
```

Expected: all tests pass (`✓ all N tests passed`).

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/lib/notif-menu-format.sh tests/notif-menu-format-test.sh && git commit -m "notif-menu: format lib + unit tests

Pure row formatters: fmt_l1_header, fmt_l1_row (with unread/critical/empty-summary handling), fmt_l2_separator, fmt_l2_back. No icon metadata (v2 drops it; rationale in spec)."
```

---

## Task 2: notif-mako.sh — mako adapter + journal_remove helper

**Files:**
- Create: `/etc/nixos/home/scripts/lib/notif-mako.sh`
- Modify: `/etc/nixos/home/scripts/lib/notif-journal.sh` (append `journal_remove`)
- Create: `/etc/nixos/home/tests/notif-mako-test.sh`

- [ ] **Step 1: Write the failing test file**

Create `/etc/nixos/home/tests/notif-mako-test.sh`:

```bash
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
check "[mako_list_live emits id\\turg]" test "$out" = $'42\t1'

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
check "[actions array: has reply\\tReply]" test -n "$(grep -F $'reply\tReply' <<<"$out")"

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
```

- [ ] **Step 2: Make it executable and run it (expect FAIL)**

```bash
chmod +x /etc/nixos/home/tests/notif-mako-test.sh
/etc/nixos/home/tests/notif-mako-test.sh
```

Expected: error sourcing missing `notif-mako.sh`. Red state.

- [ ] **Step 3: Write the mako adapter lib**

Create `/etc/nixos/home/scripts/lib/notif-mako.sh`:

```bash
# notif-mako.sh — adapter between notif-menu and mako (D-Bus + makoctl).
#
# All busctl/makoctl calls in the menu codebase go through here so tests can
# mock these primitives by overriding `busctl` and `makoctl` as bash functions
# before sourcing this lib.

_mako_busctl_list() {
    busctl --user --json=short call \
        org.freedesktop.Notifications /fr/emersion/Mako \
        fr.emersion.Mako ListNotifications 2>/dev/null
}

# mako_list_live — prints `id\turgency` per live notification, one per line.
# Empty output when no live notifs (or busctl error).
mako_list_live() {
    _mako_busctl_list \
        | jq -r '.data[0][]? | "\(.id.data)\t\(.urgency.data)"' 2>/dev/null
}

# mako_list_actions ID — prints `key\tlabel` per action on the given notif,
# one per line. The entry whose key == "default" is hoisted to the top of
# the output; remaining entries follow mako's natural order.
# Handles both mako 1.10's object actions payload (a{ss} → JSON object)
# and older mako's alternating-string-array payload.
mako_list_actions() {
    local id="$1"
    _mako_busctl_list | jq -r --argjson id "$id" '
        .data[0][]? | select(.id.data == $id) | .actions.data as $a
        | (if ($a | type) == "object" then
              ($a | to_entries | map([.key, .value]))
           elif ($a | type) == "array" then
              [range(0; ($a | length); 2) as $i | [$a[$i], $a[$i+1]]]
           else [] end) as $rows
        | ($rows | map(select(.[0] == "default")))
          + ($rows | map(select(.[0] != "default")))
        | .[] | @tsv
    ' 2>/dev/null
}

mako_invoke()      { makoctl invoke -n "$1" "$2" 2>/dev/null; }
mako_dismiss()     { makoctl dismiss -n "$1" 2>/dev/null; }
mako_dismiss_all() { makoctl dismiss --all 2>/dev/null; }
```

- [ ] **Step 4: Append `journal_remove` to the existing notif-journal.sh**

Append to `/etc/nixos/home/scripts/lib/notif-journal.sh`:

```bash

# journal_remove PATH ID TS
# Removes the single journal line whose id matches AND ts matches exactly.
# (Two args used together because mako recycles numeric ids over time, so
# id alone isn't a unique key across the journal's lifetime.)
# Clean no-op when the file is missing, empty, or has no matching line.
journal_remove() {
    local path="$1" id="$2" ts="$3"
    [[ -f $path && -s $path ]] || return 0
    local tmp="${path}.tmp.$$"
    if jq -c --argjson id "$id" --arg ts "$ts" '
        select(.id != $id or .ts != $ts)
    ' < "$path" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path"
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
```

- [ ] **Step 5: Run the test (expect PASS)**

```bash
/etc/nixos/home/tests/notif-mako-test.sh
```

Expected: all tests pass.

- [ ] **Step 6: Re-run the existing journal test to make sure the addition didn't regress it**

```bash
/etc/nixos/home/tests/notif-journal-test.sh
```

Expected: all existing tests still pass.

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home && git add scripts/lib/notif-mako.sh scripts/lib/notif-journal.sh tests/notif-mako-test.sh && git commit -m "notif-menu: mako adapter + journal_remove + unit tests

mako adapter: list_live, list_actions (default-hoisted, object/array payload), invoke, dismiss, dismiss_all. notif-journal.sh gains journal_remove (id+ts keyed) for Remove-from-history."
```

---

## Task 3: notif-menu — Level 1 build (populate + emit)

**Files:**
- Create: `/etc/nixos/home/scripts/notif-menu`

This task creates the entry script and populates / emits the L1 row sequence
(Actions block, Unread section, History section, empty placeholder). No rofi
yet — that wires in Task 5. We assert the row sequence via test in Task 6.

- [ ] **Step 1: Create the entry script skeleton with L1 build**

Create `/etc/nixos/home/scripts/notif-menu`:

```bash
#!/usr/bin/env bash
# notif-menu — rofi notification selector with per-notif action surfacing.
#
# Two-level flow:
#   L1 → list (Actions block + Unread + History sections)
#   L2 → per-notif actions (app actions + Copy/Snooze/Dismiss for live;
#                           Copy + Remove for history)
#
# Manual launch only this iteration; the bar's notif-bell still uses notif-rofi.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB_DIR="${NOTIF_LIB_DIR:-$HERE/lib}"
[[ -d $LIB_DIR ]] || { printf 'notif-menu: lib dir not found: %s\n' "$LIB_DIR" >&2; exit 1; }

# shellcheck source=lib/notif-mako.sh
source "$LIB_DIR/notif-mako.sh"
# shellcheck source=lib/notif-journal.sh
source "$LIB_DIR/notif-journal.sh"
# shellcheck source=lib/notif-menu-format.sh
source "$LIB_DIR/notif-menu-format.sh"

JOURNAL="${NOTIF_JOURNAL:-$HOME/.local/share/standard-os/notif-history.jsonl}"
JOURNAL_READ_N="${NOTIF_JOURNAL_READ_N:-200}"

# ── Index arrays — populated by populate_l1, consumed by dispatch ────────
# Indexed by 0-based row index as rofi sees it (-format i).
declare -A kind_at id_at ts_at app_at summary_at body_at urgency_at

reset_index() {
    kind_at=(); id_at=(); ts_at=(); app_at=()
    summary_at=(); body_at=(); urgency_at=()
}

# put_row IDX KIND [ID TS APP SUMMARY BODY URGENCY]
# Populates the metadata arrays. Missing trailing args become empty strings.
put_row() {
    local idx="$1" kind="$2" id="${3:-}" ts="${4:-}" app="${5:-}" \
          summary="${6:-}" body="${7:-}" urgency="${8:-}"
    kind_at[$idx]="$kind"
    id_at[$idx]="$id"
    ts_at[$idx]="$ts"
    app_at[$idx]="$app"
    summary_at[$idx]="$summary"
    body_at[$idx]="$body"
    urgency_at[$idx]="$urgency"
}

# fetch_live_meta ID → "app\tsummary\tbody\tts" via busctl. Used when a live
# id has no journal entry yet (daemon was down at arrival).
fetch_live_meta() {
    local id="$1"
    busctl --user --json=short call \
        org.freedesktop.Notifications /fr/emersion/Mako \
        fr.emersion.Mako ListNotifications 2>/dev/null \
        | jq -r --argjson id "$id" '
            .data[0][]? | select(.id.data == $id)
            | [."app-name".data // "?", .summary.data // "", .body.data // "",
               (now | strftime("%Y-%m-%dT%H:%M:%S%z"))]
            | @tsv
        ' 2>/dev/null
}

# populate_l1 → populates the metadata arrays AND prints the L1 row sequence.
# Caller pipes the stdout to rofi -format i; the returned index is then used
# to look up metadata in the arrays.
populate_l1() {
    reset_index
    local idx=0

    # ── Actions block ────────────────────────────────────────────────────
    put_row $idx "header"
    fmt_l1_header "Actions"; printf '\n'
    idx=$((idx+1))

    put_row $idx "dismiss_all"
    printf 'Dismiss all unread\n'
    idx=$((idx+1))

    # ── Live unread ──────────────────────────────────────────────────────
    local live_map unread_count=0
    live_map=$(mako_list_live)
    [[ -n $live_map ]] && unread_count=$(grep -c '^' <<<"$live_map")

    if (( unread_count > 0 )); then
        put_row $idx "header"
        fmt_l1_header "Unread ($unread_count)"; printf '\n'
        idx=$((idx+1))

        local id urg ts app summary body fields
        while IFS=$'\t' read -r id urg; do
            [[ -z $id ]] && continue
            # Look in journal first (newest entry with that id and no
            # dismissed_at — that's the active arrival).
            fields=$(tac "$JOURNAL" 2>/dev/null | jq -r --argjson id "$id" '
                fromjson? // empty
                | select(.id == $id) | [.ts, .app, .summary, .body] | @tsv
            ' 2>/dev/null | head -1)
            if [[ -n $fields ]]; then
                IFS=$'\t' read -r ts app summary body <<<"$fields"
            else
                # Journal miss → busctl fetch.
                fields=$(fetch_live_meta "$id")
                IFS=$'\t' read -r app summary body ts <<<"$fields"
            fi
            local crit=0
            (( urg == 2 )) && crit=1
            put_row $idx "unread" "$id" "$ts" "$app" "$summary" "$body" "$urg"
            fmt_l1_row "$ts" "$app" "$summary" 1 "$crit"; printf '\n'
            idx=$((idx+1))
        done <<<"$live_map"
    fi

    # ── History (journal entries whose id is NOT in the live set) ────────
    local hist_buf="" hist_count=0
    if [[ -s $JOURNAL ]]; then
        local line id urg ts app summary body
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            local row
            row=$(jq -r '
                fromjson? // empty
                | [.id, .urgency, .ts, .app, .summary, .body] | @tsv
            ' <<<"$line" 2>/dev/null) || continue
            [[ -z $row ]] && continue
            IFS=$'\t' read -r id urg ts app summary body <<<"$row"
            if [[ -n $live_map ]] && grep -qE "^${id}"$'\t' <<<"$live_map"; then
                continue
            fi
            hist_buf+="$id"$'\t'"$urg"$'\t'"$ts"$'\t'"$app"$'\t'"$summary"$'\t'"$body"$'\n'
            hist_count=$((hist_count+1))
        done < <(tac "$JOURNAL" | tail -n "$JOURNAL_READ_N")
    fi

    if (( hist_count > 0 )); then
        put_row $idx "header"
        fmt_l1_header "History ($hist_count)"; printf '\n'
        idx=$((idx+1))

        local id urg ts app summary body
        while IFS=$'\t' read -r id urg ts app summary body; do
            [[ -z $id ]] && continue
            put_row $idx "history" "$id" "$ts" "$app" "$summary" "$body" "$urg"
            fmt_l1_row "$ts" "$app" "$summary" 0 0; printf '\n'
            idx=$((idx+1))
        done <<<"$hist_buf"
    fi

    # ── Empty placeholder ────────────────────────────────────────────────
    if (( unread_count == 0 && hist_count == 0 )); then
        put_row $idx "header"
        fmt_l1_header "no notifications"; printf '\n'
        idx=$((idx+1))
    fi
}
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /etc/nixos/home/scripts/notif-menu
```

- [ ] **Step 3: Smoke-test the L1 build by hand**

```bash
NOTIF_JOURNAL=/tmp/no-such-file bash -c '
    source /etc/nixos/home/scripts/notif-menu 2>/dev/null
    # If "source" tries to run main flow, we need to refactor — but at this
    # point no main exists yet. Just call populate_l1 directly:
    populate_l1
'
```

The script has no `main` yet so sourcing leaves us at the function definitions.
Expected output (with empty journal and no live mako):

```
── Actions ──
Dismiss all unread
── no notifications ──
```

(`mako_list_live` will likely return empty too unless you have live notifs;
that's fine.)

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-menu && git commit -m "notif-menu: entry script with Level 1 row build

populate_l1 + per-row metadata arrays indexed by rofi -format i. Sections: Actions, Unread (live), History (journal-N exclusive of live), empty placeholder. No rofi/dispatch yet — wired in subsequent tasks."
```

---

## Task 4: notif-menu — Level 2 builders (live + history)

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-menu` (append L2 builders)

- [ ] **Step 1: Append L2 builders to notif-menu**

Append to `/etc/nixos/home/scripts/notif-menu`:

```bash

# ── Level 2: live action menu ────────────────────────────────────────────
# Populates the metadata arrays AND prints the L2 row sequence for a live
# notification (whose data is taken from the L1 metadata arrays at IDX).
# Sets globals L2_APP / L2_SUMMARY for the dispatcher's rofi prompt.
declare -A l2_action_key   # idx → mako action key (empty for static rows)

populate_l2_live() {
    local l1_idx="$1"
    local id="${id_at[$l1_idx]}" ts="${ts_at[$l1_idx]}"
    local app="${app_at[$l1_idx]}" summary="${summary_at[$l1_idx]}"
    local body="${body_at[$l1_idx]}" urg="${urgency_at[$l1_idx]}"
    L2_APP="$app"; L2_SUMMARY="$summary"
    L2_ID="$id"; L2_TS="$ts"; L2_BODY="$body"; L2_URG="$urg"
    L2_KIND="live"

    reset_index
    l2_action_key=()
    local idx=0

    # Re-query mako to detect "live → vanished" between L1 pick and now.
    if ! mako_list_live | grep -qE "^${id}"$'\t'; then
        put_row $idx "header"
        fmt_l1_header "no longer live — history actions only"; printf '\n'
        idx=$((idx+1))
        L2_KIND="history-fallback"
        _populate_l2_history_tail $idx
        return
    fi

    # App actions (default hoisted first by mako_list_actions).
    local k label
    while IFS=$'\t' read -r k label; do
        [[ -z $k ]] && continue
        put_row $idx "app_action"
        l2_action_key[$idx]="$k"
        printf '%s\n' "$label"
        idx=$((idx+1))
    done < <(mako_list_actions "$id")

    # Separator
    put_row $idx "noop"
    fmt_l2_separator; printf '\n'
    idx=$((idx+1))

    # Generic actions
    put_row $idx "copy_summary"; printf 'Copy summary\n'
    idx=$((idx+1))
    if [[ -n $body ]]; then
        put_row $idx "copy_body"; printf 'Copy body\n'
        idx=$((idx+1))
    fi
    put_row $idx "snooze_10m"; printf 'Snooze 10 minutes\n'
    idx=$((idx+1))
    put_row $idx "snooze_1h"; printf 'Snooze 1 hour\n'
    idx=$((idx+1))
    put_row $idx "dismiss"; printf 'Dismiss\n'
    idx=$((idx+1))

    put_row $idx "noop"; fmt_l2_separator; printf '\n'
    idx=$((idx+1))
    put_row $idx "back"; fmt_l2_back; printf '\n'
}

# ── Level 2: history action menu ─────────────────────────────────────────
populate_l2_history() {
    local l1_idx="$1"
    L2_APP="${app_at[$l1_idx]}"; L2_SUMMARY="${summary_at[$l1_idx]}"
    L2_ID="${id_at[$l1_idx]}"; L2_TS="${ts_at[$l1_idx]}"
    L2_BODY="${body_at[$l1_idx]}"; L2_URG="${urgency_at[$l1_idx]}"
    L2_KIND="history"

    reset_index
    l2_action_key=()
    local idx=0
    _populate_l2_history_tail $idx
}

# Shared tail: history-only rows (used by both true-history and the
# live→vanished fallback inside populate_l2_live).
_populate_l2_history_tail() {
    local idx="$1"
    put_row $idx "copy_summary"; printf 'Copy summary\n'
    idx=$((idx+1))
    if [[ -n ${L2_BODY:-} ]]; then
        put_row $idx "copy_body"; printf 'Copy body\n'
        idx=$((idx+1))
    fi
    put_row $idx "remove_history"; printf 'Remove from history\n'
    idx=$((idx+1))
    put_row $idx "noop"; fmt_l2_separator; printf '\n'
    idx=$((idx+1))
    put_row $idx "back"; fmt_l2_back; printf '\n'
}
```

- [ ] **Step 2: Smoke-test live L2 build with mocked mako**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_list_live() { printf "42\t1\n"; }
    mako_list_actions() { printf "default\tOpen\nreply\tReply\n"; }
    # Stage L1 metadata for idx 0
    put_row 0 unread 42 "2026-06-14T10:00:00-03:00" "Slack" "msg" "body" 1
    populate_l2_live 0
'
```

Expected output:

```
Open
Reply
── ──
Copy summary
Copy body
Snooze 10 minutes
Snooze 1 hour
Dismiss
── ──
← Back
```

- [ ] **Step 3: Smoke-test history L2 build**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    put_row 0 history 1 "2026-06-14T09:00:00-03:00" "kitty" "ran" "" 1
    populate_l2_history 0
'
```

Expected output (no `Copy body` because body is empty):

```
Copy summary
Remove from history
── ──
← Back
```

- [ ] **Step 4: Smoke-test live→vanished fallback**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_list_live() { return 0; }   # empty — pretend the notif is gone
    put_row 0 unread 42 "2026-06-14T10:00:00-03:00" "Slack" "msg" "body" 1
    populate_l2_live 0
'
```

Expected output:

```
── no longer live — history actions only ──
Copy summary
Copy body
Remove from history
── ──
← Back
```

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-menu && git commit -m "notif-menu: L2 builders for live + history + vanished-fallback

populate_l2_live re-queries mako and falls back to history rows with a no-op header when the id vanished between L1 and L2. populate_l2_history is history-only. Shared tail via _populate_l2_history_tail."
```

---

## Task 5: notif-menu — dispatch + main flow (rofi wiring)

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-menu` (append dispatchers + main)

- [ ] **Step 1: Append dispatchers and main**

Append to `/etc/nixos/home/scripts/notif-menu`:

```bash

# ── Action implementations (the actual side effects) ─────────────────────
do_invoke_app_action() {
    local id="$1" key="$2"
    mako_invoke "$id" "$key" || true
    mako_dismiss "$id" || true
}

do_copy() {
    printf '%s' "$1" | wl-copy
}

do_snooze() {
    local id="$1" app="$2" urg="$3" summary="$4" body="$5" when="$6"
    systemd-run --user --on-active="$when" --collect \
        notify-send -a "$app" -u "$urg" -- "$summary" "$body" >/dev/null 2>&1 || true
    mako_dismiss "$id" || true
}

do_remove_from_history() {
    journal_remove "$JOURNAL" "$1" "$2"
}

do_relaunch() {
    exec "$(readlink -f "$0")"
}

# ── Rofi wrapper (function so tests can mock it) ─────────────────────────
run_rofi() {
    local prompt="$1"
    rofi -no-config -dmenu -i -p "$prompt" -no-custom -format i \
        -theme-str '
            configuration { font: "meslo-ng 13"; }
            window { width: 50%; }
            element-text { padding: 4px 10px; }
        ' 2>/dev/null
}

# ── Tempdir (set by main; used by main + dispatch_l1 to stage rows) ─────
# CRITICAL: populate_l1 / populate_l2_* must NOT be invoked via $(...)
# capture because they mutate global arrays (kind_at, id_at, etc.) that
# the dispatchers read. Subshell capture loses those mutations. Instead,
# we redirect their stdout to a file in the parent shell (redirection
# alone doesn't subshell), then pipe the file into rofi.
NOTIF_MENU_TMP=""

# ── L2 dispatch ──────────────────────────────────────────────────────────
dispatch_l2() {
    local idx="$1"
    local kind="${kind_at[$idx]:-}"
    case "$kind" in
        app_action)
            do_invoke_app_action "$L2_ID" "${l2_action_key[$idx]}"
            ;;
        copy_summary)   do_copy "$L2_SUMMARY" ;;
        copy_body)      do_copy "$L2_BODY" ;;
        snooze_10m)     do_snooze "$L2_ID" "$L2_APP" "$L2_URG" "$L2_SUMMARY" "$L2_BODY" "10min" ;;
        snooze_1h)      do_snooze "$L2_ID" "$L2_APP" "$L2_URG" "$L2_SUMMARY" "$L2_BODY" "1h" ;;
        dismiss)        mako_dismiss "$L2_ID" || true ;;
        remove_history) do_remove_from_history "$L2_ID" "$L2_TS" ;;
        back)           do_relaunch ;;
        ""|header|noop) : ;;   # no-op
    esac
}

# ── L1 dispatch ──────────────────────────────────────────────────────────
dispatch_l1() {
    local idx="$1"
    local kind="${kind_at[$idx]:-}"
    case "$kind" in
        dismiss_all)
            mako_dismiss_all || true
            ;;
        unread)
            populate_l2_live "$idx" > "$NOTIF_MENU_TMP/l2"
            local prompt; prompt=$(_l2_prompt)
            local l2_idx
            l2_idx=$(run_rofi "$prompt" < "$NOTIF_MENU_TMP/l2") || return 0
            dispatch_l2 "$l2_idx"
            ;;
        history)
            populate_l2_history "$idx" > "$NOTIF_MENU_TMP/l2"
            local prompt; prompt=$(_l2_prompt)
            local l2_idx
            l2_idx=$(run_rofi "$prompt" < "$NOTIF_MENU_TMP/l2") || return 0
            dispatch_l2 "$l2_idx"
            ;;
        ""|header|noop) : ;;
    esac
}

# Composes the L2 rofi prompt: "<App> · <summary truncated to 60 chars>".
_l2_prompt() {
    local s="$L2_SUMMARY"
    if (( ${#s} > 60 )); then s="${s:0:60}…"; fi
    if [[ -n $s ]]; then printf '%s · %s' "$L2_APP" "$s"
    else                 printf '%s' "$L2_APP"; fi
}

# ── Main ────────────────────────────────────────────────────────────────
main() {
    NOTIF_MENU_TMP=$(mktemp -d)
    # EXIT covers normal-exit and signals; RETURN covers function-return from
    # tests that call main directly (so tempdirs don't leak across iterations).
    trap 'rm -rf "$NOTIF_MENU_TMP"' EXIT RETURN
    populate_l1 > "$NOTIF_MENU_TMP/l1"
    local l1_idx
    l1_idx=$(run_rofi "notifications" < "$NOTIF_MENU_TMP/l1") || return 0
    dispatch_l1 "$l1_idx"
}

# Only run main when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
```

- [ ] **Step 2: Verify the script doesn't error on syntax**

```bash
bash -n /etc/nixos/home/scripts/notif-menu
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-menu && git commit -m "notif-menu: dispatchers, rofi wiring, and main

L1 picks route to L2 build → rofi → L2 dispatch. dispatch_l2 maps row kinds to side-effects (mako_invoke, wl-copy, systemd-run snooze, dismiss, remove_history, relaunch on Back). main is guarded so the script can be sourced by tests."
```

---

## Task 6: End-to-end flow test

**Files:**
- Create: `/etc/nixos/home/tests/notif-menu-flow-test.sh`

The script is now complete. This task adds a flow test that mocks rofi + every
side-effect call, sources the script (without running `main`), and asserts the
expected calls happen for each L1/L2 choice.

- [ ] **Step 1: Write the failing flow test**

Create `/etc/nixos/home/tests/notif-menu-flow-test.sh`:

```bash
#!/usr/bin/env bash
# notif-menu-flow-test.sh — end-to-end flow tests with mocks for rofi,
# mako, wl-copy, systemd-run. No live daemons required.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Sandbox dirs
SANDBOX=$(mktemp -d)
JOURNAL="$SANDBOX/notif-history.jsonl"
CALL_LOG="$SANDBOX/calls"
ROFI_QUEUE="$SANDBOX/rofi_queue"   # one chosen index per line; consumed in order
: > "$CALL_LOG"; : > "$ROFI_QUEUE"

trap 'rm -rf "$SANDBOX"' EXIT

# ── Mocks (defined BEFORE sourcing notif-menu) ───────────────────────────
# Mako/journal mocks
MAKO_LIVE_PAYLOAD=""       # set per test
MAKO_ACTIONS_PAYLOAD=""    # set per test

mako_list_live()    { printf '%s' "$MAKO_LIVE_PAYLOAD"; }
mako_list_actions() { printf '%s' "$MAKO_ACTIONS_PAYLOAD"; }
mako_invoke()       { printf 'mako_invoke %s %s\n' "$1" "$2" >> "$CALL_LOG"; }
mako_dismiss()      { printf 'mako_dismiss %s\n' "$1" >> "$CALL_LOG"; }
mako_dismiss_all()  { printf 'mako_dismiss_all\n' >> "$CALL_LOG"; }

wl-copy() {
    # Capture stdin bytes verbatim for byte-exact assertions.
    cat > "$SANDBOX/last_copy"
    printf 'wl-copy\n' >> "$CALL_LOG"
}

systemd-run() {
    printf 'systemd-run %s\n' "$*" >> "$CALL_LOG"
}

notify-send() { :; }  # silent — should never be called directly

run_rofi() {
    local prompt="$1"
    printf 'rofi prompt=%s\n' "$prompt" >> "$CALL_LOG"
    local idx
    idx=$(head -1 "$ROFI_QUEUE")
    sed -i '1d' "$ROFI_QUEUE"
    if [[ "$idx" == "ESC" ]]; then return 1; fi
    printf '%s' "$idx"
}

export NOTIF_JOURNAL="$JOURNAL"
# Source the script — guarded main won't run because $0 is this test, not notif-menu.
# shellcheck source=../scripts/notif-menu
source "$HERE/../scripts/notif-menu"

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

# ── Test 1: L1 → "Dismiss all unread" ────────────────────────────────────
: > "$CALL_LOG"; printf '1\n' > "$ROFI_QUEUE"   # idx 1 = "Dismiss all unread"
MAKO_LIVE_PAYLOAD=""
main
check "[t1: mako_dismiss_all called]" grep -qF 'mako_dismiss_all' "$CALL_LOG"

# ── Test 2: L1 unread → L2 app action ────────────────────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=$'default\tOpen\nreply\tReply\n'
# Seed journal so populate_l1 has metadata for id=42
journal_append "$JOURNAL" "2026-06-14T10:00:00-03:00" 42 "Slack" "Hi" "body text" 1
# Row order from populate_l1:
#   0 header "── Actions ──"
#   1 dismiss_all
#   2 header "── Unread (1) ──"
#   3 unread (id=42, Slack)
# So pick idx 3 in L1, then in L2 pick idx 1 ("Reply"):
#   L2 row order from populate_l2_live with 2 actions:
#     0 app_action "Open"  (default hoisted)
#     1 app_action "Reply"
#     2 noop (separator)
#     3 copy_summary
#     4 copy_body
#     5 snooze_10m
#     6 snooze_1h
#     7 dismiss
#     8 noop (separator)
#     9 back
printf '3\n1\n' > "$ROFI_QUEUE"
main
check "[t2: mako_invoke 42 reply called]" grep -qF 'mako_invoke 42 reply' "$CALL_LOG"
check "[t2: mako_dismiss 42 called after invoke]" grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 3: L2 Copy summary copies the exact bytes ───────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""   # no app actions → L2 starts at separator+copy block
printf '3\n1\n' > "$ROFI_QUEUE"
# L2 with no app actions:
#   0 noop separator
#   1 copy_summary     ← pick this
#   2 copy_body
#   3 snooze_10m
#   4 snooze_1h
#   5 dismiss
#   6 noop separator
#   7 back
main
check "[t3: wl-copy called]" grep -qF 'wl-copy' "$CALL_LOG"
check "[t3: copied bytes equal summary exactly (no trailing newline)]" \
    test "$(cat "$SANDBOX/last_copy")" = "Hi"
check "[t3: copied byte length = strlen(summary)]" \
    test "$(wc -c < "$SANDBOX/last_copy")" -eq 2

# ── Test 4: Snooze 10 minutes → systemd-run + dismiss ────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""
printf '3\n3\n' > "$ROFI_QUEUE"   # L1 idx 3 (Slack), L2 idx 3 = snooze_10m
main
check "[t4: systemd-run called with --on-active=10min]" \
    grep -qF -- '--on-active=10min' "$CALL_LOG"
check "[t4: systemd-run called with --collect]" \
    grep -qF -- '--collect' "$CALL_LOG"
check "[t4: mako_dismiss 42 called after snooze]" \
    grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 5: History row → L2 has no Dismiss/Snooze ──────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=""   # nothing live
MAKO_ACTIONS_PAYLOAD=""
# Journal still has id=42; with no live notifs, that becomes a history row.
# Row order:
#   0 header Actions
#   1 dismiss_all
#   2 header "History (1)"
#   3 history (id=42)
# L2 history rows:
#   0 copy_summary
#   1 copy_body
#   2 remove_history     ← pick
#   3 noop separator
#   4 back
printf '3\n2\n' > "$ROFI_QUEUE"
main
check "[t5: journal line removed]" ! grep -qF '"id":42' "$JOURNAL"

# ── Test 6: Esc at L1 → no side effects ──────────────────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
journal_append "$JOURNAL" "2026-06-14T11:00:00-03:00" 42 "Slack" "Hi again" "" 1
printf 'ESC\n' > "$ROFI_QUEUE"
main || true   # main exits 0 on Esc; defend against `set -e` if someone adds it
# After Esc no mako_* / wl-copy / systemd-run lines should have been logged
# beyond the one "rofi prompt=" line:
non_rofi_calls=$(grep -vF 'rofi prompt=' "$CALL_LOG" || true)
check "[t6: Esc at L1 produces no side-effect calls]" test -z "$non_rofi_calls"

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
```

- [ ] **Step 2: Make it executable and run (expect PASS — the implementation already exists)**

```bash
chmod +x /etc/nixos/home/tests/notif-menu-flow-test.sh
/etc/nixos/home/tests/notif-menu-flow-test.sh
```

Expected: all tests pass. If any fail, fix the implementation OR the test —
investigate which is wrong before patching.

- [ ] **Step 3: Re-run all three test scripts as one batch**

```bash
for t in notif-menu-format-test notif-mako-test notif-menu-flow-test; do
    echo "── $t ──"
    "/etc/nixos/home/tests/$t.sh" || { echo "FAILED: $t"; exit 1; }
done
```

Expected: all three suites pass.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add tests/notif-menu-flow-test.sh && git commit -m "notif-menu: end-to-end flow tests

Mocked rofi/mako/wl-copy/systemd-run cover: dismiss-all, L1 unread → L2 app action (invoke+dismiss), Copy summary byte-exactness (no trailing newline), Snooze 10m (systemd-run flags + dismiss), history → remove_history, Esc → no side effects."
```

---

## Task 7: Manual smoke test + TODO.md update

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md` (add a DONE entry with hint)

- [ ] **Step 1: Run notif-menu against a real notification**

```bash
notify-send -a TestApp -u 1 "Hello" "this is a test body"
/etc/nixos/home/scripts/notif-menu
```

A rofi list opens. Expected:
- `── Actions ──`
- `Dismiss all unread`
- `── Unread (1) ──`
- `HH:MM  TestApp · Hello · unread`
- (history rows below if any)

Pick the TestApp row. Expected L2:
- (no app actions — notify-send didn't declare any)
- `── ──`
- `Copy summary`
- `Copy body`
- `Snooze 10 minutes`
- `Snooze 1 hour`
- `Dismiss`
- `── ──`
- `← Back`

Pick `Copy body`. Verify clipboard with `wl-paste` — expected exactly `this is a test body` with no trailing newline:

```bash
wl-paste | od -An -c | head -3
```

The bytes should end with `t   b   o   d   y` (no `\n`).

- [ ] **Step 2: Test app actions with a real action-declaring notification**

```bash
notify-send -a TestApp -u 1 --action=open=Open --action=archive=Archive "With actions" "body"
/etc/nixos/home/scripts/notif-menu
```

Pick the row → L2 should show `Open`, `Archive`, then the separator and
generic rows. Pick `Archive` → mako should dismiss the notification (check
with `makoctl history` or run `notif-menu` again to confirm the row moved
to History).

- [ ] **Step 3: Test the Back path**

`notify-send -a TestApp "back-test"`, run `notif-menu`, pick the row, in L2
pick `← Back`. Expected: L1 re-appears immediately. Pick a row again to
confirm state was reset cleanly.

- [ ] **Step 4: Test snooze**

```bash
notify-send -a TestApp "snooze-test" "body"
/etc/nixos/home/scripts/notif-menu
```

Pick the row, then `Snooze 10 minutes` (or temporarily reduce by editing the
script if you don't want to wait 10 minutes — but for the real-flow check,
test with 10m and just verify the timer was queued):

```bash
systemctl --user list-timers --all | grep -i run
```

Expected: a transient one-shot unit with the right `Next` time.

- [ ] **Step 5: Update TODO.md (add to DONE)**

Add the following entry to `/etc/nixos/home/waybar/TODO.md` under the `## DONE`
section (most-recent first):

```markdown
- **2026-06-14** — **notif-menu: rofi selector with per-notif action surfacing.**
  New alternative to `notif-rofi` shipped as `/etc/nixos/home/scripts/notif-menu`.
  Two-level rofi flow: L1 lists Actions block + Unread + History sections; picking
  a notif opens L2 with app-declared actions (default hoisted), Copy summary,
  Copy body (suppressed when empty), Snooze 10m/1h (via `systemd-run --user
  --on-active=… --collect notify-send`), Dismiss, ← Back. History L2: Copy +
  Remove-from-history + Back. Stale-id (notif vanished between L1 and L2)
  falls back to history actions with a no-op header. New libs:
  `scripts/lib/notif-mako.sh` (busctl/makoctl adapter, handles both mako 1.10's
  object actions payload and legacy array form), `scripts/lib/notif-menu-format.sh`
  (pure plain-text formatters — no NUL/icon metadata, simpler than the old
  notif-rofi-format). `notif-journal.sh` gained `journal_remove` (id+ts keyed).
  Bar untouched: `custom/notif-bell` keeps calling the old `notif-rofi`; the
  new menu is launched manually for now.
  **Hint:** rofi pick→metadata uses `-format i` (index) plus parallel bash
  associative arrays keyed by row index (`kind_at`, `id_at`, `ts_at`, etc.)
  populated during `populate_l1` / `populate_l2_*`. Avoids the text-parse-back
  fragility the old `notif-rofi` paid for in `handle_pick`.
  **Hint:** `mako_list_actions` defensively type-switches on `actions.data`
  (object vs array) to handle mako 1.10's `a{ss}` rendering quirk that was
  documented in TODO.md line 826.
  **Hint:** `Back` is implemented as `exec "$(readlink -f "$0")"` — full
  re-launch is the cheapest correct re-render and resets all index arrays
  for free. Symlink-safe via `readlink -f`.
  **Hint:** Tests mock `rofi` / `mako_*` / `wl-copy` / `systemd-run` via
  bash function overrides. No live daemons required to run any of the three
  test scripts.
```

- [ ] **Step 6: Commit the TODO update**

```bash
cd /etc/nixos/home && git add waybar/TODO.md && git commit -m "TODO: notif-menu shipped (rofi selector with per-notif actions)"
```

- [ ] **Step 7: Final verification — full test suite re-run**

```bash
for t in notif-menu-format-test notif-mako-test notif-menu-flow-test \
         notif-rofi-test notif-journal-test; do
    echo "── $t ──"
    "/etc/nixos/home/tests/$t.sh" || { echo "FAILED: $t"; exit 1; }
done
```

Expected: all five suites pass. (Includes the existing notif-rofi and
notif-journal tests — proves no regressions from the `journal_remove`
addition.)

---

## Self-review notes

Sanity check against the spec sections:

| Spec section | Plan task |
|---|---|
| Architecture / files | Tasks 1–6 create exactly the spec's file list |
| L1 row format | Task 1 (format lib) + Task 3 (build) — `fmt_l1_row` produces the spec's `HH:MM  App · Summary[ · unread][ · critical]` shape, empty-summary suppression covered by a test |
| L1 sections / ordering | Task 3 — Actions block, Unread (live), History (journal minus live), empty placeholder |
| L1 icons NO | Task 1 has an explicit NUL-count==0 test |
| L1 search | rofi `-i` flag in `run_rofi` (Task 5) |
| L2 live menu | Task 4 — app actions (default hoisted by `mako_list_actions`), separator, Copy/Copy body (conditional), Snooze 10m/1h, Dismiss, Back |
| L2 history menu | Task 4 — Copy, Copy body (conditional), Remove from history, Back |
| L2 prompt = `App · summary…60` | Task 5 — `_l2_prompt` truncates with `…` |
| Stale-id fallback | Task 4 — `populate_l2_live` re-queries mako, falls back to history rows with a `── no longer live — history actions only ──` header |
| Action dispatch table | Task 5 — `dispatch_l2` case statement matches the spec's table |
| Snooze via `systemd-run --user --on-active=… --collect` | Task 5 — `do_snooze` |
| `printf '%s'` for copy (no trailing newline) | Task 5 — `do_copy`; Task 6 byte-exact test |
| App-action dispatch via `label → key` parallel array | Task 4 — `l2_action_key[$idx]`; Task 5 — `dispatch_l2` reads it |
| `Remove from history` keys on id+ts | Task 2 — `journal_remove` signature; tested in Task 2 with same-id-different-ts case |
| `Back` = `exec "$(readlink -f "$0")"` | Task 5 — `do_relaunch` |
| busctl object vs array variance | Task 2 — `mako_list_actions` jq has both branches; tested both payloads |
| Empty everything → placeholder | Task 3; smoke-tested in Task 3 Step 3 |
| Empty body → suppress Copy body | Task 4 (both `populate_l2_live` and `_populate_l2_history_tail`); Task 6 not directly but implied by Test 3 row indexing |
| makoctl failures silent (`\|\| true`) | Task 5 — `do_invoke_app_action`, `do_snooze`, `dismiss` branch all use `\|\| true` |
| Snooze preserves urgency | Task 5 — `do_snooze` passes `-u "$urg"` |
| No bar wiring | Confirmed: plan touches no waybar config files |
| Three test files mirror existing patterns | Confirmed; check function copied verbatim |

No "TBD" / "TODO" / "later" markers in plan steps. All code blocks are complete. Function names consistent across tasks (`fmt_l1_row` same in Task 1 + Task 3; `mako_list_actions` same in Task 2 + Task 4; `populate_l2_live` same in Task 4 + Task 5; `journal_remove` same in Task 2 + Task 5).

One spec-vs-plan delta worth flagging: spec said `notif-journal.sh` reused
"unchanged"; plan extends it by appending `journal_remove`. Existing functions
and their tests are untouched. Justification baked into the plan header.
