# Widgets Canvas — Wave 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three Dashboard widgets ship — **date** (CROWN), **calendar** (FIELD), **notes preview** (FIELD) — and the canvas window pivots to `:focusable true` so future configuration widgets have a clicks-captured surface to work on.

**Architecture:** Eww remains the rendering substrate (waves 0). The dashboard window flips to `:focusable true`; mouse clicks are now captured by widgets instead of passing through to underlying apps, and keyboard focus moves to the canvas while it is open. The Hyprland `bind` for Esc continues to dispatch BEFORE the focused client receives the key, so Esc still dismisses the canvas regardless of focus state. Date and notes are pure-label / pure-read widgets; calendar is Eww's built-in `(calendar)` (interactive month navigation, styled via SCSS to match the canvas palette).

**Tech Stack:** Existing — NixOS + home-manager, Eww (GTK 3 + Yuck/SCSS), Hyprland. No new packages, no new daemons.

## Global Constraints

- Wave 1 ships exactly 3 widgets: `date`, `calendar`, `notes` (preview-only). Anything else from the 12-widget catalog (weather, media, agenda, etc.) is Wave 2+.
- Each widget is one commit. Plus one commit for the canvas focusable pivot (Task 1) and one commit for Wave 1 graduation (Task 4 absorbs the graduation step). Total: 4 commits.
- The canvas pivot is **architectural** — once `:focusable true` lands, clicks do not pass through. Future waves' configuration widgets depend on this. Do NOT re-flip to false unless explicitly directed.
- Use `StandardOS` in all prose / commit messages / docs (memory rule).
- Edits under `/etc/nixos/home/widgets/eww/*` are LIVE via `mkOutOfStoreSymlink`. Eww does NOT hot-reload yuck/scss changes; restart the user service to pick them up: `systemctl --user restart standardos-canvas.service`. NO `nixos-rebuild` required for yuck/scss iteration (only for Nix-module changes).
- Notes file path: `~/.config/standardos/notes.md`. If absent, the widget displays an empty-state message — never crashes the daemon.
- Verification: every "the widget works" claim is backed by a physical test — user presses Super+RETURN, sees the widget, presses Esc.
- Commits use existing repo style: lowercase scope prefix, short imperative summary, behavior-first language. Each task ends with one commit.

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `/etc/nixos/home/widgets/eww/eww.yuck` | Modify | Add date / calendar / notes widget defs; replace CROWN + FIELD placeholders; flip dashboard window `:focusable true`. |
| `/etc/nixos/home/widgets/eww/eww.scss` | Modify | Add per-widget styling (`.widget-date`, `.widget-calendar`, `.widget-notes`), restructure `.canvas-root` for horizontal FIELD flex. |
| `/etc/nixos/home/docs/superpowers/specs/2026-06-19-widgets-canvas-design.md` | Modify | Update §2 Interaction column (Dashboard row) to reflect interactive widgets; update §5.3 "user sitting with the dashboard" line to reflect the interactive model. |
| `/etc/nixos/home/waybar/TODO.md` | Modify | Wave 1 DONE entry with Hints for each widget and the pivot. |
| `/etc/nixos/home/waybar/todonow.md` | Modify | Item #7 updated to reflect Wave 1 shipped. |

---

## Task 1: Canvas pivots to `:focusable true` + spec sync

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (one line change: `:focusable false` → `:focusable true`)
- Modify: `/etc/nixos/home/docs/superpowers/specs/2026-06-19-widgets-canvas-design.md` (§2 table + §5.3 prose)

**Interfaces:**
- Consumes: Wave 0 substrate (commit `09a0183` and ancestors).
- Produces: an interactive canvas. Tasks 2/3/4 add widgets to this interactive surface. The change is architectural — once shipped, all future waves assume clicks captured.

- [ ] **Step 1: Edit eww.yuck — flip the dashboard window to focusable**

Find this block in `/etc/nixos/home/widgets/eww/eww.yuck`:

```yuck
(defwindow dashboard
  :monitor 0
  :geometry (geometry
              :x "0%"
              :y "0%"
              :width "100%"
              :height "100%"
              :anchor "center")
  :stacking "overlay"
  :exclusive false
  :focusable false
  (canvas))
```

Change `:focusable false` to `:focusable true`. Leave everything else in the block exactly as is. The result:

```yuck
(defwindow dashboard
  :monitor 0
  :geometry (geometry
              :x "0%"
              :y "0%"
              :width "100%"
              :height "100%"
              :anchor "center")
  :stacking "overlay"
  :exclusive false
  :focusable true
  (canvas))
```

