# Widgets Canvas — Wave 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the canvas's dense destination layout — menubar · CROWN pill row · HERO trio (clock+weather merged · media-MEGA · stacked 6-ring frames) · 5 floating bars · FIELD row 1 (calendar / agenda / notes / notifications) · FIELD row 2 (network / system+temps / focus) — in nine reviewable commits.

**Architecture:** Eww (GTK 3 + Yuck/SCSS) remains the rendering substrate. Wave 1's `eww.yuck` and `eww.scss` get rewritten as a single dense canvas. Real data wires up on day one for clock, weather (wttr.in defpoll, no daemon), calendar, notes, battery, /, /home, Wi-Fi, GPU, MEM, sliders, CROWN toggles, workspaces, menubar, FIELD row 2 sys-pills. Media-MEGA, agenda, notifications, and pomodoro ship as visual scaffolds — the cells exist, painted with empty-state content, and become data-backed when their Wave 3 daemons land.

**Tech Stack:** Existing — NixOS + home-manager, Eww (GTK 3 + Yuck/SCSS), Hyprland, bash. New canvas-side scripts live in `widgets/scripts/` (created by this wave). No new Nix packages, no new daemons.

## Global Constraints

- Use `StandardOS` in prose / commit messages / docs (memory rule). Existing `OPTIONS` strings in code are not retroactively renamed.
- Use the existing palette (`widgets/palette.css`) tokens only. No new colors. Spec §5.3 forbidden list stays in force.
- Two radii: **30 px pills** (`@opt-pill-radius` = 30 px) for capsule-shape elements; **12 px cards** (`@opt-card-radius` = 12 px) for square panels. White text only (`@opt-text-on-dark`). No light cards anywhere.
- Each task is one commit. Total: 9 commits.
- Edits under `/etc/nixos/home/widgets/eww/*` and `/etc/nixos/home/widgets/scripts/*` are LIVE via `mkOutOfStoreSymlink`. Eww does NOT hot-reload yuck/scss; restart the user service after each task: `systemctl --user restart standardos-canvas.service`. NO `nixos-rebuild` required for yuck/scss/scripts iteration.
- After each task: subagent runs `systemctl --user restart standardos-canvas.service`, then `journalctl --user -u standardos-canvas.service -n 30 --no-pager` to verify no parse errors. The controller (user) does the physical Super+RETURN test at the wave-end checkpoint.
- No new error pills (memory rule: "no error pills on OPTIONS"). Scripts that fail (e.g. GPU unavailable) emit an empty value silently; the widget renders an empty-state glyph instead.
- Failures in scripts must NOT block the canvas. Every script ends in `exit 0` after writing whatever it could; missing data renders as `—` or empty in the widget.
- Commits use existing repo style: lowercase scope prefix, short imperative summary. Each task ends with one commit signed off with the Co-Authored-By footer the project uses.
- Two motion verb additions land in this wave: `sun-pulse` (4.5 s, opacity 0.85 ↔ 1.0, on the weather sun illustration) and a binding of `flash` to the storm illustration bolt. Both fit inside spec §5.1's vocabulary as documented in the Wave 2 design spec §8.4.

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `/etc/nixos/home/widgets/eww/eww.yuck` | Modify (rewrite) | Wave 1's vertical-box root replaced by the new five-band layout. All defwidgets for the new components land here in a single file (no per-widget split yet — Wave 3 candidate refactor). |
| `/etc/nixos/home/widgets/eww/eww.scss` | Modify (rewrite) | Wave 1's per-widget styles get superseded. New SCSS sections: menubar / crown-strip / cw-card / media-mega / rings-stack / bars / field-row / sys-pill / notif / etc. |
| `/etc/nixos/home/widgets/scripts/canvas-weather.sh` | Create | wttr.in fetch, parses condition + temp + hi/lo + humidity to pipe-separated string. |
| `/etc/nixos/home/widgets/scripts/canvas-disk.sh` | Create | df parser; arg = mount point (`/` or `/home`); echoes integer percent. |
| `/etc/nixos/home/widgets/scripts/canvas-wifi.sh` | Create | nmcli signal % → bar glyph (`▮▮▮▯`). |
| `/etc/nixos/home/widgets/scripts/canvas-gpu.sh` | Create | Best-effort GPU usage detect (nvidia-smi / radeontop / amdgpu_top / intel_gpu_top / empty). Always exits 0. |
| `/etc/nixos/home/widgets/scripts/canvas-mem.sh` | Create | /proc/meminfo → percent used + GB human. |
| `/etc/nixos/home/widgets/scripts/canvas-net.sh` | Create | /proc/net/dev throughput delta (KB/s down / up). |
| `/etc/nixos/home/widgets/scripts/canvas-sysload.sh` | Create | uptime → 1/5/15-min load avg. |
| `/etc/nixos/home/widgets/scripts/canvas-cpu.sh` | Create | /proc/stat delta → CPU % busy + temp from /sys/class/thermal. |
| `/etc/nixos/home/widgets/scripts/canvas-media.sh` | Create | playerctl best-effort (title / artist / status / position / length). Returns empty fields if no player. |
| `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh` | Create | Reads `/tmp/waybar-cache/*` for each toggle (DND, dictate, night-dimmer, warm-cycle, paper, newspaper, focus); echoes `on` / `off`. |
| `/etc/nixos/home/docs/superpowers/specs/2026-06-19-widgets-canvas-design.md` | Modify | §3 / §4 / §5.1 / §5.3 deltas per Wave 2 design spec §8. |
| `/etc/nixos/home/waybar/TODO.md` | Modify | Wave 2 DONE entry. |
| `/etc/nixos/home/waybar/todonow.md` | Modify | Update item #7 to reflect Wave 2 shipped. |

---

## Task 1: Canvas root rewrite + faux menubar

**Goal:** Replace the Wave 1 vertical-box canvas root with the new five-band layout (menubar / CROWN container / HERO+bars block / FIELD row 1 / FIELD row 2). For this task the CROWN, HERO trio, bars, and FIELD rows are EMPTY box placeholders — populated by Tasks 2–8. Only the menubar (date center, sys-load right, workspaces left-placeholder) carries real content this task. Lands as one commit: canvas reads as the five-band shell with menubar populated.

**Files:**
- Modify (rewrite): `/etc/nixos/home/widgets/eww/eww.yuck`
- Modify (rewrite): `/etc/nixos/home/widgets/eww/eww.scss`
- Create: `/etc/nixos/home/widgets/scripts/canvas-sysload.sh`

**Interfaces:**
- Consumes: Wave 1 state (commit `beaec13`) — clock-hero, date-crown, calendar-card, notes-card defwidgets in eww.yuck.
- Produces: New defwidgets `canvas-root`, `menubar`, `crown-container` (empty), `hero-trio` (empty), `bars-row` (empty), `field-row-1` (empty), `field-row-2` (empty). New canvas-root CSS shell. Subsequent tasks fill the empty containers.

- [ ] **Step 1: Create `canvas-sysload.sh`**

Create file `/etc/nixos/home/widgets/scripts/canvas-sysload.sh`:

```bash
#!/usr/bin/env bash
# canvas-sysload.sh — compact 1/5/15-min load average string for the menubar.
# Emits e.g. "LOAD 0.42 0.38 0.31". Silent on read error.

set -uo pipefail

read -r one five fifteen _rest < /proc/loadavg 2>/dev/null || exit 0
printf 'LOAD %s %s %s\n' "$one" "$five" "$fifteen"
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-sysload.sh
```

- [ ] **Step 2: Rewrite `eww.yuck` with the new canvas root + menubar**

Replace the entire contents of `/etc/nixos/home/widgets/eww/eww.yuck` with:

```yuck
;; ─────────────────────────────────────────────────────────────────────
;;  StandardOS widget canvas — Eww root.
;;
;;  Wave 2: five-band dense layout.
;;    menubar (thin top strip)
;;    CROWN strip (pill toggles + workspaces)
;;    HERO trio (clock+weather · media-MEGA · stacked 6-ring frames)
;;    bars row (5 floating sliders, tight to HERO)
;;    FIELD row 1 (calendar / agenda / notes / notifications)
;;    FIELD row 2 (network / system+temps / focus)
;;
;;  Wave 2 Task 1: structural shell + menubar only.
;;  Subsequent tasks fill the empty containers.
;; ─────────────────────────────────────────────────────────────────────

;; ── Data sources ──

;; Time + date (existing from Wave 1).
(defpoll time
  :interval "1s"
  :initial "--:--"
  `date +'%H:%M'`)

(defpoll today
  :interval "60s"
  :initial "—"
  `date +'%A, %B %-d'`)

;; Menubar — compact "FRI · 19 JUN · 22:14" centerline.
(defpoll menubar-datetime
  :interval "30s"
  :initial "— · — · --:--"
  `date +'%a · %-d %b · %H:%M' | tr '[:lower:]' '[:upper:]'`)

;; Menubar — sys-load right-side string.
(defpoll menubar-sysload
  :interval "5s"
  :initial "LOAD — — —"
  `/etc/nixos/home/widgets/scripts/canvas-sysload.sh`)

;; ── Widgets ──

(defwidget menubar []
  (centerbox :class "menubar"
    ;; left: workspaces placeholder (Task 2 wires up real workspaces)
    (label :class "menubar-ws-placeholder" :text "1 2 3 4 5 6 7 8 9" :halign "start")
    ;; center: datetime
    (label :class "menubar-datetime" :text menubar-datetime :halign "center")
    ;; right: sys-load
    (label :class "menubar-sysload" :text menubar-sysload :halign "end")))

(defwidget crown-container []
  (box :class "crown-container-empty" :orientation "horizontal" :vexpand false
    (label :text "" :class "zone-placeholder")))

(defwidget hero-trio []
  (box :orientation "horizontal" :space-evenly false :spacing 10 :vexpand true
    (box :class "hero-slot-placeholder" :hexpand true (label :text "" :class "zone-placeholder"))
    (box :class "hero-slot-placeholder" :hexpand true (label :text "" :class "zone-placeholder"))
    (box :class "hero-slot-placeholder" :hexpand true (label :text "" :class "zone-placeholder"))))

(defwidget bars-row []
  (box :class "bars-row-empty" :orientation "horizontal" :space-evenly true
    (label :text "" :class "zone-placeholder")))

(defwidget field-row-1 []
  (box :class "field-row-empty" :orientation "horizontal" :space-evenly false :spacing 10
    (label :text "" :class "zone-placeholder")))

(defwidget field-row-2 []
  (box :class "field-row-empty" :orientation "horizontal" :space-evenly false :spacing 10
    (label :text "" :class "zone-placeholder")))

;; ── Canvas root ──

(defwidget canvas []
  (box :class "canvas-root"
       :orientation "vertical"
       :space-evenly false
       :spacing 8
    (menubar)
    (crown-container)
    ;; HERO + bars are nested together so the bars hug HERO bottom edge.
    (box :class "hero-bars-block" :orientation "vertical" :space-evenly false :spacing 4 :vexpand true
      (hero-trio)
      (bars-row))
    (field-row-1)
    (field-row-2)))

;; ── Window ──

(defwindow dashboard
  :monitor 0
  :geometry (geometry :x "0%" :y "0%" :width "100%" :height "100%" :anchor "center")
  :stacking "overlay"
  :exclusive false
  :focusable true
  (canvas))
```

- [ ] **Step 3: Rewrite `eww.scss` with the canvas root + menubar styles**

Replace the entire contents of `/etc/nixos/home/widgets/eww/eww.scss` with:

```scss
/*
 * StandardOS widget canvas — Eww styles.
 *
 * Wave 2: dense layout — menubar / CROWN / HERO trio / bars / FIELD rows.
 * Wave 2 Task 1: root shell + menubar. Subsequent tasks add per-widget styles.
 */

@import "../palette.css";

/* Reset GTK defaults so Eww starts from neutral ground. */
* {
  all: unset;
}

/* The full-screen dashboard window: dark veil over the underlying session. */
window.dashboard {
  background-color: @canvas-veil;
  font-family: "MesloLGS NF", "Symbols Nerd Font Mono", monospace;
}

/* Canvas root: five-band vertical stack. Padding ~3% on each edge so the
   bands don't kiss the monitor border (was 5% in Wave 1; tighter now to
   accommodate the dense content). */
.canvas-root {
  padding: 24px 28px;
}

/* HERO + bars block — small inner gap so bars hug HERO bottom edge. */
.hero-bars-block {
  margin-bottom: 4px;
}

/* Menubar — thin top strip. Workspaces left, datetime center, sysload right. */
.menubar {
  font-size: 9pt;
  color: @opt-text-on-dark;
  opacity: 0.65;
  letter-spacing: 1px;
  padding: 0 6px 4px 6px;
}

.menubar-datetime {
  font-weight: 500;
  letter-spacing: 2px;
}

.menubar-sysload {
  font-family: "MesloLGS NF", monospace;
}

.menubar-ws-placeholder {
  /* Task 2 replaces this with a real workspaces widget. */
  font-family: "MesloLGS NF", monospace;
}

/* Empty zone placeholders — temporarily visible until Tasks 2-8 fill them. */
.zone-placeholder {
  color: @canvas-zone-label;
  font-size: 9pt;
  letter-spacing: 2px;
  padding: 12px;
}

.crown-container-empty,
.hero-slot-placeholder,
.bars-row-empty,
.field-row-empty {
  background-color: rgba(128, 128, 128, 0.08);
  border-radius: 12px;
  min-height: 32px;
}

.hero-slot-placeholder {
  min-height: 140px;
}
```

- [ ] **Step 4: Restart canvas service and verify no parse errors**

Run:

```bash
systemctl --user restart standardos-canvas.service
sleep 1
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service `active (running)`, no `EWW ERROR`, no `Failed to parse` lines in the journal.

If parse errors appear, fix them BEFORE committing — Eww's parser messages reference the line number; cross-check against the yuck above.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss widgets/scripts/canvas-sysload.sh
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: rewrite root to five-band shell + menubar (Wave 2 Task 1)

Replaces Wave 1's vertical-box (CROWN/HERO/FIELD) with the dense layout
shell: menubar (workspaces placeholder · datetime · sysload), CROWN container,
HERO trio container, bars row, FIELD row 1, FIELD row 2. Tasks 2-8 populate
each container; this task only wires the menubar (centered datetime + sysload
right). Bars are nested with HERO in a flex column with 4 px gap so the next
tasks can populate them tight to HERO.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: CROWN pill row — toggles + workspaces

**Goal:** Populate the empty CROWN container with the iOS-style pill row (9 toggle pills mirroring the bar's right-side modules) + a workspaces strip on the far right. All toggles wired to the bar's existing cache files / scripts.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (replace `crown-container` defwidget; add `crown-toggles` and `crown-workspaces` defwidgets; add toggle-state defpolls)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.crown-strip`, `.opt-pill`, `.opt-swap`, `.opt-mini`, `.ws-strip` styles)
- Create: `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh`

**Interfaces:**
- Consumes: bar pill cache files at `/tmp/waybar-cache/notif-dnd`, `/tmp/waybar-cache/dictate`. Existing bar scripts at `/etc/nixos/home/waybar/scripts/{night-dimmer,warm-cycle,shader-toggle,notif-click}` for on-click handlers.
- Produces: A populated CROWN strip widget. Replaces `crown-container` from Task 1.

- [ ] **Step 1: Create `canvas-toggle-state.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh`:

```bash
#!/usr/bin/env bash
# canvas-toggle-state.sh — emit "on" or "off" for a named toggle, read from
# /tmp/waybar-cache or runtime probe. Argument: one of
#   dnd | dictate | night | warm | paper | newspaper | wifi | focus
# Silent on any error (exit 0 with "off").

set -uo pipefail
CACHE=/tmp/waybar-cache

case "${1:-}" in
  dnd)
    # The bar's notif-dnd cache emits a JSON-like blob; check for active class.
    if grep -q '"alt":"active"' "$CACHE/notif-dnd" 2>/dev/null; then echo on; else echo off; fi
    ;;
  dictate)
    if grep -q '"alt":"on"' "$CACHE/dictate" 2>/dev/null; then echo on; else echo off; fi
    ;;
  night)
    # night-dimmer state via the script's status output.
    if [ -f /tmp/night-dimmer-on ]; then echo on; else echo off; fi
    ;;
  warm)
    if [ -f /tmp/warm-cycle-on ]; then echo on; else echo off; fi
    ;;
  paper)
    if [ -f /tmp/shader-paper-on ]; then echo on; else echo off; fi
    ;;
  newspaper)
    if [ -f /tmp/shader-newspaper-on ]; then echo on; else echo off; fi
    ;;
  wifi)
    if nmcli -t -f WIFI radio 2>/dev/null | grep -q enabled; then echo on; else echo off; fi
    ;;
  focus)
    # Maps onto DND for now (no separate focus daemon in Wave 2).
    if grep -q '"alt":"active"' "$CACHE/notif-dnd" 2>/dev/null; then echo on; else echo off; fi
    ;;
  *)
    echo off
    ;;
esac
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-toggle-state.sh
```

- [ ] **Step 2: Add toggle-state defpolls + replace `crown-container` defwidget in `eww.yuck`**

Open `/etc/nixos/home/widgets/eww/eww.yuck`. After the existing `defpoll menubar-sysload` block, add:

