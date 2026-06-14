# notif-menu — a fresh rofi notification selector

**Date:** 2026-06-14
**Status:** design approved, awaiting implementation plan
**Topic:** new rofi-based notification list/action menu, launched manually, alongside
the existing `notif-rofi`.

## Why a new selector

The current `notif-rofi` (shipped 2026-06-10 as part of notif-center P1) routes every
click through `makoctl invoke -n $ID` + `makoctl dismiss -n $ID`. That fires the
notification's *default* action only — apps that declare named actions (Slack's
"Reply", Calendar's "Snooze", Discord's "Mark as read") have no surface in rofi.
The visible effect is that picking a notification feels like a dismiss button: the
row disappears, nothing happens.

`notif-menu` exposes the full action set per notification and adds generic
operations (copy summary, copy body, snooze) that work even when an app declares
no actions.

This is a rofi-only iteration. **The bar is untouched.** `custom/notif-bell`'s
on-click handler keeps invoking `notif-rofi`. `notif-menu` is launched manually
from a terminal or keybind until we decide to flip the bar over.

## Architecture

### Files

```
/etc/nixos/home/scripts/
├── notif-menu                       NEW. Entry script. ~80 lines.
├── lib/
│   ├── notif-mako.sh                NEW. Pure mako adapter.
│   ├── notif-menu-format.sh         NEW. Pure row formatters.
│   └── notif-journal.sh             reused unchanged.
```

`notif-rofi`, `notif-rofi-format.sh`, and `notif-rofi-test.sh` are not modified.
The bar's wiring is not modified. No Nix module changes in this iteration.

### Library boundaries

**`notif-mako.sh`** — adapter between the menu and mako's D-Bus surface. All
busctl/makoctl calls go through here; the rest of the codebase never touches mako
directly. Functions:

- `mako_list_live` — prints `id\turgency\tdefault_action_key` per live notif,
  one per line. Empty if no live notifs.
- `mako_list_actions ID` — prints `action_key\tlabel` per action declared by
  this notif, one per line. Empty if no actions or id not live.
- `mako_invoke ID KEY` — `makoctl invoke -n $ID $KEY`. Returns exit code.
- `mako_dismiss ID` — `makoctl dismiss -n $ID`.
- `mako_dismiss_all` — `makoctl dismiss --all`.

**`notif-menu-format.sh`** — pure formatters, no I/O. Output is plain text
(no NUL markers, no Pango markup). Functions:

- `fmt_l1_header LABEL` → `── LABEL ──`
- `fmt_l1_row TS APP SUMMARY UNREAD CRITICAL` → `HH:MM  App · Summary[ · unread][ · critical]`
- `fmt_l2_separator` → `── ──`
- `fmt_l2_row LABEL` → `LABEL` (identity; reserved so future formatting hooks here)
- `fmt_l2_back` → `← Back`

**`notif-menu`** — orchestrator. Sources the three libs, builds Level 1, pipes
to rofi, dispatches on the picked row. Re-enters Level 2 by calling its own
internal functions; "Back" is `exec "$(readlink -f "$0")"`.

## Level 1 — the notification list

### Row format

Single-line plain text:

```
HH:MM  App · Summary[ · unread][ · critical]
```

- `HH:MM` derived from the JSONL `ts` field: `${ts:11:5}`.
- `App` and `Summary` from the journal entry, OR from a live busctl fetch if a
  live id has no journal entry yet (daemon was down at arrival — same fallback
  the current `notif-rofi` does at lines 73–83).
- ` · unread` tag for entries currently in mako's live set.
- ` · critical` tag for urgency 2 AND unread (matches current behavior).
- When `Summary` is empty, suppress the ` · ` separator: emit `HH:MM  App` alone.

### Sections

Rendered as no-op rows starting with the `── ` prefix (the entry script treats
any row with that prefix as a no-op):

```
── Actions ──
Dismiss all unread
── Unread (N) ──
  <live rows, newest-id first>
── History (M) ──
  <historical rows, newest-ts first, excluding ids in live set>
```

When both N=0 and M=0, omit both `Unread`/`History` headers and emit a single
no-op row `── no notifications ──` below the Actions block. The Actions block
itself stays so the user can still see the rofi rendered (confidence that the
script ran).

### Ordering and search

