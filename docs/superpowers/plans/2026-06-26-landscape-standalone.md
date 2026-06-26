# Landscape-Standalone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the Landscape section out of the StandardOS canvas into its own independent eww gtk-layer-shell window; rebind Super+RETURN to Landscape, Super+Shift+S to Control Center (canvas), Super+Alt+S to movewindow d.

**Architecture:** New `defwindow landscape` peer of the existing `defwindow dashboard`, sharing the eww daemon and the shipped `landscape-snap` data plane. New `landscape-open` / `landscape-close` / `landscape-panic` triplet mirroring the canvas triplet. The verify signal in canvas-close/canvas-panic switches from "any overlay gtk-layer-shell surface present" to "overlay gtk-layer-shell surface count decremented after dismiss" — required because both surfaces share `namespace: gtk-layer-shell` under eww 0.6.0.

**Tech Stack:** eww 0.6.0 (yuck + scss); Hyprland binds + submaps; bash for open/close/panic scripts; flock for re-entrancy; hyprctl layers as truth signal; NixOS Home Manager.

## Global Constraints

Copied verbatim from `2026-06-26-landscape-standalone-design.md` and the `standard-os` skill — every task inherits these.

- `eww.scss` MUST be strictly ASCII. Grep `[^\x00-\x7f]` before saving any `.scss` edit; one em-dash makes grass-rs emit `@charset "UTF-8";` and GTK 3 silently drops the whole stylesheet.
- Every `:focusable` setting on a `defwindow landscape` MUST be `false`. eww 0.6.0 translates `:focusable true` to gtk-layer-shell `keyboard-interactivity=exclusive`, which bypasses Hyprland's keybind dispatcher and bricks BOTH Esc binds in the submap. This was the actual cause of the 2026-06-25 reboot incident on the canvas; do not re-introduce the failure mode on the new window.
- No error pill on OPTIONS. `eww open` failures, `grim` failures, daemon crashes — all silent. Logs only.
- Cache writes MUST be atomic (`tmp + mv -f`). No new cache files in this stream, but the daemon's existing pattern stays untouched.
- After any `*.conf` or `*.nix` change: `sudo nixos-rebuild switch` (NOT `test`). `test` activates in RAM only and the new submap binds vanish after reboot.
- After any `eww.yuck` / `eww.scss` change: `eww reload`. (Both files are out-of-store symlinks per `feedback_waybar_source_edits_and_out_of_store_symlinks` — edits are live, but the eww daemon needs a reload to pick them up.)
- After any `hypr/modules/*.conf` change: `sudo nixos-rebuild switch` then `hyprctl reload` (per `feedback_hypr_config_needs_rebuild` — hypr configs are NOT live like waybar's).
- Commit discipline (`/etc/nixos/home` IS a git repo): commit each task's deliverable before starting the next. Use explicit file paths, never `git add -A`, per `project_canvas_prefs_polish_in_flight` — the canvas-prefs polish stream may still be dirty later.
- No new error pill on OPTIONS. Failures are silent (logs only).

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `widgets/scripts/landscape-open` | Create | Touch `open-trigger`, compute monitor size via shared `lib/canvas-anchor.sh`, `exec eww open landscape --size WxH`. |
| `widgets/scripts/landscape-close` | Create | flock-guarded three-tier dismiss: submap reset → `eww close landscape` → count-decrement verify → restart `standardos-canvas.service` on failure. |
| `widgets/scripts/landscape-panic` | Create | Skip graceful, run submap reset → `eww close landscape` → count-decrement verify → service restart unconditionally if not verified. |
| `tests/wave3/test_landscape_exit_invariant.sh` | Create | Static guard: `:focusable false` on `defwindow landscape`; `submap = landscape-open` with both Esc and Super+Shift+Esc binds. |
| `widgets/eww/eww.yuck` | Modify | Remove v0 Landscape from canvas (section-pill, canvas body branch, `defwidget ls-cell`, `defwidget landscape-section`). Add `defwidget landscape-grid` (3×3 of `(image)`). Add `defwindow landscape` peer. |
| `widgets/eww/eww.scss` | Modify | Remove v0 `.ls-grid`/`.ls-cell`/`.ls-cell-current`/`.ls-shot`/`.ls-empty`. Add `window#landscape .lg-grid` + `.lg-cell` + `.lg-shot`. Strictly ASCII. |
| `hypr/modules/Binds.conf` | Modify | Replace `bind = $mainMod SHIFT, S, movewindow, d` with `$mainMod ALT, S`. Rebind Super+RETURN exec+submap from canvas-open to landscape-open. Add Super+Shift+S → canvas-open. Add `submap = landscape-open` block. Update cross-file invariant comments. |
| `scripts/canvas-close` | Modify | Switch verify from presence-of-surface to count-decrement (BEFORE/AFTER snapshots of overlay gtk-layer-shell count). Required so verify still works once Landscape is a peer surface. |
| `scripts/canvas-panic` | Modify | Same count-decrement verify update. |
| `widgets/scripts/canvas-jump-ws` | Modify | Tail `exec`s a small two-call close ladder (`landscape-close` + `canvas-close`) instead of just `canvas-close`. |
| `waybar/TODO.md` | Modify (post-ship) | Append DONE entry with Hint line. |

Ten files: four created, seven modified. Daemon (`landscape-snap-daemon.sh`), nix module (`landscape-snap.nix`), listener (`canvas-landscape-listen`), cold-start placeholder (`widgets/svg/_blank.svg`) — all reused unchanged.

---

## Task 1: canvas-close + canvas-panic count-decrement verify (pre-flight)

**Why first.** The verify update is required before Landscape can exist — once a second eww layer-shell surface is on screen, the v1 presence-check in canvas-close produces a false positive on every canvas dismiss. Land this BEFORE wiring Landscape so we never have an in-tree intermediate state where canvas Esc misfires.

**Files:**
- Modify: `/etc/nixos/home/scripts/canvas-close`
- Modify: `/etc/nixos/home/scripts/canvas-panic`
- Test: manual — open canvas, Esc, check `hyprctl layers` for clean closure

**Interfaces:**
- Consumes: `hyprctl layers`, `eww close dashboard`, `systemctl --user`
- Produces: same `exit 0` contract as v1; verify signal is now count-based instead of presence-based

- [ ] **Step 1: Read current `canvas-close` (already done in design phase).** No code change — proceed.

- [ ] **Step 2: Define the helper inline in both scripts.**

Add this small helper above the Tier-3 line in BOTH `canvas-close` and `canvas-panic`:

```bash
# Count overlay-level gtk-layer-shell surfaces RIGHT NOW.
# Returns "0" on any failure (timeout, non-zero exit, parse error).
# We use count-decrement instead of presence-of-surface so the verify
# stays correct once a second eww layer-shell surface (Landscape) is
# allowed to coexist with the dashboard.
overlay_gls_count() {
    local layers overlay
    if ! layers=$(timeout 1 hyprctl layers 2>/dev/null); then
        echo 0; return
    fi
    overlay=$(awk '
        /Layer level 3 \(overlay\):/ { flag=1; next }
        /Layer level [0-9]+ \(/      { flag=0 }
        flag
    ' <<<"$layers")
    grep -c 'namespace: gtk-layer-shell' <<<"$overlay" || echo 0
}
```

- [ ] **Step 3: Replace the verify block in `canvas-close`.**

Replace lines 67-77 of `/etc/nixos/home/scripts/canvas-close`:

```bash
verified_closed=0
if layers=$(timeout 1 hyprctl layers 2>/dev/null); then
    overlay=$(awk '
        /Layer level 3 \(overlay\):/ { flag=1; next }
        /Layer level [0-9]+ \(/      { flag=0 }
        flag
    ' <<<"$layers")
    if ! grep -q 'namespace: gtk-layer-shell' <<<"$overlay"; then
        verified_closed=1
    fi
fi
```

with this (also moving the BEFORE snapshot earlier in the script, see Step 4 for placement):

```bash
# Verify: did the overlay gtk-layer-shell count actually decrement?
# A presence check would falsely say "still up" whenever Landscape is
# also open. Count-decrement honors the case where dashboard cleanly
# closed while Landscape stays.
sleep 0.15
after=$(overlay_gls_count)
verified_closed=0
[ "$after" -lt "$before" ] && verified_closed=1
```

- [ ] **Step 4: Add the BEFORE snapshot in `canvas-close`.**

Right after the flock acquire (after line 40, before the Tier-3 `submap reset`), insert:

```bash
# Snapshot the count BEFORE any dismiss action so the verify in Tier 1
# can detect a real decrement rather than just an absence.
before=$(overlay_gls_count)
```

Also paste the `overlay_gls_count` helper from Step 2 above this line (or above `set -u`, either works — bash allows function definitions before use).

- [ ] **Step 5: Apply the same patch to `canvas-panic`.**

Same helper + same BEFORE snapshot (right after `set -u`) + same AFTER+verify block (replacing lines 39-49).

- [ ] **Step 6: Functional test — canvas alone.**

```bash
# Open and dismiss canvas via Esc, confirm it actually closes.
/etc/nixos/home/scripts/canvas-open &
sleep 0.5
hyprctl layers 2>&1 | awk '/overlay/,/^$/' | grep -c gtk-layer-shell
# Expected: 1 (dashboard is up).

/etc/nixos/home/scripts/canvas-close
sleep 0.3
hyprctl layers 2>&1 | awk '/overlay/,/^$/' | grep -c gtk-layer-shell
# Expected: 0.
```

If the count doesn't drop, Tier 2 should fire from inside canvas-close. Inspect `journalctl --user -u standardos-canvas.service -n 20` for the restart line.

- [ ] **Step 7: Commit.**

```bash
cd /etc/nixos/home
git add scripts/canvas-close scripts/canvas-panic
git commit -m "canvas-close/panic: count-decrement verify (Landscape-peer-ready)"
```

---

## Task 2: `canvas-jump-ws` heuristic close

**Why now.** Single tiny line change; isolating it keeps Task 1's diff narrow and Task 3+ free to assume the click handler already routes correctly. Also exercised as a side effect by the rest of the work.

**Files:**
- Modify: `/etc/nixos/home/widgets/scripts/canvas-jump-ws`

**Interfaces:**
- Consumes: `landscape-close` (created Task 4), `canvas-close`
- Produces: same one-arg API; tail now closes BOTH surfaces (each no-ops if its window isn't open)

- [ ] **Step 1: Replace the tail.**

Current contents (line 7):
```bash
exec /etc/nixos/home/scripts/canvas-close
```

Replace with:
```bash
# Close whichever surface invoked us. Both scripts are no-ops if their
# target window isn't open, so issuing both is cheap and correct without
# the caller needing to identify itself.
/etc/nixos/home/widgets/scripts/landscape-close >/dev/null 2>&1 &
exec /etc/nixos/home/scripts/canvas-close
```

(Note: `landscape-close` does not yet exist at this point in the plan — it lands in Task 4. The script will function as long as Task 4 commits BEFORE the click path is exercised in production. For Task 2's commit, the missing file is fine because the click handler is only reachable from the v0 Landscape, which is being torn down in Task 5 anyway. Order: Task 1 → Task 2 (this) → Task 4 (landscape-close exists) → Task 5 (v0 removal + new defwindow uses canvas-jump-ws).)

- [ ] **Step 2: Commit.**

```bash
cd /etc/nixos/home
git add widgets/scripts/canvas-jump-ws
git commit -m "canvas-jump-ws: close both surfaces (Landscape + dashboard)"
```

---

## Task 3: `landscape-open` script

**Why next.** Independent of the eww/window changes; testable on its own by invoking the script and checking the open-trigger fired and the eww open call was attempted.

**Files:**
- Create: `/etc/nixos/home/widgets/scripts/landscape-open`

**Interfaces:**
- Consumes: `/etc/nixos/home/scripts/lib/canvas-anchor.sh`, `eww`, the (yet-to-be-added) `defwindow landscape`
- Produces: side effect — `eww open landscape` invoked; `/tmp/standardos/landscape/open-trigger` touched

- [ ] **Step 1: Write the script.**

Use `Write` to create `/etc/nixos/home/widgets/scripts/landscape-open`:

```bash
#!/usr/bin/env bash
# landscape-open — open the StandardOS Landscape (3x3 workspace expose).
# Wired to Super+RETURN via hypr/modules/Binds.conf.
#
# Peer of scripts/canvas-open. Two surfaces share the eww daemon and the
# landscape-snap data plane; they are otherwise independent.
#
# Touching open-trigger wakes landscape-snap-daemon (inotify on the
# parent dir) so the focused workspace re-grims the moment Landscape
# appears.
#
# --size passes the monitor's logical pixel size because eww's geometry
# "100%" computes against the workarea (below the waybar) and falls
# short of the full monitor by the bar height. Anchor "center" in the
# defwindow keeps Hyprland from applying the bar's exclusive-zone
# offset.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-anchor.sh
read -r _x _y w h < <(canvas_geometry_for_open)

mkdir -p /tmp/standardos/landscape && touch /tmp/standardos/landscape/open-trigger

exec eww open landscape --size "${w}x${h}"
```

- [ ] **Step 2: Make executable.**

```bash
chmod +x /etc/nixos/home/widgets/scripts/landscape-open
```

- [ ] **Step 3: Smoke test (will fail to open until Task 5 adds the defwindow).**

```bash
/etc/nixos/home/widgets/scripts/landscape-open; echo "exit=$?"
ls -l /tmp/standardos/landscape/open-trigger
```

Expected: exit 1 (eww exits non-zero because `landscape` window is not defined yet), but `open-trigger` exists with a fresh mtime. The trigger touch is what we're verifying at this stage. Eww logs `unknown window 'landscape'` — fine, will be resolved in Task 5.

- [ ] **Step 4: Commit.**

```bash
cd /etc/nixos/home
git add widgets/scripts/landscape-open
git commit -m "landscape-open: opener script (peer of canvas-open)"
```

---

## Task 4: `landscape-close` + `landscape-panic` scripts

**Why next.** Built before the eww window so by the time the window exists (Task 5) the close path is already in place. The count-decrement verify pattern from Task 1 is reused — copy the same helper.

**Files:**
- Create: `/etc/nixos/home/widgets/scripts/landscape-close`
- Create: `/etc/nixos/home/widgets/scripts/landscape-panic`

**Interfaces:**
- Consumes: `hyprctl`, `eww`, `systemctl --user restart standardos-canvas.service`, `flock`
- Produces: `exit 0` contract (same as canvas-close/panic)

- [ ] **Step 1: Write `landscape-close`.**

```bash
#!/usr/bin/env bash
# landscape-close — dismiss the StandardOS Landscape. Bulletproof exit.
# Peer of scripts/canvas-close; same three-tier strategy.
#
# Tier 1 — graceful: reset Hyprland submap (keyboard always recovers),
# ask eww to close the landscape window. Verify via overlay
# gtk-layer-shell surface count decrement.
#
# Tier 2 — hard restart: if verify shows no decrement OR verify itself
# times out, bounce standardos-canvas.service. The service has
# Restart=always RestartSec=1, comes back clean in ~1 s. A fresh daemon
# cannot have a stuck surface. The eww daemon hosts BOTH surfaces, so
# this also takes down dashboard if it was open — acceptable, the user
# is in a wedged state at that point.
#
# Tier 3 — keyboard recovery: submap reset runs FIRST unconditionally.
# Keyboard is back regardless of what eww does.
#
# Locking: flock -n coalesces mashed-Esc presses.

set -u

LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/landscape-close.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

# Count overlay-level gtk-layer-shell surfaces NOW. Returns "0" on any
# failure. Used by Tier 1 verify (count-decrement, not presence).
overlay_gls_count() {
    local layers overlay
    if ! layers=$(timeout 1 hyprctl layers 2>/dev/null); then
        echo 0; return
    fi
    overlay=$(awk '
        /Layer level 3 \(overlay\):/ { flag=1; next }
        /Layer level [0-9]+ \(/      { flag=0 }
        flag
    ' <<<"$layers")
    grep -c 'namespace: gtk-layer-shell' <<<"$overlay" || echo 0
}

before=$(overlay_gls_count)

# Tier 3 first: keyboard always recovers, regardless of what eww does.
timeout 1 hyprctl dispatch submap reset >/dev/null 2>&1 || true

# Tier 1: graceful close.
timeout 1 eww close landscape >/dev/null 2>&1 || true

# Tier 1 verify: count decremented?
sleep 0.15
after=$(overlay_gls_count)
verified_closed=0
[ "$after" -lt "$before" ] && verified_closed=1

if [ "$verified_closed" -eq 0 ]; then
    # Tier 2: hard restart of the shared eww daemon.
    systemctl --user restart standardos-canvas.service >/dev/null 2>&1 || true
fi

exit 0
```

- [ ] **Step 2: Write `landscape-panic`.**

```bash
#!/usr/bin/env bash
# landscape-panic — emergency dismiss for StandardOS Landscape.
# Peer of scripts/canvas-panic; same tiers, no flock (panic is invoked
# precisely when graceful is suspected wedged).

set -u

overlay_gls_count() {
    local layers overlay
    if ! layers=$(timeout 1 hyprctl layers 2>/dev/null); then
        echo 0; return
    fi
    overlay=$(awk '
        /Layer level 3 \(overlay\):/ { flag=1; next }
        /Layer level [0-9]+ \(/      { flag=0 }
        flag
    ' <<<"$layers")
    grep -c 'namespace: gtk-layer-shell' <<<"$overlay" || echo 0
}

before=$(overlay_gls_count)

timeout 1 hyprctl dispatch submap reset >/dev/null 2>&1 || true
timeout 1 eww close landscape >/dev/null 2>&1 || true

sleep 0.15
after=$(overlay_gls_count)
verified_closed=0
[ "$after" -lt "$before" ] && verified_closed=1

if [ "$verified_closed" -eq 0 ]; then
    systemctl --user restart standardos-canvas.service >/dev/null 2>&1 || true
fi

exit 0
```

- [ ] **Step 3: Make executable.**

```bash
chmod +x /etc/nixos/home/widgets/scripts/landscape-close \
         /etc/nixos/home/widgets/scripts/landscape-panic
```

- [ ] **Step 4: Smoke test (script runs without erroring, even though landscape isn't open).**

```bash
/etc/nixos/home/widgets/scripts/landscape-close; echo "exit=$?"
# Expected: exit=0 (graceful close of a non-open window is a no-op).
```

- [ ] **Step 5: Commit.**

```bash
cd /etc/nixos/home
git add widgets/scripts/landscape-close widgets/scripts/landscape-panic
git commit -m "landscape-close + landscape-panic: three-tier dismiss + verify"
```

---

## Task 5: eww — remove v0 Landscape, add new defwindow

The biggest single edit. Five separate edits to `eww.yuck` and one to `eww.scss`. Land them as ONE commit because they all touch the same surface (canvas section-nav, canvas body, landscape widget defs, defwindow). A staged commit per edit would leave the tree in a broken state where (e.g.) the section-pill references a section that no longer renders.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck`
- Modify: `/etc/nixos/home/widgets/eww/eww.scss`

**Interfaces:**
- Consumes: `ws-paths` deflisten (already defined), `canvas-jump-ws` (updated in Task 2)
- Produces: `defwindow landscape` (consumed by `landscape-open` from Task 3) — section-nav no longer includes a Landscape pill

- [ ] **Step 1: Remove the `landscape` section-pill from `section-nav`.**

At line 172 of `eww.yuck`, change:
```yuck
    (section-pill :id "location"  :label "Location")
    (section-pill :id "landscape" :label "Landscape")))
```
to:
```yuck
    (section-pill :id "location"  :label "Location")))