- [ ] **Step 2: Update spec §2 — Dashboard interaction column**

In `/etc/nixos/home/docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`, find the §2 table row for Dashboard:

```
| **Dashboard** | User presses Super+Return | Until user presses Esc | Read-mostly during v0; clicks pass through to underlying windows (canvas window is non-focusable) | None (already in session) |
```

Replace with:

```
| **Dashboard** | User presses Super+Return | Until user presses Esc | Widgets are focusable + clickable from Wave 1 onward (the canvas window is `:focusable true`); clicks are captured by widgets, not passed through. Esc still dismisses via a Hyprland `bind` that intercepts before the focused widget. | None (already in session) |
```

- [ ] **Step 3: Update spec §5.3 — "user sitting with the dashboard" line**

Find this line in §5.3:

```
- No hover beat / no `opt-pushed` on widget cards themselves. Widgets are
  read-mostly; on Dashboard the user is sitting with the dashboard, not
  interacting.
```

Replace with:

```
- No hover beat / no `opt-pushed` on widget cards themselves *by default*.
  Interactive widgets (calendar month navigation, configuration toggles
  in later waves) ARE clickable + focusable — the canvas window is
  `:focusable true` from Wave 1 onward. Hover/pushed states apply per
  widget where the widget's nature is interactive; non-interactive
  display widgets (clock, date, notes preview) stay calm.
```

- [ ] **Step 4: Restart the canvas service to pick up the yuck change**

```bash
systemctl --user restart standardos-canvas.service
```

Expected: command returns 0; `systemctl --user status standardos-canvas.service` shows `active (running)` afterward.

- [ ] **Step 5: Physical-test the focusable pivot**

Press `Super+RETURN`. The canvas opens. While the canvas is open:

- Click anywhere on the veil. **Expected:** nothing happens — no underlying window gets focused, no click event leaks through. (Wave 0 would have transferred focus to an app behind the veil.)
- Press `Esc`. **Expected:** canvas closes immediately.

If clicks still pass through, the yuck change did not take effect — re-check the file, re-restart the service, and re-check `eww list-windows` shows `dashboard` as defined.

If Esc no longer closes, Hyprland's `bind` precedence is unexpectedly different on this version. Investigate `hyprctl binds | grep -A2 ESCAPE` to confirm the canvas-open submap bind is still registered.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck docs/superpowers/specs/2026-06-19-widgets-canvas-design.md
git commit -m "$(cat <<'EOF'
canvas: pivot to :focusable true — widgets are now interactive

Wave 1's architectural change. Dashboard window flips from focusable
false to focusable true; clicks no longer pass through to underlying
apps, keyboard focus moves to the canvas while open. Esc still dismisses
via the Hyprland canvas-open-submap bind (intercepted before the
focused widget receives the key).

Forward-looking decision — future waves' configuration widgets depend
on clicks being captured. Calendar (Wave 1 Task 3) is the first widget
to exercise the new interactivity (month navigation).

Spec §2 Dashboard interaction column + §5.3 visual-identity-Forbidden
line both updated to describe the interactive model.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git -C /etc/nixos/home status -s` empty.

---

## Task 2: Date widget in CROWN zone

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add `defpoll today`, add `(defwidget date-crown)`, replace `crown-placeholder` call with `date-crown`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.widget-date` class)

**Interfaces:**
- Consumes: Task 1 (focusable canvas — though date itself is non-interactive, the broader architecture is in place).
- Produces: a CROWN-zone date widget displaying "Friday, June 19" format. Tasks 3 + 4 add other widgets to FIELD; CROWN is owned by date until Wave 4 (when user-select joins for lock/greeter).

- [ ] **Step 1: Add the date poll + widget def to eww.yuck**

In `/etc/nixos/home/widgets/eww/eww.yuck`, locate the `defpoll time` block (near top, around line 8-12):

```yuck
(defpoll time
  :interval "1s"
  :initial "--:--"
  `date +'%H:%M'`)
```

Immediately after that block, add:

```yuck
;; Date data — polled every minute. Format matches "Friday, June 19".
;; %A = full weekday name, %B = full month name, %-d = day-of-month
;; without leading zero.
(defpoll today
  :interval "60s"
  :initial "—"
  `date +'%A, %B %-d'`)
```

Then locate the `(defwidget crown-placeholder [] ...)` block (around line 30-35):

