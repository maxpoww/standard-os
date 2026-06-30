# Notification drawer + DND + per-app rules (P1)

**Date:** 2026-06-10
**Status:** Approved (pending user review of this written doc).
**Builds on:** `2026-06-06-notification-center-spine-design.md` — the spine ships mako + notif-daemon + custom/notif pill. This spec extends those primitives without changing the spine's invariants (mako popups OFF, OPTIONS owns the surface, RTMIN+12, /tmp/waybar-cache/notif).
**Scope:** Phase 1 of "finish the notification setup" — drawer, DND toggle, per-app rules infrastructure. Phase 2 (action buttons, app icon rendering, 2FA extraction) and Phase 3 (sound, focus modes) are separate specs that compose onto this one.

---

## Purpose

The spine made notifications visible. P1 makes them **usable day-to-day**:

1. The user can see PAST notifications without using `makoctl`.
2. The user can mute notification alerts before a meeting / focused-work block.
3. The user can declaratively silence specific noisy apps via a Nix option.

Everything is reachable via left-click, hover, or hardware key — never right-click ([[no-right-click]]). Rofi is the canonical "more OPTIONS" path for anything that overflows the bar ([[rofi-as-more-options]]).

---

## The new layout

```
Rest face (always visible, no hover required):

  [î³]                                    ← bell, color reflects state

On hover bell, drawer expands LEFT (right-zone rule):

  [󰂛 dnd][î³]                            ← DND child appears left of bell

On new notification arrival (the bell pill widens in place):

  [Slack · PR review requested][󰂛?][...]   ← wide "noti pill" for 5s
                                            then collapses back to bell
                                            with appropriate pin color
```

There is **no separate "+" pill, no separate "row" pill**. The bell is the single anchor; it transforms in place when a notification arrives, then settles back. The DND child is the only hover-revealed sibling. Everything else routes through rofi.

### Click semantics (all left-click)

| Target | Bell state | Action |
|---|---|---|
| Bell pill | rest face (bell glyph) | Open rofi notification list |
| Bell pill | transient face (wide `App · Title`) | Invoke the notification's default action via `makoctl invoke -n <id>`, then `makoctl dismiss -n <id>` (matches the spine's existing fallback for action-less notifications) |
| DND child | any | Toggle DND via `makoctl mode -t dnd` |

The "click the bell to open rofi" mechanic gives the user a single, always-present entry point to ALL notifications including dismissed history. The drawer (just DND) keeps the bar minimal at rest.

### State paint on the bell pill

The bell carries ALL state at rest. Pin color and `opt-pushed` compose orthogonally with each other and with the transient face.

| Bell state | Class composition |
|---|---|
| 0 unread, DND off | `opt-pill dark` (plain bell glyph) |
| 0 unread, DND on | `opt-pill dark opt-pushed` |
| N unread, no critical | `opt-pill dark opt-pin-green` |
| N unread, critical (5s arrival window) | `opt-pill dark opt-no opt-pulse-orange` |
| N unread, critical (after 5s — calmed) | `opt-pill dark opt-no opt-pin-orange` |
| Any state + DND on | composes `opt-pushed` |