```

- [ ] **Step 2: Remove the canvas body's `landscape` branch.**

At lines 518-520 of `eww.yuck`, delete:
```yuck
        (box :visible {current-section == "landscape"} :orientation "vertical"
             :hexpand true :vexpand true :halign "fill" :valign "fill"
          (landscape-section))))
```
and add a `)` to the previous line's closing parens so the `canvas` defwidget body closes cleanly:
```yuck
        (section-slot :id "security" :name "Security and privacy")
        (section-slot :id "location" :name "Location")))
```

(Count the parens carefully — `section-slot` returns its own widget so the closing `)))` belongs to it + the section-body box + the canvas-root box.)

- [ ] **Step 3: Remove `defwidget ls-cell` and `defwidget landscape-section`.**

In `eww.yuck` lines 445-466 (approximately), delete the two defwidgets entirely. Verify by searching: `grep -n "ls-cell\|landscape-section" eww.yuck` should return zero matches after the edit.

- [ ] **Step 4: Add `defwidget landscape-grid` near where `landscape-section` used to live.**

Add this defwidget at the same location (just before `section-placeholder`):

```yuck
;; --- Landscape (standalone defwindow) ----------------------------------
;;
;; 3x3 grid of cached workspace screenshots. Cells fill the screen
;; edge-to-edge with a 14px gutter between them. Click any cell to
;; jump to that workspace and dismiss. No current-cell highlight, no
;; chrome of any kind -- only the 9 thumbnails by user direction
;; 2026-06-26.
;;
;; Data plane: `ws-paths` deflisten (defined near the top of this file)
;; emits {ws1..ws9: "/tmp/standardos/landscape/ws-N.png?t=mtime" or
;; "/etc/nixos/home/widgets/svg/_blank.svg"} on every manifest change.
;; The cache-buster `?t=mtime` suffix forces gtk-image to reload on
;; file change.

