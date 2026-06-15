# notif-menu — `View` action and L2 menu rework

**Date:** 2026-06-14
**Status:** design approved, awaiting implementation plan
**Topic:** add a `View` action to notif-menu that takes the user to the source
of a notification (focus the right tab/chat/window). Replace the existing
Copy / Snooze L2 rows with a much tighter menu (View / app non-default
actions / Dismiss / Back).

## Why this work exists

The first notif-menu iteration shipped 2026-06-14 with a generic L2 menu —
Copy summary, Copy body, Snooze 10m/1h, Dismiss. The user's reaction was
direct: those aren't real actions. A real notification from Slack /
Facebook-on-Firefox / Telegram / WhatsApp wants ONE primary verb — "take me
to the source so I can see/respond." Reading the summary and copying text
isn't what notifications are for.

`View` is that verb. It invokes whatever the sending app declared as the
default D-Bus action (which is how Firefox focuses the originating tab,
Telegram focuses the chat, Slack focuses the channel) and falls back to
focusing the app's window via Hyprland when the app declared nothing.

`Dismiss` stays as-is. `Mute this app for 30 minutes` is queued for a
follow-up iteration. `Reply` was considered and dropped — the universal
implementation (rofi-prompt → focus window → `wtype` text) is too fragile
across apps, and per-app integrations are too much per-app work for
marginal gain.

## Behavior contract

### The `View` action

```
do_view(id, app):
  # Step 1 — invoke the notif's default action if declared.
  if mako_has_default_action(id):
      mako_invoke(id, "default")
      mako_dismiss(id)
      return ok

  # Step 2 — no default; focus an existing Hyprland window by class.
  if hypr_focus_by_class(app):
      mako_dismiss(id)
      return ok

  # Step 3 — recursion guard (skip if this is one of OUR fallback notifs).
  if app == "notif-menu":
      mako_dismiss(id)
      return ok

  # Step 4 — nothing worked. Surface honest feedback.
  notify-send -a "notif-menu" -u low \
      "View couldn't open '$app'" \
      "no default action and no matching window"
  return fail
```

The order matters. Step 1 covers Firefox, Telegram, Slack, Discord, native
desktop chat apps — anything that bothered to declare a `default` action,
which is most of them. Step 2 catches the residue: CLI tools, kitty
terminals running Claude, system notifs that just want to bring the
relevant window forward. Step 3 prevents the fallback from looping if the
user picks View on a fallback notif. Step 4 is the only path that does
nothing destructive — it leaves the original notif in mako so the user can
try again.

### Hyprland window matching

```
hypr_focus_by_class(app):
  app_lc = lowercase(app)
  hyprctl -j clients
    | jq -r '.[] | select(.class | ascii_downcase | contains($app_lc))
                  | .address'
    | head -1
    | xargs -I {} hyprctl dispatch focuswindow address:{}
```

Match rule: case-insensitive substring — class contains app-name-lowercased.
Catches:

- mako `app="Firefox"` → class `firefox` / `firefox-esr` /
  `firefox-developer-edition` ✓
- mako `app="kitty"` → class `kitty` ✓
- mako `app="Claude Code"` → class `kitty` ✗ (but Claude Code notifs come
  from kitty, so we'd need the kitty window — out of scope for v2; if it
  matters, the user can add a per-app override later)
- mako `app="Telegram Desktop"` → class `org.telegram.desktop` ✗ (Telegram
  declares a default action, step 1 covers this anyway)

The match is intentionally simple. If a real-world miss accumulates, the
remedy is a per-app `MAP=("Firefox=firefox" "Telegram Desktop=org.telegram.desktop")`
override in a follow-up iteration, NOT in v2.

`focuswindow` automatically switches to the target window's workspace.
That's the behavior we want — "go to the source" means cross-workspace too.

If `hyprctl` exits non-zero (no Hyprland running, e.g. running notif-menu
under X11 for testing), `hypr_focus_by_class` returns 1 cleanly. Step 4
fires.

### `mako_has_default_action`

A thin wrapper around `mako_list_actions` that returns 0 if any row has key
`default`, 1 otherwise. Keeps the `do_view` code readable and avoids
parsing the actions JSON twice.

