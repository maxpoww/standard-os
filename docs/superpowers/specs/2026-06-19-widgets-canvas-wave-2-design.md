# Widgets canvas — Wave 2 design

A focused extension to the shared canvas design at
`docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`. This document
records the layout, frame language, motion verbs, and widget-catalog choices
that came out of the 2026-06-19 brainstorm and names the spec deltas the
implementation plan will apply to the shared design.

This is the design destination for Wave 2 of the canvas — the Dashboard
becomes a dense, single-glance information + control surface, in the spirit
of macOS's Today view crossed with iOS's Control Center, skinned with
StandardOS's bar grammar (translucent parent surfaces, 30 px pills + 12 px
cards, white text, motion verbs only).

This document does NOT replace `2026-06-19-widgets-canvas-design.md`; the
shared spec is still canonical for canvas-wide rules (surface convention,
keybinds, lock/greeter, palette tokens, wave boundaries). This document
extends and bends a few of those rules and names which ones explicitly.

---

## 1. Why Wave 2 looks different from the shared spec's sketch

The shared spec's §8 Wave 2 sketch reads:

> Wave 2 — Dashboard widgets dependent on existing caches:
> `quick-toggles` (bar pill caches), `battery-card` (existing battery
> script), `media-player` (depends on mpris-waybar rewrite).

That sketch presumed each widget would slot into the existing
CROWN / HERO / FIELD anatomy one at a time. Visual-review during the
brainstorm showed two things:

1. A canvas with only three new widgets sitting in the same vertical-box
   FIELD as Wave 1 reads empty — out of step with the "moment of pause"
   intent of the surface (shared spec §1).
2. The macOS-Today + iOS-Control-Center reference set the user keeps
   coming back to is a *dense* surface. Single glance answers
   "what's happening" and "what do I need to touch." A sparse three-widget
   addition does not.

So Wave 2 ships the canvas's destination shape, not an incremental
three-widget add. Most cells carry real data. A few cells ship as visual
scaffolds (placeholder content, real layout) because their data sources
graduate in Wave 3+ — see §6 below.

---

## 2. Canvas layout

The canvas now reads top-to-bottom as five horizontal bands. The shared
spec's CROWN / HERO / FIELD nouns survive but are reinterpreted; see §8 for
the spec deltas.

```
┌──────────────────────────────────────────────────────────────────────┐
│  1 2 3 4 5 6 7 8 9        FRI 19 JUN 22:14        ↓2.1M  52°C  UP…   │  menubar
├──────────────────────────────────────────────────────────────────────┤
│ [Wi-Fi…][Focus…][Dictate][BT][AirDrop][Night][Warm][Paper][News][○○] │  CROWN strip
├──────────────────────────────────────────────────────────────────────┤
│ ┌──────────────┐ ┌────────────────────┐ ┌──────────────┐             │
│ │ ☀  14°       │ │ ♪ Heroes Tonight   │ │ ⃝ ⃝ ⃝         │ vitals       │
│ │   MENDOZA    │ │ jemzi · NCS · 2014 │ │ ⃝ ⃝ ⃝         │ perf         │
│ │   Clear ↑18 ↓6│ │ ▮▮▮▮ 1:42 / 4:03 │ │              │ HERO TRIO    │
│ │ ──────────── │ │ ⏮ ⏸ ⏭             │ │              │              │
│ │ 22:14  FRI…  │ │                    │ │              │              │
│ └──────────────┘ └────────────────────┘ └──────────────┘             │
│  [Display──][Sound──][Mic──][Keyboard──][Night-dim──]                │  bars (5)
├──────────────────────────────────────────────────────────────────────┤
│ ┌────────┐ ┌────────┐ ┌────────────┐ ┌────────────┐                  │
│ │ JUNE   │ │ TODAY  │ │ # Notes    │ │ NOTIF · 4  │  FIELD row 1     │
│ │ heatmap│ │ agenda │ │ Bear-style │ │ list       │                  │
│ └────────┘ └────────┘ └────────────┘ └────────────┘                  │
│ ┌─────────────┐ ┌─────────────────┐ ┌────────┐                       │
│ │ NETWORK     │ │ SYSTEM · TEMPS  │ │ FOCUS  │  FIELD row 2          │
│ │ pill cluster│ │ pill cluster    │ │ pom 3/4│                       │
│ └─────────────┘ └─────────────────┘ └────────┘                       │
└──────────────────────────────────────────────────────────────────────┘
```