(defwidget lg-cell [n]
  (eventbox :class "lg-cell"
            :onclick "/etc/nixos/home/widgets/scripts/canvas-jump-ws ${n}"
    (image :class "lg-shot"
           :path {jq(ws-paths, ".ws${n}", "r")}
           :image-width 540 :image-height 340)))

(defwidget landscape-grid []
  (box :class "lg-grid" :orientation "vertical" :space-evenly true :spacing 14
       :hexpand true :vexpand true :halign "fill" :valign "fill"
    (box :orientation "horizontal" :space-evenly true :spacing 14
         :hexpand true :vexpand true
      (lg-cell :n "1") (lg-cell :n "2") (lg-cell :n "3"))
    (box :orientation "horizontal" :space-evenly true :spacing 14
         :hexpand true :vexpand true
      (lg-cell :n "4") (lg-cell :n "5") (lg-cell :n "6"))
    (box :orientation "horizontal" :space-evenly true :spacing 14
         :hexpand true :vexpand true
      (lg-cell :n "7") (lg-cell :n "8") (lg-cell :n "9"))))
```

(`:image-width 540 :image-height 340` is a starting size for a 1600x1000 screen; gtk-image scales the underlying PNG to fit. The `:hexpand true :vexpand true` on the parent boxes does the layout work — the image numbers just give gtk an aspect-ratio hint. Tune in Task 7 after the first render.)

- [ ] **Step 5: Add `defwindow landscape`.**

After the existing `(defwindow dashboard …)` block (around line 553), append:

```yuck
;; --- Landscape window ---
;;
;; Peer of `defwindow dashboard`. Opened by widgets/scripts/landscape-open,
;; closed by widgets/scripts/landscape-close. Both share the eww daemon
;; (standardos-canvas.service) and the landscape-snap data plane.
;;
;; CRITICAL -- :focusable MUST stay false. Same gtk-layer-shell rule
;; as the dashboard above: :focusable true => keyboard-interactivity=
;; exclusive => Wayland routes Esc and Super+Shift+Esc to eww instead
;; of Hyprland, both submap binds (landscape-close + landscape-panic)
;; silently never fire, user is keyboard-trapped on the surface.
;; tests/wave3/test_landscape_exit_invariant.sh enforces this.

