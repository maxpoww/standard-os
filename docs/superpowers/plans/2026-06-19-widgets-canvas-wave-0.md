# Widgets Canvas — Wave 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Holding Super+Return shows a full-screen translucent canvas with a huge clock in the HERO zone and labeled CROWN / FIELD placeholders. Releasing the key closes it.

**Architecture:** Eww runs as a systemd-user daemon. Hyprland's `bind`/`bindr` calls `eww open dashboard` on press and `eww close dashboard` on release. The Eww window is overlay-layer (gtk-layer-shell), full-screen, draws a dark veil + a clock label that polls `date(1)` every second. A shared `palette.css` defines StandardOS color tokens that future waves will reuse from Eww, hyprlock, and regreet.

**Tech Stack:** NixOS + home-manager, Eww (ElKowar's Wacky Widgets, GTK 3 + Yuck/SCSS), Hyprland.

## Global Constraints

- StandardOS spec defines all 12 widgets as the destination; this plan ships ONLY the canvas substrate + 1 widget (clock). Anything outside that scope is Wave 1+.
- Use `StandardOS` in all prose / commit messages / docs. CSS class identifiers may keep `opt-*` for parity with existing waybar styles.
- All edits to `/etc/nixos/home/hypr/modules/*.conf` require `sudo nixos-rebuild switch` (NOT `test`) and then `hyprctl reload` — the conf files are frozen in `/nix/store` via home-manager.
- All edits to files under `/etc/nixos/home/widgets/eww/` are LIVE via `mkOutOfStoreSymlink` once the Nix module exists — no rebuild needed for config-file iteration, only for module changes.
- Verification before claiming done: every claim of "the canvas works" must be backed by the user pressing Super+Return and seeing the result. No "tests pass therefore the UI is correct."
- TODO.md graduation: when Wave 0 ships, this work moves from `todonow.md` item #7 / #5 to `waybar/TODO.md` DONE with a Hint line.
- Commits use the existing waybar repo's style: lowercase scope prefix, short imperative summary, behavior-first language. Each task ends with one commit.

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `/etc/nixos/home/widgets/palette.css` | Create | Shared StandardOS color tokens as GTK `@define-color` declarations. Future waves (hyprlock, regreet) reference the same hex values. |
| `/etc/nixos/home/widgets/eww/palette.css` | Create | Symlink or copy of the shared palette (Eww imports it from `eww/`). Implementation: a relative `@import` in `eww.scss` to `../palette.css`, no separate file needed. |
| `/etc/nixos/home/widgets/eww/eww.scss` | Create | Eww-only styling. Imports palette tokens. Defines the dashboard window background (dark veil), zone placeholder text styling, and the HERO clock typography. |
| `/etc/nixos/home/widgets/eww/eww.yuck` | Create | Eww canvas root. Declares the clock poll variable, the `clock-hero` widget, and the `dashboard` window with the three zones. |
| `/etc/nixos/home/modules/widgets-canvas.nix` | Create | Home-manager module. Installs `pkgs.eww`, mkOutOfStoreSymlinks the three config files into `~/.config/eww/`, and runs `eww daemon` as a systemd-user service bound to graphical-session.target. |
| `/etc/nixos/home.nix` | Modify | Add `./home/modules/widgets-canvas.nix` to imports and `services.standardosCanvas.enable = true;`. |
| `/etc/nixos/home/hypr/modules/Binds.conf` | Modify | Add `bind` + `bindr` for `$mainMod, RETURN` calling `eww open dashboard` / `eww close dashboard`. |
| `/etc/nixos/home/waybar/TODO.md` | Modify | Add DONE entry after Wave 0 ships with two Hint lines (spec path + plan path). |
| `/etc/nixos/home/waybar/todonow.md` | Modify | Mark items #5 and #7 as "in flight (Wave 0)" with a back-reference to TODO.md. |

---

## Task 1: Scaffold the widgets/ directory + palette + Eww config files

**Files:**
- Create: `/etc/nixos/home/widgets/palette.css`
- Create: `/etc/nixos/home/widgets/eww/eww.scss`
- Create: `/etc/nixos/home/widgets/eww/eww.yuck`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `palette.css` defining color tokens: `@opt-surface-parent`, `@opt-surface-child`, `@opt-bar-veil`, `@opt-yes` (blue-state), `@opt-no` (red-state), `@opt-middle` (yellow-state), `@opt-violet`, `@opt-green`, `@opt-orange`, `@opt-text-on-dark`.
  - `eww.scss` importing the palette (relative path `../palette.css`).
  - `eww.yuck` exporting a window named `dashboard` and a polled variable named `time`.
  - Together they form the on-disk config that Task 2 will symlink into `~/.config/eww/`.

- [ ] **Step 1: Create the widgets/ + widgets/eww/ directories**

Run:
```bash
mkdir -p /etc/nixos/home/widgets/eww
```

Expected: directories exist; `ls /etc/nixos/home/widgets/eww/` returns empty (no errors).

- [ ] **Step 2: Write palette.css**

Create `/etc/nixos/home/widgets/palette.css` with:

```css
/*
 * StandardOS palette tokens — single source of truth for color across
 * Eww (Dashboard), hyprlock (Lock), and regreet (Greeter).
 *
 * Values mirror /etc/nixos/home/waybar/style.css §50-126. Keep in sync
 * if waybar's palette changes (waybar is canonical for the bar; this
 * file is canonical for the canvas surfaces).
 *
 * GTK CSS @define-color works in Eww. hyprlock / regreet pick up the
 * raw rgba() values manually (they don't share GTK CSS variables).
 */

/* Surfaces */
@define-color opt-bar-veil          rgba(128, 128, 128, 0.10);
@define-color opt-surface-parent    rgba(128, 128, 128, 0.30);
@define-color opt-surface-child     rgba(170, 170, 170, 0.30);

/* Hover (universal brighten film, layered via inset box-shadow on hover) */
@define-color opt-hover-bright      rgba(255, 255, 255, 0.30);

/* Primary state colors */
@define-color opt-blue              rgba(179, 191, 255, 0.05);
@define-color opt-blue-state        rgba(110, 150, 255, 0.55);
@define-color opt-yellow            rgba(255, 230, 179, 0.05);
@define-color opt-yellow-state      rgba(255, 230, 179, 0.35);
@define-color opt-red               rgba(255, 179, 179, 0.05);
@define-color opt-red-state         rgba(255, 179, 179, 0.35);

/* Secondary animation / pin colors */
@define-color opt-violet            rgba(217, 179, 255, 0.70);
@define-color opt-green             rgba(179, 255, 179, 0.70);
@define-color opt-orange            rgba(255, 191, 179, 0.70);
@define-color opt-yellow-pin        rgba(255, 230, 179, 0.70);

/* Press feedback */
@define-color opt-pushed-shadow     rgba(  0,   0,   0, 0.35);

/* Text */
@define-color opt-text-on-dark      rgba(255, 255, 255, 1.00);
@define-color opt-text-on-light     rgba(  0,   0,   0, 0.85);
@define-color opt-text-on-light-hov rgba(  0,   0,   0, 0.95);
@define-color opt-text-light-shadow rgba(255, 255, 255, 0.25);

/* Canvas-specific (Wave 0): the dashboard veil */
@define-color canvas-veil           rgba(  0,   0,   0, 0.85);
@define-color canvas-zone-label     rgba(255, 255, 255, 0.30);
```

- [ ] **Step 3: Write eww.scss**

Create `/etc/nixos/home/widgets/eww/eww.scss` with:

```scss
/*
 * StandardOS widget canvas — Eww styles.
 * Imports the shared StandardOS palette and styles the Dashboard window.
 *
 * Wave 0: dark veil + three zone placeholders + clock in HERO.
 * Wave 1+ adds per-widget card styles.
 */

@import "../palette.css";

/* Reset GTK defaults so Eww starts from neutral ground. */
* {
  all: unset;
}

/* The full-screen dashboard window: dark veil over the underlying session. */
window.dashboard {
  background-color: @canvas-veil;
  font-family: "MesloLGS NF", "Symbols Nerd Font Mono", sans-serif;
}

/* Wave 0 placeholders for CROWN and FIELD (future widgets fill these). */
.zone-placeholder {
  color: @canvas-zone-label;
  font-size: 11pt;
  font-weight: 300;
  letter-spacing: 2px;
  padding: 24px;
}

/* HERO clock: the only place the 96pt scale appears (spec §5.2). */
.widget-clock-hero {
  color: @opt-text-on-dark;
  font-size: 96pt;
  font-weight: 200;
  letter-spacing: -2px;
}

/* Vertical zone container: CROWN at top, HERO in middle, FIELD at bottom. */
.canvas-root {
  padding: 5% 5%;
}
```

- [ ] **Step 4: Write eww.yuck**

Create `/etc/nixos/home/widgets/eww/eww.yuck` with:

```yuck
;; ─────────────────────────────────────────────────────────────────────
;;  StandardOS widget canvas — Eww root.
;;
;;  Wave 0: the dashboard window with three zones (CROWN / HERO / FIELD)
;;  drawn as labeled placeholders, plus a clock label in HERO that polls
;;  date(1) every second.
;;
;;  Future waves replace the placeholders with real widgets (see
;;  docs/superpowers/specs/2026-06-19-widgets-canvas-design.md).
;; ─────────────────────────────────────────────────────────────────────

;; Time data — polled every second. `date(1)` is the cheapest possible
;; source; locale comes from the user's environment.
(defpoll time
  :interval "1s"
  :initial "--:--"
  `date +'%H:%M'`)

;; HERO widget: the huge clock. The only widget shipped in Wave 0.
(defwidget clock-hero []
  (label
    :class "widget-clock-hero"
    :text time))

;; CROWN zone placeholder — will hold identity widgets (date, user-select)
;; in Wave 1 / Wave 4.
(defwidget crown-placeholder []
  (label
    :class "zone-placeholder"
    :text "CROWN"))

;; FIELD zone placeholder — will hold smaller info widgets in Wave 1+.
(defwidget field-placeholder []
  (label
    :class "zone-placeholder"
    :text "FIELD"))

;; The canvas root: a vertical box with three zones, edge-padded by 5%
;; per spec §3.
(defwidget canvas []
  (box
    :class "canvas-root"
    :orientation "vertical"
    :space-evenly false
    ;; CROWN — top, fixed height roughly 15% of the canvas.
    (box
      :orientation "horizontal"
      :halign "center"
      :valign "start"
      :vexpand false
      (crown-placeholder))
    ;; HERO — vertical center, fills available space, holds exactly one
    ;; widget (the clock).
    (box
      :orientation "horizontal"
      :halign "center"
      :valign "center"
      :vexpand true
      (clock-hero))
    ;; FIELD — bottom row, fixed height, will become a responsive wrap
    ;; container in Wave 1+.
    (box
      :orientation "horizontal"
      :halign "center"
      :valign "end"
      :vexpand false
      (field-placeholder))))

;; The dashboard window: overlay layer, full-screen on the focused
;; monitor (Wave 0 ships single-monitor; multi-monitor decision deferred
;; per spec §9.1).
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

- [ ] **Step 5: Inspect the files**

Run:
```bash
ls -la /etc/nixos/home/widgets/ /etc/nixos/home/widgets/eww/
```

Expected: shows `palette.css` in `widgets/`, and `eww.scss` + `eww.yuck` in `widgets/eww/`.

Run:
```bash
grep -c "@define-color" /etc/nixos/home/widgets/palette.css
```

Expected: `18` (one per color token).

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add widgets/palette.css widgets/eww/eww.scss widgets/eww/eww.yuck
git commit -m "$(cat <<'EOF'
widgets-canvas: scaffold the canvas config — palette + eww yuck + scss

Wave 0 config files for the StandardOS widget canvas. palette.css is the
single source of truth for canvas-surface colors (Eww + future hyprlock +
regreet read from here). eww.yuck declares the dashboard window with
CROWN / HERO / FIELD zones; HERO holds the only Wave 0 widget — a clock
polling date(1) every second.

No Nix module yet; nothing wires these in until Task 2. These are just
the config text.

Spec: docs/superpowers/specs/2026-06-19-widgets-canvas-design.md
Plan: docs/superpowers/plans/2026-06-19-widgets-canvas-wave-0.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git status` is clean for the three new files.

---

## Task 2: Create the Nix module and wire it into home.nix

**Files:**
- Create: `/etc/nixos/home/modules/widgets-canvas.nix`
- Modify: `/etc/nixos/home.nix` (add to `imports` + enable the service)

**Interfaces:**
- Consumes: the three files Task 1 wrote (`/etc/nixos/home/widgets/{palette.css, eww/eww.scss, eww/eww.yuck}`).
- Produces:
  - Nix option `services.standardosCanvas.enable` (bool, default false).
  - When enabled: `pkgs.eww` is added to `home.packages`; `~/.config/eww/{palette.css,eww.scss,eww.yuck}` are out-of-store symlinks back to the source; a systemd-user service `standardos-canvas.service` runs `eww daemon --no-daemonize` with Restart=always.
  - Task 3 (hyprland binds) consumes this service: the binds call `eww open dashboard` which only works if this service is running.

- [ ] **Step 1: Verify eww is in nixpkgs and pick the right binary**

Run:
```bash
nix-instantiate --eval -E 'with import <nixpkgs> {}; eww.outPath' 2>&1 | head -5
```

Expected: a `/nix/store/…-eww-0.x.x` path. If this fails (network or eval error), stop and resolve before continuing — the module depends on `pkgs.eww`.

Then check the binary name:
```bash
nix-build '<nixpkgs>' -A eww --no-out-link 2>/dev/null | xargs -I{} ls {}/bin/
```

Expected: `eww` listed (single binary).

- [ ] **Step 2: Write the Nix module**

Create `/etc/nixos/home/modules/widgets-canvas.nix` with:

```nix
# =============================================================================
# widgets-canvas.nix — declarative home-manager management of the
# StandardOS widget canvas (the Dashboard surface).
#
# Owns ~/.config/eww/{eww.yuck, eww.scss, palette.css}. The source files
# live under /etc/nixos/home/widgets/ so they remain easy to read and edit,
# mapped into the user's config via xdg.configFile.
#
# IMPORTANT — out-of-store symlinks. ~/.config/eww/* symlink DIRECTLY to
# /etc/nixos/home/widgets/* via `mkOutOfStoreSymlink`, NOT to copies in
# /nix/store. Iteration is "edit + `systemctl --user restart
# standardos-canvas.service`" — no rebuild step. Mirrors the pattern
# established by waybar.nix; see that module's header for the full
# rationale.
#
# Wires `eww daemon --no-daemonize` as a systemd-user service bound to
# graphical-session.target with Restart=always — the daemon must be
# running before the user holds Super+Return, or `eww open dashboard`
# fails silently. The Hyprland keybinds live in
# /etc/nixos/home/hypr/modules/Binds.conf (separate module, see
# hyprland-config.nix).
#
# Usage:
#   services.standardosCanvas.enable = true;
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.standardosCanvas;

  # Source-of-truth directory for the canvas config files. The actual
  # paths are absolute strings (not Nix paths) so `mkOutOfStoreSymlink`
  # symlinks to /etc/nixos/home/widgets/ directly, preserving edit-and-
  # restart iteration.
  widgetsDir = "/etc/nixos/home/widgets";
in
{
  options.services.standardosCanvas = {
    enable = lib.mkEnableOption "StandardOS widget canvas (Dashboard surface)";

    ewwPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.eww;
      description = "Eww package providing the daemon binary.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install eww into the user's profile so the binary is on PATH for
    # the Hyprland keybind exec strings (`eww open dashboard`).
    home.packages = [ cfg.ewwPackage ];

    # Out-of-store symlinks: edits to /etc/nixos/home/widgets/* are live
    # the moment the file is saved. Only a daemon restart picks up
    # eww.yuck / eww.scss changes (eww does not hot-reload on file
    # change in Wave 0). palette.css changes also require a restart.
    xdg.configFile."eww/eww.yuck" = {
      source = config.lib.file.mkOutOfStoreSymlink "${widgetsDir}/eww/eww.yuck";
      force  = true;
    };
    xdg.configFile."eww/eww.scss" = {
      source = config.lib.file.mkOutOfStoreSymlink "${widgetsDir}/eww/eww.scss";
      force  = true;
    };
    xdg.configFile."eww/palette.css" = {
      source = config.lib.file.mkOutOfStoreSymlink "${widgetsDir}/palette.css";
      force  = true;
    };

    systemd.user.services.standardos-canvas = {
      Unit = {
        Description = "StandardOS widget canvas (eww daemon)";
        PartOf = [ "graphical-session.target" ];
        # Order after the session is up so the wayland display socket
        # exists when eww connects.
        After = [ "graphical-session.target" ];
        # Don't try to start without a wayland display.
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Environment = [
          "PATH=${cfg.ewwPackage}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
        ];
        Type = "simple";
        # --no-daemonize keeps eww in the foreground so systemd tracks
        # the actual process (without it, systemd loses the daemon
        # after the launcher forks).
        ExecStart = "${cfg.ewwPackage}/bin/eww daemon --no-daemonize";
        # Restart=always: eww can die from a yuck parse error after a
        # config edit; the user always wants the daemon back without
        # manual intervention. The next config edit + restart fixes the
        # parse error.
        Restart = "always";
        RestartSec = 1;
      };
    };
  };
}
```

- [ ] **Step 3: Wire the module into home.nix**

Modify `/etc/nixos/home.nix`:

Add `./home/modules/widgets-canvas.nix` to the `imports` list, immediately after `./home/modules/notif-center.nix`. Add `services.standardosCanvas.enable = true;` in the body, next to the other service enables.

The relevant section becomes:

```nix
{
  imports = [
    ./home-nautilus.nix
    ./home-screen-type.nix
    ./home-xdg.nix
    ./home/modules/hypr-context.nix
    ./home/modules/hypr-bg.nix
    ./home/modules/voice-dictation.nix
    ./home/modules/waybar.nix
    ./home/modules/rofi.nix
    ./home/modules/hyprland-config.nix
    ./home/modules/keyring-unlocked.nix
    ./home/modules/standard-os-resume-user.nix
    ./home/modules/standard-os-update-scheduler.nix
    ./home/modules/notif-center.nix
    ./home/modules/widgets-canvas.nix
    ./home/hosts/STDOS.nix
  ];

  # … existing body …

  services.waybarBar.enable = true;
  services.keyring.unlocked.enable = true;
  services.notifCenter.enable = true;
  services.standardosCanvas.enable = true;

  # … rest unchanged …
}
```

- [ ] **Step 4: Rebuild and verify the service comes up**

Run:
```bash
sudo nixos-rebuild switch
```

Expected: build succeeds (may take a minute the first time eww is fetched); activation completes without errors. If the rebuild fails on Nix eval, fix the syntax in `widgets-canvas.nix` or `home.nix` before continuing.

Then check the systemd-user unit:
```bash
systemctl --user status standardos-canvas.service
```

Expected: `Active: active (running)`, ExecStart pointing to `…-eww-…/bin/eww daemon --no-daemonize`, no errors in the last 20 log lines.

Then check the symlinks resolve to the source files:
```bash
readlink -f ~/.config/eww/eww.yuck
readlink -f ~/.config/eww/eww.scss
readlink -f ~/.config/eww/palette.css
```

Expected: each prints `/etc/nixos/home/widgets/eww/eww.yuck`, `…/eww.scss`, `/etc/nixos/home/widgets/palette.css`. If any returns a path under `/nix/store/…-hm_…`, the symlink fell back to the store-copy path — investigate `mkOutOfStoreSymlink` wiring before continuing.

- [ ] **Step 5: Verify Eww parses the config without showing the window**

Run:
```bash
eww list-windows
```

Expected: output includes `dashboard` (possibly prefixed with a closed-state marker). If eww errors with "could not parse eww.yuck", check `eww logs` for the line + column.

- [ ] **Step 6: Smoke-test that the window can open and close manually**

Run:
```bash
eww open dashboard
sleep 2
eww close dashboard
```

Expected: a full-screen translucent canvas appears for 2 seconds showing the placeholder labels CROWN, FIELD, and a clock in the center, then disappears.

If the canvas does NOT appear:
- Check `eww logs` for runtime errors.
- Verify the eww daemon is actually running (`pgrep -af 'eww daemon'`).
- Verify GTK can find the Nerd Font: `fc-match "MesloLGS NF"` should print MesloLGS NF.
- If the clock label shows `--:--`, the poll has not fired yet — wait 2 seconds.

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home
git add modules/widgets-canvas.nix ../home.nix
git commit -m "$(cat <<'EOF'
widgets-canvas: nix module + home.nix wiring; eww daemon as user service

services.standardosCanvas.enable installs eww, out-of-store-symlinks the
three canvas config files into ~/.config/eww/, and runs `eww daemon` as
a graphical-session-bound user unit with Restart=always.

The keybind that triggers `eww open dashboard` lands in the next task
(Hyprland binds). Manually invoking `eww open dashboard` after this
commit already brings up the canvas with a clock.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git status` clean.

Note: `../home.nix` in the `git add` line is needed because `home.nix` lives at `/etc/nixos/home.nix` (one level up from the home-manager source tree). If the working directory is `/etc/nixos/home/`, use `git add ../home.nix` or `git -C /etc/nixos/home add /etc/nixos/home.nix`.

---

## Task 3: Hyprland keybinds for Super+Return press/release

**Files:**
- Modify: `/etc/nixos/home/hypr/modules/Binds.conf`

**Interfaces:**
- Consumes: the `standardos-canvas.service` from Task 2 must be running before this keybind has any visible effect (`eww open dashboard` is a no-op without a running daemon).
- Produces: no code interfaces. The user-facing interface is the keybinding itself: `$mainMod + RETURN` opens, releasing closes.

- [ ] **Step 1: Read the current Binds.conf to find the right section**

Read `/etc/nixos/home/hypr/modules/Binds.conf` and find the section containing the existing XF86 hardware-key binds (around line 45-57 per earlier survey). The canvas binds go in a new section *after* the XF86 block and *before* the workspace numeric binds (60+).

- [ ] **Step 2: Add the canvas binds**

Modify `/etc/nixos/home/hypr/modules/Binds.conf`: between the existing `bindl = , XF86AudioStop, …` line (~line 57) and the workspace block (`bind = $mainMod, 1, …`, ~line 60), insert:

```hyprlang
# ───────────────────────────────────────────────────────────────
# StandardOS widget canvas — Super+RETURN opens the Dashboard;
# the canvas persists until Esc dismisses it.
# ───────────────────────────────────────────────────────────────
# Opening Super+RETURN dispatches `eww open dashboard` AND enters the
# `canvas-open` submap. Inside the submap, Esc dispatches the close
# AND resets back to the default submap. Outside the submap, Esc is
# its normal application key — apps never lose their Esc when the
# canvas is closed.
#
# This is NOT hold-to-peek and NOT toggle (pressing Super+RETURN a
# second time does not close — the user reaches for Esc).
#
# The eww daemon (services.standardosCanvas) must be running for
# these to do anything; the service is graphical-session-bound, so
# by the time the user can press a keybind the daemon is up.
#
# These keybinds are NOT advertised. Per the spec, widgets sit above
# pillar 6's mouse floor — mouse users have no path to the canvas,
# the keyboard is the only door.
bind = $mainMod, RETURN, exec, eww open dashboard
bind = $mainMod, RETURN, submap, canvas-open

submap = canvas-open
bind = , ESCAPE, exec, eww close dashboard
bind = , ESCAPE, submap, reset
submap = reset
```

- [ ] **Step 3: Verify Super+Return is not already bound**

Run:
```bash
grep -nE "RETURN|Return" /etc/nixos/home/hypr/modules/Binds.conf
```

Expected: only the two new lines (`bind` + `bindr`) reference RETURN. No prior bindings exist for Super+Return. If any other line binds it, resolve the conflict before proceeding.

- [ ] **Step 4: Rebuild and reload Hyprland**

Per the `feedback_hypr_config_needs_rebuild` memory: Hyprland's modular conf is frozen in `/nix/store` via home-manager — a plain `hyprctl reload` reads the stale store path. So:

```bash
sudo nixos-rebuild switch
hyprctl reload
```

Expected: rebuild succeeds; `hyprctl reload` returns `ok`. Check the keybinding registered:

```bash
hyprctl binds | grep -B1 -A2 "RETURN\|ESCAPE"
```

Expected: at least two RETURN entries (one `exec eww open dashboard`, one `submap canvas-open`) and at least two ESCAPE entries inside the `canvas-open` submap (one `exec eww close dashboard`, one `submap reset`). Hyprland's `submap` listing may report them grouped under the `canvas-open` submap.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add hypr/modules/Binds.conf
git commit -m "$(cat <<'EOF'
hypr/binds: Super+RETURN holds the StandardOS widget canvas (Dashboard)

bind on press → `eww open dashboard`; bindr on release → `eww close
dashboard`. The held-key window is the canvas's peek-and-release
contract per spec §2.1.

Keybind is intentionally undocumented inside the OS (no help line, no
tooltip surface) — widgets sit above the mouse floor; the keyboard is
their only door.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git status` clean.

---

## Task 4: End-to-end verification + TODO graduation

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md` (add DONE entry).
- Modify: `/etc/nixos/home/waybar/todonow.md` (mark items #5 / #7 as in flight, with back-pointer).

**Interfaces:**
- Consumes: everything from Tasks 1–3 must be in place and rebuilt.
- Produces: a recorded shipping event in the work map. No code interfaces.

- [ ] **Step 1: User-acceptance test (the only test that matters for this Wave)**

Press `Super + Return`.

**Expected:**
- The screen veils with a dark translucent overlay (~85% opacity black per `@canvas-veil`).
- A large clock (HH:MM, ~96pt) appears centered vertically and horizontally (HERO zone).
- The text "CROWN" appears small, dim, top center.
- The text "FIELD" appears small, dim, bottom center.
- The bar at the top remains visible (it's not part of the underlying session that gets veiled; deferred-decision §9.2 — current default is "bar stays").
- The veil **stays** — release of the key chord does not close it.

Press `Esc`.

**Expected:**
- The veil disappears immediately.
- The underlying session is interactive again.
- A subsequent `Esc` outside the canvas-open state behaves normally (apps that consume Esc still get it).

If the canvas does not appear:
- `journalctl --user -u standardos-canvas.service -n 50` for daemon-side errors.
- `eww logs` for yuck-runtime errors.
- `hyprctl binds | grep RETURN` to confirm the bindings are loaded.

If the clock reads `--:--` for more than 2 seconds: the `defpoll` initial value is showing because the first poll has not run yet. Wait. If it persists beyond 3 seconds, run `eww update time="$(date +%H:%M)"` manually — if that updates the label, the poll command itself is broken; verify `date +'%H:%M'` works in the user's PATH.

- [ ] **Step 2: Regression check — bar + launcher + window switcher still work**

Smoke test that Wave 0 did not break neighbors:

- Click the launcher `+` pill → rofi drun opens. Cancel with Esc.
- Click the focused-window pill → window switcher rofi opens. Cancel.
- Hold Super+Return again → canvas opens (confirms keybind didn't accidentally rebind on rebuild).
- Press Super+SPACE → apps launcher still works (verifies the new bind didn't shadow the space launcher; they share Super but different keys).

If any of these fail, stop and investigate before declaring done.

- [ ] **Step 3: Update TODO.md (graduation to DONE)**

Modify `/etc/nixos/home/waybar/TODO.md` — at the top of the DONE section (immediately after the `## DONE` header, before the existing 2026-06-17 entry), insert:

```markdown
- **2026-06-19** — **widgets-canvas Wave 0: dashboard substrate + clock.**
  New surface class shipped: the canvas, Eww-rendered, full-screen
  translucent overlay opened on Super+RETURN and dismissed on Esc
  (persistent — not hold-to-peek, not toggle, decision reversed mid-
  flight after physical test). CROWN / HERO / FIELD zone layout drawn
  as placeholders; HERO holds a 96pt clock polling `date(1)` every
  second. Eww daemon runs as `systemd --user
  services.standardos-canvas` bound to graphical-session.target.
  **Hint:** new module `modules/widgets-canvas.nix` mirrors the waybar.nix
  out-of-store-symlink pattern — edit `/etc/nixos/home/widgets/eww/*` and
  `systemctl --user restart standardos-canvas.service` to iterate without
  a rebuild.
  **Hint:** Hyprland binds at `hypr/modules/Binds.conf` use a `submap`
  pattern: default-submap `bind` on $mainMod+RETURN dispatches both
  `exec eww open dashboard` AND `submap canvas-open`; inside the
  canvas-open submap, `bind` on ESCAPE dispatches `exec eww close
  dashboard` AND `submap reset`. The daemon must be up before press;
  graphical-session binding handles that.
  **Hint:** spec at `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
  Wave 0 plan at `docs/superpowers/plans/2026-06-19-widgets-canvas-wave-0.md`.
  Waves 1–5 (catalog widgets, lock, greeter) are separate plans.
  **Hint:** palette tokens at `/etc/nixos/home/widgets/palette.css`
  mirror waybar/style.css §50-126 — future hyprlock + regreet work
  reads from the same file.
  **Hint:** home.nix at `/etc/nixos/home.nix` is OUTSIDE the
  `/etc/nixos/home` git worktree; its `services.standardosCanvas.enable
  = true;` line lives on disk but is not tracked. Existing repo
  pattern.
```

- [ ] **Step 4: Update todonow.md (back-reference, signal shipping)**

Modify `/etc/nixos/home/waybar/todonow.md` — items #5 and #7 are partially addressed by Wave 0. Replace those two entries with:

```markdown
5. **Themed login + lock screen** — Wave 4 + Wave 5 of the widgets-canvas
   plan series. Substrate shipped 2026-06-19 (Wave 0); Lock and Greeter
   are independent follow-ups. Spec:
   `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.

7. **Widgets** — Wave 0 (substrate + clock) shipped 2026-06-19. Waves 1–3
   add the rest of the 12-widget Dashboard catalog. Spec:
   `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
```

- [ ] **Step 5: Commit the TODO / todonow updates**

```bash
cd /etc/nixos/home
git add waybar/TODO.md waybar/todonow.md
git commit -m "$(cat <<'EOF'
waybar/TODO: graduate widgets-canvas Wave 0 to DONE; update todonow

Wave 0 (substrate + clock + Hyprland summon binds) shipped. Items #5
(themed login/lock) and #7 (widgets) in todonow.md now point at the
widgets-canvas spec; Waves 1–5 are independent follow-ups tracked under
TODO.md when each begins.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds; `git status` clean.

- [ ] **Step 6: Final tree-clean confirmation**

Run:
```bash
git -C /etc/nixos/home status -s
```

Expected: empty output. Tree is clean; Wave 0 is fully shipped across 4 commits (Task 1 / Task 2 / Task 3 / Task 4).

---

## Wave 0 acceptance summary

Wave 0 is complete when ALL of these are true:

- [ ] `systemctl --user status standardos-canvas.service` is `active (running)`.
- [ ] Pressing `Super+Return` shows a full-screen dark veil with CROWN / HERO / FIELD placeholders + a 96pt clock in HERO; veil persists after the chord is released.
- [ ] Pressing `Esc` closes the canvas immediately.
- [ ] Esc outside the canvas-open submap behaves normally (apps still receive it).
- [ ] The clock updates at least once per second.
- [ ] No regression in: bar pills, launcher (Super+SPACE), window switcher, workspace navigation, hardware keys (XF86 family).
- [ ] `~/.config/eww/*` files resolve via `readlink -f` to `/etc/nixos/home/widgets/*` (out-of-store symlinks intact).
- [ ] `waybar/TODO.md` has a DONE entry for Wave 0 with the four Hint lines from Task 4 Step 3.
- [ ] `waybar/todonow.md` items #5 and #7 reference the spec and waves.
- [ ] `git -C /etc/nixos/home status -s` returns empty.

Anything left for Wave 1: the canvas fade-in/out animation (spec §5.2 mentioned ~150ms; Wave 0 ships with no transition — the canvas snaps on and off). This is acceptable for v0 because the canvas is a peek; if 150ms fade-in proves valuable in practice, Wave 1 can add it without disturbing the substrate.

---

*Plan authored 2026-06-19, derived from the destination spec at
`docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`. Waves 1
through 5 will follow as separate plan documents, each producing an
independently shippable increment.*