```yuck
;; CROWN zone placeholder — will hold identity widgets (date, user-select)
;; in Wave 1 / Wave 4.
(defwidget crown-placeholder []
  (label
    :class "zone-placeholder"
    :text "CROWN"))
```

Replace it with the date widget def:

```yuck
;; CROWN: the date. Replaces the Wave 0 placeholder.
;; Matches "Friday, June 19" — full weekday + month + day.
(defwidget date-crown []
  (label
    :class "widget-date"
    :text today))
```

Then locate the canvas root's CROWN box (around line 50-55):

```yuck
    ;; CROWN — top, fixed height roughly 15% of the canvas.
    (box
      :orientation "horizontal"
      :halign "center"
      :valign "start"
      :vexpand false
      (crown-placeholder))
```

Replace the `(crown-placeholder)` call with `(date-crown)`:

```yuck
    ;; CROWN — top, fixed height roughly 15% of the canvas.
    (box
      :orientation "horizontal"
      :halign "center"
      :valign "start"
      :vexpand false
      (date-crown))
```

- [ ] **Step 2: Add date styling to eww.scss**

In `/etc/nixos/home/widgets/eww/eww.scss`, find the `.widget-clock-hero` block (around line 50):

```scss
.widget-clock-hero {
  color: @opt-text-on-dark;
  font-size: 96pt;
  font-weight: 200;
  letter-spacing: -2px;
}
```

Immediately after it, add:

```scss
/* CROWN date — full weekday + month + day; sits above the HERO clock. */
.widget-date {
  color: @opt-text-on-dark;
  font-size: 18pt;
  font-weight: 300;
  letter-spacing: 0.5px;
  opacity: 0.85;
}
```

- [ ] **Step 3: Restart the canvas service**

```bash
systemctl --user restart standardos-canvas.service
```

Expected: service is `active (running)` after the restart.

- [ ] **Step 4: Physical-test the date widget**

Press `Super+RETURN`.

**Expected:**
- The CROWN zone shows the current date in "Friday, June 19" format at ~18pt, white-ish, 85% opacity.
- The HERO clock is still in place below.
- The FIELD placeholder is still visible (will be replaced in Task 3 / Task 4).

Press `Esc`. Canvas closes.

If the date label shows `—` (the initial value): wait 60 seconds — the first poll has not yet fired. If it still shows `—`, run `date +'%A, %B %-d'` in a shell to confirm the command works (it should).

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck widgets/eww/eww.scss
git commit -m "$(cat <<'EOF'
widgets-canvas: date widget in CROWN — "Friday, June 19"

Replaces the Wave 0 CROWN placeholder with a real date widget. Polls
`date +'%A, %B %-d'` every 60 s (the format only changes at midnight).
18pt, 85% opacity, sits above the HERO clock. Pure label, no
interaction.

First catalog widget shipped from Wave 1's three (date / calendar /
notes). FIELD still placeholder; the next two tasks land there.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git status` clean.

---

## Task 3: Calendar widget in FIELD zone (restructures FIELD container)

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add `(defwidget calendar-card)`, restructure FIELD box to hold multiple widgets, drop `field-placeholder`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (style the calendar; restructure `.canvas-root` if needed)

**Interfaces:**
- Consumes: Tasks 1 + 2 (interactive canvas, CROWN holds date).
- Produces: a FIELD-zone calendar widget using Eww's built-in `(calendar)`. Restructures the FIELD container from a single-widget box to a horizontal flex container that Task 4 will append notes to.

- [ ] **Step 1: Add the calendar widget def to eww.yuck**

In `/etc/nixos/home/widgets/eww/eww.yuck`, locate the `(defwidget field-placeholder [] ...)` block (around line 38-43):

```yuck
;; FIELD zone placeholder — will hold smaller info widgets in Wave 1+.
(defwidget field-placeholder []
  (label
    :class "zone-placeholder"
    :text "FIELD"))
```

Replace it with the calendar widget def:

```yuck
;; FIELD: calendar card. Eww's built-in (calendar) is interactive — the
;; user can click ← / → to navigate months. Today is highlighted by GTK
;; default; SCSS styles the typography to match the canvas palette.
;; Props omitted intentionally — GTK defaults give us day names + heading
;; + no week numbers, which is what we want. If you need to tweak,
;; eww's accepted props (varies by version) are :day :month :year
;; :show-heading :show-day-names :show-week-numbers. Add them ONLY
;; after verifying the running eww version supports them with a quick
;; `eww logs` check after restart.
(defwidget calendar-card []
  (box
    :class "widget-calendar"
    :orientation "vertical"
    :halign "center"
    :valign "center"
    (calendar)))
