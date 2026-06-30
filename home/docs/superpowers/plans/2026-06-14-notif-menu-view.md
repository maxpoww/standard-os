# notif-menu View Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace notif-menu's current L2 Copy/Snooze rows with a tight
View / Dismiss / Back menu. View takes the user to the source — invoking
mako's default action when declared (Firefox focuses the tab, Telegram
focuses the chat) or focusing the app's Hyprland window otherwise.

**Architecture:** One new lib (`notif-hypr.sh`) for Hyprland window
operations (encapsulating every `hyprctl` call so tests can mock it),
one new helper in `notif-mako.sh` (`mako_has_default_action`), and a
focused modification to `notif-menu` adding `do_view` + restructuring
`populate_l2_live` and `dispatch_l2`. No new dependencies beyond
`hyprctl` (already present on the system).

**Tech Stack:** Bash 5, `jq`, `hyprctl -j clients`, existing notif-menu
libs (mako adapter, journal lib, format lib).

**Spec reference:** `/etc/nixos/home/docs/superpowers/specs/2026-06-14-notif-menu-view-design.md`

---

## File structure

| File | Purpose | Created in |
|---|---|---|
| `scripts/lib/notif-hypr.sh` | NEW. Hyprland window adapter — `hypr_focus_by_class`. | Task 1 |
| `scripts/lib/notif-mako.sh` | EXISTING — add `mako_has_default_action`. | Task 2 |
| `scripts/notif-menu` | EXISTING — add `do_view`, modify `populate_l2_live`, modify `dispatch_l2`, drop `do_copy`/`do_snooze`. | Task 3 |
| `tests/notif-hypr-test.sh` | NEW. Unit tests for the hypr adapter (mocked `hyprctl`). | Task 1 |
| `tests/notif-mako-test.sh` | EXISTING — add 3 cases for `mako_has_default_action`. | Task 2 |
| `tests/notif-menu-flow-test.sh` | EXISTING — restructure to 9 tests (View paths + recursion guard + renumber). | Task 4 |
| `waybar/TODO.md` | EXISTING — DONE entry. | Task 5 |

---

## Task 1: notif-hypr.sh — Hyprland window adapter

**Files:**
- Create: `/etc/nixos/home/scripts/lib/notif-hypr.sh`
- Create: `/etc/nixos/home/tests/notif-hypr-test.sh`

- [ ] **Step 1: Write the failing test file**

Create `/etc/nixos/home/tests/notif-hypr-test.sh`:

```bash
#!/usr/bin/env bash
# notif-hypr-test.sh — unit tests for lib/notif-hypr.sh (mocked hyprctl)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Mocks — must be defined BEFORE sourcing the lib so its functions
# resolve through bash's function table (not PATH).
HYPRCTL_LOG=$(mktemp)
HYPRCTL_CLIENTS_JSON='[]'

hyprctl() {
    # Calls of the form: hyprctl -j clients         → echo $HYPRCTL_CLIENTS_JSON
    # Calls of the form: hyprctl dispatch focuswindow ...  → log args
    if [[ "$1" == "-j" && "${2:-}" == "clients" ]]; then
        printf '%s' "$HYPRCTL_CLIENTS_JSON"
        return 0
    fi
    printf 'hyprctl %s\n' "$*" >> "$HYPRCTL_LOG"
    return 0
}
export -f hyprctl 2>/dev/null || true

# shellcheck source=../scripts/lib/notif-hypr.sh
source "$HERE/../scripts/lib/notif-hypr.sh"

trap 'rm -f "$HYPRCTL_LOG"' EXIT

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

# ── hypr_focus_by_class: empty clients → returns 1, no dispatch ─────────
HYPRCTL_CLIENTS_JSON='[]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[empty clients: returns 1]" test $? -eq 1
check "[empty clients: no dispatch logged]" test ! -s "$HYPRCTL_LOG"

# ── exact class match (case-insensitive) ────────────────────────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0x123","class":"firefox","title":"Reddit"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[exact match: returns 0]" test $? -eq 0
check "[exact match: dispatch focuswindow address:0x123 logged]" \
    grep -qF 'dispatch focuswindow address:0x123' "$HYPRCTL_LOG"

# ── substring match (class contains the app-name-lowercased) ────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0x456","class":"firefox-developer-edition","title":"test"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[substring match: returns 0]" test $? -eq 0
check "[substring match: dispatch focuswindow address:0x456 logged]" \
    grep -qF 'dispatch focuswindow address:0x456' "$HYPRCTL_LOG"

# ── no match → returns 1, no dispatch ───────────────────────────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0x789","class":"kitty","title":"shell"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[no match: returns 1]" test $? -eq 1
check "[no match: no dispatch logged]" test ! -s "$HYPRCTL_LOG"

# ── multiple matches → picks the first (head -1) ────────────────────────
HYPRCTL_CLIENTS_JSON='[{"address":"0xAAA","class":"firefox","title":"a"},{"address":"0xBBB","class":"firefox","title":"b"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[multiple matches: returns 0]" test $? -eq 0
check "[multiple matches: dispatched first address (0xAAA)]" \
    grep -qF 'dispatch focuswindow address:0xAAA' "$HYPRCTL_LOG"
check "[multiple matches: did NOT dispatch second address (0xBBB)]" \
    ! grep -qF '0xBBB' "$HYPRCTL_LOG"

# ── app-name with spaces / unusual chars: lowercased then substring ─────
HYPRCTL_CLIENTS_JSON='[{"address":"0xCCC","class":"org.telegram.desktop","title":"chat"}]'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Telegram"
check "[telegram substring matches org.telegram.desktop]" test $? -eq 0
check "[telegram substring: dispatch focuswindow address:0xCCC logged]" \
    grep -qF 'dispatch focuswindow address:0xCCC' "$HYPRCTL_LOG"

# ── hyprctl returns malformed JSON → graceful return 1 ──────────────────
HYPRCTL_CLIENTS_JSON='not json'
: > "$HYPRCTL_LOG"
hypr_focus_by_class "Firefox"
check "[malformed JSON: returns 1]" test $? -eq 1

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
```