```
mako_has_default_action(id):
  mako_list_actions(id) | grep -q '^default\t'
```

The `^default\t` anchor avoids false-matching a custom action whose key
*contains* the string "default" mid-string.

## L2 menu shape after this iteration

### For a live notification

```
View                                  ← always row 0
<app actions other than 'default'>    ← e.g. "Mark read", "Archive"
── ──
Dismiss
── ──
← Back
```

- The app-declared `default` action is HIDDEN from the row list — `View`
  invokes it. Showing both would be redundant ("Open" + "View" sitting
  side by side).
- Other app actions (e.g. mako returns `default\tOpen` plus `archive\tArchive`)
  are surfaced normally. The user keeps access to per-app verbs.
- Dropped from v1: Copy summary, Copy body, Snooze 10 minutes, Snooze 1
  hour. They can return in a later iteration if the user actually wants
  them. The OTP use case (Copy body) is a real loss but worth eating for
  the menu honesty win — most notifs do not carry OTP codes, and the
  notif-daemon's existing OTP-extraction handles the OTP case via the
  bell pill's transient face.

### For a vanished-fallback (notif was live at L1 but gone at L2)

Unchanged from v1: `Copy summary` / `Copy body` / `Remove from history` /
`Back`. The notif is gone — `View` has nothing to invoke and nothing to
focus. The vanished path is precisely when the read/copy actions make
sense, so they stay there.

### For a true history pick

Unchanged from v1: `Copy summary` / `Copy body` / `Remove from history` /
`Back`. Same reasoning as the vanished fallback.

## Architecture and files

### New file

- **`/etc/nixos/home/scripts/lib/notif-hypr.sh`** — Hyprland adapter.
  - `hypr_focus_by_class CLASS` — substring-match class, dispatch
    focuswindow, return 0/1.
  - Encapsulates every `hyprctl` call so tests can mock by overriding
    `hyprctl` as a bash function before sourcing (same pattern as
    `notif-mako.sh`).

### Modified files

- **`/etc/nixos/home/scripts/lib/notif-mako.sh`** — add
  `mako_has_default_action ID`. No changes to existing functions.

- **`/etc/nixos/home/scripts/notif-menu`** — five changes:
  1. Source `notif-hypr.sh` alongside the other libs at the top.
  2. New `do_view ID APP` function in the do_* block (lines ~260-280).
  3. Modified `populate_l2_live`:
     - Emit `View` as the first row, kind `view`.
     - In the app-action loop, skip the row whose key is `default`.
     - Drop the Copy/Snooze rows. Keep the separator + Dismiss + Back.
  4. Modified `dispatch_l2` case statement:
     - Add branch `view) do_view "$L2_ID" "$L2_APP" ;;`.
     - Drop branches `copy_summary`, `copy_body`, `snooze_10m`,
       `snooze_1h`. (Their kinds are no longer emitted, so dropping
       the branches is mostly cleanup.)
  5. Drop the `do_copy` and `do_snooze` functions — no callers remain.
     (`do_remove_from_history` stays — history L2 still uses it.)

