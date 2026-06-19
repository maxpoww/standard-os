# Widgets canvas — design

A new surface class for StandardOS: the **canvas**. It hosts widgets the way
the bar hosts pills. Three surfaces share the canvas substrate: a **Dashboard**
the user summons during a session by pressing Super+RETURN (canvas persists
until Esc dismisses it), a **Lock screen**
that re-uses the same canvas with an auth boundary, and a **Greeter** for
multi-user installs and the post-logout path. All three share data through
the existing `/tmp/waybar-cache/` pattern and share visual identity through a
single CSS palette tokens file. The Dashboard catalog grows to 12 widgets at
maturity; the first shippable wave delivers only the substrate + a clock.

This spec is the destination. The implementation plan (next document) will
break the destination into independently-shippable waves, the first being
"clock on a veiled canvas, nothing else."

---

## 1. Why this surface exists

StandardOS today has one visible surface: the bar, hosting pills. Pills are
small, dense, contextual, and tied to *moments of need*. They are excellent
for "I want to change the volume" or "I want to see what's playing." They
are bad — by design — for "show me what's happening" or "let me sit with my
day for a moment." That second class of need lives on a different surface in
every modern OS: macOS's Notification Center, iOS's Today view, Windows 11's
widget board, GNOME's Activities, KDE's dashboard.

StandardOS needs that second surface and has not had one. The 2026-06-19
UX-gap analysis flagged it as todonow item #7 (Widgets) and item #5
(Themed login + lock screen); brainstorming collapsed them into one design
because they share substrate.

The canvas is that surface.

The bar is for **moments of need**. The canvas is for **moments of pause**.
Pillar 3 ("appear when their use is logical") still holds: the canvas is
never persistent during work — it's summoned, and on the Dashboard surface it
closes the instant the user lets go.

---

## 2. The three surfaces

| Surface | When it appears | Persistence | Interaction | Auth |
|---|---|---|---|---|
| **Dashboard** | User presses Super+Return | Until user presses Esc | Widgets are focusable + clickable from Wave 1 onward (the canvas window is `:focusable true`); clicks are captured by widgets, not passed through. Esc still dismisses via a Hyprland `bind` that intercepts before the focused widget. | None (already in session) |
| **Lock screen** | `loginctl lock-session`, idle timer (off by default), lid-close (configurable) | Until auth succeeds or hibernate | Password input + read-only widgets | PAM password |
| **Greeter** | Boot if autologin off; after explicit logout | Until auth + session choice | User-pick (if >1 user) + password input | PAM password |

Three rules that follow from this table:

1. **Lock is opt-in.** The 2026-06-05 suspend-hibernate spec deliberately
   eliminated swaylock with the rationale that full-disk encryption is the
   real security boundary on a single-user FDE host. This design re-introduces
   a lock screen *without* re-introducing the friction by default. The Nix
   option `services.standardos.lock.enable` defaults to **false**; users who
   want a shared-desk lock turn it on. Single-user FDE installs stay
   friction-free.
2. **Greeter rarely appears.** Default install autologins (today's behavior,
   preserved). The greeter exists for multi-user installs and the logout
   path. `services.standardos.greeter.enable` defaults to **false**.
3. **Dashboard is the only canvas seen daily.** Lock + greeter are rare
   events. Design effort follows usage: Dashboard gets the full widget
   catalog and the polished animations; Lock + Greeter render a curated
   subset.

### 2.1 Summon mechanism (Dashboard)

Hyprland bindings:

```
bind = $mainMod, RETURN, exec, eww open dashboard
bind = $mainMod, RETURN, submap, canvas-open

submap = canvas-open
bind = , ESCAPE, exec, eww close dashboard
bind = , ESCAPE, submap, reset
submap = reset
```

Press Super+RETURN to open the canvas; press **Esc** to dismiss it. The
canvas persists between open and Esc — no holding, no second-press
toggle. The Esc binding lives inside a Hyprland *submap* so it only
intercepts Esc while the canvas is open; outside the canvas-open state,
Esc is its normal application key.