- [ ] **Step 2: Make it executable and run it (expect FAIL — lib doesn't exist)**

```bash
chmod +x /etc/nixos/home/tests/notif-hypr-test.sh
/etc/nixos/home/tests/notif-hypr-test.sh
```

Expected: error sourcing the missing lib file. That's the "red" state.

- [ ] **Step 3: Write the lib**

Create `/etc/nixos/home/scripts/lib/notif-hypr.sh`:

```bash
# notif-hypr.sh — Hyprland adapter for notif-menu.
#
# All hyprctl calls in the menu codebase go through here so tests can
# mock by overriding `hyprctl` as a bash function before sourcing.

# hypr_focus_by_class CLASS
# Lowercases CLASS, then finds the FIRST Hyprland window whose own class
# (lowercased) contains it as a substring. On hit, dispatches
# `focuswindow address:<addr>` (Hyprland switches workspace automatically
# if the target is elsewhere). Returns 0 on hit, 1 on miss / hyprctl
# error / malformed JSON.
hypr_focus_by_class() {
    local needle="${1,,}"   # lowercase
    local addr
    addr=$(hyprctl -j clients 2>/dev/null \
        | jq -r --arg n "$needle" '
            .[]? | select((.class // "" | ascii_downcase) | contains($n))
                 | .address' 2>/dev/null \
        | head -1)
    [[ -z $addr ]] && return 1
    hyprctl dispatch focuswindow "address:$addr" 2>/dev/null
    return 0
}
```

- [ ] **Step 4: Run the test (expect PASS)**

```bash
/etc/nixos/home/tests/notif-hypr-test.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/lib/notif-hypr.sh tests/notif-hypr-test.sh && git commit -m "notif-menu: hypr adapter (hypr_focus_by_class) + unit tests

Pure Hyprland window-focus helper. Lowercases the needle, substring-matches against client class names, dispatches focuswindow on the first hit. Returns 0/1 cleanly on miss / hyprctl error / malformed JSON. Mocked-hyprctl test covers exact / substring / multi-match / no-match / malformed JSON paths."
```

---

## Task 2: mako_has_default_action helper + tests

**Files:**
- Modify: `/etc/nixos/home/scripts/lib/notif-mako.sh` (append `mako_has_default_action`)
- Modify: `/etc/nixos/home/tests/notif-mako-test.sh` (append 3 cases)

- [ ] **Step 1: Append the failing tests**

Append to `/etc/nixos/home/tests/notif-mako-test.sh`, just BEFORE the final `echo` + summary block:

```bash
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
```

- [ ] **Step 2: Run the test (expect FAIL — function doesn't exist yet)**

```bash
/etc/nixos/home/tests/notif-mako-test.sh
```

Expected: errors on `mako_has_default_action: command not found` (or similar).

- [ ] **Step 3: Append the helper to notif-mako.sh**

Append to `/etc/nixos/home/scripts/lib/notif-mako.sh`:

```bash

# mako_has_default_action ID — returns 0 if the notif declared a `default`
# action key, 1 otherwise. Anchored grep avoids matching custom keys that
# happen to contain the literal string "default" mid-key.
mako_has_default_action() {
    mako_list_actions "$1" | grep -q '^default	'
}
```

(The grep pattern uses a literal TAB character between `default` and the
end of the anchor. Bash's `'^default\t'` would be interpreted by grep as
`\` + `t` literally — use a real TAB byte in the source.)

- [ ] **Step 4: Run the test (expect PASS)**

```bash
/etc/nixos/home/tests/notif-mako-test.sh
```

Expected: all tests pass (16 + 3 = 19 total).

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/lib/notif-mako.sh tests/notif-mako-test.sh && git commit -m "notif-menu: mako_has_default_action helper + tests

Thin wrapper around mako_list_actions that greps for a row keyed 'default'. Used by do_view to decide between step 1 (invoke default action) and step 2 (hyprctl focus fallback). Three new tests cover object-with-default, object-without-default, and empty actions."
```

---

## Task 3: do_view + populate_l2_live + dispatch_l2 (the heart of the change)

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-menu` (multiple edits)

This task changes the entry script in four coordinated places:
1. Source the new `notif-hypr.sh` lib.
2. Add `do_view`. Drop `do_copy` and `do_snooze` (no remaining callers).
3. Rewrite the live-L2 body of `populate_l2_live` to emit `View` + non-default app actions + separator + Dismiss + separator + Back.
4. Update `dispatch_l2`: add `view) ...` branch, drop `copy_summary`/`copy_body`/`snooze_10m`/`snooze_1h` branches.

Smoke tests at the end of the task validate the new behavior before the
flow test restructure in Task 4.

- [ ] **Step 1: Source the new lib**

In `/etc/nixos/home/scripts/notif-menu`, find the existing lib sources at
the top (around lines 21-26):

```bash
# shellcheck source=lib/notif-mako.sh
source "$LIB_DIR/notif-mako.sh"
# shellcheck source=lib/notif-journal.sh
source "$LIB_DIR/notif-journal.sh"
# shellcheck source=lib/notif-menu-format.sh
source "$LIB_DIR/notif-menu-format.sh"
```

Add a fourth source line below them:

```bash
# shellcheck source=lib/notif-hypr.sh
source "$LIB_DIR/notif-hypr.sh"
```

- [ ] **Step 2: Add do_view, drop do_copy and do_snooze**

Find the `do_*` action implementations block (around lines 246-280). The
existing block contains: `do_invoke_app_action`, `do_dismiss`, `do_copy`,
`do_snooze`, `do_remove_from_history`, `do_relaunch`.

REMOVE `do_copy` (the `printf '%s' | wl-copy` function) and `do_snooze`
(the `systemd-run --user ...` function). Keep the others.

ADD `do_view` somewhere in the same block (place it just after
`do_invoke_app_action` for visibility — View IS the canonical
invocation):

```bash
do_view() {
    local id="$1" app="$2"
    # Step 1 — if the app declared a default action, that's the right verb.
    if mako_has_default_action "$id"; then
        mako_invoke "$id" default || true
        mako_dismiss "$id" || true
        return 0
    fi
    # Step 2 — no default; recursion guard for our own fallback notifs.
    if [[ "$app" == "notif-menu" ]]; then
        mako_dismiss "$id" || true
        return 0
    fi
    # Step 3 — focus an existing Hyprland window by app class.
    if hypr_focus_by_class "$app"; then
        mako_dismiss "$id" || true
        return 0
    fi
    # Step 4 — nothing to do; surface honest feedback. notif-menu app-name
    # marks it so step 2 short-circuits if the user picks View on it.
    notify-send -a "notif-menu" -u low \
        "View couldn't open '$app'" \
        "no default action and no matching window" 2>/dev/null || true
    return 1
}
```

- [ ] **Step 3: Rewrite the live-L2 body of populate_l2_live**

Find `populate_l2_live` (around lines 165-225). The current body, AFTER the
stale-id fallback `if ! mako_list_live | grep -qF ... ; then ... fi`,
looks like:

```bash
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
```

REPLACE that entire post-fallback body with:

```bash
    # View row — always first. do_view dispatches to mako's default
    # action when declared, otherwise hyprctl focuses the app window.
    put_row $idx "view"
    printf 'View\n'
    idx=$((idx+1))

    # App actions OTHER than 'default' — View covers default.
    local k label
    while IFS=$'\t' read -r k label; do
        [[ -z $k ]] && continue
        [[ "$k" == "default" ]] && continue
        put_row $idx "app_action"
        l2_action_key[$idx]="$k"
        printf '%s\n' "$label"
        idx=$((idx+1))
    done < <(mako_list_actions "$id")

    # Separator + Dismiss + separator + Back.
    put_row $idx "noop"
    fmt_l2_separator; printf '\n'
    idx=$((idx+1))

    put_row $idx "dismiss"; printf 'Dismiss\n'
    idx=$((idx+1))

    put_row $idx "noop"; fmt_l2_separator; printf '\n'
    idx=$((idx+1))

    put_row $idx "back"; fmt_l2_back; printf '\n'
}
```

(The local `body` is no longer used — leave the `local body=` line at the
top of populate_l2_live alone; it doesn't hurt.)

- [ ] **Step 4: Update dispatch_l2 case statement**

Find `dispatch_l2` (around lines 296-310). Current branches include
`view` (no — wait, View doesn't exist yet), `app_action`, `copy_summary`,
`copy_body`, `snooze_10m`, `snooze_1h`, `dismiss`, `remove_history`,
`back`, header/noop.

REPLACE the case statement body to add `view` and drop `copy_summary` /
`copy_body` / `snooze_10m` / `snooze_1h`:

```bash
dispatch_l2() {
    local idx="$1"
    local kind="${kind_at[$idx]:-}"
    case "$kind" in
        view)
            do_view "$L2_ID" "$L2_APP"
            ;;
        app_action)
            do_invoke_app_action "$L2_ID" "${l2_action_key[$idx]:-}"
            ;;
        dismiss)        do_dismiss "$L2_ID" ;;
        remove_history) do_remove_from_history "$L2_ID" "$L2_TS" ;;
        back)           do_relaunch ;;
        ""|header|noop) : ;;   # no-op
    esac
}
```

- [ ] **Step 5: Syntax check**

```bash
bash -n /etc/nixos/home/scripts/notif-menu
```

Expected: no output, exit 0.

- [ ] **Step 6: Smoke-test: L2 with default + reply actions**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_list_live() { printf "42\t1\n"; }
    mako_list_actions() { printf "default\tOpen\nreply\tReply\n"; }
    put_row 0 unread 42 "2026-06-14T10:00:00-03:00" "Slack" "msg" "body" 1
    populate_l2_live 0
'
```