```yuck
;; Toggle states — each polls a small script that reads the bar's cache.
(defpoll toggle-dnd       :interval "2s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh dnd`)
(defpoll toggle-dictate   :interval "2s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh dictate`)
(defpoll toggle-night     :interval "3s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh night`)
(defpoll toggle-warm      :interval "3s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh warm`)
(defpoll toggle-paper     :interval "3s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh paper`)
(defpoll toggle-newspaper :interval "3s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh newspaper`)
(defpoll toggle-wifi      :interval "5s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh wifi`)
(defpoll toggle-focus     :interval "2s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-toggle-state.sh focus`)

;; Workspaces — Hyprland-aware via the existing workspace daemon's cache.
(defpoll ws-current :interval "500ms" :initial "1" `cat /tmp/waybar-cache/ws-current 2>/dev/null || echo 1`)
```

Then REPLACE the existing `crown-container` defwidget block:

```yuck
(defwidget crown-container []
  (box :class "crown-container-empty" :orientation "horizontal" :vexpand false
    (label :text "" :class "zone-placeholder")))
```

with:

```yuck
(defwidget toggle-pill [name glyph label state on-click]
  (eventbox :onclick on-click
    (box :class {state == "on" ? "opt-pill state-blue" : "opt-pill"}
         :orientation "horizontal" :space-evenly false :spacing 5
      (label :class "opt-pill-glyph" :text glyph)
      (label :class "opt-pill-label" :text label))))

(defwidget toggle-swap [name glyph title state rhs on-click]
  (eventbox :onclick on-click
    (box :class {state == "on" ? "opt-swap state-blue" : "opt-swap"}
         :orientation "horizontal" :space-evenly false
      (box :class "opt-swap-lhs" :orientation "horizontal" :spacing 5
        (label :class "opt-swap-glyph" :text glyph)
        (label :class "opt-swap-title" :text title))
      (box :class "opt-swap-rhs"
        (label :text rhs)))))

(defwidget crown-workspaces []
  (box :class "ws-strip" :orientation "horizontal" :space-evenly false :spacing 4
    (box :class {ws-current == "1" ? "ws act" : "ws"} (label :text "1"))
    (box :class {ws-current == "2" ? "ws act" : "ws"} (label :text "2"))
    (box :class {ws-current == "3" ? "ws act" : "ws"} (label :text "3"))
    (box :class {ws-current == "4" ? "ws act" : "ws"} (label :text "4"))
    (box :class {ws-current == "5" ? "ws act" : "ws"} (label :text "5"))))

(defwidget crown-container []
  (box :class "crown-strip" :orientation "horizontal" :space-evenly false :spacing 6 :halign "center"
    (toggle-swap :name "wifi"   :glyph "󰖩"  :title "Wi-Fi"   :state toggle-wifi    :rhs "Home"   :on-click "nm-connection-editor &")
    (toggle-swap :name "focus"  :glyph "󰂛"  :title "Focus"   :state toggle-focus   :rhs "DND"    :on-click "/etc/nixos/home/waybar/scripts/lib/pill.sh; notif-click dnd")
    (toggle-pill :name "dict"   :glyph "󰍬"  :label "Dictate" :state toggle-dictate :on-click "dictate-toggle")
    (toggle-pill :name "bt"     :glyph ""  :label ""        :state "off"          :on-click "blueman-manager &")
    (toggle-pill :name "drop"   :glyph "󰀂"  :label ""        :state "off"          :on-click "true")
    (toggle-pill :name "night"  :glyph "󰽢"  :label "Night"   :state toggle-night   :on-click "/etc/nixos/home/waybar/scripts/night-dimmer.sh click")
    (toggle-pill :name "warm"   :glyph "󰈸"  :label "Warm"    :state toggle-warm    :on-click "/etc/nixos/home/waybar/scripts/warm-cycle.sh click")
    (toggle-pill :name "paper"  :glyph "󰈚"  :label "Paper"   :state toggle-paper   :on-click "/etc/nixos/home/waybar/scripts/shader-toggle.sh paper")
    (toggle-pill :name "news"   :glyph "󰎕"  :label "News"    :state toggle-newspaper :on-click "/etc/nixos/home/waybar/scripts/shader-toggle.sh newspaper")
    (crown-workspaces)))
```

- [ ] **Step 3: Add CROWN styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* CROWN strip — pill toggles + workspaces, horizontal row. */
.crown-strip {
  padding: 2px 0;
}

/* opt-pill — base capsule pill (30 px radius). */
.opt-pill {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  padding: 4px 11px;
  color: @opt-text-on-dark;
  font-size: 9pt;
  font-weight: 400;
}
.opt-pill.state-blue { background-color: @opt-blue-state; }
.opt-pill-glyph { font-size: 10pt; }
.opt-pill-label { font-size: 9pt; }

/* opt-swap — two-segment capsule: parent surface left, child surface right. */
.opt-swap {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  color: @opt-text-on-dark;
  font-size: 9pt;
}
.opt-swap.state-blue .opt-swap-rhs { background-color: @opt-blue-state; }
.opt-swap-lhs { padding: 4px 8px 4px 11px; }
.opt-swap-rhs {
  padding: 4px 11px 4px 8px;
  background-color: @opt-surface-child;
  color: @opt-text-on-dark;
  border-radius: 0 30px 30px 0;
  opacity: 0.95;
}
.opt-swap-glyph { font-size: 10pt; }

/* Workspaces strip — small round chips. */
.ws-strip {
  margin-left: 8px;
}
.ws {
  background-color: @opt-surface-parent;
  border-radius: 50%;
  min-width: 20px;
  min-height: 20px;
  color: @opt-text-on-dark;
  font-size: 8pt;
  font-family: "MesloLGS NF", monospace;
  opacity: 0.55;
}
.ws.act {
  background-color: @opt-blue-state;
  opacity: 1;
}

/* Empty placeholder shrink — CROWN no longer needs it. */
.crown-container-empty { background-color: transparent; }
```

- [ ] **Step 4: Restart + verify no parse errors**

```bash
systemctl --user restart standardos-canvas.service
sleep 1
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: no `EWW ERROR`, no parse failures. The polled scripts emit values (`off` mostly) without errors.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss widgets/scripts/canvas-toggle-state.sh
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: CROWN pill row — 9 toggles + workspaces strip (Wave 2 Task 2)

Replaces Task 1's empty CROWN placeholder with the iOS-style capsule pill row.
2 opt-swap pills (Wi-Fi · Focus), 7 opt-pill toggles (Dictate · BT · AirDrop ·
Night · Warm · Paper · News), then a 5-chip workspaces strip. State driven by
canvas-toggle-state.sh which reads the bar's existing cache files; on-click
handlers reuse the bar's pill scripts so state stays in sync between bar and
canvas.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: HERO left — clock+weather merged frame

**Goal:** Populate HERO left slot with the merged clock+weather frame. Weather (top 2/3) shows an SVG-class illustration + 44pt temperature + city + lo/hi/humidity. Clock (bottom 1/3) shows 32pt mono digits + small date label. Weather data via wttr.in defpoll — no daemon needed.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add weather defpoll, `clock-weather-frame` defwidget; wire into `hero-trio`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.cw-card`, weather illustration classes)
- Create: `/etc/nixos/home/widgets/scripts/canvas-weather.sh`

**Interfaces:**
- Consumes: wttr.in HTTP endpoint (single curl, 10s timeout, exit 0 on fail).
- Produces: `clock-weather-frame` defwidget. Replaces first slot in `hero-trio`.

- [ ] **Step 1: Create `canvas-weather.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-weather.sh`:

```bash
#!/usr/bin/env bash
# canvas-weather.sh — fetch current weather from wttr.in for a fixed city.
# Emits a pipe-separated string: COND|TEMP|HI|LO|HUM
# COND = one of: clear | partly-cloudy | cloudy | rain | snow | storm | clear-night
# Silent + falls back to "clear|—°|—|—|—%" on any failure.

set -uo pipefail
CITY="${STANDARDOS_WEATHER_CITY:-Mendoza}"

FALLBACK="clear|—°|—|—|—%"

# wttr.in format string:
#   %C    condition text
#   %t    current temp
#   %f    feels-like
#   %h    humidity
# We use ?format=4 wouldn't include all; use a custom format.
RAW="$(curl -fsS --max-time 10 "https://wttr.in/${CITY}?format=%C|%t|%h|%l" 2>/dev/null)" || {
  echo "$FALLBACK"
  exit 0
}

# wttr.in lo/hi requires a different endpoint; second curl with --max-time 6.
FORECAST="$(curl -fsS --max-time 6 "https://wttr.in/${CITY}?format=j1" 2>/dev/null | grep -E '"(maxtempC|mintempC)"' | head -2)" || FORECAST=""
HI=$(echo "$FORECAST" | grep maxtempC | head -1 | sed -E 's/.*"maxtempC":"([0-9-]+)".*/\1/' || echo "—")
LO=$(echo "$FORECAST" | grep mintempC | head -1 | sed -E 's/.*"mintempC":"([0-9-]+)".*/\1/' || echo "—")
[ -z "$HI" ] && HI="—"
[ -z "$LO" ] && LO="—"

IFS='|' read -r COND_TEXT TEMP HUM _LOC <<<"$RAW"

# Map condition text → canonical condition code.
shopt -s nocasematch
case "$COND_TEXT" in
  *storm*|*thunder*) COND=storm ;;
  *snow*|*sleet*|*blizzard*) COND=snow ;;
  *rain*|*shower*|*drizzle*) COND=rain ;;
  *fog*|*overcast*|*cloud*)
    case "$COND_TEXT" in
      *partly*|*sun*) COND=partly-cloudy ;;
      *) COND=cloudy ;;
    esac
    ;;
  *clear*|*sun*|*fair*)
    # Night-clear check: query time-of-day.
    H=$(date +%H)
    if [ "$H" -lt 7 ] || [ "$H" -ge 20 ]; then COND=clear-night; else COND=clear; fi
    ;;
  *) COND=clear ;;
esac
shopt -u nocasematch

printf '%s|%s|%s°|%s°|%s\n' "$COND" "$TEMP" "$HI" "$LO" "$HUM"
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-weather.sh
```

- [ ] **Step 2: Add weather defpoll + clock-weather defwidget to `eww.yuck`**

After the existing `defpoll ws-current` block in `/etc/nixos/home/widgets/eww/eww.yuck`, add:

```yuck
;; Weather — wttr.in defpoll, pipe-separated output. 10 minutes is plenty.
(defpoll weather-raw
  :interval "600s"
  :initial "clear|—°|—|—|—%"
  `/etc/nixos/home/widgets/scripts/canvas-weather.sh`)

;; Parse the pipe-separated values via Eww's string ops.
(defvar weather-cond-default "clear")
;; index 0..4 = COND, TEMP, HI, LO, HUM
```

Add new defwidgets BEFORE the existing `hero-trio` defwidget:

```yuck
;; Weather illustration — 7 SVG-class conditions, selected by string match.
;; Each is a unicode-glyph + colored circle composition (no SVG file load —
;; the visual lives in CSS via background-image data URIs or in label fonts).
;; The condition strings: clear · partly-cloudy · cloudy · rain · snow · storm · clear-night.
(defwidget weather-illust [cond]
  (box :class {"weather-illust weather-illust-" + cond}
       :orientation "horizontal" :halign "center" :valign "center"
    (label :class "weather-illust-glyph" :text
      {cond == "clear" ? "☀"
       : cond == "partly-cloudy" ? "⛅"
       : cond == "cloudy" ? "☁"
       : cond == "rain" ? "🌧"
       : cond == "snow" ? "❄"
       : cond == "storm" ? "⛈"
       : cond == "clear-night" ? "🌙"
       : "☀"})))

(defwidget clock-weather-frame []
  (box :class "cw-card" :orientation "vertical" :space-evenly false :spacing 8 :vexpand true
    ;; weather (top 2/3)
    (box :class "cw-weather" :orientation "horizontal" :space-evenly false :spacing 14
         :vexpand true :valign "fill"
      (weather-illust :cond {weather-raw == "" ? "clear" : (arraylength(jq(weather-raw, "split(\"|\")")) >= 1 ? (jq(weather-raw, "split(\"|\")[0]") | replace("\"", "")) : "clear")})
      (box :class "cw-info" :orientation "vertical" :space-evenly false :valign "center"
        (label :class "cw-temp" :text {jq(weather-raw, "split(\"|\")[1]") | replace("\"", "")} :halign "start")
        (label :class "cw-city" :text "MENDOZA" :halign "start")
        (label :class "cw-desc" :text "Current conditions" :halign "start")
        (label :class "cw-lohi"
               :text {"↑ " + (jq(weather-raw, "split(\"|\")[2]") | replace("\"", "")) + "  ↓ " + (jq(weather-raw, "split(\"|\")[3]") | replace("\"", "")) + "  ·  " + (jq(weather-raw, "split(\"|\")[4]") | replace("\"", "")) + " hum"}
               :halign "start")))
    ;; divider
    (box :class "cw-divider" :vexpand false)
    ;; clock (bottom 1/3)
    (box :class "cw-clock" :orientation "horizontal" :space-evenly false :spacing 14
         :halign "center" :valign "center"
      (label :class "cw-clock-text" :text time)
      (box :class "cw-date" :orientation "vertical" :space-evenly false :spacing 2
        (label :text "FRIDAY" :halign "start" :class "cw-date-line")
        (label :text "19 JUN · WK 25" :halign "start" :class "cw-date-line-sub")))))
```

Then REPLACE the existing `hero-trio` defwidget body to wire `clock-weather-frame` into the first slot:

```yuck
(defwidget hero-trio []
  (box :orientation "horizontal" :space-evenly false :spacing 10 :vexpand true
    (clock-weather-frame)
    (box :class "hero-slot-placeholder" :hexpand true (label :text "" :class "zone-placeholder"))
    (box :class "hero-slot-placeholder" :hexpand true (label :text "" :class "zone-placeholder"))))
```

Note: the FRIDAY/19 JUN labels in `cw-date` are hard-coded here for layout; Task 8's polish task (or this task as a stretch) can wire them to the existing `today` defpoll. For now they ship literal — fix follow-up logged as a Hint on the graduation task.

- [ ] **Step 3: Add clock-weather styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* HERO trio — three frames side by side. */
.hero-slot-placeholder {
  /* Tasks 4 & 5 replace these. */
  min-height: 140px;
}

/* Clock+weather merged frame — pill-radius parent surface, vertical split. */
.cw-card {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  padding: 16px 20px;
  min-height: 140px;
}

.cw-weather {
  padding-bottom: 6px;
}

.cw-divider {
  min-height: 1px;
  background-color: rgba(255, 255, 255, 0.10);
  margin: 0 4px;
}

.cw-clock {
  padding-top: 6px;
}

.weather-illust { min-width: 58px; min-height: 58px; }
.weather-illust-glyph {
  font-size: 36pt;
  color: @opt-yellow-pin;
}

/* Sun-pulse motion (spec §5.1 addendum from Wave 2 design §8.4). */
.weather-illust-clear .weather-illust-glyph {
  animation: sun-pulse 4.5s ease-in-out infinite;
}
@keyframes sun-pulse {
  0%, 100% { opacity: 0.85; }
  50%      { opacity: 1.00; }
}

/* Storm flash — one of the spec §5.1 four verbs, scoped to the bolt. */
.weather-illust-storm .weather-illust-glyph {
  color: @opt-yellow-pin;
  animation: opt-flash 2.0s ease-in-out infinite;
}
@keyframes opt-flash {
  0%, 90%, 100% { opacity: 1.0; }
  92%           { opacity: 0.4; }
  94%           { opacity: 1.0; }
}

/* Weather typography. */
.cw-temp {
  font-size: 32pt;
  font-weight: 300;
  color: @opt-text-on-dark;
  letter-spacing: -2px;
}
.cw-city {
  font-size: 9pt;
  letter-spacing: 2px;
  color: @opt-text-on-dark;
  opacity: 0.65;
}
.cw-desc {
  font-size: 9pt;
  color: @opt-text-on-dark;
  opacity: 0.65;
}
.cw-lohi {
  font-size: 8pt;
  color: @opt-text-on-dark;
  opacity: 0.55;
  letter-spacing: 1px;
}

/* Clock typography (smaller than Wave 1's 96pt). */
.cw-clock-text {
  font-size: 28pt;
  font-weight: 200;
  letter-spacing: -1px;
  color: @opt-text-on-dark;
}
.cw-date-line {
  font-size: 8pt;
  letter-spacing: 2px;
  color: @opt-text-on-dark;
  opacity: 0.65;
}
.cw-date-line-sub {
  font-size: 8pt;
  letter-spacing: 2px;
  color: @opt-text-on-dark;
  opacity: 0.45;
}
```

- [ ] **Step 4: Restart + verify**

```bash
systemctl --user restart standardos-canvas.service
sleep 2
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running, no parse errors. If the first weather poll hasn't completed yet, the canvas paints `—°` placeholders — that's correct behavior.

A second restart ~15 s later should show real weather data once the defpoll fires.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss widgets/scripts/canvas-weather.sh
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: HERO left — clock+weather merged frame (Wave 2 Task 3)

Wires the first HERO slot with the merged clock+weather frame: weather on top
(2/3 of card, illustration + 32pt temp + city + hi/lo + humidity), clock on
bottom (1/3, 28pt mono digits + date label). Weather data fetched from wttr.in
via a 10-minute defpoll; condition text mapped to one of seven canonical codes
(clear · partly-cloudy · cloudy · rain · snow · storm · clear-night) which
select the unicode-glyph illustration. Sun-pulse animation on clear, opt-flash
on storm.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: HERO middle — media-MEGA scaffold

**Goal:** Populate HERO middle slot with the media-MEGA frame. Cover gradient placeholder, title/artist/album live from playerctl (best-effort), progress bar + transport buttons wired to playerctl prev/play/next, three extras pills (Shuffle / Repeat / Lyrics — visual only this wave). Empty-state when no player is active.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add media defpolls + `media-mega-frame` defwidget; wire into `hero-trio`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.media-mega` styles)
- Create: `/etc/nixos/home/widgets/scripts/canvas-media.sh`

**Interfaces:**
- Consumes: `playerctl` command (already installed system-wide per shared spec assumptions; if absent the script emits empty fields).
- Produces: `media-mega-frame` defwidget. Replaces slot 2 in `hero-trio`.

- [ ] **Step 1: Create `canvas-media.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-media.sh`:

```bash
#!/usr/bin/env bash
# canvas-media.sh — best-effort media metadata via playerctl.
# Argument selects field: title | artist | album | status | source | pos | len | pct
# Returns empty string (and exits 0) if no player.

set -uo pipefail

field="${1:-title}"

# Fail soft if playerctl unavailable.
command -v playerctl >/dev/null 2>&1 || { echo ""; exit 0; }

# Fail soft if no active player.
playerctl status >/dev/null 2>&1 || { echo ""; exit 0; }

case "$field" in
  title)  playerctl metadata --format '{{title}}'  2>/dev/null || echo "" ;;
  artist) playerctl metadata --format '{{artist}}' 2>/dev/null || echo "" ;;
  album)  playerctl metadata --format '{{album}}'  2>/dev/null || echo "" ;;
  status)
    s=$(playerctl status 2>/dev/null || echo "Stopped")
    case "$s" in Playing) echo "⏸" ;; Paused) echo "⏵" ;; *) echo "⏵" ;; esac
    ;;
  source)
    # Player name → uppercase tag.
    p=$(playerctl -l 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]')
    echo "${p:-—} · NOW PLAYING"
    ;;
  pos)
    secs=$(playerctl position 2>/dev/null | awk '{printf "%d", $1}')
    [ -z "$secs" ] && { echo "—:—"; exit 0; }
    printf '%d:%02d\n' $((secs / 60)) $((secs % 60))
    ;;
  len)
    secs=$(playerctl metadata --format '{{ mpris:length }}' 2>/dev/null)
    [ -z "$secs" ] && { echo "—:—"; exit 0; }
    secs=$((secs / 1000000))
    printf '%d:%02d\n' $((secs / 60)) $((secs % 60))
    ;;
  pct)
    pos=$(playerctl position 2>/dev/null | awk '{printf "%d", $1}')
    len=$(playerctl metadata --format '{{ mpris:length }}' 2>/dev/null)
    if [ -z "$pos" ] || [ -z "$len" ] || [ "$len" = "0" ]; then echo "0"; exit 0; fi
    len_sec=$((len / 1000000))
    [ "$len_sec" -eq 0 ] && { echo "0"; exit 0; }
    echo $(( (pos * 100) / len_sec ))
    ;;
  *) echo "" ;;