- **`/etc/nixos/home/tests/notif-menu-flow-test.sh`** — restructure:
  - Old Test 2 (L2 app action `Reply` via idx 1) keeps its assertions
    but its scenario shifts: the new L2 layout with mocked actions
    `default\tOpen\nreply\tReply` is: 0 view, 1 app_action `Reply`
    (Open is hidden because View covers it), 2 noop, 3 dismiss,
    4 noop, 5 back. The pick still happens at L2 idx 1 — the value of
    the test is now "non-default app actions still surface and
    dispatch correctly when View is added."
  - Old Test 3 (Copy summary byte-exactness) — DELETE. No more
    Copy rows.
  - Old Test 4 (Snooze 10 minutes) — DELETE. No more Snooze rows.
  - NEW Test 3 — View with default action: `mako_has_default_action`
    returns true. Pick L1 idx 3 → L2 idx 0 (View). Assert
    `mako_invoke 42 default` and `mako_dismiss 42` in CALL_LOG. NO
    `hyprctl` call.
  - NEW Test 4 — View without default but matching Hyprland window:
    actions empty, mocked `hyprctl -j clients` returns a window with
    class containing the app-name. Pick L1 idx 3 → L2 idx 0 (View).
    Assert `hyprctl dispatch focuswindow address:<addr>` in
    CALL_LOG.
  - NEW Test 5 — View with nothing matching: actions empty, mocked
    `hyprctl -j clients` returns `[]`. Pick L1 idx 3 → L2 idx 0
    (View). Assert a `notify-send -a notif-menu` fallback call was
    recorded in CALL_LOG.
  - NEW Test 6 — View on a fallback notif (recursion guard): journal
    seeded with `app="notif-menu"`, hyprctl mock returns `[]`. Pick
    L1 idx 3 → L2 idx 0 (View). Assert `mako_dismiss` called,
    `notify-send` NOT called.
  - Old Test 5 (history → Remove) renumbers to Test 7 — unchanged
    scenario, history L2 layout unchanged so indices stay correct.
  - Old Test 6 (Esc) renumbers to Test 8 — unchanged.
  - Old Test 7 (vanished fallback) renumbers to Test 9 — unchanged
    (the vanished-fallback L2 layout is unchanged).

- **`/etc/nixos/home/tests/notif-mako-test.sh`** — three new cases for
  `mako_has_default_action`:
  - With actions object containing `default` → returns 0.
  - With actions object NOT containing `default` (e.g.
    `reply\tReply`) → returns 1.
  - With empty actions → returns 1.

### Total scope

| Bucket | Count |
|---|---|
| New files | 1 (`notif-hypr.sh`) |
| Modified script files | 2 (`notif-menu`, `notif-mako.sh`) |
| Modified test files | 2 |
| Roughly new lines (code) | ~50 |
| Roughly new lines (tests) | ~80 |
| Lines removed | ~30 (Copy/Snooze code paths) |

## Edge cases and hazards

- **Fallback notify-send loop.** Step 4 fires a notif from app
  `"notif-menu"`. If the user picks View on it, step 3's recursion
  guard short-circuits before step 4 fires again. The guard is
  load-bearing — losing it would create a loop.

- **`hyprctl` not installed / not running.** All three `hyprctl`
  invocations in `notif-hypr.sh` end with `2>/dev/null || true` style
  protection. `hypr_focus_by_class` returns 1 cleanly on any failure
  (no Hyprland socket, jq error, no matching class). Step 4 fires —
  honest.

- **Multiple Hyprland windows match.** `hyprctl dispatch focuswindow
  address:<addr>` focuses ONE specific window. We take the first
  matching one (`head -1`). Acceptable — when the user asks for
  "Firefox" they want to see Firefox, not be picky about which window.

- **Workspace switch.** `focuswindow` follows the target's workspace
  (Hyprland docs). Cross-workspace navigation is intentional.

- **App-name with spaces.** mako emits `app="Telegram Desktop"`.
  Lowercased = `"telegram desktop"`. The `contains` match against
  class `org.telegram.desktop` would fail (no substring overlap with
  "telegram desktop" — the space breaks it). Telegram declares a
  default action though, so step 1 handles it. If this becomes a
  real-world miss for other apps, add per-app overrides later.

- **Race: notif arrives → user invokes View → mako has already
  expired the id.** `mako_invoke` returns non-zero; `|| true` in
  `do_view` suppresses; `mako_dismiss` also no-ops on a missing id.
  Net effect: View on a vanished notif silently does nothing. The
  user will notice the notif is already gone. Acceptable.

- **kitty / Claude Code.** mako's app-name for Claude notifs is
  `"kitty"` (per current journal sample) NOT `"Claude Code"`. Step 2
  matches class `kitty` correctly. If we ever change the notif source
  to emit `app="Claude Code"`, step 2 stops matching and step 4
  fires. Out of scope to fix in v2.

## Testing

Three additions to the existing test suite (no new test scripts —
the existing flow + mako tests are the right homes).

### `notif-menu-flow-test.sh`

The full test list after this iteration (9 tests):

