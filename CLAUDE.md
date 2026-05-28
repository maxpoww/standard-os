# CLAUDE.md — OPTIONS (Standard-OS UX layer)

This is the operating manual. The design treatise is `README.md` next to this file — read it once per session and treat it as load-bearing. The soul of the project lives in five sentences:

1. The unit is the **option**, a pill. Pills are the only visible primitive.
2. The bar has three zones — **user** (left, where the user IS: workspaces + focused window + per-window actions), **task** (center, task-manipulation tools: launcher / switcher / restore), **system** (right, persistent state). The focused-window pill at the right edge of USER touches the launcher "+" at the left edge of TASK — that boundary is the visual bridge between current and next.
3. Color is meaning, not decoration. **6 colors + 3 motions + 2 surfaces** — this is a closed budget. Anything new replaces something existing.
4. Help appears when its use is logical and disappears when it isn't. Modules subscribe to context; the bar composes.
5. Frustration → revelation. The user feels clever, not guided.

If a change would violate any of those five, push back before writing code.

---

## Project layout

```
/etc/nixos/home/waybar/           ← this repo (git, main branch)
├── CLAUDE.md                     ← this file (operating manual)
├── README.md                     ← OPTIONS spec (design treatise)
├── config.jsonc                  ← waybar module declarations
└── style.css                     ← pill CSS, animations, light/dark text rules

/etc/nixos/home/modules/waybar.nix     ← Home-Manager module wiring waybar + cache daemons as systemd user services. Installs config.jsonc and style.css into ~/.config/waybar/.
/home/max/.config/waybar/scripts/      ← daemon and per-module shell scripts (NOT yet nix-packaged; lives in user home for now — migration to writeShellScriptBin is tracked in distro work)
/tmp/waybar-cache/                     ← per-module JSON files written by daemons, read by waybar
/tmp/glass-mode                        ← single-line file: "light" or "dark"
/tmp/hypr-edge-bg/                     ← hypr-edge-bg's current solid-color PNG cache; the glass-text-daemon reads filenames here to compute luminance
```

The waybar tree is git-tracked from `e8ad8b1` onward. Every change to `config.jsonc` or `style.css` is one commit, message phrased as a behavior change, not a file change.

---

## The pill primitive (exact CSS)

Every options pill — current or future — starts from this spec. Anything different needs a written reason.

```css
.opt-pill {
    background: rgba(50, 50, 70, 0.30);    /* parent surface (cool) */
    border-radius: 30px;
    color: rgba(255, 255, 255, 1);
    font-size: 12px;
    padding: 1px 8px 1px 7px;              /* T R B L — note the 8/7 left/right asymmetry */
    margin: 2px 1px;
}

.opt-pill:hover {
    background: rgba(130, 130, 150, 0.70); /* @opt-hover-veil — same for every non-swap pill */
}
```

Hover is **one uniform veil**: `rgba(130, 130, 150, 0.70)`, applied identically to every non-swap pill regardless of state. State paint (yes/middle/no) lives on the rest face; hover just signals targeting. Swap pills (ws-current "+" reveal, etc.) are the only exception — they paint their own action-reveal color + motion. **No borders, ever** — outlines read as decoration, not meaning.

Bar window: `background: rgba(50, 50, 70, 0.10); border-radius: 30px; height: 30px`.

---

## Color and motion budget (closed)

Total set: **6 colors + 3 motions + 2 surfaces**. Adding to it requires a justification that no existing element suffices.

### Surfaces (structure)

| Use | rgba | Family |
|---|---|---|
| Parent pill background | `rgba(50, 50, 70, 0.30)` | cool dark blue-violet |
| Child pill background (inside an expanded group) | `rgba(70, 50, 50, 0.30)` | warm dark brown-red |

### Primary state colors (painted ON the pill, persistent)

| Color | Role | Approx hex |
|---|---|---|
| Blue | YES / on / good | (existing accents use `rgba(80,120,220,*)` and `rgba(100,160,255,*)`) |
| Yellow | MIDDLE / partial | (existing accent `rgba(255,200,50,0.50)`) |
| Red | NO / off / destructive | (existing accents use `rgba(255,100,100,0.60)` and `#ff9999`) |