- Unread: by live-id descending (mako's natural order; newest = highest id).
- History: by `ts` descending (`tac` over the journal).
- rofi's `-i` (case-insensitive substring) over the visible row text. App,
  summary, and HH:MM all match. Section headers also match but selecting them
  is a no-op.

### Icons

**No icons.** The current `notif-rofi` carries them via `\0icon\x1f<app_name>`
row metadata, but app names rarely match freedesktop icon-theme keys, so the
column is sparse, and the NUL handling forces a two-pass row build (direct
`printf` to stdout, bypassing `$()` capture) plus a `-show-icons` rofi flag.
Dropping icons collapses `build_rows` to a clean single stream. The trade-off is
visual scanability; the row text already starts with `HH:MM  App`, which gives
the same affordance.

Reversible later: one new function (`fmt_l1_row_with_icon`) and one flag.

## Level 2 — the action menu

Level 2 opens a *fresh* rofi when the user picks a notif row from Level 1.

### For a LIVE notification

```
<app action 1, e.g. Open>             ← the default action if one exists
<app action 2, e.g. Reply>            ← remaining actions in declared order
<app action 3, e.g. Mark as read>
── ──
Copy summary
Copy body                              ← omitted if body is empty
Snooze 10 minutes
Snooze 1 hour
Dismiss
── ──
← Back
```

- App-declared actions come from `mako_list_actions ID`. The entry whose key
  is the literal string `default` (mako convention) is hoisted to the top of
  the rendered list. Remaining entries follow in the order mako returned them.
  The default's position is the signal — no `(default)` tag.
- The separator row `── ──` is the same `── `-prefixed no-op pattern as L1
  section headers — selecting it returns the user to L2 unchanged.
- When the app declares no actions (most `notify-send` rows), the entire app-
  action block is empty; L2 starts directly at Copy. The menu is never empty.

### For a HISTORY notification

```
Copy summary
Copy body                              ← omitted if body is empty
Remove from history
── ──
← Back
```

mako has forgotten the id, so the named actions are unreachable. No
`Dismiss` (nothing to dismiss). No `Snooze` (the original is gone — snoozing
implies "the same notification again at time T", which only makes sense when
that notification is still live).

### Rofi prompt

Level 2's rofi `-p` value is `<App> · <truncated summary>` (60 chars max,
appending `…`), so the user keeps context of which notification they're acting
on.

### Stale-id handling between L1 and L2

When the user picks an Unread row in Level 1, mako may have dismissed it in
the 100–500 ms between picks (auto-expiry, another tool, the daemon's per-app
timeout). On Level 2 entry, the script calls `mako_list_live` once and checks
whether the id is still present:

- Present → live action menu.
- Absent → history action menu, with a top no-op row
  `── no longer live — history actions only ──` so the user understands why
  the menu is sparse.

One extra busctl call per L1 pick; acceptable for an interactive flow.

## Action dispatch

| Picked row | Syscall |
|---|---|
| App action label (matched against the rendered list) | `mako_invoke $ID $KEY` then `mako_dismiss $ID` |
| `Copy summary` | `printf '%s' "$SUMMARY" \| wl-copy` |
| `Copy body` | `printf '%s' "$BODY" \| wl-copy` |
| `Snooze 10 minutes` | `systemd-run --user --on-active=10min --collect notify-send -a "$APP" -u $URGENCY -- "$SUMMARY" "$BODY"` then `mako_dismiss $ID` |
| `Snooze 1 hour` | same with `--on-active=1h` |
| `Dismiss` (live L2) | `mako_dismiss $ID` |
| `Dismiss all unread` (L1 Actions block) | `mako_dismiss_all` |
| `Remove from history` (history L2) | rewrite journal via `jq -c "select(.id != \$ID or .ts != \"\$TS\")"` → atomic `tmp + mv -f` |
| `← Back` | `exec "$(readlink -f "$0")"` |
| `── …` (any `── `-prefixed row) | no-op |

### Notes

- `printf '%s'` (no trailing newline) — important for OTP codes and URLs where
  a stray newline would break paste-into-textfield flows.
- `systemd-run --user --collect` queues a one-shot transient unit; no daemon
  needed; the unit auto-collects after firing.
- The snooze re-fire is a *new* notification with a fresh mako id. Original
  is dismissed at snooze-pick time so it doesn't linger in the unread set.
- App-action invocation also dismisses (belt-and-braces; matches current
  `notif-rofi` lines 167-168). Apps usually self-dismiss but not all do.