1. **Dismiss all unread** — unchanged.
2. **L1 unread → non-default app action** — adapted: pick L2 idx 1 to
   hit `Reply` (View at idx 0 invokes default and is tested separately).
   Asserts `mako_invoke 42 reply` and `mako_dismiss 42`.
3. **View with default action** (NEW): `MAKO_ACTIONS_PAYLOAD=$'default\tOpen\n'`.
   Pick L1 idx 3 → L2 idx 0. Assert `mako_invoke 42 default` and
   `mako_dismiss 42` in CALL_LOG, `hyprctl` NOT called.
4. **View with matching Hyprland window** (NEW): actions empty, mock
   `hyprctl -j clients` returns one window with class `firefox` (and
   journal seeds `app="Firefox"`). Pick L1 idx 3 → L2 idx 0. Assert
   `hyprctl dispatch focuswindow address:0x...` in CALL_LOG.
5. **View with nothing matching** (NEW): actions empty, mock `hyprctl
   -j clients` returns `[]`. Mock `notify-send` to log. Pick L1 idx 3
   → L2 idx 0. Assert a `notify-send -a notif-menu` call recorded.
6. **View on a fallback notif** (NEW, recursion guard): journal seeds
   `app="notif-menu"`, hyprctl mock returns `[]`. Pick L1 idx 3 → L2
   idx 0. Assert `mako_dismiss` called, `notify-send` NOT called.
7. **History row → Remove from history** — renumbered from old Test 5.
   Unchanged: history L2 layout is unchanged.
8. **Esc at L1 → no side effects** — renumbered from old Test 6.
   Unchanged.
9. **Vanished fallback** — renumbered from old Test 7. Unchanged.

### `notif-mako-test.sh`

Three cases for `mako_has_default_action`:

```
# Object payload containing default → returns 0
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{"default":"Open","reply":"Reply"}}}]]}'
mako_has_default_action 42
check "[has_default object: returns 0]" test $? -eq 0

# Object payload without default → returns 1
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{"reply":"Reply"}}}]]}'
! mako_has_default_action 42
check "[has_default object missing default: returns 1]" test $? -eq 0

# Empty actions → returns 1
BUSCTL_PAYLOAD='{"data":[[{"id":{"data":42},"actions":{"data":{}}}]]}'
! mako_has_default_action 42
check "[has_default empty: returns 1]" test $? -eq 0
```

## Decisions locked at design

- `View` is the headline action and lives at L2 idx 0 for live notifs.
- The app's `default` action row is hidden when View is shown (no
  redundant "Open" alongside View).
- Step 4's fallback uses `notify-send -a "notif-menu"` so the
  recursion guard can detect it.
- History L2 menu (true history + vanished fallback) is unchanged:
  still Copy summary / Copy body / Remove from history / Back. View
  doesn't apply to dismissed notifs.
- Cold-launch (start the app if not running) is NOT in v2. If a notif
  arrived from an app, the app was running at notif time — focus is
  the right verb. Cold-launch can come later if real-world misses
  accumulate.
- Per-app overrides for class-matching (e.g. `app="Telegram Desktop"`
  → class `org.telegram.desktop`) are NOT in v2. Telegram's default
  action covers this case; other apps with the same pattern can be
  added on demand later.

## Decisions deferred to follow-up iterations

- `Mute this app for N minutes` (mako per-app silence + timer). Will
  be its own design + plan.
- Cold-launch the app when no window matches (`gtk-launch` / desktop
  file lookup).
- Per-app class-name override map for fuzzier matching.
- Bringing Copy / Snooze back if the user finds they actually miss
  them. The new menu's emptiness might reveal that, or might confirm
  the drop was correct.

## Out of scope

- Reply (universal `wtype`-into-focused-window approach was discussed
  and rejected as too fragile).
- Browser-tab-specific deep linking (Firefox's default-action handles
  it; we don't try to do better).
- Bar wiring. `custom/notif-bell` continues to call the original
  `notif-rofi`. Promoting notif-menu to the bar is a separate decision
  for a future iteration once we've used it for a while.
- Nix / home-manager packaging. The script stays at the canonical path
  and is invoked manually.