(defwindow landscape
  :monitor 0
  :geometry (geometry :x "0%" :y "0%" :width "100%" :height "100%" :anchor "center")
  :stacking "overlay"
  :exclusive false
  :focusable false
  (landscape-grid))
```

- [ ] **Step 6: Update `eww.scss` — remove v0 Landscape rules.**

Open `eww.scss`. At lines ~388-407 (`.ls-grid`, `.ls-cell`, `.ls-cell-current`, `.ls-shot`, `.ls-empty`), delete the entire block. Replace with:

```scss
/* Landscape -- standalone defwindow. Edge-to-edge 3x3 grid of cached
   workspace screenshots, no chrome. The eww image widget scales the
   underlying PNG to its allocated box. */
window#landscape .lg-grid {
    padding: 0;
}

window#landscape .lg-cell {
    background-color: transparent;
}

window#landscape .lg-shot {
    /* gtk-image inherits its size from :image-width/:image-height; no
       border-radius because cells touch screen edges. */
}
```

- [ ] **Step 7: ASCII scan of `eww.scss`.**

```bash
grep -P '[^\x00-\x7f]' /etc/nixos/home/widgets/eww/eww.scss && echo FAIL || echo OK
```
Expected: `OK`. If FAIL, fix any em-dash / curly quote / non-ASCII char.

- [ ] **Step 8: Reload eww (the daemon picks up the new yuck + scss).**

```bash
eww reload
```
Expected: silent exit 0. If parse error: re-count parens in `landscape-grid` and `defwindow landscape`. If `unknown widget`: check that `lg-cell` is defined before `landscape-grid`.

- [ ] **Step 9: Open Landscape via the script.**

```bash
/etc/nixos/home/widgets/scripts/landscape-open
```
Expected: the 9-cell grid renders. Already-cached workspaces show their screenshot. Never-visited ones render `_blank.svg`. No section-nav, no pills, no chrome.

Note: at this point Super+RETURN still opens the canvas (Binds.conf is patched in Task 6). For now invoke the script directly to test the surface.

- [ ] **Step 10: Click a populated cell.**

Open one or two side workspaces first (manually move there and back so the snapshot daemon caches them), then trigger Landscape again and click a cell.

Expected: workspace switches AND Landscape closes. (`canvas-jump-ws` dispatches `hyprctl workspace N`, then issues both `landscape-close` and `canvas-close`; the latter is a no-op since canvas isn't open.)

- [ ] **Step 11: Commit.**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck widgets/eww/eww.scss
git commit -m "landscape: standalone defwindow + 3x3 grid, remove v0 from canvas"
```