Blue is the resting "everything in order" color — a healthy bar reads predominantly blue.

### Secondary animation colors (painted OVER the pill, transient)

| Color | Role | Pairs with state |
|---|---|---|
| Violet | YES / full / healthy | Blue |
| Green | MIDDLE / attention worth noting | Yellow |
| Orange | NO / failing / urgent | Red |

Correlative pairs (blue↔violet, yellow↔green, red↔orange) make transitions read naturally: a WiFi pill in yellow animating violet (we want a yes) snaps to solid blue on connect.

### Motions (the shape; color carries meaning)

| Name | Specs | Default pairing |
|---|---|---|
| **Pulse** | opacity / bg 0.5 → 1.0 → 0.5, ~1 Hz, infinite | Orange (urgent) |
| **Glow** | fade-in, hold ~2 s, fade-out | Green (suggest) |
| **Breathe** | very slow opacity sine, ~6 s cycle | Violet (ambient healthy) |

Primary state colors do NOT animate by themselves. If something is changing, an animation in the *secondary* palette paints over the state to show the change.

Existing `@keyframes` in `style.css` (`blink`, `shine`, `pulse-plus`) are pre-OPTIONS-naming forms of these three motions and are good references for how the live GTK 3 build accepts animation. New keyframes are added under the names `opt-pulse`, `opt-glow`, `opt-breathe`.

---

## Bar layout and expansion direction

```
[ user options ............. ][ task ............. ][ system options ... ]
   left zone                    center (anchored)        right zone
```

- **Left (user)**: where the user IS — workspaces (current location), focused-window pill (current focus), per-window actions (close/minimize/swap/move). The focused-window pill sits at the right edge of the zone.
- **Center (task)**: task-manipulation tools — launcher (the "+"), lock, task switcher, restore-minimized. The launcher "+" sits at the left edge so it touches the focused-window pill across the user/task boundary.
- **Right (system)**: persistent state — network, audio, bluetooth, battery, brightness, time, power, dictation indicator.

### Cluster expansion (the rule)

When a pill expands a horizontal cluster of siblings (via hover or click), the cluster slides **away from the nearest wall**:

| Parent location | Cluster slides | Wall avoided |
|---|---|---|
| Left zone | right | left screen edge |
| Right zone | left | right screen edge |
| Center, right of focused-window pill | right | the focused-window pill |
| Center, left of focused-window pill | left | the focused-window pill |

In waybar terms this is `"drawer": { "transition-left-to-right": true | false }` on a `group/*`. Left-zone groups → `true`. Right-zone groups → `false`.

Vertical "more options" drops (the rofi-style child column) go straight down — no horizontal direction involved.

---

## Module anatomy

Every options module is one custom waybar entry plus optionally one writer script.

### Read pattern (the canonical pill)

```jsonc
"custom/<name>": {
    "exec": "m=$(cat /tmp/glass-mode 2>/dev/null || echo dark); printf '{\"text\":\"<glyph>\",\"class\":\"%s\"}' \"$m\"",
    "return-type": "json",
    "format": "{}",
    "interval": "once",   // or a number; or use cache-file pattern below for daemon-driven
    "signal": 10,
    "tooltip": false,
    "on-click": "<command>"
}
```

### Daemon-driven pattern (when state updates externally)

```jsonc
"custom/<name>": {
    "exec": "cat /tmp/waybar-cache/<name> 2>/dev/null",
    "return-type": "json",
    "format": "{}",
    "interval": <seconds> | "once",
    "signal": 10,
    "tooltip": false,
    "on-click": "<command>"
}
```

A daemon (systemd-user service or background script) writes `/tmp/waybar-cache/<name>` as a JSON object (`text`, `class`, optional `tooltip`) and calls `pkill -RTMIN+10 waybar` after every meaningful write.

### Light/dark adaptation (mandatory for every pill with text)