```

Then locate the canvas root's FIELD box (around line 65-72):

```yuck
    ;; FIELD — bottom row, fixed height, will become a responsive wrap
    ;; container in Wave 1+.
    (box
      :orientation "horizontal"
      :halign "center"
      :valign "end"
      :vexpand false
      (field-placeholder))
```

Replace it with the multi-widget FIELD container that holds calendar today (notes joins in Task 4):

```yuck
    ;; FIELD — bottom row, horizontal flex of small info widgets.
    ;; Wave 1: calendar; Task 4 adds notes; future waves grow this row.
    (box
      :class "field-row"
      :orientation "horizontal"
      :halign "center"
      :valign "end"
      :space-evenly false
      :spacing 24
      :vexpand false
      (calendar-card))
```

- [ ] **Step 2: Add calendar styling to eww.scss**

In `/etc/nixos/home/widgets/eww/eww.scss`, after the `.widget-date` block, add:

```scss
/* FIELD container — horizontal flex of small widgets, breathing room
   between cards. */
.field-row {
  padding: 24px 0;
}

/* Calendar card outer container. */
.widget-calendar {
  background-color: @opt-surface-parent;
  border-radius: 12px;
  padding: 16px 20px;
}

/* GTK calendar typography — match canvas palette. The :selected
   pseudo applies to today and to the user's clicked day. */
.widget-calendar calendar {
  color: @opt-text-on-dark;
  font-size: 12pt;
  font-weight: 400;
}

.widget-calendar calendar:selected {
  background-color: @opt-blue-state;
  color: @opt-text-on-dark;
  border-radius: 4px;
}

.widget-calendar calendar.header {
  color: @opt-text-on-dark;
  font-size: 13pt;
  font-weight: 500;
  opacity: 0.95;
}
```

- [ ] **Step 3: Restart the canvas service**

```bash
systemctl --user restart standardos-canvas.service
```

Expected: `active (running)`. Check eww logs for parse errors:

```bash
journalctl --user -u standardos-canvas.service -n 20 --no-pager
```

If yuck parsed wrong, the service will be running but `eww list-windows` will show parse errors — investigate before continuing.

- [ ] **Step 4: Physical-test the calendar**

Press `Super+RETURN`.

**Expected:**
- CROWN: date label ("Friday, June 19") visible.
- HERO: 96pt clock.
- FIELD: a calendar card showing the current month, week-day headers (Mo Tu We Th Fr Sa Su), today's date highlighted.
- Clicking ← (previous month) navigates back; clicking → forward navigates forward.
- Clicking a specific day highlights it.

Press `Esc`. Canvas closes.

Verify the calendar background matches the parent-surface tone (slightly visible behind the day grid).

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck widgets/eww/eww.scss
git commit -m "$(cat <<'EOF'
widgets-canvas: calendar widget in FIELD — Eww built-in, styled to palette

Uses Eww's GTK calendar widget. User can navigate months with the
header arrows; today is highlighted. Styled via SCSS to read against
the dark canvas veil: parent-surface card background, white text, blue
state color for selected day.

First interactive widget — exercises the canvas's :focusable true
pivot from Task 1. Clicks on the calendar header buttons are captured
by the widget (not passed through), keyboard arrow navigation also
works.

FIELD container restructured from a single-widget box to a horizontal
flex (`.field-row`, 24px spacing, halign center). Task 4 appends notes
to the same row.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git status` clean.

---

## Task 4: Notes (read-only preview) + Wave 1 graduation

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add `defpoll notes-preview`, add `(defwidget notes-card)`, append `notes-card` to the FIELD row)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.widget-notes` class)
- Modify: `/etc/nixos/home/waybar/TODO.md` (Wave 1 DONE entry)
- Modify: `/etc/nixos/home/waybar/todonow.md` (item #7 reflects Wave 1 shipped)

**Interfaces:**
- Consumes: Tasks 1 + 2 + 3 (interactive canvas, date in CROWN, calendar in FIELD).
- Produces: Wave 1's third widget — a notes preview showing the last 8 lines of `~/.config/standardos/notes.md`. Read-only in Wave 1; future wave adds inline editing. Plus the work-map graduation.

- [ ] **Step 1: Add the notes poll + widget def to eww.yuck**

In `/etc/nixos/home/widgets/eww/eww.yuck`, immediately after the `defpoll today` block (added in Task 2), add:

```yuck
;; Notes preview — last 8 lines of the user's notes file. If the file
;; doesn't exist, the poll command exits non-zero and Eww's `:initial`
;; value is used (an empty-state hint).
(defpoll notes-preview
  :interval "5s"
  :initial "Notes file not yet created.\nWrite to ~/.config/standardos/notes.md"
  `tail -n 8 ~/.config/standardos/notes.md 2>/dev/null || echo 'Notes file not yet created.\nWrite to ~/.config/standardos/notes.md'`)