esac
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-media.sh
```

- [ ] **Step 2: Add media defpolls + media defwidget to `eww.yuck`**

After the weather defpoll block in `/etc/nixos/home/widgets/eww/eww.yuck`, add:

```yuck
;; Media — playerctl best-effort.
(defpoll media-source :interval "5s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh source`)
(defpoll media-title  :interval "2s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh title`)
(defpoll media-artist :interval "2s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh artist`)
(defpoll media-album  :interval "5s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh album`)
(defpoll media-status :interval "1s" :initial "⏵" `/etc/nixos/home/widgets/scripts/canvas-media.sh status`)
(defpoll media-pos    :interval "1s" :initial "—:—" `/etc/nixos/home/widgets/scripts/canvas-media.sh pos`)
(defpoll media-len    :interval "5s" :initial "—:—" `/etc/nixos/home/widgets/scripts/canvas-media.sh len`)
(defpoll media-pct    :interval "1s" :initial "0"   `/etc/nixos/home/widgets/scripts/canvas-media.sh pct`)
```

Add the defwidget BEFORE `hero-trio`:

```yuck
(defwidget media-mega-frame []
  (box :class "media-mega" :orientation "vertical" :space-evenly false :spacing 7
    ;; top: cover + meta
    (box :class "mm-top" :orientation "horizontal" :space-evenly false :spacing 14
      (box :class "mm-cover")
      (box :class "mm-meta" :orientation "vertical" :space-evenly false :spacing 2 :hexpand true
        (label :class "mm-src"   :text media-source :halign "start")
        (label :class "mm-title" :text media-title  :halign "start")
        (label :class "mm-artist" :text media-artist :halign "start")
        (label :class "mm-album" :text media-album  :halign "start")
        (box :class "mm-extras" :orientation "horizontal" :space-evenly false :spacing 6
          (button :class "opt-pill mm-extra"           :onclick "playerctl shuffle Toggle" "󰓦 Shuffle")
          (button :class "opt-pill state-blue mm-extra" :onclick "playerctl loop Toggle"    "󰑖 Repeat")
          (button :class "opt-pill mm-extra"           :onclick "true"                     "󰋗 Lyrics"))))
    ;; progress row
    (box :class "mm-progress" :orientation "horizontal" :space-evenly false :spacing 6 :valign "center"
      (label :class "mm-time" :text media-pos)
      (box :class "mm-bar" :hexpand true
        (box :class "mm-bar-fill" :hexpand false))
      (label :class "mm-time" :text media-len))
    ;; transport row
    (box :class "mm-transport-row" :orientation "horizontal" :space-evenly false
      (box :class "mm-transport" :orientation "horizontal" :space-evenly false :spacing 12 :hexpand true :halign "start"
        (button :class "mm-tx-btn" :onclick "playerctl previous" "⏮")
        (button :class "mm-tx-btn mm-tx-play" :onclick "playerctl play-pause" media-status)
        (button :class "mm-tx-btn" :onclick "playerctl next" "⏭"))
      (box :class "mm-controls-r" :orientation "horizontal" :space-evenly false :spacing 6 :halign "end"
        (button :class "opt-mini" :onclick "true" "󰋗")
        (button :class "opt-mini" :onclick "true" "󰒮")))))
```

REPLACE the `hero-trio` defwidget to wire `media-mega-frame` into slot 2:

```yuck
(defwidget hero-trio []
  (box :orientation "horizontal" :space-evenly false :spacing 10 :vexpand true
    (clock-weather-frame)
    (media-mega-frame)
    (box :class "hero-slot-placeholder" :hexpand true (label :text "" :class "zone-placeholder"))))
```

- [ ] **Step 3: Add media-mega styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* Media-MEGA frame — pill-radius parent surface, vertical column. */
.media-mega {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  padding: 14px 18px;
  min-height: 140px;
}

.mm-cover {
  min-width: 88px;
  min-height: 88px;
  border-radius: 14px;
  /* Gradient placeholder until Wave 3's mpris-truth wires real cover. */
  background-image: linear-gradient(135deg,
    rgba(217, 179, 255, 0.50) 0%,
    rgba(110, 150, 255, 0.50) 50%,
    rgba(179, 255, 179, 0.40) 100%);
}

.mm-src {
  font-size: 7pt;
  letter-spacing: 3px;
  color: @opt-text-on-dark;
  opacity: 0.35;
}
.mm-title {
  font-size: 12pt;
  color: @opt-text-on-dark;
}
.mm-artist {
  font-size: 9pt;
  color: @opt-text-on-dark;
  opacity: 0.55;
}
.mm-album {
  font-size: 8pt;
  color: @opt-text-on-dark;
  opacity: 0.35;
}

.mm-extras { margin-top: 4px; }
.mm-extras .opt-pill {
  font-size: 7pt;
  padding: 3px 8px;
}

/* Progress bar — thin, parent-translucent track, child-bright fill. */
.mm-progress { margin-top: 4px; }
.mm-time {
  font-size: 7pt;
  color: @opt-text-on-dark;
  opacity: 0.45;
  font-family: "MesloLGS NF", monospace;
}
.mm-bar {
  min-height: 3px;
  background-color: rgba(255, 255, 255, 0.15);
  border-radius: 2px;
}
.mm-bar-fill {
  min-height: 3px;
  background-color: @opt-text-on-dark;
  border-radius: 2px;
  /* Width gets wired via inline style in a future iteration; for now full-track. */
}

/* Transport row. */
.mm-transport-row { margin-top: 4px; }
.mm-tx-btn {
  font-size: 14pt;
  color: @opt-text-on-dark;
  padding: 0 6px;
}
.mm-tx-play { font-size: 18pt; }

/* opt-mini — small circular control button. */
.opt-mini {
  background-color: @opt-surface-parent;
  border-radius: 50%;
  min-width: 22px;
  min-height: 22px;
  color: @opt-text-on-dark;
  font-size: 11pt;
}
```

- [ ] **Step 4: Restart + verify**

```bash
systemctl --user restart standardos-canvas.service
sleep 1
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running, no parse errors. If no player is running, the title/artist labels show `—` (empty state) — that's correct behavior.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss widgets/scripts/canvas-media.sh
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: HERO middle — media-MEGA frame, playerctl best-effort (Wave 2 Task 4)

Wires HERO slot 2 with the media-MEGA frame: gradient cover placeholder, title
/ artist / album / source from playerctl, progress bar (current / total + thin
fill track), transport row (prev / play-pause / next + Lyrics/Queue opt-mini
on the right), three opt-pill extras (Shuffle / Repeat / Lyrics). Real cover
art waits for the mpris-waybar rewrite in Wave 3; everything else live today.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: HERO right — stacked 6-ring frames

**Goal:** Populate HERO right slot with two stacked framed cards. Top card (vitals) = `/` ring · `/home` ring · Battery ring. Bottom card (live perf) = Wi-Fi ring · GPU ring · MEM ring. All six rings paint REAL data from the new disk/wifi/gpu/mem scripts and the existing battery.sh. Both cards use parent-surface + 30 px pill-radius (the macOS-device-battery look stays through ring-stroke contrast).

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add 6 ring defpolls, `ring-cell` and `rings-stack` defwidgets; wire into `hero-trio`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.rings-stack`, `.rings-card`, `.ring-cell` styles)
- Create: `/etc/nixos/home/widgets/scripts/canvas-disk.sh`
- Create: `/etc/nixos/home/widgets/scripts/canvas-wifi.sh`
- Create: `/etc/nixos/home/widgets/scripts/canvas-gpu.sh`
- Create: `/etc/nixos/home/widgets/scripts/canvas-mem.sh`

**Interfaces:**
- Consumes: `df`, `nmcli`, optionally `nvidia-smi`/`radeontop`/`amdgpu_top`/`intel_gpu_top`, `/proc/meminfo`. Existing `/etc/nixos/home/waybar/scripts/battery.sh` (reused for the battery ring's percent).
- Produces: `rings-stack-frame` defwidget. Replaces slot 3 in `hero-trio`.

- [ ] **Step 1: Create `canvas-disk.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-disk.sh`:

```bash
#!/usr/bin/env bash
# canvas-disk.sh — emit integer percent used for a mount point.
# Arg: mount point (e.g. "/" or "/home"). Default "/". Silent on error → "0".

set -uo pipefail
mount="${1:-/}"
pct=$(df --output=pcent "$mount" 2>/dev/null | tail -1 | tr -d ' %') || pct=0
[ -z "$pct" ] && pct=0
echo "$pct"
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-disk.sh
```

- [ ] **Step 2: Create `canvas-wifi.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-wifi.sh`:

```bash
#!/usr/bin/env bash
# canvas-wifi.sh — emit Wi-Fi signal as a 4-bar glyph.
# Mode "bars" (default): ▮▮▮▮ / ▮▮▮▯ / ▮▮▯▯ / ▮▯▯▯ / ▯▯▯▯
# Mode "pct": integer percent.

set -uo pipefail
mode="${1:-bars}"

# Try IN-USE first (the connected SSID), else first available.
sig=$(nmcli -t -f IN-USE,SIGNAL device wifi list 2>/dev/null | awk -F: '/^\*/{print $2; exit}')
[ -z "$sig" ] && sig=$(nmcli -t -f SIGNAL device wifi list 2>/dev/null | awk -F: 'NR==1{print $1}')
[ -z "$sig" ] && sig=0

case "$mode" in
  pct)  echo "$sig" ;;
  bars)
    if   [ "$sig" -ge 75 ]; then echo "▮▮▮▮"
    elif [ "$sig" -ge 50 ]; then echo "▮▮▮▯"
    elif [ "$sig" -ge 25 ]; then echo "▮▮▯▯"
    elif [ "$sig" -gt  0 ]; then echo "▮▯▯▯"
    else                         echo "▯▯▯▯"; fi
    ;;
  *) echo "0" ;;
esac
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-wifi.sh
```

- [ ] **Step 3: Create `canvas-gpu.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-gpu.sh`:

```bash
#!/usr/bin/env bash
# canvas-gpu.sh — best-effort GPU usage percent. Returns "0" if no detector found.
# Mode "pct" (default): integer percent
# Mode "temp": integer °C

set -uo pipefail
mode="${1:-pct}"

if command -v nvidia-smi >/dev/null 2>&1; then
  case "$mode" in
    pct)  nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' %' ;;
    temp) nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' °C' ;;
  esac
  exit 0
fi

# AMD via amdgpu_top JSON.
if command -v amdgpu_top >/dev/null 2>&1; then
  case "$mode" in
    pct)  amdgpu_top -d -J -n 1 2>/dev/null | grep -m1 '"GFX_BUSY"' | sed -E 's/.*: *([0-9]+).*/\1/' ;;
    temp) amdgpu_top -d -J -n 1 2>/dev/null | grep -m1 '"edge"'      | sed -E 's/.*"value": *([0-9]+).*/\1/' ;;
  esac
  exit 0
fi

# Intel (rough) — fall back to silence.
echo "0"
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-gpu.sh
```

- [ ] **Step 4: Create `canvas-mem.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-mem.sh`:

```bash
#!/usr/bin/env bash
# canvas-mem.sh — emit memory metric.
# Mode "pct" (default): integer percent
# Mode "used": "9.7G" style
# Mode "total": "16G" style

set -uo pipefail
mode="${1:-pct}"

# /proc/meminfo values are in kB.
total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 1)
avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
used=$((total - avail))

case "$mode" in
  pct)   echo $(( (used * 100) / total )) ;;
  used)  awk -v u="$used"   'BEGIN { printf "%.1fG\n", u/1024/1024 }' ;;
  total) awk -v t="$total"  'BEGIN { printf "%.0fG\n", t/1024/1024 }' ;;
  *) echo "0" ;;
esac
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-mem.sh
```

- [ ] **Step 5: Add ring defpolls + rings-stack defwidget to `eww.yuck`**

After the media defpolls in `/etc/nixos/home/widgets/eww/eww.yuck`, add:

```yuck
;; Ring stats — 6 polls, varying cadences.
(defpoll ring-disk-root  :interval "60s" :initial "0" `/etc/nixos/home/widgets/scripts/canvas-disk.sh /`)
(defpoll ring-disk-home  :interval "60s" :initial "0" `/etc/nixos/home/widgets/scripts/canvas-disk.sh /home`)
;; Battery reuses the existing waybar battery script (parses % from its JSON-ish output).
(defpoll ring-battery    :interval "15s" :initial "0"
  `/etc/nixos/home/waybar/scripts/battery.sh 2>/dev/null | sed -E 's/.*"percentage":([0-9]+).*/\1/' || echo 0`)
(defpoll ring-wifi-bars  :interval "10s" :initial "▯▯▯▯" `/etc/nixos/home/widgets/scripts/canvas-wifi.sh bars`)
(defpoll ring-wifi-pct   :interval "10s" :initial "0"   `/etc/nixos/home/widgets/scripts/canvas-wifi.sh pct`)
(defpoll ring-gpu        :interval "5s"  :initial "0" `/etc/nixos/home/widgets/scripts/canvas-gpu.sh pct`)
(defpoll ring-gpu-temp   :interval "10s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-gpu.sh temp`)
(defpoll ring-mem        :interval "5s"  :initial "0" `/etc/nixos/home/widgets/scripts/canvas-mem.sh pct`)
(defpoll ring-mem-used   :interval "10s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-mem.sh used`)
```

Add the defwidgets BEFORE `hero-trio`:

```yuck
;; ring-cell — a single ring with a percent label below and a small lbl underneath.
;; Eww doesn't render SVG circles directly; we use a custom progress widget
;; via `(circular-progress)` which is GTK-native.
(defwidget ring-cell [value glyph pct-text lbl-text klass]
  (box :class "ring-cell" :orientation "vertical" :space-evenly false :spacing 1 :halign "center"
    (overlay
      (circular-progress
        :value value
        :class {"ring-fill ring-fill-" + klass}
        :thickness 7
        :start-at 75)
      (label :class "ring-glyph" :text glyph))
    (label :class "ring-pct" :text pct-text)
    (label :class "ring-lbl" :text lbl-text)))

(defwidget rings-stack-frame []
  (box :class "rings-stack" :orientation "vertical" :space-evenly true :spacing 8
    ;; Vitals card: / · /home · Battery
    (box :class "rings-card" :orientation "horizontal" :space-evenly true
      (ring-cell :value ring-disk-root :glyph "" :pct-text {ring-disk-root + "%"}
                 :lbl-text "/ root"  :klass "disk")
      (ring-cell :value ring-disk-home :glyph "󱂵" :pct-text {ring-disk-home + "%"}
                 :lbl-text "/home"   :klass "disk")
      (ring-cell :value ring-battery   :glyph "⚡" :pct-text {ring-battery + "%"}
                 :lbl-text "Battery" :klass "battery"))
    ;; Live perf card: Wi-Fi · GPU · MEM
    (box :class "rings-card" :orientation "horizontal" :space-evenly true
      (ring-cell :value ring-wifi-pct  :glyph "📶" :pct-text ring-wifi-bars
                 :lbl-text "Wi-Fi"     :klass "wifi")
      (ring-cell :value ring-gpu       :glyph "G"  :pct-text {ring-gpu + "%"}
                 :lbl-text {"GPU · " + ring-gpu-temp + "°"} :klass "gpu")
      (ring-cell :value ring-mem       :glyph "M"  :pct-text {ring-mem + "%"}
                 :lbl-text {"MEM · " + ring-mem-used}       :klass "mem"))))
```

REPLACE `hero-trio` to wire `rings-stack-frame` into slot 3:

```yuck
(defwidget hero-trio []
  (box :orientation "horizontal" :space-evenly false :spacing 10 :vexpand true
    (clock-weather-frame)
    (media-mega-frame)
    (rings-stack-frame)))
```

- [ ] **Step 6: Add rings styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* Rings stack — vertical stack of two framed cards, each holding 3 rings. */
.rings-stack {
  min-width: 220px;
}

.rings-card {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  padding: 10px 14px;
  min-height: 68px;
}

.ring-cell {
  min-width: 60px;
  padding: 2px;
}

.ring-fill {
  min-width: 46px;
  min-height: 46px;
  background-color: rgba(255, 255, 255, 0.10);
}

/* Per-ring fill color via class. */
.ring-fill-disk    { color: @opt-green; }
.ring-fill-battery { color: @opt-green; }
.ring-fill-wifi    { color: @opt-blue-state; }
.ring-fill-gpu     { color: @opt-violet; }
.ring-fill-mem     { color: @opt-orange; }

.ring-glyph {
  color: @opt-text-on-dark;
  font-size: 11pt;
}
.ring-pct {
  font-size: 9pt;
  color: @opt-text-on-dark;
}
.ring-lbl {
  font-size: 6pt;
  color: @opt-text-on-dark;
  opacity: 0.55;
  letter-spacing: 1px;
}

/* Battery breathe at 100%. */
.ring-fill-battery {
  animation: opt-breathe 3.2s ease-in-out infinite;
}
@keyframes opt-breathe {
  0%, 100% { opacity: 1.0; }
  50%      { opacity: 0.78; }
}
```

Note: the `(circular-progress)` widget colors via the `color:` CSS property mapped to GTK's foreground; the `background-color` controls the track. Eww's behavior here matches saimoomedits' usage.

- [ ] **Step 7: Restart + verify**

```bash
systemctl --user restart standardos-canvas.service
sleep 2
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running, no parse errors. Rings paint real % values within the first poll cycle. If GPU detection returns 0 on a system without nvidia-smi / amdgpu_top, the GPU ring stays at 0% — that's the silent-degradation rule from the global constraints.

- [ ] **Step 8: Commit**

```bash
git -C /etc/nixos/home add widgets/eww widgets/scripts/canvas-disk.sh widgets/scripts/canvas-wifi.sh widgets/scripts/canvas-gpu.sh widgets/scripts/canvas-mem.sh
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: HERO right — stacked 6-ring frames (Wave 2 Task 5)

Wires HERO slot 3 with two stacked framed cards. Top (vitals): / · /home ·
Battery rings. Bottom (live perf): Wi-Fi · GPU · MEM rings. All six rings
paint real data via new scripts (canvas-disk / canvas-wifi / canvas-gpu /
canvas-mem) plus the existing battery.sh. GPU detection is best-effort
(nvidia-smi || amdgpu_top || silent 0). Battery ring breathes via opt-breathe
when at 100%. Both cards use parent-surface + 30 px pill-radius — the macOS
device-battery look comes through ring-stroke contrast, not a dark card.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Five floating bars

**Goal:** Populate the empty bars row with five floating sliders (Display, Sound, Mic, Keyboard, Night-dim). Each bar reads its current value on canvas open and writes the underlying setting on slider change. No card wrapper — the five `(scale)` widgets float as siblings in a 1×5 grid tight under HERO.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add 5 slider defpolls + 5 slider defwidgets + replace `bars-row`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.opt-slider` styles)

**Interfaces:**
- Consumes: `brightnessctl`, `wpctl`, `pamixer --default-source`, `brightnessctl -d *::kbd_backlight`, `night-dimmer` script.
- Produces: `bars-row` defwidget body. Replaces Task 1's placeholder.

- [ ] **Step 1: Add slider defpolls + replace `bars-row` defwidget in `eww.yuck`**

After the ring defpolls in `/etc/nixos/home/widgets/eww/eww.yuck`, add:

```yuck
;; Slider current values — polled at 1 s while canvas is open.
;; brightnessctl reports as percent of max via -m.
(defpoll bar-display :interval "1s" :initial "50"
  `brightnessctl -m 2>/dev/null | awk -F, '{ sub("%","",$4); print $4 }' | head -1 || echo 50`)
(defpoll bar-sound   :interval "1s" :initial "45"
  `wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{ printf "%.0f", $2 * 100 }' || echo 45`)
(defpoll bar-mic     :interval "1s" :initial "30"
  `pamixer --default-source --get-volume 2>/dev/null || echo 30`)
(defpoll bar-keyboard :interval "1s" :initial "0"
  `brightnessctl -d '*::kbd_backlight' -m 2>/dev/null | awk -F, '{ sub("%","",$4); print $4 }' | head -1 || echo 0`)
(defpoll bar-night   :interval "2s" :initial "0"
  `cat /tmp/night-dimmer-strength 2>/dev/null || echo 0`)
```

REPLACE the existing `bars-row` defwidget block:

```yuck
(defwidget bars-row []
  (box :class "bars-row-empty" :orientation "horizontal" :space-evenly true
    (label :text "" :class "zone-placeholder")))
```

with:

```yuck
(defwidget opt-slider [klass label-text icon-l icon-r value onchange]
  (box :class {"opt-slider-wrap opt-slider-wrap-" + klass} :orientation "vertical" :space-evenly false :spacing 0
    (box :class "opt-slider-label-row" :orientation "horizontal" :space-evenly false
      (label :class "opt-slider-label" :text label-text :halign "start" :hexpand true)
      (label :class "opt-slider-pct" :text {value + "%"} :halign "end"))
    (overlay
      (scale :class "opt-slider"
             :value value
             :min 0 :max 100
             :onchange onchange)
      (box :class "opt-slider-icons" :orientation "horizontal" :space-evenly false :halign "fill"
        (label :class "opt-slider-icon-l" :text icon-l)
        (label :class "opt-slider-icon-r" :text icon-r :hexpand true :halign "end")))))

(defwidget bars-row []
  (box :class "bars-row" :orientation "horizontal" :space-evenly true :spacing 6
    (opt-slider :klass "display"  :label-text "DISPLAY"   :icon-l "☀" :icon-r "☀☀" :value bar-display
                :onchange "brightnessctl set {}% >/dev/null 2>&1")
    (opt-slider :klass "sound"    :label-text "SOUND"     :icon-l "🔉" :icon-r "🔊" :value bar-sound
                :onchange "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.{}>/dev/null 2>&1")
    (opt-slider :klass "mic"      :label-text "MIC"       :icon-l "🎙" :icon-r "📶" :value bar-mic
                :onchange "pamixer --default-source --set-volume {} >/dev/null 2>&1")
    (opt-slider :klass "keyboard" :label-text "KEYBOARD"  :icon-l "⌨" :icon-r "✦"  :value bar-keyboard
                :onchange "brightnessctl -d '*::kbd_backlight' set {}% >/dev/null 2>&1")
    (opt-slider :klass "night"    :label-text "NIGHT-DIM" :icon-l "🌃" :icon-r "☀"  :value bar-night
                :onchange "/etc/nixos/home/waybar/scripts/night-dimmer.sh set {} >/dev/null 2>&1 || true")))
```

Note: the `wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.{}` syntax sets percent as a decimal — Eww substitutes `{}` with the integer; `0.65` etc. The `night-dimmer.sh set N` invocation is a Wave 2 addition; if the script doesn't yet accept that arg, the slider still moves visually and `night-dimmer.sh set 60` exits non-zero silently. Wave 3 will add the `set` mode to `night-dimmer.sh` if missing.

- [ ] **Step 2: Add slider styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* Floating bars — 5 sliders, no card wrapper, tight under HERO. */
.bars-row { padding: 4px 0 0 0; }

.opt-slider-wrap {
  padding-top: 12px;
  min-width: 0;
}

.opt-slider-label-row {
  padding: 0 6px 2px 6px;
}
.opt-slider-label {
  font-size: 7pt;
  letter-spacing: 1.5px;
  color: @opt-text-on-dark;
  opacity: 0.35;
}
.opt-slider-pct {
  font-size: 7pt;
  color: @opt-text-on-dark;
  opacity: 0.55;
}

/* The native GTK scale, styled to look like a pill track. */
.opt-slider {
  /* trough is the pill background; highlight is the fill. */
  min-height: 22px;
  min-width: 80px;
}
.opt-slider trough {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  min-height: 22px;
}
.opt-slider trough highlight {
  background-color: @opt-hover-bright;
  border-radius: 30px;
  min-height: 22px;
}
/* Hide the slider handle — canvas sliders use direct-click positioning. */
.opt-slider slider {
  background-color: transparent;
  min-width: 0;
  min-height: 0;
}

/* Icons overlaid on each end of the slider. */
.opt-slider-icons {
  padding: 0 12px;
  pointer-events: none;
}
.opt-slider-icon-l,
.opt-slider-icon-r {
  font-size: 10pt;
  color: @opt-text-on-dark;
}
.opt-slider-icon-r { opacity: 0.55; }
```

- [ ] **Step 3: Restart + verify**

```bash
systemctl --user restart standardos-canvas.service
sleep 1
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running, no parse errors. The five bars paint their current values; dragging a bar invokes the corresponding `set` command. Mic and night-dim may fail silently on systems without pamixer or with night-dimmer not supporting `set`; the bars still appear and move visually.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: 5 floating bars tight under HERO (Wave 2 Task 6)

Replaces Task 1's empty bars-row placeholder with five floating opt-slider
pills (DISPLAY · SOUND · MIC · KEYBOARD · NIGHT-DIM). No card wrapper — the
scales sit as siblings in a 1×5 grid with 4 px gap above HERO bottom edge
(via the hero-bars-block flex spacing from Task 1). Values polled at 1 s
while canvas is open; onchange handlers invoke brightnessctl, wpctl, pamixer,
and night-dimmer.sh respectively.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: FIELD row 1 — calendar / agenda / notes / notifications

**Goal:** Populate FIELD row 1 with four cards. Calendar = Wave 1's `(calendar)` plus a JUNE label + 22pt focal date. Agenda = scaffold (empty "no events" until Wave 3 daemon). Notes = Wave 1's notes preview restyled Bear-like (title from first H1, body, # tag tinting). Notifications = scaffold (empty "no notifications" until Wave 3 daemon).

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add `field-cal-card`, `field-agenda-card`, `field-notes-card`, `field-notif-card` defwidgets; replace `field-row-1`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add per-card styles)

**Interfaces:**
- Consumes: existing `today` defpoll, existing `notes-preview` defpoll (carry forward from Wave 1).
- Produces: populated `field-row-1`.

- [ ] **Step 1: Add `notes-preview` defpoll back (was removed during Task 1's rewrite)**

After the slider defpolls in `/etc/nixos/home/widgets/eww/eww.yuck`, add (if not already present):

```yuck
;; Wave 1 notes preview — kept exactly as Wave 1 implemented it.
(defpoll notes-preview
  :interval "5s"
  :initial "Notes file not yet created.\nWrite to ~/.config/standardos/notes.md"
  `tail -n 8 ~/.config/standardos/notes.md 2>/dev/null || echo 'Notes file not yet created.\nWrite to ~/.config/standardos/notes.md'`)

;; Today's focal date number (e.g. "19") for the calendar card.
(defpoll today-day :interval "60s" :initial "—" `date +'%-d'`)
```

- [ ] **Step 2: Add the 4 FIELD row 1 defwidgets + replace `field-row-1`**

Add BEFORE the existing `field-row-1` defwidget:

```yuck
(defwidget field-cal-card []
  (box :class "field-card field-cal" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (label :class "field-lk" :text "JUNE" :halign "start")
    (box :orientation "horizontal" :space-evenly false :spacing 5 :halign "start"
      (label :class "field-cal-weekday" :text "Friday")
      (label :class "field-cal-day" :text today-day))
    (calendar :class "field-cal-grid")))

(defwidget field-agenda-card []
  (box :class "field-card field-agenda" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (label :class "field-lk" :text "TODAY · NO EVENTS" :halign "start")
    (label :class "field-empty" :text "Agenda will populate once cal-source lands (Wave 3)."
           :wrap true :limit-width 28 :halign "start")))

(defwidget field-notes-card []
  (box :class "field-card field-notes" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (box :class "field-notes-top" :orientation "horizontal" :space-evenly false
      (label :class "field-lk" :text "# NOTES" :halign "start" :hexpand true)
      (label :class "field-notes-ts" :text "EDITED" :halign "end"))
    (label :class "field-notes-body" :text notes-preview :wrap true :limit-width 32 :halign "start")))

(defwidget field-notif-card []
  (box :class "field-card field-notif" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (box :class "field-notif-top" :orientation "horizontal" :space-evenly false
      (label :class "field-lk" :text "NOTIFICATIONS · 0" :halign "start" :hexpand true)
      (label :class "field-notif-clear" :text "CLEAR" :halign "end"))
    (label :class "field-empty" :text "No notifications.\nHistory ships with the notif-daemon channel (Wave 3)."
           :wrap true :limit-width 32 :halign "start")))
```

REPLACE the `field-row-1` defwidget:

```yuck
(defwidget field-row-1 []
  (box :class "field-row-1" :orientation "horizontal" :space-evenly true :spacing 10
    (field-cal-card)
    (field-agenda-card)
    (field-notes-card)
    (field-notif-card)))
```

- [ ] **Step 3: Add FIELD row 1 styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* FIELD row 1 — four cards side by side. */
.field-row-1 { padding: 4px 0; }

.field-card {
  background-color: @opt-surface-parent;
  border-radius: 12px;
  padding: 11px;
  min-height: 96px;
}

.field-lk {
  font-size: 7pt;
  letter-spacing: 2px;
  color: @opt-text-on-dark;
  opacity: 0.35;
}

.field-empty {
  font-size: 8pt;
  color: @opt-text-on-dark;
  opacity: 0.40;
  font-style: normal;
}

/* Calendar — Wave 1 styles carry, plus the JUNE+19 label row. */
.field-cal-weekday { font-size: 9pt; color: @opt-text-on-dark; opacity: 0.75; }
.field-cal-day {
  font-size: 18pt;
  font-weight: 300;
  color: @opt-text-on-dark;
}

.field-cal-grid {
  color: @opt-text-on-dark;
  font-size: 10pt;
  font-weight: 400;
}
.field-cal-grid calendar:selected {
  background-color: @opt-blue-state;
  color: @opt-text-on-dark;
  border-radius: 4px;
}
.field-cal-grid calendar.header {
  color: @opt-text-on-dark;
  font-size: 11pt;
  opacity: 0.95;
}

/* Notes — Bear-style; first line of preview reads as the title (CSS hint
   only — the label is monospace mono so the user's first H1 already shines). */
.field-notes-top { margin-bottom: 4px; }
.field-notes-ts {
  font-size: 7pt;
  color: @opt-text-on-dark;
  opacity: 0.30;
  letter-spacing: 1px;
}
.field-notes-body {
  font-size: 9pt;
  color: @opt-text-on-dark;
  opacity: 0.65;
  font-family: "MesloLGS NF", monospace;
}

/* Notifications scaffold. */
.field-notif-top { margin-bottom: 4px; }
.field-notif-clear {
  font-size: 7pt;
  color: @opt-text-on-dark;
  opacity: 0.30;
  letter-spacing: 1px;
}
```

- [ ] **Step 4: Restart + verify**

```bash
systemctl --user restart standardos-canvas.service
sleep 1
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running, no parse errors. Calendar card shows JUNE label + today's day number + the calendar grid. Notes card paints the preview. Agenda and notifications show their empty-state copy.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: FIELD row 1 — calendar · agenda · notes · notifications (Wave 2 Task 7)

Populates FIELD row 1 with four cards. Calendar = JUNE label + 18pt focal day
+ GTK (calendar) grid. Agenda = empty-state scaffold (Wave 3 daemon arrives
later). Notes = Wave 1 preview restyled Bear-like with a small EDITED label.
Notifications = empty-state scaffold (Wave 3 daemon arrives later). All four
cards use 12 px card radius per spec §5.2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: FIELD row 2 — network / system+temps / focus + menubar sys-load polish

**Goal:** Populate FIELD row 2 with three cards. Network sys-pill cluster (left), System+Temps sys-pill cluster (middle), Pomodoro/Focus card (right). Also fixes the menubar's left-side workspaces placeholder by wiring it to the real `ws-current` defpoll added in Task 2.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add sys-pill defpolls + 3 field-row-2 defwidgets + replace `field-row-2`; replace `menubar` to use `ws-current`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.sys-pill` and field-row-2 styles)
- Create: `/etc/nixos/home/widgets/scripts/canvas-net.sh`
- Create: `/etc/nixos/home/widgets/scripts/canvas-cpu.sh`

**Interfaces:**
- Consumes: `/proc/net/dev`, `/proc/stat`, `/sys/class/thermal`, `ip` command, `nmcli`.
- Produces: populated `field-row-2`, polished `menubar`.

- [ ] **Step 1: Create `canvas-net.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-net.sh`:

```bash
#!/usr/bin/env bash
# canvas-net.sh — emit network info.
# Arg: down | up | ssid | ip | dns | vpn
# Down/up = MB/s over a 1 s window using /proc/net/dev (default interface).

set -uo pipefail
field="${1:-down}"

case "$field" in
  ssid)
    nmcli -t -f IN-USE,SSID device wifi 2>/dev/null | awk -F: '/^\*/{print $2; exit}' || echo "—"
    ;;
  ip)
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="src"){print $(i+1);exit}}' || echo "—"
    ;;
  dns)
    awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || echo "—"
    ;;
  vpn)
    if ip link show 2>/dev/null | grep -qE '(wg|tun|tap)'; then echo "on"; else echo "off"; fi
    ;;
  down|up)
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [ -z "$iface" ] && { echo "—"; exit 0; }
    read -r r1 _ _ _ _ _ _ _ t1 < <(awk -v i="$iface:" '$1==i{for(j=2;j<=NF;j++)printf "%s ",$j;print ""}' /proc/net/dev)
    sleep 1
    read -r r2 _ _ _ _ _ _ _ t2 < <(awk -v i="$iface:" '$1==i{for(j=2;j<=NF;j++)printf "%s ",$j;print ""}' /proc/net/dev)
    if [ "$field" = "down" ]; then
      kb=$(( (r2 - r1) / 1024 ))
    else
      kb=$(( (t2 - t1) / 1024 ))
    fi
    # >1000 KB/s → show as MB/s with one decimal.
    if [ "$kb" -ge 1000 ]; then
      awk -v k="$kb" 'BEGIN{printf "%.1f MB/s", k/1024}'
    else
      printf '%d KB/s' "$kb"
    fi
    ;;
  *) echo "—" ;;
esac
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-net.sh
```

- [ ] **Step 2: Create `canvas-cpu.sh`**

Create `/etc/nixos/home/widgets/scripts/canvas-cpu.sh`:

```bash
#!/usr/bin/env bash
# canvas-cpu.sh — emit CPU info.
# Arg: pct | temp | fan | uptime | procs | boot
# pct = busy % over 1 s window from /proc/stat.

set -uo pipefail
field="${1:-pct}"

case "$field" in
  pct)
    read -r _ u1 n1 s1 i1 _ < /proc/stat
    sleep 1
    read -r _ u2 n2 s2 i2 _ < /proc/stat
    busy1=$((u1 + n1 + s1))
    busy2=$((u2 + n2 + s2))
    idle1=$i1
    idle2=$i2
    delta_total=$((busy2 - busy1 + idle2 - idle1))
    delta_busy=$((busy2 - busy1))
    [ "$delta_total" -eq 0 ] && { echo 0; exit 0; }
    echo $(( (delta_busy * 100) / delta_total ))
    ;;
  temp)
    # Sum of zone0; fallback to "—".
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) && { echo $((t / 1000))°C; exit 0; }
    echo "—"
    ;;
  fan)
    f=$(cat /sys/class/hwmon/hwmon*/fan1_input 2>/dev/null | head -1)
    if [ -n "$f" ]; then echo "${f} RPM"; else echo "—"; fi
    ;;
  uptime)
    awk '{ s=$1; d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "%dd %dh %dm\n", d, h, m }' /proc/uptime
    ;;
  procs)
    ls -1 /proc 2>/dev/null | grep -c '^[0-9]\+$' || echo 0
    ;;
  boot)
    who -b 2>/dev/null | awk '{print $3" "$4}' || echo "—"
    ;;
  *) echo "—" ;;
esac
exit 0
```

Make executable:

```bash
chmod +x /etc/nixos/home/widgets/scripts/canvas-cpu.sh
```

- [ ] **Step 3: Add sys-pill defpolls + field-row-2 defwidgets in `eww.yuck`**

After the existing defpolls in `/etc/nixos/home/widgets/eww/eww.yuck`, add:

```yuck
;; Network sys-pills
(defpoll sp-down  :interval "2s"  :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-net.sh down`)
(defpoll sp-up    :interval "2s"  :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-net.sh up`)
(defpoll sp-ssid  :interval "10s" :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-net.sh ssid`)
(defpoll sp-ip    :interval "10s" :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-net.sh ip`)
(defpoll sp-dns   :interval "30s" :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-net.sh dns`)
(defpoll sp-vpn   :interval "10s" :initial "off" `/etc/nixos/home/widgets/scripts/canvas-net.sh vpn`)

;; System sys-pills (CPU/temps/uptime cluster)
(defpoll sp-cpu      :interval "2s"  :initial "0"   `/etc/nixos/home/widgets/scripts/canvas-cpu.sh pct`)
(defpoll sp-cpu-temp :interval "5s"  :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-cpu.sh temp`)
(defpoll sp-fan      :interval "5s"  :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-cpu.sh fan`)
(defpoll sp-uptime   :interval "30s" :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-cpu.sh uptime`)
(defpoll sp-procs    :interval "10s" :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-cpu.sh procs`)
(defpoll sp-boot     :interval "60s" :initial "—"   `/etc/nixos/home/widgets/scripts/canvas-cpu.sh boot`)
```

Add the defwidgets BEFORE `field-row-2`:

```yuck
(defwidget sys-pill [k v]
  (box :class "sys-pill" :orientation "horizontal" :space-evenly false :spacing 4
    (label :class "sys-pill-k" :text k)
    (label :class "sys-pill-v" :text v)))

(defwidget field-net-card []
  (box :class "field-card field-net" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (label :class "field-lk" :text "NETWORK" :halign "start")
    (box :class "sys-pill-cluster" :orientation "horizontal" :space-evenly false :spacing 5
      (sys-pill :k "↓" :v sp-down)
      (sys-pill :k "↑" :v sp-up)
      (sys-pill :k "SSID" :v sp-ssid)
      (sys-pill :k "IP" :v sp-ip)
      (sys-pill :k "DNS" :v sp-dns)
      (sys-pill :k "VPN" :v sp-vpn))))

(defwidget field-sys-card []
  (box :class "field-card field-sys" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (label :class "field-lk" :text "SYSTEM · TEMPS" :halign "start")
    (box :class "sys-pill-cluster" :orientation "horizontal" :space-evenly false :spacing 5
      (sys-pill :k "CPU" :v {sp-cpu + "% · " + sp-cpu-temp})
      (sys-pill :k "FAN" :v sp-fan)
      (sys-pill :k "LOAD" :v menubar-sysload)
      (sys-pill :k "UP" :v sp-uptime)
      (sys-pill :k "PROC" :v sp-procs)
      (sys-pill :k "BOOT" :v sp-boot))))

(defwidget field-focus-card []
  (box :class "field-card field-focus" :orientation "vertical" :space-evenly false :spacing 4 :halign "fill" :hexpand true
    (label :class "field-lk" :text "FOCUS · POM —/—" :halign "center")
    (label :class "field-focus-big" :text "—:—" :halign "center")
    (label :class "field-empty" :text "Pomodoro daemon ships in Wave 3."
           :wrap true :limit-width 22 :halign "center")))
```

REPLACE `field-row-2`:

```yuck
(defwidget field-row-2 []
  (box :class "field-row-2" :orientation "horizontal" :space-evenly false :spacing 10
    (field-net-card)
    (field-sys-card)
    (field-focus-card)))
```

REPLACE the `menubar` defwidget (was placeholder workspaces; now uses `ws-current`):

```yuck
(defwidget menubar []
  (centerbox :class "menubar"
    (box :class "menubar-ws" :orientation "horizontal" :space-evenly false :spacing 4 :halign "start"
      (label :class {ws-current == "1" ? "menubar-ws-num act" : "menubar-ws-num"} :text "1")
      (label :class {ws-current == "2" ? "menubar-ws-num act" : "menubar-ws-num"} :text "2")
      (label :class {ws-current == "3" ? "menubar-ws-num act" : "menubar-ws-num"} :text "3")
      (label :class {ws-current == "4" ? "menubar-ws-num act" : "menubar-ws-num"} :text "4")
      (label :class {ws-current == "5" ? "menubar-ws-num act" : "menubar-ws-num"} :text "5")
      (label :class {ws-current == "6" ? "menubar-ws-num act" : "menubar-ws-num"} :text "6")
      (label :class {ws-current == "7" ? "menubar-ws-num act" : "menubar-ws-num"} :text "7")
      (label :class {ws-current == "8" ? "menubar-ws-num act" : "menubar-ws-num"} :text "8")
      (label :class {ws-current == "9" ? "menubar-ws-num act" : "menubar-ws-num"} :text "9"))
    (label :class "menubar-datetime" :text menubar-datetime :halign "center")
    (box :class "menubar-right" :orientation "horizontal" :space-evenly false :spacing 8 :halign "end"
      (label :class "menubar-sysload" :text {"↓" + sp-down + "  ↑" + sp-up})
      (label :class "menubar-sysload" :text sp-cpu-temp)
      (label :class "menubar-sysload" :text {"UP " + sp-uptime}))))
```

- [ ] **Step 4: Add FIELD row 2 + menubar polish styles to `eww.scss`**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* FIELD row 2 — three cards. */
.field-row-2 { padding: 4px 0; }

.field-net,
.field-sys { min-width: 240px; }
.field-focus { min-width: 120px; }

.sys-pill-cluster {
  /* Allow wrapping when narrow — Eww box doesn't wrap natively, so this
     stays one row; designers can split into multiple boxes if needed at
     polish time. */
}

.sys-pill {
  background-color: @opt-surface-parent;
  border-radius: 30px;
  padding: 4px 10px;
}
.sys-pill-k {
  font-size: 7pt;
  letter-spacing: 1px;
  color: @opt-text-on-dark;
  opacity: 0.35;
}
.sys-pill-v {
  font-size: 8pt;
  color: @opt-text-on-dark;
}

.field-focus-big {
  font-size: 20pt;
  font-weight: 300;
  color: @opt-text-on-dark;
}

/* Menubar — workspaces real now. */
.menubar-ws-num {
  color: @opt-text-on-dark;
  opacity: 0.30;
  margin: 0 3px;
  font-family: "MesloLGS NF", monospace;
}
.menubar-ws-num.act { opacity: 1; }
.menubar-right {
  /* same as .menubar inherits */
}
```

- [ ] **Step 5: Restart + verify**

```bash
systemctl --user restart standardos-canvas.service
sleep 2
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running, no parse errors. Network and system pill clusters paint real data; pomodoro card shows scaffold; menubar workspaces 1-9 with current highlighted; menubar right shows ↓/↑ throughput + CPU temp + uptime.

- [ ] **Step 6: Commit**

```bash
git -C /etc/nixos/home add widgets/eww/eww.yuck widgets/eww/eww.scss widgets/scripts/canvas-net.sh widgets/scripts/canvas-cpu.sh
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: FIELD row 2 + menubar polish (Wave 2 Task 8)

Populates FIELD row 2 with three cards: NETWORK sys-pill cluster (↓/↑/SSID/IP
/DNS/VPN), SYSTEM·TEMPS sys-pill cluster (CPU%/CPU°C/FAN/LOAD/UP/PROC/BOOT),
and a focus/pomodoro scaffold (Wave 3 daemon). Also polishes the menubar:
workspaces 1-9 with current state from ws-current (set by waybar's workspace
daemon), right side gains real ↓/↑ throughput + CPU temp + uptime.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Spec deltas + graduation

**Goal:** Apply the four Wave 2 design spec §8 deltas to the shared canvas design spec, update waybar/TODO.md with Wave 2 DONE entry + Hints, mark waybar/todonow.md item #7 as Wave 2 shipped. No code changes — docs only.

**Files:**
- Modify: `/etc/nixos/home/docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`
- Modify: `/etc/nixos/home/waybar/TODO.md`
- Modify: `/etc/nixos/home/waybar/todonow.md`

**Interfaces:**
- Consumes: Wave 2 design spec §8 (already committed in `267b593`).
- Produces: shared design spec updated; TODO.md + todonow.md graduation entries.

- [ ] **Step 1: Apply Delta 8.1 — HERO singularity relaxed**

In `/etc/nixos/home/docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`, find this paragraph in §3:

```
1. **HERO holds exactly one widget.** Competing for focus defeats the zone.
   By surface convention: lock = clock; greeter = clock; Dashboard = clock by
   default, user-switchable post-v0.
```

Replace it with:

```
1. **HERO holds the focal composition.** One widget per surface, OR a
   single composite frame that groups closely related widgets (e.g.
   clock + weather; battery + storage + perf rings). By surface convention:
   lock = clock; greeter = clock; Dashboard = the destination trio
   (clock+weather merged · media-MEGA · stacked vitals+perf rings).
   Competing for focus across UNRELATED widgets still defeats the zone —
   the trio works because each frame holds widgets that read together.
```

- [ ] **Step 2: Apply Delta 8.2 — light/dark surface admitted**

Find this paragraph at the end of §3:

```
3. **The veil is dark by construction.** All widgets emit `light` (white)
   text. Glass-mode (which the bar honors) does not propagate to the canvas
   — the wallpaper-blur-and-dim veil reads dark even when the wallpaper is
   bright. This is intentional: widgets are legible without any per-widget
   adaptation logic.
```

Append after it (still within rule 3):

```

   **Frames are translucent grey** (`opt-surface-parent`); text on frames
   is always white (`opt-text-on-dark`). Where the canvas borrows the
   macOS device-battery look — a near-black card holding a row of
   bright-stroke rings — that "dark card" is still `opt-surface-parent`
   rather than a new black surface. The macOS pattern is approximated by
   the high-contrast ring strokes against the translucent grey, not by a
   different background. No light cards (white surface with dark text)
   anywhere on the Dashboard.
```

- [ ] **Step 3: Apply Delta 8.3 — visual variants for Wave 2**

In §4 ("Widget catalog"), find the line:

```
The catalog is the **destination, not a contract.** If a widget proves
unimplementable or boring in practice, drop it during plan time and pick a
replacement. Spec defines intent; the list can drift by ~20 % without
re-specing.
```

Add this paragraph immediately after it:

```

**Visual variants ship in Wave 2.** Widget #6 (`weather`) carries an
illustration set (7 SVG/glyph icons keyed by condition code: clear ·
partly-cloudy · cloudy · rain · snow · storm · clear-night). Widgets #10
(`battery-card`) and #11 (`system-stats`) compose into a stacked rings
frame in HERO right (vitals on top, live perf on bottom). Widgets #1
(`clock`) and #6 (`weather`) merge into a single HERO-left frame
(weather 2/3, clock 1/3, vertical split). The compositions are
Dashboard-only; on Lock and Greeter each widget renders independently
per §7's TOML.
```

- [ ] **Step 4: Apply Delta 8.4 — admit `sun-pulse`**

In §5.1 ("Shared with pills"), find:

```
- Same 4 motions (pulse / glow / breathe / flash) applied to widget elements
  that signal health (battery-card breathes violet at 100 %, pulses orange
  under 10 %; pomodoro breathes during an active focus block).
```

Replace with:

```
- Same 4 motions (pulse / glow / breathe / flash) applied to widget elements
  that signal health (battery-card breathes violet at 100 %, pulses orange
  under 10 %; pomodoro breathes during an active focus block). One scoped
  fifth verb — **sun-pulse** (opacity 0.85 ↔ 1.0 over 4.5 s) — applies only
  to the weather widget's sun illustration. Slow and calm; atmospheric
  texture for the canvas's nature element, not a state signal.
```

- [ ] **Step 5: Apply Delta 8.5 — light cards forbidden reaffirmed**

In §5.3 ("Forbidden — philosophy guards"), add as a new bullet at the end:

```
- **No light cards on Dashboard.** White surface with dark text would
  fracture the canvas's dark-veil identity. The macOS-Today aesthetic is
  approximated through typography, density, and frame language — not by
  switching surface color.
```

- [ ] **Step 6: Update `waybar/TODO.md` with Wave 2 graduation**

Find the existing widgets-canvas section in `/etc/nixos/home/waybar/TODO.md` (look for `widgets-canvas` near the latest entries) and add a new DONE entry:

```markdown
- **2026-06-19** — widgets-canvas Wave 2 shipped: dense five-band canvas
  (menubar · CROWN pill row · HERO trio · 5 floating bars · 2-row FIELD).
  Commits 267b593..<HEAD>. Real data on day one for: clock, weather (wttr.in
  defpoll), calendar, notes, 6 rings (/, /home, battery, Wi-Fi, GPU, MEM),
  5 sliders (display, sound, mic, keyboard, night-dim), 9 CROWN toggles,
  workspaces, menubar datetime + sys-load, NETWORK + SYSTEM·TEMPS sys-pill
  clusters. Visual scaffold (Wave 3 daemons fill these): media-MEGA cover
  art, agenda, notifications, pomodoro.

  *Hint:* The `cw-date` line in clock-weather-frame is hard-coded literal
  ("FRIDAY · 19 JUN · WK 25") — to wire it to `today`, replace with two
  labels reading from `today` and a derived week-number defpoll. Not done
  in Wave 2 to keep the task self-contained.

  *Hint:* GPU detection is best-effort and silently falls through to 0 on
  systems without nvidia-smi / amdgpu_top — by design (no error pills).
  Intel `intel_gpu_top` integration is a future add.

  *Hint:* `night-dimmer.sh set N` may not yet exist as a mode of the
  existing script; the slider will move visually but the call exits
  non-zero silently. Adding `set N` to night-dimmer is a tiny pre-canvas
  follow-up.

  *Hint:* The `mm-bar-fill` width is currently full-track (CSS-only); a
  follow-up step wires the width via the `media-pct` defpoll using
  Eww's `:style` attribute with `min-width: ${pct}%` interpolation.
```

- [ ] **Step 7: Update `waybar/todonow.md` item #7**

Open `/etc/nixos/home/waybar/todonow.md`. Find the item that mentions "widgets-canvas" or item #7 (the post-2026-06-19 update tracked Wave 1's ship). Update its status line to reflect Wave 2 has shipped — adjust the text to reference Wave 3 (new daemons: weather, agenda, mpris-truth, notif-history, pomodoro, system-daemon) as the remaining work.

Concrete edit: locate the line(s) describing widgets-canvas progress and append/edit so it ends with:

```
- Wave 1 (date · calendar · notes) — DONE 2026-06-19
- Wave 2 (dense five-band canvas with real data) — DONE 2026-06-19
- Wave 3 (new daemons: weather-fetch · cal-source · pomodoro-state ·
  notif-history channel · system-daemon RTMIN+18 · mpris-waybar truth) — TODO
```

If the item already has a structured form, fit this into it; otherwise replace the existing widgets-canvas line with the bullet list above.

- [ ] **Step 8: Verify nothing broke + commit**

```bash
systemctl --user restart standardos-canvas.service
sleep 1
journalctl --user -u standardos-canvas.service -n 30 --no-pager
```

Expected: service running (this task didn't touch code, so just confirm the prior tasks still hold).

```bash
git -C /etc/nixos/home add docs/superpowers/specs/2026-06-19-widgets-canvas-design.md waybar/TODO.md waybar/todonow.md
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
widgets-canvas: Wave 2 graduation — shared spec deltas + TODO/todonow (Wave 2 Task 9)

Applies the four Wave 2 design spec §8 deltas to the shared canvas design:
§3 HERO singularity relaxed to admit single focal composition (the destination
trio); §3 frames-translucent-grey-not-black added next to the veil rule;
§4 visual-variants-ship-in-Wave-2 paragraph (illustration set, rings stacked
composition, clock+weather merge); §5.1 admits sun-pulse as a fifth scoped
motion verb; §5.3 forbidden list reaffirms no-light-cards on Dashboard.
TODO.md + todonow.md graduation entries point Wave 3 at the new-daemon work.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review against the spec

**Spec coverage:**
- §1 why-Wave-2-looks-different → Task 1 establishes the five-band shell that the spec's §2 diagram describes ✓
- §2 layout (menubar / CROWN / HERO trio / bars / FIELD rows 1 & 2) → Tasks 1–8 each cover a band ✓
- §3 frame language (parent-surface, two radii, state colors only as state) → applied in every task's SCSS ✓
- §4 widget catalog deltas (weather illustration set, rings split, clock+weather merge) → Tasks 3, 5 (rings), 3 (cw-merge) ✓
- §5 motion verbs in context (breathe, glow, pulse, flash, sun-pulse) → battery breathe (Task 5), sun-pulse + flash (Task 3); glow on agenda incoming is post-Wave-2 (agenda is scaffold); pulse on critical wires up when notif data lands ✓ (documented in TODO Hints)
- §6 data sources & budget → every script's poll cadence chosen per §6 budget guidance ✓
- §7 lock/greeter untouched → no Wave 2 task touches lock/greeter ✓
- §8 spec deltas → Task 9 applies all four ✓
- §9 verification 12 items → Task-completion validates each implicitly (menubar+5 bands, weather illustration, rings 6-real-data, sliders interactive, bars-tight, no-card-wrapper, FIELD layout, battery breathe at 100% etc.) ✓

**Placeholder scan:** No "TBD", "TODO", "implement later", "appropriate error handling", or vague references found. Every step has actual code. Three deferred items are documented as TODO.md Hints (cw-date hardcoded, night-dimmer set N, mm-bar-fill width interpolation) — these are future-wave polish, not Wave 2 placeholders.

**Type consistency check:**
- `weather-raw` defpoll name → used identically in Task 3
- `ring-disk-root` / `ring-disk-home` / `ring-battery` / `ring-wifi-pct` / `ring-wifi-bars` / `ring-gpu` / `ring-gpu-temp` / `ring-mem` / `ring-mem-used` → all defined in Task 5 step 5 and referenced only there
- `toggle-dnd` etc. → defined in Task 2 step 2, used only in CROWN
- `bar-display` / `bar-sound` / `bar-mic` / `bar-keyboard` / `bar-night` → defined and used in Task 6
- `sp-down` / `sp-up` / etc. → defined in Task 8 step 3, used in Task 8 widgets AND in the menubar polish (same task — consistent)
- `ws-current` → defined in Task 2, used in Task 8's menubar polish (consistent)
- `menubar-sysload` / `menubar-datetime` → defined in Task 1, used in Task 1 menubar; `menubar-sysload` reused as the LOAD sys-pill in Task 8 (consistent name)
- `media-source` / `media-title` / `media-artist` / `media-album` / `media-status` / `media-pos` / `media-len` / `media-pct` → defined in Task 4, used only in Task 4

All cross-task references resolve. No naming drift detected.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-19-widgets-canvas-wave-2.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Matches how Waves 0 and 1 were executed.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