`opt-pushed` already composes with state colors and animations via the existing CSS (`opt-pushed`'s soft top-inset shadow is purely additive; see `waybar/CLAUDE.md` "Pushed (toggle ON)").

### Arrival behavior

| Urgency | DND off | DND on |
|---|---|---|
| Low (0) | No transient. Bell silently bumps to `opt-pin-green` if it wasn't already. | No transient. Bell silently bumps to `opt-pin-green`. |
| Normal (1) | **Wide pill for 5s** with `App · Title`. NO `opt-flash` (silent context shift per Rule 4 — see below). After 5s, collapses to bell + `opt-pin-green`. | No transient. Bell silently bumps to `opt-pin-green`. |
| Critical (2) | **Wide pill for 5s** with `opt-pulse-orange` (urgency mandate pierces the silent-context rule). After 5s, collapses to bell + `opt-pin-orange`. | **Same** — critical pierces DND, identical behavior to DND-off. |

**Why no opt-flash on normal arrivals:** the spine spec wired `opt-flash` to every normal arrival. P1 removes that because Rule 4 says context shifts (a system-initiated notification arrival is a context shift, not user input) should be **silent**. `opt-flash` is reserved for *user-initiated* events (hardware-key press, click). The spine's `opt-flash` on normal-arrival was a Rule 4 violation we ship without; critical's `opt-pulse-orange` is a documented exception (the spec's urgency-pierces-DND mandate has the same "loud override" logic).

**5s vs spine's 4s:** the user picked 5s as the read window. Configurable via the Nix `transientMs` option (default 5000).

---

## The drawer (`group/notif`)

The current `custom/notif` (a leaf module) becomes a `group/notif`:

```jsonc
"group/notif": {
    "orientation": "inherit",
    "drawer": {
        "transition-duration": 200,
        "transition-left-to-right": false   // right-zone: expand LEFT
    },
    "modules": [
        "custom/notif-dnd",
        "custom/notif-bell"
    ]
}
```

- `custom/notif-bell` is the parent (the hover trigger, always visible).
- `custom/notif-dnd` is the only child (revealed on hover).

In `modules-right` we replace the single `"custom/notif"` with `"group/notif"`. The bell is the rightmost item in the group (children declared first appear LEFT when `transition-left-to-right: false`).

### Position in SYSTEM zone

Same as the spine: leftmost in `modules-right` after `tray`. The hover-revealed DND chip appears one step further left when the group expands.

```
[tray][group/notif: 󰂛 î³][group/group-2][group/group-power]...
                  ↑ DND (hover-revealed)
                       ↑ bell (always visible, click → rofi)
```

---

## DND toggle (`custom/notif-dnd`)

A hover-revealed child pill. Reads `/tmp/waybar-cache/notif-dnd`, written by the daemon. Glyph: Material Design `󰂛` (U+F009B, bell-slash). Click invokes `notif-click dnd` which runs `makoctl mode -t dnd` (toggle); the daemon's DBus subscription sees the `ModeChanged` signal and updates both `notif-dnd` and `notif-bell` cache files.

```jsonc
"custom/notif-dnd": {
    "exec": "cat /tmp/waybar-cache/notif-dnd 2>/dev/null || echo '{\"text\":\"\"}'",
    "return-type": "json",
    "format": "{}",
    "interval": "once",
    "signal": 12,
    "tooltip": true,
    "on-click": "notif-click dnd"
}
```

State render:

| Daemon state | Cache content |
|---|---|
| DND off | `{"text":"󰂛","class":["opt-pill-child","dark"],"tooltip":"Do Not Disturb"}` |
| DND on | `{"text":"󰂛","class":["opt-pill-child","dark","opt-pushed"],"tooltip":"Do Not Disturb (on)"}` |

The DND child is `.opt-pill-child` (warmer surface, since it's inside an expanded cluster).

---

## The bell (`custom/notif-bell`)

The renamed `custom/notif`. Reads `/tmp/waybar-cache/notif-bell`. Glyph: Font Awesome `` U+F0F3 (already used by the spine). State machine table above is the authoritative paint spec; the daemon's `render_bell_for_state` is the encoding.

```jsonc
"custom/notif-bell": {
    "exec": "cat /tmp/waybar-cache/notif-bell 2>/dev/null || echo '{\"text\":\"\"}'",
    "return-type": "json",
    "format": "{}",
    "interval": "once",
    "signal": 12,
    "tooltip": true,
    "on-click": "notif-click bell"
}
```

`notif-click bell` dispatches based on the cache's current `text` field: contains the ` · ` separator → invoke-and-dismiss latest; pure bell glyph → open rofi.

---

## Rofi notification list

`~/.config/waybar/scripts/notif-rofi` is a thin bash script (installed via the Nix module). It reads the persistent journal, formats entries, presents via `rofi -dmenu`.

### Layout

```
> [filter]
  ── Actions ─────────────────────────
  ── Dismiss all unread ──────────────
  ── Unread (3) ──────────────────────
   Slack · PR review requested        10:42  unread
   firefox · Download complete         10:38  unread
   systemd · foo.service failed         10:31  unread  critical
  ── History (last 197) ──────────────
   Slack · channel message              09:14
   firefox · Page loaded                08:42
   ...
```

- Top action row: "Dismiss all unread" — Enter clears them all.
- Unread section: lives entries from mako. Enter on one invokes `makoctl invoke -n <id>` + `makoctl dismiss -n <id>`.
- History section: entries from the persistent journal that are no longer in mako's live list. Enter on a historical entry is a no-op (already dismissed) — closes rofi.

### Persistent journal

Path: `~/.local/share/standard-os/notif-history.jsonl`

Format: append-only newline-delimited JSON, one record per arrival:

```json
{"ts":"2026-06-10T13:42:11-03:00","id":42,"app":"Slack","summary":"PR review requested","body":"...","urgency":1,"dismissed_at":"2026-06-10T13:43:05-03:00"}
```

- `ts` — ISO 8601 with timezone, set when daemon's `Notify` handler fires.
- `id` — mako's notification id (only meaningful while the entry is in mako's live list; we still write it for traceability).
- `app`, `summary`, `body`, `urgency` — copied from D-Bus.
- `dismissed_at` — empty at first; set when daemon sees the `Dismissed` D-Bus signal for the same id. May stay empty if the daemon misses the dismiss (mako restart, etc.) — rofi script cross-references with mako's live list and considers any id NOT in live list to be dismissed.

Ring-bounded to last **200 entries** (configurable via `services.notifCenter.journalLimit` Nix option). Implementation: after every append, if the file exceeds 200 lines, the daemon rewrites it as `tail -n 200`. Rewrite is atomic (`tmp + mv -f`) so partial reads from rofi can't corrupt.

Journal pruning is cheap (< 100 µs at 200 lines) and runs only on arrival, so it does not affect steady-state CPU.

### Why a persistent journal at all

The spine's "rest face shows pin color when unread" works for the immediate moment, but a user who closed their laptop yesterday and opened it today loses ALL context — mako's history is volatile (per-session). The journal makes "show me what came in" a meaningful question across reboots.

200 entries is roughly a week of light-use notification volume; for power users we expose `journalLimit`.

---

## Per-app rules

A declarative Nix option that emits mako `[app-name=<name>]` blocks into `~/.config/mako/config`:

```nix
services.notifCenter.silencedApps = lib.mkOption {
  type = lib.types.listOf lib.types.str;
  default = [];
  description = ''
    Apps whose notifications should be DROPPED entirely — neither
    transient nor pin nor journal entry. App names match the D-Bus
    `app_name` field exactly (case-sensitive). Examples:
    NetworkManager, bluez, spotify, cups.
  '';
};
```

For each entry, the rendered mako config gets:

```
[app-name=<entry>]
invisible=1
history=0
```

`history=0` makes mako drop the notification immediately after presentation (which is itself invisible because of `max-visible=0` globally) — never reaches `ListNotifications`, never reaches our journal.

**Default:** empty. The OS is already quiet (popups off); the user opts in to specific app silencing if they hit noise. No default-silenced list ships.

### Caveat: app names from D-Bus are NOT stable across distros

The same conceptual "Slack" app may emit `app_name="Slack"` on one distro, `"Slack Technologies Inc."` on another. The Nix option is a string list because that's the user's escape hatch. We document the discovery recipe in the module: `busctl --user --json=short call org.freedesktop.Notifications /fr/emersion/Mako fr.emersion.Mako ListNotifications | jq '.data[0][]?."app-name".data'` shows the exact strings to feed back.

---

## Daemon changes

### Two cache files instead of one

The current spine writes `/tmp/waybar-cache/notif` (a single object describing the whole pill). P1 splits this into:

- `/tmp/waybar-cache/notif-bell` — the bell parent pill's text + class + tooltip
- `/tmp/waybar-cache/notif-dnd` — the DND child pill's text + class + tooltip

Both written atomically (`tmp + mv`). Both signaled by RTMIN+12 (one `pkill` wakes both children).

### Journal append + prune

A new helper `journal_append(ts, id, app, summary, body, urgency)` appends one JSON line then prunes if needed. A separate `journal_mark_dismissed(id, ts)` updates the most recent entry with matching id to set `dismissed_at`. Pruning is `tail -n 200` to a temp file, then atomic mv.

### DND tracking

The daemon reads `makoctl mode` at startup AND on every `ModeChanged` D-Bus signal. The current mode flows into the bell + DND cache renders. Critical-pierces-DND is the only urgency-vs-mode override; everything else respects the mode.

### State machine (revised)

```
on Notify (D-Bus):
    1. journal_append(...)
    2. query mako state (unread count, critical count, ids list)
    3. if urgency == low or (DND on and urgency != critical):
           re-render bell-only (state pin update; no transient)
       else:
           start transient: write bell-wide-pill cache for 5s
    4. write bell + dnd caches, signal waybar

on Dismissed (D-Bus):
    1. journal_mark_dismissed(id, now)
    2. query mako state
    3. clear transient if active and matches dismissed id
    4. re-render bell + dnd, signal waybar

on ModeChanged (D-Bus):
    1. read new mode via makoctl mode
    2. re-render bell + dnd, signal waybar

on timer (transient 5s expiry):
    1. clear transient kind, return bell to rest-with-pin
    2. write bell cache, signal waybar
```

The current spine's `TRANSIENT_KIND` state distinction (normal/critical/critical_acked) collapses to just `transient` vs not — the transition from animating to pin-orange happens at the SAME 5s boundary as collapse-back-to-bell. (The spine's separate `critical_acked` state with motion-stopped-but-still-wide is not retained because the wide pill always disappears at 5s in P1.)

---

## Click handler changes (`notif-click`)

Subcommands grow from `{invoke, drawer}` to `{bell, dnd}`:

```
notif-click bell
    → if cache text contains ' · ' (transient):
          makoctl invoke -n <latest-id> + makoctl dismiss -n <latest-id>
      else:
          exec ~/.config/waybar/scripts/notif-rofi

notif-click dnd
    → makoctl mode -t dnd   (mako handles toggle vs set semantics)
```

The pure decision function `notif_click_decide` is extended; existing test cases for `invoke` rename to `bell` and grow new ones for `dnd`.

---

## Implementation seams (file inventory)

```
home/modules/notif-center.nix            ← extended: typed options for journalLimit,
                                            silencedApps, transientMs; mako config grows
                                            per-app blocks
home/scripts/notif-daemon                ← extended: two cache files, journal append+prune,
                                            ModeChanged subscription, 5s transient window
home/scripts/notif-click                 ← rewritten subcommand surface (bell/dnd)
home/scripts/notif-rofi                  ← NEW — reads journal + mako, formats rofi entries
waybar/config.jsonc                      ← custom/notif → group/notif with two children
waybar/ARCHITECTURE.md                   ← notif-daemon cache list grows to 2; rofi entry point noted
home/tests/notif-state-test.sh           ← renamed cases for bell-rest / bell-transient
home/tests/notif-click-test.sh           ← updated for bell/dnd subcommands
home/tests/notif-journal-test.sh         ← NEW — journal append/prune/mark-dismissed unit tests
home/tests/notif-rofi-test.sh            ← NEW — rofi script entry formatting (text-only test;
                                            doesn't actually launch rofi)
```

---

## Verification / acceptance criteria

A fresh `systemctl --user restart notif-daemon.service` followed by `systemctl --user restart waybar.service` should produce:

1. **Rest:** bell is visible immediately, no pin color, no opt-pushed.
2. **Hover bell:** DND child appears LEFT of bell.
3. **Click DND child:** `makoctl mode` flips between `default` and `dnd`; child gains/loses opt-pushed. Bell ALSO gains/loses opt-pushed (mirror).
4. **`notify-send "normal test"`** (DND off): bell pill widens to ` notify-send · normal test` for 5s, no animation. Collapses to bell + opt-pin-green. Journal file gains a new line.
5. **`notify-send --urgency=critical "critical test"`** (DND off): bell widens with opt-pulse-orange + opt-no for 5s. Collapses to bell + opt-pin-orange.
6. **`notify-send --urgency=low "low test"`** (DND off): NO wide pill. Bell silently gains opt-pin-green if not already.
7. **DND on + normal:** no wide pill. Bell silently gains opt-pin-green.
8. **DND on + critical:** pierces — wide pill with opt-pulse-orange for 5s, collapses to bell + opt-pin-orange (opt-pushed retained throughout).
9. **Click bell at rest:** rofi opens with all unread + journal history.
10. **Click bell during wide pill:** the notification's default action fires (if any) AND the notification is dismissed. Wide pill disappears immediately.
11. **Rofi: Enter on "Dismiss all unread":** `makoctl dismiss --all` runs; bell returns to no-pin state; rofi closes.
12. **Rofi: Enter on an unread entry:** invoke+dismiss that specific notification; rofi closes (rofi's default behavior — re-open if you want to dismiss another).
13. **Rofi: Enter on a historical entry:** no-op; rofi closes.
14. **`services.notifCenter.silencedApps = [ "spotify" ];`** rebuild → mako config grows a `[app-name=spotify]` block; spotify notifications no longer reach the bell, the daemon, or the journal.
15. **Journal limit:** after 250 arrivals, journal file is exactly 200 lines (oldest pruned).

Hazard audit:
- `class` JSON arrays on all three pill caches.
- `dark` token on every non-empty cache.
- Atomic writes verified for bell, dnd, journal.
- `pkill -RTMIN+12` fires only on real-content change (bell + dnd dedup independently).
- No standalone `#custom-notif-bell { ... }` or `#custom-notif-dnd { ... }` geometry blocks in style.css.
- `notif-rofi` script source byte-checked (`od -An -c`) for the bell-slash glyph U+F09B.
- Rule 4 compliance: normal arrivals produce no animation (silent context shift); only critical pulses.

---

## Open questions (resolved before implementation)

1. **Rofi: stay open after invoking an entry?** Default rofi behavior is to close on Enter. We'll keep that — the user can re-open if they want to dismiss another. If repetitive dismissal becomes a pain we can switch to a multi-select mode in a follow-up.
2. **DND tooltip text:** "Do Not Disturb" + parenthetical "(on)" when engaged. Per the OPTIONS tooltip rule, name what the pill IS, not its current state — but DND's whole point is that you check the state, so the parenthetical helps. Acceptable deviation.
3. **Bell glyph during DND-on, 0 unread:** the bell glyph stays; opt-pushed paints engaged. (Considered: replacing the bell with bell-slash; rejected because the DND child already carries the bell-slash glyph and showing two of them is redundant.)

---

## Out of scope — Phase 2 + 3 (separate specs)

P2 — "drawer composers" (compose onto the wide-pill state and the rofi script):
- Action buttons rendered inside rofi entries (multi-action notifications).
- App icon rendering — `image-path` D-Bus hint as the prefix glyph in both the wide pill and the rofi entries.
- 2FA / OTP code extraction — regex scan of summary/body; auto-copy to clipboard via `wl-copy`; surface in the wide pill as `opt-glow-green` offer.

P3 — "orthogonal" (compose onto DND):
- Sound — `canberra-gtk-play` per urgency / per-app, honoring DND.
- Focus modes — scheduled DND profiles (Work / Sleep / Gaming), per-app exclusions, calendar integration.

Each follows the same brainstorm → spec → plan → implement → commit discipline.

---

## Hazards specific to this design

- **`group/drawer` children all render constantly, even when collapsed.** waybar renders every group child to the DOM; CSS `.empty` collapse just hides them visually. This is fine for two children but is an architectural cap on how many drawer children a future feature can add cheaply.
- **5s transient + same-id rapid repeats.** If the user gets 4 notifications in 5 seconds, the wide pill displays each (latest wins per spine), but the 5s timer extends to "5s after the latest." Same trick the spine uses; carry forward.
- **Mako DND mode is `default` vs `dnd` only.** No `invisible` or `do-not-disturb` mode in mako 1.10 beyond these two. The Nix option `services.notifCenter.silencedApps` complements mode-based silencing with per-app drops.
- **Journal pruning under high arrival rate.** If 1000 notifications/s hit (unlikely but possible from a misbehaving app), pruning rewrites the file each time. Could be amortized by pruning only when `lines > limit * 1.1` so we prune in batches. Implementation note for the plan.
- **Journal write race with rofi read.** mitigated by atomic `tmp + mv`; rofi reads a complete snapshot or the prior version, never a half-written file.
- **Rofi script PATH.** Installed via writeShellScriptBin (same pattern as notif-daemon/notif-click) with `lib.makeBinPath` curating jq, busctl, mako, coreutils. Rofi itself comes from system PATH; if absent, script logs and exits non-zero.
- **`makoctl mode -t dnd` is a TOGGLE.** Calling it twice flips back. The daemon must not assume a particular post-call mode; it queries `makoctl mode` after every toggle to read the new state. Critical: do NOT cache the click direction.
- **DND child is `opt-pill-child` (child surface).** Different background tint from `.opt-pill`. Verify hover and click work — the existing CSS for `.opt-pill-child` should compose with `.opt-pushed` already (per the spine's existing hover-system rules).