Expected exact output:

```
View
Reply
── ──
Dismiss
── ──
← Back
```

(View is row 0. The `default\tOpen` row is hidden. `reply\tReply` is row 1. Separator at 2. Dismiss at 3. Separator at 4. Back at 5.)

- [ ] **Step 7: Smoke-test: L2 with no app actions**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_list_live() { printf "42\t1\n"; }
    mako_list_actions() { return 0; }
    put_row 0 unread 42 "2026-06-14T10:00:00-03:00" "kitty" "" "" 1
    populate_l2_live 0
'
```

Expected exact output:

```
View
── ──
Dismiss
── ──
← Back
```

(5 rows. View at 0. No app actions. Separator at 1. Dismiss at 2. Separator at 3. Back at 4.)

- [ ] **Step 8: Smoke-test: do_view step 1 (default action wins)**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_has_default_action() { return 0; }
    mako_invoke() { echo "INVOKE $*"; }
    mako_dismiss() { echo "DISMISS $*"; }
    hypr_focus_by_class() { echo "FOCUS $*"; return 0; }
    do_view 42 "Firefox"
'
```

Expected exact output:

```
INVOKE 42 default
DISMISS 42
```

(No FOCUS line — step 1 returned before step 3.)

- [ ] **Step 9: Smoke-test: do_view step 3 (window focus)**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_has_default_action() { return 1; }
    mako_invoke() { echo "INVOKE $*"; }
    mako_dismiss() { echo "DISMISS $*"; }
    hypr_focus_by_class() { echo "FOCUS $*"; return 0; }
    do_view 42 "kitty"