Every dynamic exec MUST read `/tmp/glass-mode` and emit `"class": "light"` or `"class": "dark"`. The matching CSS rules in `style.css` flip text color (white ↔ near-black with text-shadow) so the pill stays readable under any wallpaper. This is the **glass-text-daemon contract** — see next section. Modules that ignore it become invisible over light backgrounds.

### Empty collapse recipe

Any pill that conditionally hides emits `"class": "<mode> empty"` and the CSS collapses it via:

```css
.empty {
    padding: 0; margin: 0;
    min-width: 0; min-height: 0;
    border: 0; background: transparent;
    opacity: 0;
    font-size: 0;   /* if the pill still emits a glyph in empty state */
}
```

---

## The glass-text daemon (system-wide UX feature)

`waybar-glass-text-daemon.service` runs `~/.config/waybar/scripts/glass-text-daemon.sh` continuously. It reads the current solid-color filename written by `hypr-edge-bg` to `/tmp/hypr-edge-bg/`, computes luminance from the hex in the filename, and writes `light` or `dark` to `/tmp/glass-mode`.

Every options module emitting text reads that file and outputs a `light` or `dark` class. The CSS in `style.css` flips text color based on the class so the pill stays readable when the desktop behind the bar changes color.

**Rules for new modules:**
- Always read `/tmp/glass-mode` in the exec (default to `dark` if missing).
- Always emit a `class` field with `light` or `dark` (plus any state-specific classes appended, space-separated).
- Add the module's `#custom-<name>.light label` and `#custom-<name>.light:hover label` selectors to the light-text blocks in `style.css` (the long comma-separated lists near the bottom).

If a module forgets any of this, it works invisibly over dark wallpapers and disappears entirely over light ones. Easy to miss in dark-themed testing.

---

## The workspace daemon

`waybar-workspace-daemon.service` runs `~/.config/waybar/scripts/workspace-daemon.sh` once per second. It calls `hyprctl activeworkspace`, `hyprctl workspaces`, `hyprctl activewindow` (one shot each), and writes per-module cache files into `/tmp/waybar-cache/`:

- `ws-current`, `ws-1` … `ws-9` (workspaces module)
- `window` (focused window title/icon)
- `win-close`, `win-minimize`, `win-swap-right`, `win-move-trigger`, `win-move-1` … `win-move-9`, `win-move-new`

It sends `pkill -RTMIN+10 waybar` after each batch so the modules pick up the new state. Daemon-written modules use `signal: 10`.

Adding a new daemon-driven module: extend `workspace-daemon.sh` OR create a new dedicated daemon. Prefer dedicated daemons per concern (it scales better than a god-loop).

---

## Context sources (the engine)

For OPTIONS modules that need state beyond what the workspace-daemon already publishes, use the tool listed here. Add a new daemon to broadcast it into `/tmp/waybar-cache/<name>`.

| Signal | Tool | Notes |
|---|---|---|
| Focused window class & title | `hyprctl activewindow -j` | jq for fields; subscribe via `socat $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` for push events |
| Workspace state | `hyprctl workspaces -j`, `hyprctl activeworkspace -j` | already covered by workspace-daemon |
| CPU load | `top -bn1` or `/proc/loadavg` | parse the per-cpu line; cap polling to ≥ 2 s |
| GPU load (NVIDIA) | `nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits` | or `nvtop -s` |
| Audio routing / default sink | `wpctl status`, `wpctl inspect @DEFAULT_AUDIO_SINK@`, `wpctl get-volume <id>` | wireplumber. Subscribe via `pw-mon --color=never` filtered to `^changed:` |
| Text selection state | `wl-paste --watch` or polling `wl-paste -t TARGETS` | Wayland clipboard; for selection events use `wl-paste --primary` |
| Network state | `nmcli -t -f NAME,DEVICE,STATE connection show --active`, `nmcli device wifi list` | also `nmcli monitor` for push events |
| Bluetooth state | `bluetoothctl info`, `bluetoothctl devices Connected` | `bluetoothctl --` for non-interactive |
| Battery / power | `/sys/class/power_supply/BAT0/{capacity,status}` | already used by `custom/battery` |
| Time / timezone | `date +%H:%M`, `TZ=<zone> date` | already used by `custom/clock` |
| Background light/dark | `/tmp/glass-mode` | read every exec — see Glass-text section |
| Background color (raw) | `/tmp/hypr-edge-bg/` filename | hex is in the filename; rare to need directly |