The keybind is **not** advertised. Mouse users have no path to the canvas.
This is a deliberate philosophy choice: widgets sit *above* pillar 6's floor.
A user who never presses Super+RETURN experiences no degradation, the same
way a macOS user can ignore Cmd+Space their whole life. The canvas is the
quiet invitation, not the floor.

**Why persistent + Esc instead of hold-to-peek.** The first draft of this
spec specified hold-Super+RETURN-to-peek; on physical test the user found
the chord uncomfortable to hold while reading widgets. Persistent +
Esc-to-dismiss matches how macOS Notification Center, iOS Today, and
Windows 11 widgets all behave — open it, sit with it, dismiss when
done. The lock and greeter surfaces also persist until auth, so the
Dashboard's interaction model is now a clean superset across surfaces.

### 2.2 Trigger mechanism (Lock)

The standard Wayland lock entry point: `loginctl lock-session`. The Nix
module wires this to launch hyprlock as a systemd unit. Idle-triggering and
lid-close-triggering are configurable via hypridle and `logind` lid settings
respectively — both default off in v0 to match the friction-free default.

### 2.3 Greeter activation

`services.greetd.settings.default_session.command` flips from
`uwsm start hyprland-uwsm.desktop` (today's autologin path) to `regreet` when
`services.standardos.greeter.enable = true`. regreet launches the user-select
+ password flow; on success it execs the user's chosen session.

---

## 3. Canvas anatomy

The canvas is a full-screen translucent veil with three named zones. Widgets
declare a zone; the canvas places them.

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│                    CROWN (top center)                    │ ← identity / clock
│                  small-to-medium widgets                 │
│                                                          │
│                                                          │
│                                                          │
│                                                          │
│                    HERO (vertical mid)                   │ ← the focal piece
│                    one large widget                      │
│                                                          │
│                                                          │
│                                                          │
│                                                          │
│  ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐ │
│  │    │  │    │  │    │  │    │  │    │  │    │  │    │ │ ← FIELD
│  └────┘  └────┘  └────┘  └────┘  └────┘  └────┘  └────┘ │   small widgets
└──────────────────────────────────────────────────────────┘
```

| Zone | Position | Slot count | Holds |
|---|---|---|---|
| **CROWN** | top center, ~15 % of canvas height | 1–3, horizontally aligned | Identity-bearing widgets (user-select on lock/greeter, secondary clock or date on Dashboard) |
| **HERO** | vertical center, ~40 % of canvas height | Exactly 1 | The focal element — large clock on lock/greeter, clock by default on Dashboard (user-switchable post-v0) |
| **FIELD** | bottom row + side margins, ~30 % of canvas height | N, responsive wrap | Smaller info widgets — weather, media, notifications, battery, system stats, pomodoro, notes, quick toggles, calendar |

Three anatomy rules:

1. **HERO holds exactly one widget.** Competing for focus defeats the zone.
   By surface convention: lock = clock; greeter = clock; Dashboard = clock by
   default, user-switchable post-v0.
2. **CROWN and FIELD wrap responsively** based on monitor width. On 1366×768
   the FIELD fits ~3 widgets; on 4K it fits 7+.
3. **The veil is dark by construction.** All widgets emit `light` (white)
   text. Glass-mode (which the bar honors) does not propagate to the canvas
   — the wallpaper-blur-and-dim veil reads dark even when the wallpaper is
   bright. This is intentional: widgets are legible without any per-widget
   adaptation logic.

Canvas safe margins: ~5 % on each screen edge so widgets don't kiss the
monitor border.

---

## 4. Widget catalog (the destination)

Thirteen widget definitions; Dashboard sees 12 of them (user-select is
lock/greeter-only).

| # | Widget | Surfaces | Default zone | Data source | Depends on |
|---|---|---|---|---|---|
| 1 | **clock** | Dashboard + Lock + Greeter | HERO (lock/greeter), CROWN (Dashboard) | Pure data (`date(1)`) | Nothing — v0 proof |
| 2 | **user-select** | Lock + Greeter only | HERO (greeter), CROWN (lock) | PAM + `/etc/passwd` enumeration | Lock/greeter PAM wiring (Wave 4 / Wave 5) |
| 3 | **date** | All three | CROWN | Pure data (`date(1)`) | Nothing |
| 4 | **calendar** (month grid) | Dashboard, optional on Lock | FIELD | Pure data | Nothing |
| 5 | **agenda** (next events) | Dashboard, optional on Lock | FIELD | New daemon `cal-source` (ICS / Google Calendar) | Calendar source plumbing |
| 6 | **weather** | Dashboard, optional on Lock | FIELD | New daemon `weather-fetch` (Open-Meteo) | Weather daemon |
| 7 | **media-player** | Dashboard, optional on Lock | FIELD | mpris-waybar cache (shared) | mpris-waybar rewrite (already on NEXT) |
| 8 | **notifications-list** | Dashboard, optional on Lock | FIELD | notif-daemon cache (shared) — new `notif-history` channel | notif-daemon extension |
| 9 | **quick-toggles** | Dashboard only | FIELD | Shared with bar pills (theme / DND / airplane / dictate / night-dimmer) | Existing pill caches |
| 10 | **battery-card** | Dashboard, optional on Lock | FIELD | `upower` (existing battery script extended) | Nothing |
| 11 | **system-stats** | Dashboard only | FIELD | NEXT system daemon (RTMIN+18) | System daemon (already on NEXT) |
| 12 | **pomodoro** | Dashboard only | FIELD | New daemon `pomodoro-state` (cache file + timer) | Pomodoro daemon |
| 13 | **notes** (scratchpad) | Dashboard only | FIELD | Local file (`~/.config/standardos/notes.md`) | Nothing |

Two notes:

- **"Optional on Lock" means user-customizable.** See §7. Default lock
  surface = clock + user-select only (privacy-respecting: a glance by a
  passing colleague sees a clock and a name, not your unread notifications,
  not your calendar). The user can loosen this consciously.
- **`quick-toggles` is the one place pills appear on the canvas.** They are
  not really widgets; they are a row of bar pills mirrored at canvas scale.
  Same caches, same classes, just bigger. Justification: making the existing
  pill grammar reachable from the canvas means the canvas is also a control
  surface, not only an info surface — without forcing the user to learn a
  second vocabulary for toggles.

The catalog is the **destination, not a contract.** If a widget proves
unimplementable or boring in practice, drop it during plan time and pick a
replacement. Spec defines intent; the list can drift by ~20 % without
re-specing.

---

## 5. Visual identity

Widgets share StandardOS's closed-budget palette but compose it differently
from pills.

### 5.1 Shared with pills

- Same 6 colors (blue / yellow / red / violet / green / orange).
- Same 2 surfaces (parent cool blue-violet, child warm brown-red) — but
  applied as larger card backgrounds, not small pills.
- Same 4 motions (pulse / glow / breathe / flash) applied to widget elements
  that signal health (battery-card breathes violet at 100 %, pulses orange
  under 10 %; pomodoro breathes during an active focus block).
- Same pin lifecycle — a widget signaling an event that wants persistent
  attention paints `opt-pin-violet | opt-pin-green | opt-pin-orange` until the
  user opens the canvas (the open *is* the acknowledgement).
- All widgets emit `light` (white) text. Glass-mode does not propagate to the
  canvas (the veil is always dark, §3).

### 5.2 Different from pills (richer compositions)

- **Cards, not pills.** A widget's outer container is a card: same surface
  colors, but ~12 px corner radius (vs. pills' 30 px), larger internal
  padding, room for multiple internal elements. Pills are chips; cards are
  panels.
- **Typography scale.** Pills use the bar font at ~11 pt. Widget cards use:
  - 11 pt — label / secondary text
  - 16 pt — primary / value text
  - 64–96 pt — HERO clock (the only place this scale appears)
- **Images allowed.** Avatars (user-select), cover art (media-player),
  weather glyphs, calendar dots. Pills are glyph-only by rule; cards lift the
  limit.
- **Canvas-level motion: fade-in on summon, fade-out on dismiss** — ~150 ms
  each direction, eased. The whole canvas animates, not per-widget.
  Widget-internal motion (pulse/glow/breathe on health signals) still applies
  normally.

### 5.3 Forbidden (philosophy guards)

- No new colors. No "accent" or "brand" color beyond the 6.
- No new motion verbs. No spinners, no swooshes, no parallax.
- No animation on context-driven appearance/disappearance of internal widget
  elements (Rule 4 — input acknowledged, context shifts silent — still holds).
- No hard borders. Card edge is surface-color difference, not an outline
  (same constraint as pills).
- No hover beat / no `opt-pushed` on widget cards themselves *by default*.
  Interactive widgets (calendar month navigation, configuration toggles
  in later waves) ARE clickable + focusable — the canvas window is
  `:focusable true` from Wave 1 onward. Hover/pushed states apply per
  widget where the widget's nature is interactive; non-interactive
  display widgets (clock, date, notes preview) stay calm.
  The `quick-toggles` row is the one exception — it's a strip of pills
  mirrored, so it carries the bar's full hover/pushed grammar.

---

## 6. Implementation architecture

Three surfaces × one widget catalog leads to a real question about how
widgets are *rendered* on each surface, because no single Wayland substrate
covers all three cleanly.

**Decision: share data and palette, not runtime.**

| Surface | Rendering engine | Why |
|---|---|---|
| **Dashboard** | **Eww** (gtk-layer-shell overlay) | Eww natively makes overlay-layer windows, supports rich GTK composition, has reactive bindings to commands and files. Best fit for the full widget vocabulary. |
| **Lock** | **hyprlock** with custom theming | Lock-screen on Wayland requires `ext-session-lock-v1`. Eww does not implement it. hyprlock does, and its `label` / `image` / `input-field` / `shape` primitives are enough to recreate every catalog widget visually. |
| **Greeter** | **regreet** with custom CSS | greetd's GTK-based greeter. Themable via CSS (same palette as Eww). Has user-select + password built in. |

A single unified runtime — a custom Wayland client speaking
`ext-session-lock-v1`, embedding Eww-like widgets, also functioning as a
greetd greeter — is a multi-month project before a single widget ships.
Sharing **data** (via the existing cache-file pattern) and sharing **palette
tokens** (one variables file imported by each engine) buys ~95 % of the
unified-feel benefit at ~10 % of the work.

### 6.1 Shared substrates

1. **Palette tokens** — `~/.config/standardos/palette.css` defines `@opt-yes`,
   `@opt-no`, `@opt-surface-parent`, etc. as CSS custom properties. Eww
   imports it directly. hyprlock conf references the same hex values (no CSS,
   but hex parity). regreet's CSS imports it. One source of truth for color.
2. **Cache files** — `/tmp/waybar-cache/<widget-data>`. New widgets that need
   a daemon (weather, agenda, pomodoro) write here using the same `pill.sh` /
   atomic-write pattern. Eww uses `defpoll` or `deflisten` to read them.
   hyprlock uses `label { exec = cat /tmp/waybar-cache/<file> ; update = N }`.
   Same data, three readers.
3. **Widget naming** — a widget called `weather` has files:
   `daemons/weather.sh` (writes cache), `eww/widgets/weather.yuck` (Eww
   render), `hyprlock/widgets/weather.conf.snippet` (hyprlock include). Each
   engine has its rendering recipe; data and name are shared.

### 6.2 File layout

```
/etc/nixos/home/
├── widgets/                       ← new package for the canvas system
│   ├── daemons/                   ← per-widget data daemons
│   │   ├── weather.sh
│   │   ├── agenda.sh
│   │   ├── pomodoro.sh
│   │   └── …
│   ├── eww/
│   │   ├── eww.yuck               ← Dashboard canvas root
│   │   ├── eww.scss               ← imports palette.css
│   │   └── widgets/*.yuck
│   ├── hyprlock/
│   │   ├── hyprlock.conf          ← Lock canvas root
│   │   └── widgets/*.conf.snippet
│   ├── regreet/
│   │   └── style.css              ← Greeter palette + layout
│   └── palette.css                ← shared color tokens
└── modules/
    ├── widgets-canvas.nix         ← installs eww, daemons, keybinds
    ├── widgets-lock.nix           ← installs hyprlock; gated on
    │                                services.standardos.lock.enable (default false)
    └── widgets-greeter.nix        ← installs regreet; gated on
                                     services.standardos.greeter.enable (default false)
```

Three Nix modules so each surface enables independently. A single-user FDE
host enables only `widgets-canvas`; a multi-user install enables all three.

### 6.3 Keybinds & triggers

- **Dashboard:** Hyprland `bind` on Super+RETURN (two dispatches on press: `exec eww open dashboard` + `submap canvas-open`). Inside the canvas-open submap, `bind` on Esc dispatches `exec eww close dashboard` + `submap reset`. See §2.1.
- **Lock:** `loginctl lock-session` → systemd unit runs hyprlock. Idle
  trigger via hypridle (off by default). Lid-close trigger via logind
  (off by default).
- **Greeter:** greetd's `default_session.command` swap (§2.3).

---

## 7. Lock screen customization

The Lock canvas is the one surface where the user picks which widgets appear.
Dashboard customization is post-v0 (graduates to the Settings surface,
todonow #1).

### 7.1 Config file (v0 mechanism)

`~/.config/standardos/lock-widgets.toml`:

```toml
# Default — ships with this:
crown = ["user-select", "date"]
hero  = "clock"
field = []                     # empty by default; user adds widgets here
```

### 7.2 Available pool

Widgets allowed on the Lock surface (the "optional on Lock" entries in §4):

```
calendar, agenda, weather, media-player,
notifications-list, battery-card
```

### 7.3 Forbidden on Lock

Privacy / security gates that the validator rejects:

- `quick-toggles` — toggling the system from a locked screen would be a
  bypass.
- `system-stats` — leaks fingerprintable info to bystanders.
- `pomodoro`, `notes` — display in-progress personal content while away.

### 7.4 Reload model

A file watcher (or simple "regenerate on lock-session start") rebuilds the
hyprlock `widgets/` include set when the TOML changes. No daemon restart, no
reboot — the next lock session uses the new layout.

### 7.5 Validation

The TOML is validated on load:

- Every name must be in the available pool.
- `hero` is exactly one widget (never zero, never two).
- `crown` length capped at 3, `field` at 7 (an authoring cap; the responsive
  layout may show fewer on narrow monitors, with overflow hidden
  gracefully).

Validation failures log to the journal and the lock screen falls back to the
**default** config — never refuses to open. A lock screen that refuses to
open = a locked-out user. Verification gate against silent broken lock.

### 7.6 Graduation path

- **Phase 1 (now):** manual TOML edit.
- **Phase 2:** a `lock-widgets` page on the future Settings surface
  (todonow #1) renders pool + selected set with drag-and-drop.
- **Phase 3:** the same Settings page extends to Dashboard customization
  (HERO + FIELD slots).

---

## 8. Wave plan (sketch)

The implementation plan (next document) will break this destination into
independently-shippable waves. Sketch:

### Wave 0 — substrate

- New Nix module `widgets-canvas.nix` + Eww package + `eww.yuck` canvas root
  drawing the three zones as colored placeholders.
- `palette.css` shared tokens.
- Hyprland keybinds: `bind` on Super+RETURN (two dispatches on press:
  `exec eww open dashboard` + `submap canvas-open`); inside the
  canvas-open submap, `bind` on Esc dispatches `exec eww close dashboard`
  + `submap reset`.
- One widget shipped: **clock** (HERO).
- Canvas fade-in / fade-out animation (~150 ms each direction) — deferred
  to Wave 1; Wave 0 ships without transitions.
- **Ships when:** pressing Super+RETURN shows a black-veiled canvas with a
  huge clock that persists; pressing Esc closes it. No other widgets, no
  lock, no greeter.

### Wave 1 — Dashboard core widgets (pure-data, no new daemons)

- `date`, `calendar`, `notes`.
- Each its own commit + TODO.md graduation entry.

### Wave 2 — Dashboard widgets dependent on existing caches

- `quick-toggles` (bar pill caches), `battery-card` (existing battery script),
  `media-player` (depends on mpris-waybar rewrite).

### Wave 3 — Dashboard widgets requiring new daemons

- `weather` (new daemon), `agenda` (new daemon), `pomodoro` (new daemon),
  `notifications-list` (notif-daemon extension), `system-stats` (depends on
  NEXT system daemon).

### Wave 4 — Lock screen

- `widgets-lock.nix` module (gated, default off).
- hyprlock + custom theming + palette mirroring.
- `lock-widgets.toml` config + validator.
- Re-implementation of `clock` and `user-select` in hyprlock primitives.
- Idle and lid-close triggers via hypridle / logind (both off by default).
- **Ships when:** `loginctl lock-session` brings up a hyprlock canvas with
  clock + user-select, password unlocks, and the user can opt-in additional
  widgets via TOML.

### Wave 5 — Greeter

- `widgets-greeter.nix` module (gated, default off).
- regreet + CSS palette mirroring.
- greetd config swap (autologin → regreet) controlled by Nix option.
- **Ships when:** disabling autologin and rebooting lands on a themed
  regreet showing clock + user-select + password.

Each wave is its own commit (or short series), its own TODO.md graduation,
its own verification. None blocks on the next; each is useful on its own.

**TODO.md cap reminder.** The work map is capped at 6. Waves 0–5 = 6
entries. If other work is in flight on TODO.md when Wave 0 starts, something
graduates or defers to NEXT first.

---

## 9. Deferred to plan time

Decisions not resolved in this spec; plan-writing picks them up.

1. **Multi-monitor behavior on Dashboard.** Primary monitor only, or one
   canvas per monitor? Lock and Greeter: every monitor (hyprlock / regreet
   default).
2. **What happens to the bar when the Dashboard summons.** Stays visible on
   top, or fades with the canvas? Probably stays — the bar is part of the
   StandardOS fabric, not the underlying session.
3. **Wallpaper-blur depth + dim opacity.** Visual-review tunable; defer to
   Wave 0.
4. **Canvas fade-in/out animation.** Wave 0 ships without transitions
   (snaps open and closed). Wave 1 can add ~150 ms fades; the cancel-mid-
   press concern from the original spec dissolves because the user opens
   once with Super+RETURN and closes once with Esc — there is no held
   chord to cancel mid-animation.
5. **PAM stack + gnome-keyring interaction.** How hyprlock + regreet talk to
   PAM, and how the empty-password keyring auto-unlock
   (`keyring-unlocked.nix`) coexists with session-time password input. Wave 4
   / Wave 5 work.
6. **Reduce-motion respect.** Canvas must honor `gtk-enable-animations:
   false`. Eww + GTK respects it by default; verify in Wave 0.
7. **The 12 widgets are a destination, not a contract.** Drop/swap up to
   ~20 % at plan time without re-specing.
8. **StandardOS vs OPTIONS naming in existing code.** This spec uses
   StandardOS; existing waybar README + CLAUDE.md still say OPTIONS. Not
   retroactively renaming — separate decision.

---

## 10. Verification (the spec is done when)

The spec is complete when these statements are all true:

- A future maintainer can read sections 1–7 and answer "what is a widget,
  where does it live, and how is it rendered on each surface" without
  needing this conversation's history.
- A plan-writer can read section 8 and produce a Wave-0 plan that lands a
  shippable canvas-with-clock without inventing decisions section 9 didn't
  defer.
- The catalog (§4) and the visual identity (§5) together let a designer mock
  up any of the 12 widgets without asking another design question (color,
  surface, motion).
- The architecture (§6) names file paths and engine choices specifically
  enough that nothing in the wave plan reads "TBD."

---

*Authored 2026-06-19, brainstormed with the user across nine sections, locked
on the destination. The implementation plan follows in
`docs/superpowers/plans/2026-06-19-widgets-canvas.md` (forthcoming).*