'
```

Expected exact output:

```
FOCUS kitty
DISMISS 42
```

- [ ] **Step 10: Smoke-test: do_view step 4 (fallback notify-send)**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_has_default_action() { return 1; }
    hypr_focus_by_class() { return 1; }
    notify-send() { echo "NOTIFY $*"; }
    mako_dismiss() { echo "DISMISS (should NOT fire)"; }
    do_view 42 "unknown-app"
    echo "exit=$?"
'
```

Expected output:

```
NOTIFY -a notif-menu -u low View couldn't open 'unknown-app' no default action and no matching window
exit=1
```

(`DISMISS (should NOT fire)` must NOT appear — step 4 returns 1 without dismissing the original. Note: the `'unknown-app'` quotes come from the notify-send args; ensure your terminal preserves them.)

- [ ] **Step 11: Smoke-test: do_view recursion guard (step 2)**

```bash
bash -c '
    source /etc/nixos/home/scripts/notif-menu
    mako_has_default_action() { return 1; }
    hypr_focus_by_class() { echo "FOCUS (should NOT fire)"; return 0; }
    mako_dismiss() { echo "DISMISS $*"; }
    notify-send() { echo "NOTIFY (should NOT fire)"; }
    do_view 42 "notif-menu"
'
```

Expected exact output:

```
DISMISS 42
```

(Neither FOCUS nor NOTIFY appears — step 2 catches the recursion before either.)

- [ ] **Step 12: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-menu && git commit -m "notif-menu: do_view + L2 rework (View / Dismiss / Back)

Replace Copy/Snooze L2 rows with a tight menu: View (calls default action when declared, otherwise hyprctl focus by class, else notify-send fallback), non-default app actions, Dismiss, Back. Drop do_copy/do_snooze functions. Source notif-hypr.sh for the focus helper."
```

---

## Task 4: Flow test restructure

**Files:**
- Modify: `/etc/nixos/home/tests/notif-menu-flow-test.sh`

The flow test grows from 7 tests (numbered 1, 2, 3, 4, 5, 6, 7) to 9
tests. Old Tests 3 (Copy summary) and 4 (Snooze) are deleted. Four NEW
View tests (3, 4, 5, 6) are inserted between Test 2 and the renumbered
existing tests 7/8/9.

- [ ] **Step 1: Replace the test file's body of tests**

The mocks block at the top of the file and the `check()` helper stay
unchanged. The TESTS section (after `source notif-menu` and the mock
definitions) is what changes.

Open `/etc/nixos/home/tests/notif-menu-flow-test.sh` and locate the
TESTS section (everything from `# ── Test 1: ...` down to the final
`echo` / `if [[ $fail -gt 0 ]]` block).

REPLACE the tests section with:

```bash
# ── Test 1: L1 → "Dismiss all unread" ────────────────────────────────────
: > "$CALL_LOG"; printf '1\n' > "$ROFI_QUEUE"
MAKO_LIVE_PAYLOAD=""
main
check "[t1: mako_dismiss_all called]" grep -qF 'mako_dismiss_all' "$CALL_LOG"

# ── Test 2: L1 unread → L2 non-default app action ────────────────────────
# L1 row order: 0 Actions header, 1 dismiss_all, 2 Unread header, 3 unread
# L2 row order with default+reply actions: 0 view (default hidden),
#   1 app_action Reply, 2 noop sep, 3 dismiss, 4 noop sep, 5 back.
# Pick L1 idx 3 then L2 idx 1 (Reply).
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=$'default\tOpen\nreply\tReply\n'
journal_append "$JOURNAL" "2026-06-14T10:00:00-03:00" 42 "Slack" "Hi" "body text" 1
printf '3\n1\n' > "$ROFI_QUEUE"
main
check "[t2: mako_invoke 42 reply called]" grep -qF 'mako_invoke 42 reply' "$CALL_LOG"
check "[t2: mako_dismiss 42 called after invoke]" grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 3: View with default action ─────────────────────────────────────
# Same L1 layout. L2 row 0 is View. Pick L1 idx 3 → L2 idx 0.
# Mocked mako_has_default_action returns 0 so do_view step 1 fires.
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=$'default\tOpen\n'
mako_has_default_action() { return 0; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t3: mako_invoke 42 default called]" grep -qF 'mako_invoke 42 default' "$CALL_LOG"
check "[t3: mako_dismiss 42 called after default invoke]" grep -qF 'mako_dismiss 42' "$CALL_LOG"
check "[t3: hyprctl NOT called]" ! grep -qF 'hyprctl' "$CALL_LOG"

# ── Test 4: View without default but matching Hyprland window ────────────
# Mocked mako_has_default_action returns 1, hypr_focus_by_class returns 0.
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""
mako_has_default_action() { return 1; }
hypr_focus_by_class() { printf 'hypr_focus_by_class %s\n' "$*" >> "$CALL_LOG"; return 0; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t4: hypr_focus_by_class called with app name]" grep -qF 'hypr_focus_by_class Slack' "$CALL_LOG"
check "[t4: mako_dismiss 42 called after focus]" grep -qF 'mako_dismiss 42' "$CALL_LOG"
check "[t4: mako_invoke NOT called]" ! grep -qF 'mako_invoke' "$CALL_LOG"

# ── Test 5: View with nothing matching (fallback notify-send) ────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
MAKO_ACTIONS_PAYLOAD=""
mako_has_default_action() { return 1; }
hypr_focus_by_class() { return 1; }
notify-send() { printf 'notify-send %s\n' "$*" >> "$CALL_LOG"; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t5: notify-send fallback fired with -a notif-menu]" \
    grep -qF 'notify-send -a notif-menu' "$CALL_LOG"
check "[t5: original mako_dismiss NOT called (fallback returns 1)]" \
    ! grep -qF 'mako_dismiss 42' "$CALL_LOG"

# ── Test 6: View on a fallback notif (recursion guard) ──────────────────
# Journal seeds app="notif-menu". do_view step 2 short-circuits before step 4.
: > "$CALL_LOG"
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-14T10:30:00-03:00" 99 "notif-menu" "View couldn't open" "no default action" 0
MAKO_LIVE_PAYLOAD=$'99\t0\n'
MAKO_ACTIONS_PAYLOAD=""
mako_has_default_action() { return 1; }
hypr_focus_by_class() { printf 'hypr_focus_by_class %s\n' "$*" >> "$CALL_LOG"; return 0; }
notify-send() { printf 'notify-send %s\n' "$*" >> "$CALL_LOG"; }
printf '3\n0\n' > "$ROFI_QUEUE"
main
check "[t6: mako_dismiss 99 called (recursion guard ok)]" grep -qF 'mako_dismiss 99' "$CALL_LOG"
check "[t6: hypr_focus_by_class NOT called (step 2 short-circuited)]" \
    ! grep -qF 'hypr_focus_by_class' "$CALL_LOG"
check "[t6: notify-send NOT called (no cascading fallback)]" \
    ! grep -qF 'notify-send' "$CALL_LOG"

# Restore default mocks for subsequent tests
mako_has_default_action() { mako_list_actions "$1" | grep -q '^default	'; }
hypr_focus_by_class() { return 1; }
notify-send() { :; }

# ── Test 7: History row → Remove from history ───────────────────────────
# L1 row order with no live + 1 history entry:
#   0 Actions header, 1 dismiss_all, 2 History header, 3 history (id=99)
# History L2 unchanged: 0 copy_summary, 1 copy_body, 2 remove_history,
#   3 noop sep, 4 back. Pick L1 idx 3 then L2 idx 2.
: > "$CALL_LOG"
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-14T11:00:00-03:00" 99 "TestApp" "old notif" "old body" 1
MAKO_LIVE_PAYLOAD=""
MAKO_ACTIONS_PAYLOAD=""
printf '3\n2\n' > "$ROFI_QUEUE"
main
check "[t7: journal line removed]" ! grep -qF '"id":99' "$JOURNAL"

# ── Test 8: Esc at L1 → no side effects ─────────────────────────────────
: > "$CALL_LOG"
MAKO_LIVE_PAYLOAD=$'42\t1\n'
journal_append "$JOURNAL" "2026-06-14T11:30:00-03:00" 42 "Slack" "Hi again" "" 1
printf 'ESC\n' > "$ROFI_QUEUE"
main || true
non_rofi_calls=$(grep -vF 'rofi prompt=' "$CALL_LOG" || true)
check "[t8: Esc at L1 produces no side-effect calls]" test -z "$non_rofi_calls"

# ── Test 9: Vanished fallback (live → gone between L1 and L2) ───────────
# populate_l1's mako_list_live first call returns id=42. populate_l2_live's
# re-query (second call) returns empty — fallback to history-only L2.
# Vanished-fallback L2 row order (body non-empty from journal):
#   0 header "── no longer live ──", 1 copy_summary, 2 copy_body,
#   3 remove_history, 4 noop sep, 5 back. Pick L2 idx 3.
: > "$CALL_LOG"
: > "$JOURNAL"
journal_append "$JOURNAL" "2026-06-14T12:00:00-03:00" 42 "Slack" "Hi" "body text" 1
mako_list_live_calls=$(mktemp)
echo 0 > "$mako_list_live_calls"
mako_list_live() {
    local n; n=$(<"$mako_list_live_calls"); n=$((n+1)); echo "$n" > "$mako_list_live_calls"
    if (( n == 1 )); then
        printf '42\t1\n'
    else
        return 0
    fi
}
MAKO_ACTIONS_PAYLOAD=""
printf '3\n3\n' > "$ROFI_QUEUE"
main
check "[t9: no mako_invoke during vanished fallback]" ! grep -qF 'mako_invoke' "$CALL_LOG"
check "[t9: journal entry removed via remove_history]" ! grep -qF '"id":42' "$JOURNAL"
rm -f "$mako_list_live_calls"

# Restore default mako_list_live for any future tests
mako_list_live() { printf '%s' "$MAKO_LIVE_PAYLOAD"; }

echo
if [[ $fail -gt 0 ]]; then
    printf '\n✗ %d test(s) failed (%d passed)\n' "$fail" "$pass"
    exit 1
fi
printf '\n✓ all %d tests passed\n' "$pass"
```