---

## Task 6: Hyprland binds rewire + new submap

The bind layer. Super+RETURN → landscape, Super+Shift+S → canvas, Super+Alt+S → movewindow d. New `submap = landscape-open` block. Hypr config is NOT live — needs `nixos-rebuild switch` AND `hyprctl reload`.

**Files:**
- Modify: `/etc/nixos/home/hypr/modules/Binds.conf`

**Interfaces:**
- Consumes: `landscape-open`, `landscape-close`, `landscape-panic` (Tasks 3 + 4), `canvas-open`, `canvas-close`, `canvas-panic` (existing)
- Produces: 3 user-visible binds, 1 new submap, no surface conflict

- [ ] **Step 1: Migrate `movewindow d`.**

At line 29 of `Binds.conf`:

```
bind = $mainMod SHIFT, S, movewindow, d
```

Change to:

```
# movewindow d migrated from $mainMod SHIFT, S to $mainMod ALT, S on
# 2026-06-26 to free Super+Shift+S for the Control Center surface.
# The other three move-direction binds (A/W/D) are unchanged.
bind = $mainMod ALT, S, movewindow, d
```

- [ ] **Step 2: Rewire Super+RETURN to landscape-open.**

At lines 116-117:

```
bind = $mainMod, RETURN, exec, /etc/nixos/home/scripts/canvas-open
bind = $mainMod, RETURN, submap, canvas-open
```

