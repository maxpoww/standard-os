# todonow

The current priority slate — features picked from the 2026-06-19 UX-gap
analysis (the six things that turn Standard-OS from "compelling demo" into
"daily-driver for a normal person"). Work through these top-to-bottom.
Each item graduates to `TODO.md` when work starts and to its DONE section
when it ships.

This file is the short list. `TODO.md` is the active work map (capped at 6)
and the full history. `NEXT` in `TODO.md` still holds the longer backlog
(audio module, screenshot, brightness, mpris, rfkill, network/bluetooth/
system/clipboard daemons, control-panel row, per-window context surfacing).

---

1. **Settings surface** — the configurable-depth layer for things that can't
   reasonably become bar pills: hostname, timezone, locale, user account
   name + avatar + password, time format, default applications, startup
   apps, lid-close behavior, keyboard repeat, mouse acceleration,
   accessibility defaults, sleep / lock timers, additional users, drive
   encryption setup. Candidate substrate: rofi-grammar pages (categories →
   pill rows or text inputs in dmenu mode), bound to `$mainMod+,` (the Mac
   convention). Without this, Standard-OS is not installable by a normal
   user.

2. **Search-everything launcher** — today `apps-launcher` is
   `rofi -show drun` (apps only). Expand the "+" pill's surface to cover
   apps + files + settings entries + actions + inline calculator. Same
   pill, same anchor, broader modes. Single biggest first-impression gap
   for macOS / Windows switchers.

3. **Display / multi-monitor pill** — resolution, refresh rate, scale,
   mirror / extend, primary picker, "send focused window to other
   monitor." SYSTEM zone, value pill with a drawer of monitors. Plugging
   in HDMI / USB-C must surface *something* — today the user has no idea
   the second screen was detected. Pairs with hypr-context-daemon, which
   already publishes monitor info.

4. **Privacy indicators — screen-share, camera, mic** — three pills that
   surface silently (Rule 4) when their respective portal / device is in
   use, and a permanent "stop sharing" affordance while
   `xdg-desktop-portal` is sharing the screen. Pattern: opt-pushed +
   opt-breathe ambient for active capture; opt-pin-orange if the user
   should notice and act. `mic-monitor` cache already exists — wire its
   surfacing and add camera + screen-share peers. Non-negotiable for
   video calls and for the user trusting the OS.

5. **Themed login + lock screen** — Wave 4 + Wave 5 of the widgets-canvas
   plan series. Substrate shipped 2026-06-19 (Wave 0); Lock and Greeter
   are independent follow-ups. Spec:
   `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.

6. **Workspaces navigator** — richer workspaces surface beyond the
   current `ws-current` + `ws-1..9` button row. Design door is open;
   the user has the vision in head.

7. **Widgets** — Dashboard catalog progression:
   - Wave 0 (substrate + clock) — DONE 2026-06-19
   - Wave 1 (date · calendar · notes) — DONE 2026-06-19
   - Wave 2 (dense four-band canvas with real data) — DONE 2026-06-20
   - Wave 3 (new daemons: weather-fetch · cal-source · pomodoro-state ·
     notif-history channel · system-daemon RTMIN+18 · mpris-waybar truth) —
     SHIPPED 2026-06-20 (5/6; mpris-waybar truth blocks on the rewrite at
     `/home/max/mpris-waybar/` reaching a "publisher running by default"
     milestone — tracked in `TODO.md` NEXT under "Media player module (MPRIS)")

   Spec: `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