- [ ] **Step 2: Run the flow tests (expect all to pass)**

```bash
/etc/nixos/home/tests/notif-menu-flow-test.sh
```

Expected: all 17 tests pass (1 + 2 + 3 + 3 + 2 + 3 + 1 + 1 + 2 = 18, depending on
how the `check` calls count). The exact count isn't load-bearing — what
matters is the `✓ all N tests passed` line at the end with no failures.

If any test fails, read the relevant section of the implementation and
the test carefully. Common pitfalls:
- L1 row indices off-by-one if Actions block changed.
- L2 row indices off-by-one if the View row didn't land.
- A mock not restored between tests causing cross-contamination.

- [ ] **Step 3: Run all other test suites — confirm no regressions**

```bash
for t in notif-menu-format-test notif-mako-test notif-journal-test notif-hypr-test notif-rofi-test; do
    echo "── $t ──"
    "/etc/nixos/home/tests/$t.sh" || { echo "FAILED: $t"; exit 1; }
done
```

Expected: all five other suites pass clean.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add tests/notif-menu-flow-test.sh && git commit -m "notif-menu: flow test restructure for View (9 tests)

Drop Copy/Snooze tests, add 4 View tests (default action wins, hyprctl focus succeeds, fallback notify-send, recursion guard for notif-menu app-name). Renumber history/Esc/vanished tests. Mocks include hypr_focus_by_class and notify-send."
```

---

## Task 5: Manual smoke + TODO.md update

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md` (add DONE entry)

- [ ] **Step 1: Automated smoke — verify View against a real notification**

```bash
# Fire a real test notification
notify-send -a TestApp -u normal "View smoke" "View action test body"
sleep 0.3
makoctl history 2>/dev/null | head -3

# Now run notif-menu manually and pick View on the row.
# (Interactive — requires user input. Skip if you're not at the keyboard.)
echo "Run: /etc/nixos/home/scripts/notif-menu"
echo "Pick the TestApp row, then 'View' at idx 0."
echo "Since notify-send doesn't declare a default action, do_view step 3"
echo "will try hyprctl focus class:TestApp — likely no match — so step 4"
echo "fallback notify-send fires. You should see a 'notif-menu' notif"
echo "appear with the message: View couldn't open 'TestApp' — no default"
echo "action and no matching window."

# Clean up the live notif before the manual rofi run if you don't want it
# polluting the L1 list:
# makoctl dismiss --all
```

This step is informational — it documents what the user should see when
they manually verify. No automated assertion.

- [ ] **Step 2: Manual UI verifications (record what to test)**

These need a human in front of the keyboard. Report them to the user so
they can verify after Tasks 1-4 land:

1. **Default-action path (Firefox notif test):**
   - Open Firefox, navigate somewhere that sends a notif (e.g. allow
     site notifications and trigger one).
   - When the notif arrives, run `notif-menu`.
   - Pick the Firefox row → L2 shows `View`, no app actions other than
     mako's default (which is hidden), then Dismiss + Back.
   - Pick `View` → Firefox should focus and bring forward the
     originating tab.

2. **Hyprctl-focus path (kitty notif test):**
   - From a kitty terminal: `notify-send -a kitty "kitty test" "body"`.
   - Run `notif-menu` → pick the row → L2 → pick `View`.
   - Expected: the kitty window receives focus (the test runs in kitty
     so it should focus the active kitty window, or switch workspace
     to it if on a different one).

3. **Fallback path (no app match):**
   - `notify-send -a NotARealApp "test" "body"`.
   - Run `notif-menu` → pick → `View`.
   - Expected: a new transient notif appears from `notif-menu` saying
     "View couldn't open 'NotARealApp' — no default action and no
     matching window."

- [ ] **Step 3: Update TODO.md (add to DONE)**

In `/etc/nixos/home/waybar/TODO.md`, add this entry as the FIRST item
under `## DONE` (above any existing entries with later dates):