- For app-action dispatch we maintain a `label → action_key` parallel array
  built when Level 2 renders. Action labels are unique within a single notif's
  action set (mako doesn't permit duplicates), so literal label lookup is safe.
- `Remove from history` keys on `id + ts` together, not id alone — mako recycles
  numeric ids over time and two journal lines can share an id if they're far
  enough apart.

## Edge cases & hazards

- **busctl JSON shape variance for actions** (TODO.md line 826). mako 1.10
  returns `actions` as `a{ss}` which busctl renders as a JSON object, but
  older mako versions render an alternating-strings array. `mako_list_actions`
  must defensively type-switch:

  ```sh
  jq -r --argjson id "$1" '
    .data[0][]? | select(.id.data == $id) | .actions.data as $a
    | if ($a | type) == "object" then
        $a | to_entries[] | [.key, .value]
      elif ($a | type) == "array" then
        [range(0; $a | length; 2)] | .[] as $i | [$a[$i], $a[$i+1]]
      else empty end
    | @tsv'
  ```

- **Empty everything.** Show `── Actions ──` / `Dismiss all unread` /
  `── no notifications ──`. Never an empty rofi.

- **Snooze timer dies on logout.** Acceptable for v2. Persistence-through-reboot
  would need a stored-snooze file the daemon scans on boot; out of scope.

- **Journal write/read race.** Daemon appends, menu reads via `tac`. JSONL is
  line-atomic on local fs for lines under PIPE_BUF (~4 KB); our lines fit. No
  locking needed.

- **Stale `id` in Remove-from-history.** Keyed on `id + ts` (above).

- **rofi closed without a pick (Esc).** `pick=$(... | rofi ...) || exit 0` —
  same idiom as the current notif-rofi.

- **`exec "$0"` for Back.** Requires the script to be reachable by its argv[0].
  Resolved via `readlink -f "$0"` so symlink invocations still work.

- **jq / awk / busctl cost.** No hot-loop concern — this is interactive, runs
  once per rofi invocation. The hot-loop avoidance rule is daemon-side.

## Testing

Three test scripts under `/etc/nixos/home/tests/`, following the existing
`notif-rofi-test.sh` mocking pattern. No live mako required.

### `notif-menu-format-test.sh`

Pure format-lib unit tests:

- `fmt_l1_header "Unread (3)"` → `── Unread (3) ──`
- `fmt_l1_row` with unread=1, critical=1 → tags both present
- `fmt_l1_row` with unread=1, critical=0 → only unread tag
- `fmt_l1_row` with empty summary → no trailing ` · `
- `fmt_l2_separator` → `── ──`
- `fmt_l2_back` → `← Back`

### `notif-mako-test.sh`

Adapter tests with a mocked `busctl` function that prints canned JSON:

- `mako_list_live` parses 0, 1, and 3 live entries correctly.
- `mako_list_actions` with `actions.data` as **object** payload (mako 1.10)
  emits the right `key\tlabel` lines.
- `mako_list_actions` with `actions.data` as **alternating array** payload
  (older mako) emits the same lines.
- `mako_list_actions` with empty `actions.data` emits nothing.
- `mako_list_actions` for a non-existent id emits nothing.

### `notif-menu-flow-test.sh`

End-to-end-ish flow tests. Mock `rofi`, `mako_list_live`, `mako_list_actions`,
`wl-copy`, `systemd-run`, `mako_invoke`, `mako_dismiss`. Assert:

- L1 with 2 live + 3 history rows renders the expected row sequence.
- L1 pick of "Dismiss all unread" → `mako_dismiss_all` called once.
- L1 pick of a live row → L2 rofi opens; pick of "Reply" → `mako_invoke ID
  reply` then `mako_dismiss ID`.
- L2 pick of "Copy summary" → `wl-copy` receives the exact summary bytes
  (no trailing newline).
- L2 pick of "Snooze 10 minutes" → `systemd-run` called with `--on-active=10min`
  and `--collect`; then `mako_dismiss ID`.
- L2 pick of "Copy body" on a notif with empty body → "Copy body" not present
  in the rendered list (this is asserted on the L2 list build, not the pick).
- L1 pick of a history row → history L2 rofi opens with no Dismiss / Snooze.
- L2 "Remove from history" → journal rewritten without the matching `id+ts`
  line, all other lines preserved verbatim.

## Out of scope

- Bar integration. `custom/notif-bell` keeps calling `notif-rofi`.
- Nix module / `writeShellScriptBin` packaging. The script is invoked
  by absolute path or via a manual PATH symlink for v2.
- App-action icons or per-app icon mapping.
- Per-app grouping / coalescing (Discord ping-storm collapse).
- Snooze persistence through reboot.
- Filter / search beyond rofi's built-in case-insensitive substring.
- DND / profile interaction. The profile system continues to gate which
  notifications get into mako in the first place; the menu just lists what's
  there.

## Decisions deferred to the implementation plan

- Exact rofi `-theme-str` values — width, font, padding. The current
  `notif-rofi` uses `width: 50%`, `font: meslo-ng 13`. Match by default, tweak
  during implementation if the L2 menu reads cramped.

## Decisions locked at design

- `makoctl invoke` and `makoctl dismiss` failures are **silent** — same `|| true`
  pattern as current `notif-rofi`. rofi has already closed by the time the call
  runs, so there is no useful feedback channel; loud errors would just become
  shell noise the user never sees.
- Snooze re-fire preserves the original urgency, including 2 (critical).