**Cost discipline:** modules that poll cost CPU. Prefer event-driven sources (`socat hyprland-socket2`, `nmcli monitor`, `pw-mon`, `wl-paste --watch`) and broadcast a `{"src": "..."}` event into a FIFO that a single daemon consumes. The mpris work in `/home/max/mpris-waybar/` is a reference example of this pattern (event producers → debounced main loop → cache write + `pkill -RTMIN+N waybar`).

---

## Real-time signals (RTMIN+N)

waybar wakes a module instantly when it receives a real-time signal whose number matches the module's `signal:` field.

| Signal | Owner |
|---|---|
| RTMIN+10 | workspace-daemon, most static pills (default refresh) |
| RTMIN+11 | dictation indicator |
| RTMIN+12 | **FREE** (was mpris; now unused) |
| RTMIN+13 | **FREE** |
| RTMIN+14 | **FREE** |
| RTMIN+15 | **FREE** |

Pick the next free number when adding a new daemon. Document the new owner in this table.

Send a signal: `pkill -RTMIN+N waybar` (no quotes around the number). Cost: ~1 ms; dedup at the writer so identical content doesn't re-signal.

---

## Build / activate / verify

```bash
# Edit config.jsonc / style.css
# (no rebuild needed for the .css and .jsonc themselves — Home-Manager symlinks
#  them into ~/.config/waybar, so changes are live after a waybar restart)

systemctl --user restart waybar.service            # picks up edited config.jsonc + style.css

# When changing the Home-Manager module (modules/waybar.nix) or adding a daemon:
sudo nixos-rebuild switch
systemctl --user restart waybar.service waybar-workspace-daemon.service waybar-glass-text-daemon.service

# Live snapshot of context:
cat /tmp/glass-mode                                # "light" or "dark"
ls /tmp/waybar-cache/                              # what cache files exist right now
journalctl --user -u waybar -f                     # waybar logs

# Validate JSON before commit:
jq . config.jsonc >/dev/null && echo OK

# git workflow inside this repo:
cd /etc/nixos/home/waybar
git status
git diff
git add config.jsonc style.css
git commit -m "<what changed and why>"
```

The bar is owned by a real systemd service with `Restart=always`. Killing it manually is safe; it comes back. If it doesn't, `journalctl --user -u waybar` will say why.

---

## Hyprland quirks relevant to OPTIONS

- **Bar height pin = 22 px** (set in `config.jsonc` `"height": 22`). Any pill that affects total height (e.g. `#window` icon) must respect: icon + 2× padding + 2× margin ≤ 22. Current `#window`: icon-size 18 + padding 1+1 + margin 1+1 = 22 (exact fit). Going over makes waybar oscillate between configured 22 and forced taller value every focus change.
- **`hyprctl getoption general:gaps_in -j`** returns a `CssBoxStyle` `{"custom":"3 3 3 3","set":true}` — a *space-separated string*, NOT `{"int":3}`. Always parse with the `if has("int")…elif has("custom")…` jq pattern, splitting on spaces and taking `max`. Plain `.custom|tonumber` returns null and silently treats gaps as 0.
- **socket2 subscription** is the cheap event source for window/workspace/monitor changes. Subscribe via `socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -`. Filter line prefixes (`activewindow`, `openwindow`, etc.).
- **Center-zone task pill** is `custom/window` today, sourced from `/tmp/waybar-cache/window`. Click opens `~/.config/rofi/window-switcher.sh` — that's the existing multitasking flow.

---

## NixOS module pattern (for new options that need system-wide installation)

The distro-portability requirement is binding: every option must be installable via a Home-Manager module with a typed `services.options.<name>.enable` flag, no hardcoded paths to `/home/max/`, and reproducible from a fresh user account.

Template:

```nix
# modules/option-<name>.nix
{ config, lib, pkgs, primaryUser, userHome, ... }:

let
  cfg = config.services.options.<name>;
  daemon = pkgs.writeShellScriptBin "option-<name>-daemon" ''
    export PATH=${lib.makeBinPath [ pkgs.hyprland pkgs.jq pkgs.procps ]}:$PATH
    exec ${./../scripts/option-<name>-daemon} "$@"
  '';
in {
  options.services.options.<name> = {
    enable = lib.mkEnableOption "<name> option";
    # ... typed options
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ daemon ];
    systemd.user.services."option-<name>" = {
      Unit.PartOf = [ "graphical-session.target" ];
      Unit.After = [ "graphical-session.target" ];
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        ExecStart = "${daemon}/bin/option-<name>-daemon";
        Restart = "always";
        RestartSec = 1;
      };
    };
  };
}
```

Wire it from `/etc/nixos/home.nix` with `./home/modules/option-<name>.nix` in `imports` and `services.options.<name>.enable = true` in the body.

---

## Coding directives (priority order)

1. **Closed budget.** 6 colors + 3 motions + 2 surfaces. No exceptions without written justification in a commit message.
2. **The pill primitive is the start of every visual.** Deviate only when the deviation is itself a visible semantic (e.g. empty-collapse). Document the deviation in CSS as a comment.
3. **Hover = uniform veil.** `rgba(130, 130, 150, 0.70)` for every non-swap pill, regardless of state. State paint lives on the rest face; hover is just targeting. **No borders, ever** — outlines read as decoration, not meaning.
4. **Every text-bearing pill respects `/tmp/glass-mode`** and emits a `light`/`dark` class. Forgetting this makes the pill invisible over half of wallpapers — a silent regression.
5. **Modules don't consult each other.** Each module subscribes to context signals from its source of truth and decides its own visibility. Cross-module coupling is a maintenance smell.
6. **Daemon, not poll, when possible.** Use event-driven sources (`socat hyprland-socket2`, `nmcli monitor`, `pw-mon`, `wl-paste --watch`). Polling is a cost ceiling — fine for low-frequency status (battery every 30 s) but never for reactive UX.
7. **`pkill -RTMIN+N waybar` only on real change.** Dedup the cache write at the writer (in-memory `last_value` compare). The mpris CPU regression of 2026-05-27 was caused by signaling on every tick whether content changed or not.
8. **Atomic file writes.** Every `/tmp/waybar-cache/*` write is `printf '%s' "$content" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"`. Half-written cache files make waybar render empty pills.
9. **Trigger vs action.** Small icon-only pill = trigger (opens a cluster). Long pill displaying a value = action target. Choose explicitly when adding a new pill; the choice is binding for the pill's lifetime.
10. **Expansion direction follows the zone.** Left zone groups → `transition-left-to-right: true`. Right zone groups → `false`. Center zone follows the task-anchor rule (right of task → right, left of task → left).

---

## Known hazards (do not regress)