```markdown
- **2026-06-14** — **notif-menu: View action + tight L2 menu.**
  Replaced the v1 Copy/Snooze L2 with `View / Dismiss / Back`. `View`
  takes the user to the source of the notification: invokes mako's
  default action when the app declared one (Firefox focuses the tab,
  Telegram focuses the chat, Slack focuses the channel), falls back to
  `hyprctl dispatch focuswindow class:<app>` when there's no default,
  and surfaces an honest `notify-send` fallback when nothing matches.
  New lib `scripts/lib/notif-hypr.sh` encapsulates every `hyprctl`
  call so tests can mock it. `notif-mako.sh` gains
  `mako_has_default_action` (anchored-grep on `mako_list_actions`).
  Reply ruled out (universal `wtype`-into-focused-window approach was
  too fragile). Mute deferred to a follow-up. Vanished-fallback and
  true-history L2 menus are unchanged (Copy / Remove / Back).
  **Hint:** The `default` action key is HIDDEN from the L2 row list
  when View is shown — View invokes it. Apps that declared
  non-default actions (e.g. `archive\tArchive`) still surface those
  rows below View.
  **Hint:** `do_view`'s step 2 (recursion guard) short-circuits when
  `app == "notif-menu"`. The step 4 fallback fires notif-send with
  `-a notif-menu` so picking View on a fallback notif hits step 2
  and just dismisses — no cascading loop.
  **Hint:** Hyprland class matching is case-insensitive substring
  (lowercase needle, lowercase haystack class, `contains`). Covers
  Firefox → firefox / firefox-developer-edition. Misses
  "Telegram Desktop" → org.telegram.desktop — but Telegram declares
  a default action so step 1 catches it. Per-app override map can
  be added later if real-world misses accumulate.
  **Hint:** `focuswindow address:<addr>` follows the target's
  workspace automatically (per Hyprland docs). Cross-workspace
  navigation is intentional.
  **Hint:** Cold-launching the app when no window matches is OUT of
  scope for v2. If a notif arrived from an app, the app was running
  at notif time. If the app exited between the notif and the user's
  View pick, step 4's fallback honestly says nothing's there.
```

- [ ] **Step 4: Commit the TODO update**

```bash
cd /etc/nixos/home && git add waybar/TODO.md && git commit -m "TODO: notif-menu View action shipped"
```

- [ ] **Step 5: Final verification — full test suite**

```bash
for t in notif-menu-format-test notif-mako-test notif-menu-flow-test \
         notif-hypr-test notif-rofi-test notif-journal-test; do
    echo "── $t ──"
    "/etc/nixos/home/tests/$t.sh" || { echo "FAILED: $t"; exit 1; }
done
```

Expected: all six suites pass clean. (The five existing ones plus the
new `notif-hypr-test`.)

---

## Self-review notes

Spec coverage check:

| Spec section | Plan task |
|---|---|
| do_view algorithm (steps 1-4) | Task 3 (function definition) + Task 4 (flow tests for each step) |
| hypr_focus_by_class | Task 1 (lib + unit tests) |
| mako_has_default_action | Task 2 (helper + 3 unit tests) |
| L2 menu shape (View top, default hidden, non-default surfaced, Copy/Snooze gone, Dismiss/Back stay) | Task 3 (populate_l2_live rewrite + smoke tests) |
| Recursion guard for `app == "notif-menu"` | Task 3 (step 11 smoke test) + Task 4 (Test 6) |
| Fallback notify-send with `-a notif-menu` | Task 3 (step 10 smoke test) + Task 4 (Test 5) |
| Vanished-fallback unchanged | Task 4 (Test 9 unchanged scenario) |
| True history L2 unchanged | Task 4 (Test 7 unchanged scenario) |
| New lib sourced in entry script | Task 3 (step 1) |
| Drop do_copy / do_snooze | Task 3 (step 2) |
| Per-app override map NOT in scope | (Deliberate omission — documented in spec) |
| Cold-launch NOT in scope | (Deliberate omission — documented in spec) |

No "TBD" / "TODO" / "implement later" placeholders in plan steps. All
code blocks are complete. Function/variable names are consistent across
tasks: `hypr_focus_by_class` (Task 1, 3, 4), `mako_has_default_action`
(Task 2, 3, 4), `do_view` (Task 3, 4), `L2_ID`/`L2_APP` (Task 3
dispatch + Task 4 mocks).

One subtle consistency item flagged inline in Task 2's step 3: the
helper's grep pattern uses a literal TAB character (not the
backslash-t sequence). The plan calls this out explicitly so the
implementer doesn't write `'^default\t'` which grep would treat as
literal-backslash + t.