Change to:

```
bind = $mainMod, RETURN, exec, /etc/nixos/home/widgets/scripts/landscape-open
bind = $mainMod, RETURN, submap, landscape-open
```

- [ ] **Step 3: Add Super+Shift+S → canvas-open (Control Center).**

Immediately after the Super+RETURN binds (above the existing `submap = canvas-open` block), add:

```
# Control Center -- StandardOS canvas under its own bind. Moved off
# Super+RETURN on 2026-06-26 when Landscape was promoted to standalone.
bind = $mainMod SHIFT, S, exec, /etc/nixos/home/scripts/canvas-open
bind = $mainMod SHIFT, S, submap, canvas-open
```

- [ ] **Step 4: Add the `landscape-open` submap.**

After the existing `submap = canvas-open` ... `submap = reset` block (ends at line 126), add:

```
submap = landscape-open
bind = , ESCAPE, exec, /etc/nixos/home/widgets/scripts/landscape-close
# Panic bound inside the submap for the same reason as canvas-open:
# Hyprland only fires binds from the active submap, so the default-
# level $mainMod SHIFT, ESCAPE above does not fire while inside this
# submap. Mirror it here so it is reachable from the state it rescues.
bind = $mainMod SHIFT, ESCAPE, exec, /etc/nixos/home/widgets/scripts/landscape-panic
submap = reset
```

- [ ] **Step 5: Update the comment block above the Super+RETURN bind.**

The long comment block lines 67-115 currently says "Super+RETURN opens the Dashboard." Update the opening summary line to reflect the bind change:

Replace line 68 from:
```
# StandardOS widget canvas — Super+RETURN opens the Dashboard;
```
to:
```
# StandardOS shell surfaces — Super+RETURN opens Landscape; Super+Shift+S
# opens the Dashboard (Control Center). Both persist until Esc dismisses.
```