```

Then add the notes widget def, right after the `calendar-card` def (around the block added in Task 3):

```yuck
;; FIELD: notes card. Read-only preview of the last 8 lines of
;; ~/.config/standardos/notes.md. Editing happens out-of-band — open
;; the file in your editor of choice. A future wave adds inline
;; capture once the configuration-widget input pattern is established.
(defwidget notes-card []
  (box
    :class "widget-notes"
    :orientation "vertical"
    :halign "fill"
    :valign "center"
    (label
      :class "widget-notes-heading"
      :text "Notes")
    (label
      :class "widget-notes-body"
      :text notes-preview
      :wrap true
      :limit-width 40)))
```

Then update the FIELD container to include `notes-card`:

```yuck
    ;; FIELD — bottom row, horizontal flex of small info widgets.
    ;; Wave 1: calendar + notes. Future waves grow this row.
    (box
      :class "field-row"
      :orientation "horizontal"
      :halign "center"
      :valign "end"
      :space-evenly false
      :spacing 24
      :vexpand false
      (calendar-card)
      (notes-card))
```

- [ ] **Step 2: Add notes styling to eww.scss**

After the `.widget-calendar` blocks added in Task 3, append:

```scss
/* Notes card — read-only preview of last 8 lines. */
.widget-notes {
  background-color: @opt-surface-parent;
  border-radius: 12px;
  padding: 16px 20px;
  min-width: 280px;
  max-width: 360px;
}

.widget-notes-heading {
  color: @opt-text-on-dark;
  font-size: 11pt;
  font-weight: 500;
  letter-spacing: 1px;
  opacity: 0.6;
  margin-bottom: 8px;
}

.widget-notes-body {
  color: @opt-text-on-dark;
  font-size: 12pt;
  font-weight: 400;
  opacity: 0.85;
  font-family: "MesloLGS NF", monospace;
}
```

- [ ] **Step 3: Ensure the notes file exists (touch if absent)**

```bash
mkdir -p ~/.config/standardos
[ -f ~/.config/standardos/notes.md ] || cat > ~/.config/standardos/notes.md <<'EOF'
# Notes
EOF
```

Expected: directory + file exist. `cat ~/.config/standardos/notes.md` shows `# Notes` if the file was just created; otherwise unchanged.

- [ ] **Step 4: Restart the canvas service**

```bash
systemctl --user restart standardos-canvas.service
```

- [ ] **Step 5: Physical-test notes**

Press `Super+RETURN`.

**Expected:**
- CROWN: date label.
- HERO: clock.
- FIELD: calendar card on the left, notes card on the right (or both centered horizontally with 24 px between). Notes shows the heading "Notes" small + dim, and below it shows the contents of `~/.config/standardos/notes.md` (either `# Notes` if just created, or the last 8 lines if the user has been writing).
- Add a line to the notes file from a separate terminal: `echo "test note" >> ~/.config/standardos/notes.md`. Within 5 s the notes widget refreshes to show the new line (poll interval 5 s).
- Press `Esc`. Canvas closes.

If notes shows the initial-value text after the file exists: the `tail` command may have failed silently. Check the poll command's stdout: `tail -n 8 ~/.config/standardos/notes.md` should print content.

- [ ] **Step 6: Update waybar/TODO.md — Wave 1 DONE entry**

In `/etc/nixos/home/waybar/TODO.md`, at the top of the `## DONE` section (immediately after the `## DONE` header, before the existing Wave 0 entry from 2026-06-19), insert:

```markdown
- **2026-06-19** — **widgets-canvas Wave 1: date + calendar + notes; canvas
  pivots to :focusable true.** Three catalog widgets shipped to the
  Dashboard. Date (CROWN, "Friday, June 19", 18pt) replaces the Wave 0
  CROWN placeholder. Calendar (FIELD, Eww's built-in `(calendar)`,
  parent-surface card, blue selected-day) is the first interactive
  widget — exercises the canvas's new `:focusable true` setting.
  Notes (FIELD, read-only preview of last 8 lines from
  `~/.config/standardos/notes.md`) sits alongside calendar in a
  horizontal `.field-row` flex. Editing notes is out-of-band in Wave 1;
  inline capture deferred until the configuration-widget input pattern
  is established in a later wave.
  **Hint:** the canvas pivot is architectural — once `:focusable true`,
  clicks no longer pass through. Esc continues to dismiss via the
  Hyprland canvas-open-submap bind (intercepts before the focused
  widget). Spec §2 + §5.3 updated to match.
  **Hint:** notes file expected at `~/.config/standardos/notes.md`. If
  absent the widget shows an empty-state message. The directory is
  user-owned (not Nix-managed); the install ensures it exists by
  touching the file in Task 4 Step 3.
  **Hint:** calendar uses Eww's built-in widget — `(calendar :show-day-
  names true :show-week-numbers false :show-heading true)`. Styling
  hooks GTK pseudo-classes on the `calendar` element; see
  `.widget-calendar calendar:selected` for the today/selected highlight.
  **Hint:** spec at `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
  Wave 1 plan at `docs/superpowers/plans/2026-06-19-widgets-canvas-wave-1.md`.
  Wave 2 (existing-cache widgets — quick-toggles, battery, media-player)
  and Wave 3 (new-daemon widgets) are separate plans.
```

- [ ] **Step 7: Update waybar/todonow.md — item #7 reflects Wave 1 shipped**

In `/etc/nixos/home/waybar/todonow.md`, find item #7:

```markdown
7. **Widgets** — Wave 0 (substrate + clock) shipped 2026-06-19. Waves 1–3
   add the rest of the 12-widget Dashboard catalog. Spec:
   `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
```

Replace with:

```markdown
7. **Widgets** — Waves 0 + 1 shipped 2026-06-19 (substrate, clock, date,
   calendar, notes-preview). Waves 2–3 add the remaining Dashboard
   catalog widgets (quick-toggles, battery-card, media-player, weather,
   agenda, pomodoro, notifications-list, system-stats). Spec:
   `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
```

- [ ] **Step 8: Commit**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck widgets/eww/eww.scss waybar/TODO.md waybar/todonow.md
git commit -m "$(cat <<'EOF'
widgets-canvas: notes preview in FIELD + graduate Wave 1 to DONE

Wave 1's third widget — notes reads the last 8 lines from
~/.config/standardos/notes.md via a 5-second poll and renders them
read-only inside a parent-surface card. Missing file is handled
gracefully (initial value displays an empty-state hint). Editing the
notes file is out-of-band in Wave 1 — open the file in your editor of
choice; the canvas widget refreshes within 5 s.

Graduates Wave 1 to waybar/TODO.md DONE with four Hint lines:
architectural pivot to focusable, notes file location + empty-state
behavior, calendar built-in usage, and the spec/plan paths.
todonow.md item #7 updated.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git -C /etc/nixos/home status -s` empty.

---

## Wave 1 acceptance summary

Wave 1 is complete when ALL of these are true:

- [ ] `Super+RETURN` opens the canvas; CROWN shows "Friday, June 19" (current date), HERO shows the clock, FIELD shows calendar + notes side-by-side.
- [ ] Esc closes the canvas.
- [ ] Clicking the calendar's ← / → buttons navigates months.
- [ ] Clicking a day in the calendar highlights it (blue-state color).
- [ ] Clicking anywhere on the veil that is NOT a widget no longer passes through to the underlying app.
- [ ] Writing a new line to `~/.config/standardos/notes.md` updates the notes widget within 5 s.
- [ ] No regressions to: bar pills, launcher, window switcher, hardware keys, lock/sleep affordances.
- [ ] `waybar/TODO.md` has a Wave 1 DONE entry above the Wave 0 entry.
- [ ] `waybar/todonow.md` item #7 reflects "Waves 0 + 1 shipped".
- [ ] `git -C /etc/nixos/home status -s` returns empty (4 commits total).

What's left for Wave 2: quick-toggles row (interactive — first uses focusable for click-to-toggle), battery-card (existing battery script extended), media-player (mpris-waybar shared cache).

---

*Plan authored 2026-06-19, derived from the destination spec at
`docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`. Builds on
Wave 0's substrate (commits `e040d8d`..`09a0183`).*
