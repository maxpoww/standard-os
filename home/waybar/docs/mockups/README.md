# User Section design mockups

Browser-based mockups produced during the 2026-06-23 / 2026-06-24 design
sessions for the control-center (canvas-as-control-center). The
`.superpowers/brainstorm/` working directory is gitignored, so the designs we
landed on are saved here as a permanent reference.

## Files

- `2026-06-23-user-section-charts-v12.html` — the three User-section charts in
  isolation (Most Used Apps, Lifetime Usage, Weekly Usage). All three at the
  same compact height. Standout-row treatment (top app + Today row in violet).
  This is the baseline chart styling that v31 below inherits.

- `2026-06-24-user-section-v31.html` — the integrated mockup approved on
  2026-06-24, replacing the 2026-06-23 v29 file. Same v28-derived premium
  "Liquid Glass" treatment, with the **user-config content reshaped** so
  every row in the USER section is genuinely user-specific and doesn't
  duplicate what another section pill owns:

  - **CONFIG** (left card, 10 rows): a single consolidated config card with
    two labelled sections — **PROFILE** (Display name · Password ·
    Fingerprint · Two-factor — credentials answer "how I prove I'm me")
    and **ACCOUNT** (Username · Default shell · Groups [editable — on a
    single-user OS the owner IS the admin] · Home directory · Last login ·
    Uptime — Unix-account facts that don't belong to any other section
    pill).
  - **USER-MEGA** (centered): avatar · Display name · `@max · STDOS` +
    blue **Sign out** link (no underline). No Lock or Switch-user buttons
    — those are workflow actions, not user-section concerns.
  - **CALENDAR** (right of MEGA): scrollable stack of prev / current /
    next month with auto-scroll to current on open. Today highlighted in
    violet; days with events tinted blue.
  - **EVENTS** (rightmost): today list + tomorrow list with HH:MM times.

  **Explicitly NOT in the USER section** (each owned by its dedicated section
  pill in the section-nav):
  - Security policy (auto-login, SSH access, lock-after-idle, lock-on-lid-
    close) + privacy config (clipboard history, app usage log, file search
    index) → **Security and privacy** section pill
  - Do Not Disturb → **Notifications** section pill
  - Locale (language, keyboard layout, time zone, date/number format,
    first day of week, units) → **Location** section pill
  - Notes-file location → owned by the Notes widget itself
  - Theme / wallpaper / accent → **Style and wallpaper** section pill
  - Display brightness / scaling → **Display** section pill

  Layout: section-nav (15 sections — Max · Network and Internet · Connected
  devices · Programs · Notifications · Sound · Modes · Display · Style and
  wallpaper · Storage · Battery · System · About this computer · Security
  and privacy · Location) · USER LINE 4-col row with USER-MEGA centered
  visually by mirrored column ratios — `1.7fr 0.9fr 1.0fr 0.7fr`: CONFIG
  (1.7) | USER-MEGA (0.9) | CALENDAR (1.0) | EVENTS (0.7), where CONFIG
  width equals CALENDAR+EVENTS width so the central mega card sits dead-
  centre on the canvas · CHARTS 3-col equal-width row (Most Used Apps |
  Lifetime Usage | Weekly Usage) · BOTTOM 4-col row (POMODORO with live
  state badge + PAUSE/SKIP/STOP + 4/8 blocks + Target/Work/Short/Long
  settings | TODO | NOTES | NOTIFICATION HISTORY). Bottom row capped at
  130px on the mockup; will flex-fill remaining canvas height in the live
  implementation.

  Premium visual treatment ("Liquid Glass" — variant A from the premium-v1
  comparison) applied with the standard OPTIONS palette: frosted glass
  surfaces with `backdrop-filter: blur(22px) saturate(140%)`, layered inset
  highlights + soft drop shadows, gradient text on name/KPI values, gradient
  pills/buttons, soft glow on the avatar / active pill / standout bar /
  pomodoro primary / calendar today. Avatar and primary-button glows trimmed
  ~30% vs the original v28 pass (per the 2026-06-24 dial-back); all other
  glows kept at v28 strength.

## Opening the mockups

Open the HTML file directly in a browser:
```
xdg-open docs/mockups/2026-06-24-user-section-v31.html
```

Or re-launch the visual-companion server to serve them interactively:
```
~/.claude/plugins/cache/claude-plugins-official/superpowers/6.0.3/skills/brainstorming/scripts/start-server.sh \
  --project-dir /etc/nixos/home --open
```
Then drop a copy of the mockup HTML into the new session's content directory
(printed by the server start command) so it's served as the newest screen.

## Open questions for the next session

- Port v31 to live canvas (eww `widgets/eww/eww.yuck` + `eww.scss`) — the
  layout grids, the glass styling, the standout treatment.
- Build the `usage-tracker.sh` daemon so the chart data (current session,
  weekly per-day, lifetime cumulative, focus-time per app) is real.
- Wire the 15 section nav pills to the canvas section-router so all 15
  sections route correctly.
- Build the calendar-month scrollable widget (3 months stacked + JS scroll-to-
  current on open) in eww — non-trivial because eww/GTK doesn't have a CSS
  `scroll-snap` equivalent the same way.
- Design the remaining 14 sections (Network, Devices, Programs, Notifs,
  Sound, Modes, Display, Style+wallpaper, Storage, Battery, System, About,
  Security+privacy, Location) — should reuse the v31 visual vocabulary
  but with section-appropriate widgets.