**Five bands top-to-bottom:** menubar (thin, decorative), CROWN strip
(controls + workspaces), HERO trio (clock+weather · media · rings),
bars (5 floating sliders), FIELD row 1 (info quartet), FIELD row 2
(system + focus).

The bars sit *tight* to the HERO bottom edge (~4 px gap) and *far* from
the FIELD top edge (~16 px gap). This visual coupling reads bars as part
of the HERO trio's control surface, not as a stand-alone middle strip.

The reference mockup of record lives at
`.superpowers/brainstorm/<session>/content/s-split-cards-weather-illust.html`
(gitignored — recreate on demand from this spec).

---

## 3. Frame language

Every HERO frame and every FIELD card uses the StandardOS palette's
**translucent grey parent surface** (`opt-surface-parent`,
`rgba(128,128,128,0.30)`). Child elements inside a frame may use
`opt-surface-child` (`rgba(170,170,170,0.30)`) — "parents naturally
uncolored, children carry the differentiation" (the project's Rule 2).

Two radii in play, per shared spec §5.2:

- **Pill radius (30 px)** for any rounded-capsule element: HERO frames
  (clock+weather, media, rings-stack cards), CROWN toggles, sliders,
  workspace dots, network/system info chips ("sys-pills"),
  agenda swap pills.
- **Card radius (12 px)** for square panels: calendar heatmap, agenda
  card, notes, notifications, FIELD row 2 wide cards, focus card.

The HERO trio is the visual focal piece because all three frames share
the same shape language (pill-radius). FIELD reads visually distinct
(card-radius) so the eye doesn't confuse the two zones.

State colors only as state — never as a surface accent:

- `opt-blue-state` marks "on" (Wi-Fi connected, Night dimmer active,
  current workspace, repeat-mode on).
- `opt-violet` marks events with persistent attention (notification pin
  dots, focus active, DND pill).
- `opt-green` marks healthy completion (build passed, calendar event
  completed, battery healthy ring fill).
- `opt-orange` marks incoming-soon (agenda's next-up item, warm-cycle
  pill).
- `opt-yellow-pin` marks daylight/sunlight (weather sun glow, weather
  illustration on warm conditions).
- `opt-red-state` marks critical (battery critical, build failed,
  storm/flash weather).

No new colors. No "accent" or "brand" color beyond those six and the
neutrals. Spec §5.3 forbidden list stays in force.

---

## 4. Widget catalog deltas (vs shared spec §4)

The shared spec's catalog of 13 widgets (12 Dashboard + 1 lock-only)
stays. Wave 2 adds three *visual* features that the catalog row doesn't
name:

| Feature | Belongs to | Detail |
|---|---|---|
| **Weather illustration set** | `weather` (#6) | 7 SVG illustrations (Clear · Partly cloudy · Cloudy · Rain · Snow · Storm · Clear night), picked by condition code from the weather data source. Sun pulses subtly (sun-pulse animation, see §5). Storm flashes the bolt. The temperature is the focal piece (44 pt), illustration sits to its left. |
| **Rings split** | `battery-card` (#10) + `system-stats` (#11) | The two rings widgets compose into one HERO frame: **vitals card** (`/` · `/home` · Battery) on top, **live perf card** (Wi-Fi · GPU · MEM) on bottom. Six rings total, drawn at 46 px with 7 px stroke, dark-card pattern from the macOS reference. Both frames use parent-surface, same pill-radius as the clock+weather frame. |
| **Clock+weather merge** | `clock` (#1) + `weather` (#6) | HERO left frame holds both. Vertical split: weather occupies the **top 2/3** (illustration + temp + city + lo/hi), clock occupies the **bottom 1/3** (32 pt mono digits + small date label, right of the digits). A thin rule divides them. The clock is no longer the canvas's largest element. |

The 5-bar control strip (Display · Sound · Mic · Keyboard · Night-dim)
is not a "widget" by §4's definition — it's a control surface, more
like quick-toggles. Lives in its own zone between HERO and FIELD.

---

## 5. Motion verbs in context

The shared spec §5.1 names four motion verbs: pulse / glow / breathe /
flash. Wave 2 binds them concretely:

| Verb | What animates | When |
|---|---|---|
| **breathe** (3.2 s loop, opacity 1 ↔ 0.78) | Battery ring · Pomodoro card | Battery: when % ≥ 100 and on AC (full + healthy). Pomodoro: while focus block is active. |
| **glow** (2.6 s loop, soft violet box-shadow) | Agenda card · Notification pill | Agenda: applied to the next-upcoming item (within ~30 min). Notification: applied to a new entry on first appearance, then settles. |
| **pulse** (1.6 s loop, scale 1 ↔ 1.06) | Critical pills only | Build-fail pin, battery-low pin (< 10 %), notif of high-urgency. Reserved for "you need to look now." |
| **flash** (one-shot, opacity 0.4 → 1 in 5 % of duration, then steady) | Storm illustration bolt · New notification glyph | Storm icon flashes the bolt; new notif's app dot flashes once on first paint. |

One additional verb is added scoped to weather: **sun-pulse** (4.5 s,
opacity 0.85 ↔ 1.0). Slow, calm. Visually distinct from the
spec-original four because it isn't a state signal — it's an
atmospheric texture on the canvas's only nature element. See §8.4 for
the proposed update to the shared spec to admit this verb.

---

## 6. Data sources & Wave 2 budget

Wave 2's promise is: the canvas reads as the destination on day one,
even where some daemons haven't shipped. Cells ship in one of two
states:

**Real data on day one (in Wave 2):**

- Clock (`date(1)`, defpoll 1 s)
- Date (`date(1)`, defpoll 60 s)
- Calendar heatmap (Eww built-in `(calendar)` + heatmap intensity from
  cal-source mock — see below)
- Notes (`tail -n 12 ~/.config/standardos/notes.md`, defpoll 5 s)
- Battery ring (`battery.sh`, existing waybar script, defpoll 15 s)
- `/` and `/home` rings (`df --output=pcent`, defpoll 30 s)
- Wi-Fi ring (`nmcli -t -f SIGNAL device wifi list`, defpoll 10 s)
- GPU ring (`nvidia-smi` / `radeontop` / `intel_gpu_top` chosen at
  install time per device, defpoll 5 s — best-effort, silent if absent)
- MEM ring (`/proc/meminfo`, defpoll 5 s)
- 5 sliders (`brightnessctl`, `wpctl`, `pamixer --source`,
  `brightnessctl -d *::kbd_backlight`, `night-dimmer` script — all
  read on user input; the slider value polls only when canvas is open)
- CROWN toggles (bar pill caches: `notif-dnd`, `dictate`,
  `night-dimmer`, `warm-cycle`, `shader-paper`, `shader-newspaper`;
  mirrors existing waybar `on-click` handlers)
- Workspaces strip (Hyprland IPC, deflisten)
- Menubar (datetime + sys-load + net throughput; reuses bar scripts)
- FIELD row 2 sys-pill clusters (NETWORK + SYSTEM·TEMPS; same scripts
  as menubar, denser)

**Visual scaffold, real data in Wave 3:**

- Weather illustration + temperature: scaffold ships with a static
  sun + "—°" placeholder. Wave 2 *may* add a thin defpoll on
  `curl -s 'wttr.in/Mendoza?format=...'` (no daemon) — decided at plan
  time. If yes, real weather lands in Wave 2; if no, Wave 3 ships the
  `weather-fetch` daemon and replaces the scaffold.
- Media-MEGA: scaffold ships with cover-gradient + "—" title. Wave 3
  resolves the mpris-waybar rewrite and wires real cover art /
  metadata / transport.
- Agenda card: scaffold ships with 0 events ("nothing today"). Wave 3
  ships the `cal-source` daemon (ICS / Google Cal).
- Notifications card: scaffold ships with empty state. Wave 3 ships
  the notif-daemon "history" channel.
- Pomodoro card: scaffold ships with idle state. Wave 3 ships the
  `pomodoro-state` daemon (cache file + timer).

The scaffold-vs-real split is a budget decision, not a layout one.
A scaffold card occupies the same slot and looks identical to its
data-backed sibling — the daemon's arrival is invisible to the user
beyond "the placeholder values are now real."

**Performance budget (canvas open).** Polls sum to ~9 read/sec across
all canvas widgets, all sub-millisecond shell-outs (see §9.12 for the
measured cap). Polls suspend when the canvas closes (Eww's `defpoll`
does not run while the window is hidden), so the canvas costs ~0 % CPU
in steady state.

---

## 7. Lock & greeter parity

This document is Dashboard-only. The shared spec §7 lock-widgets-toml
mechanism is untouched. Wave 4 / Wave 5 will pick from the Wave 2
catalog additions (weather illustration set, rings frames) for the lock
surface if the user opts in.

---

## 8. Spec deltas (apply to shared design spec at plan time)

The Wave 2 implementation plan will land these edits to
`docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`:

### 8.1 §3 anatomy — HERO singularity relaxed

The current text says "HERO holds exactly one widget. Competing for
focus defeats the zone." Update to:

> HERO holds the **focal composition** — one widget per surface, OR a
> single composite frame that groups closely related widgets (e.g.
> clock + weather; battery + storage + perf rings). On Dashboard, the
> HERO is a trio of frames; on Lock and Greeter, HERO is still a
> single widget (clock).

### 8.2 §3 anatomy — light/dark surface admitted

Add a short paragraph after the "veil is dark by construction"
clause:

> Frames are translucent grey (`opt-surface-parent`); text on frames
> is always white (`opt-text-on-dark`). Where the canvas borrows the
> macOS device-battery look — a near-black card holding a row of
> bright-stroke rings — that "dark card" is still
> `opt-surface-parent` rather than a new black surface; the macOS
> pattern is approximated by the high-contrast ring strokes against
> the translucent grey, not by a different background. No light cards
> (white surface with dark text) anywhere on the Dashboard.

### 8.3 §4 catalog — add the three Wave 2 visual features

Add a short subsection after §4's notes:

> **Visual variants ship in Wave 2.** Widget #6 (`weather`) carries an
> illustration set (7 SVG icons keyed by condition code). Widgets #10
> (`battery-card`) and #11 (`system-stats`) compose into a stacked
> rings frame in HERO right (vitals on top, live perf on bottom).
> Widget #1 (`clock`) and widget #6 (`weather`) merge into a single
> HERO-left frame (weather 2/3, clock 1/3, vertical split). The
> compositions are Dashboard-only; on Lock and Greeter each widget
> renders independently per §7's TOML.

### 8.4 §5.1 motion vocabulary — admit `sun-pulse`

Add a fifth verb scoped to the weather widget only:

> 5. **sun-pulse** — opacity 0.85 ↔ 1.0 over 4.5 s. Applied to the
>    weather widget's sun illustration only. Slow, calm — atmospheric
>    texture for the canvas's nature element, not a state signal.

### 8.5 §5.3 forbidden — light cards remain forbidden

Reaffirm: "No light cards (white surface, dark text) on the canvas.
The macOS-Today aesthetic is approximated through typography, density,
and frame language — not by switching surface color." This was a
moment of temptation during brainstorming and the decision is
documented here so future waves don't backslide.

---

## 9. Verification (Wave 2 is done when)

1. Pressing Super+RETURN summons the canvas as designed: menubar,
   CROWN, HERO trio, bars, FIELD rows 1 and 2 — all five bands
   present.
2. HERO left frame shows the weather illustration (sun by default,
   any of the 7 if the data source is wired) + temperature + city,
   with the 32 pt clock + date label in the bottom third.
3. HERO middle shows the media-MEGA frame (scaffold or real, per
   plan-time decision).
4. HERO right shows the two stacked ring frames; all six rings paint
   real data (vitals: `/`, `/home`, Battery — perf: Wi-Fi, GPU, MEM).
5. The 5-bar control strip is interactive: Display, Sound, Mic,
   Keyboard, Night-dim each move the underlying setting on drag.
6. Bars sit tight under HERO (~4 px gap); FIELD top edge sits ~16 px
   below the bars.
7. Bars do NOT have a card wrapper — they read as 5 floating pills.
8. Calendar heatmap, agenda card, notes Bear-style, and notifications
   card sit side-by-side in FIELD row 1, all using 12 px card radius.
9. FIELD row 2 carries the NETWORK sys-pill cluster, SYSTEM·TEMPS
   sys-pill cluster, and the focus/pomodoro card.
10. Pressing Esc dismisses the canvas. Workspaces, CROWN toggles, and
    the menubar workspaces strip all reflect Hyprland state in real
    time.
11. Battery ring breathes at 100 %. Pomodoro card breathes during
    focus. Agenda's next-upcoming item glows. Storm illustration (if
    weather condition matches) flashes its bolt. Sun illustration
    sun-pulses.
12. Performance: with the canvas open, total CPU overhead is < 2 %
    on the reference laptop (i5-1235U, 16 GB) measured via `top -p
    $(pgrep eww)`. Polls suspend when the canvas closes.

---

*Authored 2026-06-19, locked after a multi-iteration visual
brainstorm (sun illustration set, clock+weather merge, 6-ring split,
5-bar strip, dense FIELD). Implementation plan follows in
`docs/superpowers/plans/2026-06-19-widgets-canvas-wave-2.md`.*