(Don't rewrite the whole block — the cross-file invariant warnings about `:focusable` apply to BOTH defwindows now and the wording stays correct.)

- [ ] **Step 6: Rebuild and switch.**

```bash
sudo nixos-rebuild switch
```
Expected: exits 0. Then:
```bash
hyprctl reload
```
Expected: silent exit 0.

- [ ] **Step 7: Manual acceptance — binds.**

1. Press Super+Alt+S with a focused window → window moves down. (`movewindow d` migrated.)
2. Press Super+RETURN → Landscape opens edge-to-edge.
3. Press Esc → Landscape closes (`hyprctl layers` shows no overlay gtk-layer-shell).
4. Press Super+Shift+S → Control Center opens (the canvas, section-nav with 15 pills, no Landscape pill).
5. Press Esc → Control Center closes.
6. Press Super+RETURN, then immediately press Super+Shift+S → both visible (CC stacks on top of Landscape).
7. Press Esc → CC closes, Landscape remains. Press Esc → Landscape closes.

If step 6 fails (only one closes per Esc, or wrong one closes), it is because both submaps are in different states than expected — the LAST submap opened wins. This is correct behavior: Super+Shift+S enters `canvas-open` submap, so Esc → `canvas-close`. Once CC closes, the submap is `reset` (the canvas-open submap's exit), NOT `landscape-open`. So the second Esc is the default-level Esc bind (`systemctl hibernate`!). This is a real hazard — see Step 8.

- [ ] **Step 8: Resolve the second-Esc hazard.**

If the manual acceptance step 7 reveals that the second Esc triggers `systemctl hibernate` instead of `landscape-close`, the cleanest fix is to teach the user that Landscape must be Esc'd FIRST (or canvas-close itself re-enters `landscape-open` submap if landscape is still up). The latter is heavier but more robust.

For v0 of this stream, accept the hazard and document it in the TODO.md hint. The simple workaround: dismiss surfaces in LIFO order (the visible top one first). Most-recently-opened is what Esc dismisses regardless.

- [ ] **Step 9: Commit.**

```bash
cd /etc/nixos/home
git add hypr/modules/Binds.conf
git commit -m "binds: Super+RETURN -> landscape, Super+Shift+S -> canvas, Super+Alt+S -> movewindow d"
```

---

## Task 7: Cell-size tune

After Task 6, Landscape is live. The hardcoded `:image-width 540 :image-height 340` from Task 5 was a guess for a typical 1600x1000 screen. Adjust visually so cells fill the screen edge-to-edge without leaving black bars.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (one number pair on the `image` widget)
- Optional modify: `/etc/nixos/home/widgets/eww/eww.scss`

**Interfaces:**
- Consumes: same as Task 5
- Produces: same as Task 5; visual tune only

- [ ] **Step 1: Open Landscape, observe.**

```
Super+RETURN
```

Check: do the 9 cells fill the screen with a uniform 14px gutter between them? If there are black bars on the sides, the image is too small. If cells overflow, image is too large.

- [ ] **Step 2: Compute target cell size from monitor.**

```bash
hyprctl monitors -j | jq -r '.[] | select(.focused) | "\(.width)x\(.height)"'
```
e.g. `1600x1000`. Target cell width ≈ (W - 14*4) / 3 ≈ (1600 - 56) / 3 ≈ 514. Target cell height ≈ (H - 14*4) / 3 ≈ (1000 - 56) / 3 ≈ 314.

- [ ] **Step 3: Update `:image-width` and `:image-height`.**

In `defwidget lg-cell`, change the `(image …)` line's `:image-width` and `:image-height` to the computed values from Step 2.

- [ ] **Step 4: Reload eww and reopen.**

```bash
eww reload
/etc/nixos/home/widgets/scripts/landscape-close
sleep 0.3
/etc/nixos/home/widgets/scripts/landscape-open
```

Expected: edge-to-edge 3x3, even gutter, no black borders.

- [ ] **Step 5: Commit.**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck
git commit -m "landscape-grid: tune cell size for monitor"
```

---

## Task 8: Static guard test

Mirror of `test_canvas_exit_invariant.sh`. Will be picked up by whatever test harness runs `tests/wave3/`.

**Files:**
- Create: `/etc/nixos/home/tests/wave3/test_landscape_exit_invariant.sh`

**Interfaces:**
- Consumes: `widgets/eww/eww.yuck`, `hypr/modules/Binds.conf`
- Produces: exit 0 if invariants hold; exit (number of failures) otherwise

- [ ] **Step 1: Write the test.**

```bash
#!/usr/bin/env bash
# test_landscape_exit_invariant — guards the static invariant that makes
# the Landscape Esc / Super+Shift+Esc binds reachable.
#
# Mirror of test_canvas_exit_invariant. Both surfaces share the same
# failure mode: :focusable true on the eww defwindow leaks
# keyboard-interactivity=exclusive to the compositor, which routes Esc
# to eww and bypasses Hyprland's keybind dispatcher. Both submap binds
# silently never fire and the user is trapped on the surface until
# external recovery (Super+Shift+Esc only works because it is ALSO
# bound here -- breaking that invariant retraps the user).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
YUCK="$ROOT/widgets/eww/eww.yuck"
BINDS="$ROOT/hypr/modules/Binds.conf"

pass=0; fail=0
check() {
    local name="$1" cond="$2"
    if eval "$cond"; then
        echo "PASS $name"; ((++pass))
    else
        echo "FAIL $name"; ((++fail))
    fi
}

# 1. defwindow landscape block exists and explicitly sets :focusable false.
window_block=$(awk '/\(defwindow landscape/,/\(landscape-grid\)\)/' "$YUCK")
check "landscape defwindow present" '[[ -n "$window_block" ]]'
check "landscape :focusable is false" \
    'grep -qE ":focusable[[:space:]]+false" <<<"$window_block"'
check "landscape :focusable is NOT true" \
    '! grep -qE ":focusable[[:space:]]+true" <<<"$window_block"'

# 2. landscape-open submap still has both Esc binds.
check "landscape-open submap declared" \
    'grep -qE "^submap = landscape-open" "$BINDS"'
check "submap Esc bind present" \
    'grep -qE "^bind = , ESCAPE, exec, .*/landscape-close" "$BINDS"'
check "submap panic bind present" \
    'grep -qE "^bind = .*SHIFT, ESCAPE, exec, .*/landscape-panic" "$BINDS"'

echo
echo "passed: $pass, failed: $fail"
exit "$fail"
```

- [ ] **Step 2: Make executable + run.**

```bash
chmod +x /etc/nixos/home/tests/wave3/test_landscape_exit_invariant.sh
/etc/nixos/home/tests/wave3/test_landscape_exit_invariant.sh
```
Expected: `passed: 6, failed: 0`, exit 0.

- [ ] **Step 3: Run the existing canvas test to ensure no regression.**

```bash
/etc/nixos/home/tests/wave3/test_canvas_exit_invariant.sh
```
Expected: still passes (canvas defwindow + submap unchanged).

- [ ] **Step 4: Commit.**

```bash
cd /etc/nixos/home
git add tests/wave3/test_landscape_exit_invariant.sh
git commit -m "tests/wave3: landscape exit invariant guard"
```

---

## Task 9: Full acceptance + TODO.md DONE entry

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

**Interfaces:**
- Consumes: nothing
- Produces: documented DONE entry

- [ ] **Step 1: Full acceptance script.**

Walk through the design spec's manual acceptance list (steps 1-10 in the "Manual acceptance" section of the spec). Specifically:

1. Super+Alt+S moves window down.
2. Super+Shift+S opens CC; section-nav has 15 pills (no Landscape).
3. Esc in CC closes it; `hyprctl layers` confirms.
4. Super+RETURN opens Landscape; only 9 cells visible.
5. Esc in Landscape closes it; `hyprctl layers` confirms.
6. Open Landscape, then CC; both visible; Esc closes CC; Landscape stays.
7. Esc again closes Landscape (or, per Task 6 Step 8, the second Esc lands on the default-level bind — note the hazard in the DONE hint).
8. Click cell N → workspace N + Landscape closes.
9. Reopen Landscape after workspace change; that cell's content reflects current.
10. `pkill -STOP eww` then Esc; Tier 2 restarts the eww daemon within ~2 s.

- [ ] **Step 2: Hazard audit.**

- [ ] `eww.scss` strictly ASCII? `grep -P '[^\x00-\x7f]' /etc/nixos/home/widgets/eww/eww.scss; echo $?` → must be 1.
- [ ] `:focusable false` on `defwindow landscape`? Static test passes.
- [ ] No error pill emission added? `grep -r "notify-send\|opt-" /etc/nixos/home/widgets/scripts/landscape-*` → no notify-send, no error-pill class writes.
- [ ] `nixos-rebuild switch` (not `test`) used after Binds.conf change? Yes — Task 6 Step 6.
- [ ] Both static guard tests pass?

- [ ] **Step 3: Append DONE entry to `waybar/TODO.md`.**

At the top of the DONE list (newest first):

```markdown
- **2026-06-26** — **landscape: standalone defwindow, separate from canvas.**
  Landscape promoted out of the canvas: new `defwindow landscape` peer of
  `defwindow dashboard`, sharing the eww daemon and the landscape-snap
  data plane but otherwise independent. Super+RETURN rebound from
  canvas-open to landscape-open; Super+Shift+S takes over Control
  Center; Super+Alt+S takes over the `movewindow d` that previously
  lived on Super+Shift+S. The v0 inline-in-canvas Landscape (16th
  section-pill, `defwidget landscape-section`, `defwidget ls-cell`,
  `current-section == "landscape"` body branch) is fully removed —
  section-nav back to 15 pills. New surface is chromeless: 3x3 grid of
  `_blank.svg`-or-cached PNGs edge-to-edge with a 14 px gutter; no
  current-cell highlight, no pills, nothing. New
  `widgets/scripts/landscape-{open,close,panic}` mirror the canvas
  triplet. `canvas-close` and `canvas-panic` switched their verify
  signal from "any overlay gtk-layer-shell surface present" to
  "overlay gtk-layer-shell surface count decremented after dismiss"
  — required so the verify still works when Landscape is a peer
  surface (both share `namespace: gtk-layer-shell` under eww 0.6.0).
  `canvas-jump-ws` issues a two-call close ladder
  (`landscape-close` + `canvas-close`) so clicks from either surface
  dismiss correctly. New `tests/wave3/test_landscape_exit_invariant.sh`
  mirrors the canvas guard: enforces `:focusable false` on
  `defwindow landscape` and the submap binds for Esc and
  Super+Shift+Esc. **Hint:** when both surfaces are open and the user
  presses Esc twice, Hyprland's LIFO submap stack means the
  most-recently-opened submap exits first. Second Esc may fall through
  to the default-level Esc bind (`systemctl hibernate`) if the user
  hasn't re-entered a submap by other means — design intentionally
  did not solve this for v0 because the single-surface case is the
  common path. If reports surface, the fix is teaching canvas-close
  to re-enter the `landscape-open` submap when landscape is still up.
  Spec at
  `docs/superpowers/specs/2026-06-26-landscape-standalone-design.md`;
  plan at `docs/superpowers/plans/2026-06-26-landscape-standalone.md`.
```

- [ ] **Step 4: Commit.**

```bash
cd /etc/nixos/home
git add waybar/TODO.md
git commit -m "landscape-standalone: TODO.md DONE entry"
```

- [ ] **Step 5: Final tree audit.**

```bash
cd /etc/nixos/home && git status -s
```
Expected: empty. Anything left is an unrelated stream.

---

## Self-Review

**1. Spec coverage:**
- New defwindow landscape → Task 5 ✓
- 3x3 edge-to-edge grid → Task 5 + Task 7 ✓
- Super+RETURN → landscape-open → Task 6 ✓
- Super+Shift+S → canvas-open → Task 6 ✓
- Super+Alt+S → movewindow d → Task 6 ✓
- landscape-open / landscape-close / landscape-panic → Tasks 3 + 4 ✓
- Remove v0 from canvas (section-pill, body branch, defwidget ls-cell, defwidget landscape-section) → Task 5 ✓
- canvas-close + canvas-panic count-decrement verify → Task 1 ✓
- canvas-jump-ws heuristic close → Task 2 ✓
- Static guard test → Task 8 ✓
- TODO.md DONE entry → Task 9 ✓
- `:focusable false` baked into defwindow landscape from day one → Task 5 + Task 8 ✓
- Both surfaces share eww daemon → Task 4 design called out in comments ✓
- Coexistence of both surfaces → Task 6 Step 7 + acceptance ✓

**2. Placeholder scan.** None. The hardcoded `:image-width 540 :image-height 340` in Task 5 is explicitly placeholder-flagged: Task 7 tunes it for the actual monitor.

**3. Type/naming consistency.**
- `landscape-grid` defined in Task 5, consumed in Task 5's `defwindow landscape` body — same name.
- `lg-cell` / `lg-grid` / `lg-shot` SCSS classes referenced in Task 5 SCSS, matched in Task 5 yuck — consistent.
- `landscape-open` / `landscape-close` / `landscape-panic` script names consistent across Tasks 3, 4, 6, 8.
- `overlay_gls_count` helper has identical signature in canvas-close, canvas-panic, landscape-close, landscape-panic (Tasks 1 + 4).
- `ws-paths` deflisten (pre-existing) consumed in Task 5's `lg-cell` via `jq(ws-paths, ".ws${n}", "r")` — same pattern as the v0 widget being removed.
- `services.landscapeSnap.enable` — already enabled, no change.