- **Forgetting the `light`/`dark` class** = invisible pill on light wallpapers. Audit the light-block selectors in `style.css` for every new module ID.
- **Polling daemons that fork helpers per tick** burn CPU silently. Per-tick fork of `jq`/`awk`/`head`/`tr` at 4 Hz is ~5 % CPU baseline (mpris was 130 %). Use bash builtins, `read -N`, `printf -v`, parameter expansion. Reserve subshells.
- **Inotify on a file path watching atomically-replaced files dies after the first write.** The watch is on the inode; `tmp + mv -f` unlinks the inode. Watch the *parent directory* with `--format '%f'` and filter by basename. (Bit the mpris marquee; bit me before I read cava-mpris's pre-existing comment.)
- **Inotify-driven loops need an initial render.** The first event arrived before the watcher started — re-read the source once before the first blocking read.
- **`set -u` and empty associative arrays.** `declare -A foo` leaves the variable in unassigned state; `${#foo[@]}` then trips unbound-variable. Always `declare -A foo=()` (explicit empty assignment).
- **`pw-mon` argv overflow.** Passing a large `pw-dump` JSON via `--argjson` exceeds Linux ARG_MAX. Pipe via stdin (`printf '%s' "$dump" | jq -c …`) instead.
- **Multi-waybar collisions.** Hyprland's legacy `exec-once = launch.sh` can race with the systemd `waybar.service`. The Nix module's `systemd.enable` toggle exists for this; don't enable both.
- **Glyph-bearing empty pills.** `padding:0; opacity:0` collapse keeps the slot but the LABEL still has natural width unless you also set `font-size: 0`. The mpris module documented this for waybar GTK 3 specifically.
- **Don't unload the waypaper image when cycling solid-color backgrounds.** That's a hypr-edge-bg concern but the glass-text-daemon depends on the path staying live. (Cross-project hazard.)
- **Emit `class` as a JSON ARRAY, not a space-separated string** (2026-05-28 regression). waybar/GTK 3 treats `"class":"opt-pill dark opt-yes"` as a SINGLE class named `opt-pill dark opt-yes` — every `.opt-pill`-style CSS selector then silently fails. Use `pill_emit` from `~/.config/waybar/scripts/lib/pill.sh` (it converts the space-separated string to a proper array), or emit `"class":["opt-pill","dark","opt-yes"]` directly. Static modules with dynamic content (clock, battery, anything that interpolates text or a state class) source the lib and call `pill_emit` inline rather than `printf`-ing JSON by hand.
- **GTK 3 CSS class selectors must be scoped** (2026-05-28 regression). A bare `.opt-pill { ... }` rule loads without error but silently doesn't match. Every class selector needs an ancestor (`window#waybar .opt-pill`), widget type (`button.opt-pill`, `label.light`), or ID (`#custom-X.empty`). When in doubt, prefix with `window#waybar `.
- **Nerd Font glyphs look empty in plain terminals** (2026-05-28 regression). A diff of `printf '{\"text\":\"\",...}'` may show `\"\"` where the original file held three UTF-8 bytes for a Font Awesome glyph (e.g. `\xef\x81\xa7` for `` U+F067 plus). Before rewriting an exec, inspect raw bytes with `od -An -tx1` or `od -An -c`. The glyphs that bit us once: new=`U+F067` (plus), hidden=`U+F061` (arrow), tools=`U+F0AC` (globe), blue=`U+F293` (BT), more=`U+E690` (3-dots), power=`U+F011`.
- **Hover-swap label hiding needs both button-level color AND a high-specificity light-mode label override** (2026-05-28). Setting `color: transparent` only on `.opt-swap-*:hover label` (specificity 0,2,1) loses in light mode to the canonical `.opt-pill.light:hover label` rule (0,3,1) — the resting-face number bleeds through behind the hover-face icon. Fix: put `color: transparent` on the BUTTON-level `.opt-swap-*:hover` rule (covers dark mode via cascade) AND a `.opt-pill.opt-swap-*.light:hover label` rule (0,4,1, beats the light-text override). When adding new swap kinds, extend BOTH selectors.

---

## Migration breadcrumbs

The OPTIONS spec describes the *future*. Today's bar is a partial implementation:

- ✓ Pill primitive, hover-brighter rule, 30 px border-radius — already in place.
- ✓ Group drawer + expansion-direction zoning — already in place.
- ✓ Glass-text-daemon adaptive text — already in place.
- ✓ Workspace-daemon cache + signal pattern — already in place.
- ~ Color/motion budget — partially used (current accent colors are an unsystematized prefix of the OPTIONS palette). Reconciling `win-move-trigger` green and `reboot` green to the OPTIONS scheme is a defined small task.
- ~ Three-zone explicit labelling — implied by current layout but not formalized; the `group/*` groups already cluster by zone.
- ✗ Parent vs child surface differentiation (`rgba(50,50,70,*)` vs `rgba(70,50,50,*)`) — not yet present, to be applied when first option ships with a child cluster.
- ✗ Multi-row "control panel" via additional waybar instances — not yet wired.
- ✗ Pillar #4 (dynamic difficulty / scaling help to skill) — deferred per spec; will appear in later versions.

When this list reaches all ✓, OPTIONS will have caught up to its own spec.

---

*Edit this file when reality changes. The README is the soul; this file is the body that keeps the soul aligned with the running system.*
