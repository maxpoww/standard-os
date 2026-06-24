# User Section design mockups

Browser-based mockups produced during the 2026-06-23 design session for the
control-center (canvas-as-control-center). The `.superpowers/brainstorm/`
working directory is gitignored, so the design we landed on is saved here as a
permanent reference.

## Files

- `2026-06-23-user-section-charts-v12.html` — the three User-section charts in
  isolation (Most Used Apps, Lifetime Usage, Weekly Usage). All three at the
  same compact height. Standout-row treatment (top app + Today row in violet).
  This is the baseline chart styling that v29 below inherits.

- `2026-06-23-user-section-v29-premium.html` — the final integrated mockup we
  approved on 2026-06-23. Layout: section-nav (15 sections — Max, Network and
  Internet, Connected devices, Programs, Notifications, Sound, Modes, Display,
  Style and wallpaper, Storage, Battery, System, About this computer, Security
  and privacy, Location) · USER LINE 4-col row (Profile + Account config |
  USER-MEGA centered | Focus + Privacy config | Pomodoro start/pause/stop) ·
  CHARTS 3-col equal-width row (Most Used Apps | Lifetime Usage | Weekly
  Usage) · BOTTOM 5-col equal-width row capped at 130px on the mockup, will
  flex-fill remaining canvas height in the live implementation (TODO |
  CALENDAR with scrollable months | EVENTS | NOTES | NOTIFICATION HISTORY).

  Premium visual treatment ("Liquid Glass" — variant A from the premium-v1
  comparison) applied with the standard OPTIONS palette: frosted glass
  surfaces with `backdrop-filter: blur(22px) saturate(140%)`, layered inset
  highlights + soft drop shadows, gradient text on name/KPI values, gradient
  pills/buttons, soft glow on the avatar / active pill / standout bar /
  pomodoro primary / calendar today. Glow opacities dialed back to ~50%
  vs the first pass per the final feedback.

## Opening the mockups

Open the HTML file directly in a browser:
```
xdg-open docs/mockups/2026-06-23-user-section-v29-premium.html
```

Or re-launch the visual-companion server to serve them interactively:
```
~/.claude/plugins/cache/claude-plugins-official/superpowers/6.0.3/skills/brainstorming/scripts/start-server.sh \
  --project-dir /etc/nixos/home --open
```
Then drop a copy of the mockup HTML into the new session's content directory
(printed by the server start command) so it's served as the newest screen.

## Open questions for the next session

- Port v29 to live canvas (eww `widgets/eww/eww.yuck` + `eww.scss`) — the
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
  Security+privacy, Location) — should reuse the v29 visual vocabulary
  but with section-appropriate widgets.
