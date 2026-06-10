# CLAUDE.md — OPTIONS (Standard-OS UX layer)

> **Session start: invoke the global `standard-os` skill before any work in this directory.** It loads the navigator, the named patterns, the verification checklist, the condensed hazards, and the five-rules summary in ~150 lines — instead of forcing you to re-read every doc wholesale. Read this file *by section* (grep for what you need); use the skill as the index.

This is the operating manual. The design treatise is `README.md` next to this file — read it once per session and treat it as load-bearing. The soul of the project lives in five sentences:

1. The unit is the **option**, a pill. Pills are the only visible primitive.
2. The bar has three zones — **user** (left, where the user IS: workspaces + focused window + per-window actions), **task** (center, task-manipulation tools: launcher / switcher / restore), **system** (right, persistent state). The focused-window pill at the right edge of USER touches the launcher "+" at the left edge of TASK — that boundary is the visual bridge between current and next.
3. Color is meaning, not decoration. **6 colors + 4 motions + 2 surfaces + 1 border** — this is a closed budget. Anything new replaces something existing.
4. Help appears when its use is logical and disappears when it isn't. Modules subscribe to context; the bar composes.
5. Frustration → revelation. The user feels clever, not guided.

If a change would violate any of those five, push back before writing code.

---

## Project layout

```
/etc/nixos/home/waybar/           ← this repo (git, main branch)
├── CLAUDE.md                     ← this file (operating manual)
├── README.md                     ← OPTIONS spec (design treatise)
├── ARCHITECTURE.md               ← wiring schematic (daemons, signals, cache files)
├── TODO.md                       ← work map (TODO ≤ 6 / NEXT / DONE)
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

## TODO.md (the work map)

`TODO.md` is the project's running work map. Three sections, in flow order:

- **TODO** — active work. **Capped at 6 items.** When full, nothing promotes from NEXT until something completes. The cap is the discipline that keeps focus honest.
- **NEXT** — ideas not yet started. Unbounded. Promote into TODO when a slot opens and the user agrees to begin the work.
- **DONE** — history of what shipped. Each entry: date, one-line title, optional **Hint:** line that captures the implementation seam most likely to matter to future debugging (e.g. *"opt-flash uses box-shadow only, so it composes with state colors AND swap SVGs"*). Sorted reverse-chronological. The hint is the value — it's the breadcrumb that saves the next person an hour of re-reading commits.

**Maintenance rules for the file:**

1. **Check at session start.** Every session that begins work in this directory reads TODO.md first. The cost is ~120 lines for an authoritative snapshot of what is in flight; skipping it leaves Claude blind. The `standard-os` skill enforces this in its session-start protocol.
2. **When starting work on an item**, ensure it is in TODO (promote from NEXT or, with user approval, add directly). Mark `[ ]` → `[x]` only when shipped.
3. **When shipping an item**, move it to DONE with the date and a Hint line. Remove from TODO in the same edit.
4. **Work completed that was NOT on TODO goes straight to DONE.** Add it with date + Hint as if it had been planned. Do not retroactively add to TODO just to ceremoniously move it through. TODO is for planned active work; DONE is the history of all shipped work — planned or not. This keeps TODO honest about *future* intent rather than backfilling past completions.
5. **Never exceed 6 TODO items.** If the user proposes new work while TODO is full, push back: ask what to defer to NEXT, or what to finish first. Do not silently grow the section.
6. **Update the file in the same commit as the code change** when possible. A commit that ships an item should also move that item to DONE — the file and the codebase stay coherent that way.
7. **TODO.md is not a planning document.** It does not contain design discussion, tradeoffs, or acceptance criteria. Those live in the user's mind and in the commits. TODO.md is a one-line-per-thing map. Keep entries terse.
8. **Both Claude and the user maintain it.** Claude updates after shipping or when the user signals intent to start something; the user prunes / reorders freely.

If a NEXT item gets stale (no longer relevant), the user removes it; do not auto-prune NEXT.

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

Hover is **one uniform veil**: `rgba(130, 130, 150, 0.70)`, applied identically to every non-swap pill regardless of state. State paint (yes/middle/no) lives on the rest face; hover just signals targeting. Swap pills (ws-current "+" reveal, etc.) are the only exception — they paint their own action-reveal color + motion. **Borders only carry `opt-pushed`** (the toggle-ON modifier — see the "Pushed" subsection); no other class ever introduces an outline.

Bar window: `background: rgba(50, 50, 70, 0.10); border-radius: 30px; height: 30px`.

---

## Color and motion budget (closed)

Total set: **6 colors + 4 motions + 2 surfaces + 1 border** (the border lives only on `opt-pushed`). Adding to it requires a justification that no existing element suffices.

**Parent pills are naturally uncolored** at rest — `ws-current`, `custom/tools`, `custom/power`, `hyprland/window`, `custom/new`, the focused-window pill all sit on bare surface tint with no primary state class. A parent acquires color only as: (a) a hover-swap action-reveal face (`opt-swap-*` / `opt-plus`), (b) a hover-only beat (`opt-hover-red` / `opt-hover-yellow` / `opt-hover-blue` — neutral rest, color cycles in the tone on `:hover`), (c) a secondary-color animation while *communicating a state* (`opt-pulse|glow|breathe`, e.g. warm-screen ON paints its parent blue), (d) a pin (`opt-pin-violet|green|orange`), or (e) `opt-pushed` (soft pressed-in shadow). **Primary state colors live on children** — pills inside an expanded cluster — where they express action semantics (`opt-no` = destructive, `opt-middle` = defer, `opt-yes` = forward) at rest, then beat in their tone on hover. Parents borrow the hover-beat momentarily; permanent color is a child privilege.

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

| Name | Specs | Default pairing | Purpose |
|---|---|---|---|
| **Pulse** | opacity / bg 0.5 → 1.0 → 0.5, ~1 Hz, infinite | Orange (urgent) | system wants the user to look NOW |
| **Glow** | fade-in, hold ~2 s, fade-out | Green (suggest) | system OFFERS something the user may take |
| **Breathe** | very slow opacity sine, ~6 s cycle | Violet (ambient healthy) | background activity ongoing |
| **Flash** | one-shot 250 ms, inset shadow + darkening (no color) | n/a — carries no state meaning | user input acknowledged (hardware key, transient pill appearing in direct response) |

Primary state colors do NOT animate by themselves. If something is changing, a state-meaning animation (pulse/glow/breathe in the *secondary* palette) paints over the state to show the change. Flash is the exception — it has no color or state, only the brief pressed-in shape.

Existing `@keyframes` in `style.css` (`blink`, `shine`, `pulse-plus`) are pre-OPTIONS-naming forms of three of these motions and are good references for how the live GTK 3 build accepts animation. New keyframes are added under the names `opt-pulse`, `opt-glow`, `opt-breathe`, `opt-flash`.

### Pins (post-animation persistence)

A pin is a **solid secondary color held after an animation resolves**. The animation calls the eye; the pin holds it until the underlying state changes or the user acknowledges. Classes:

- `opt-pin-violet` — completed healthily (build done, sync finished).
- `opt-pin-green` — soft attention (low-but-not-critical battery, update available).
- `opt-pin-orange` — needs attention (WiFi dropped, render failed).

Lifecycle is **daemon-owned**: the daemon writes `opt-pulse` (or `opt-glow` / `opt-breathe`) initially, then on a timeout (typically when the motion's first cycle completes) rewrites the cache file replacing the motion class with the matching `opt-pin-*` class. The pin clears when (a) the daemon detects the underlying state changed, (b) the user hovered the pill (waybar emits no hover-out event the daemon can subscribe to directly — for now, hover-clears the pin only when the daemon polls a state that the hover indirectly fixes), or (c) the user clicked the pill (the click handler invokes a "clear-pin" path the daemon honors).

Pins never animate — they are calm, persistent, solid. The point is the *absence* of motion after the call: stable signal the user can sit with.

### Pushed (toggle ON)

`opt-pushed` is the binary "this toggle is currently engaged" modifier. Composes orthogonally with state colors and animations:

- `opt-pill opt-pushed` — engaged, neutral (shader texture is on).
- `opt-pill opt-pushed opt-yes` — engaged AND good (WiFi radio on AND connected).
- `opt-pill opt-pushed opt-breathe` — engaged with ambient activity (microphone recording).

CSS: `box-shadow: inset 0 2px 5px @opt-pushed-shadow` (single soft top-inset shadow, 4 px blur, 35% alpha). The pill's rest face — parent surface, child surface, or state color when combined with opt-yes/middle/no — is preserved; the shadow alone signals "engaged." **No hard borders anywhere in OPTIONS.** The earlier 1 px inset border + dark surface combo (which painted a black stamp over the pill's identity) was replaced 2026-05-28 — subtler, keeps state colors readable, no competing outline.

### Dimmed (occupied, not selected)

A peer item that exists but is not the focus. Reduced opacity (0.45), surface unchanged, no state color. Implemented in `style.css` as `.inactive` — the class the workspace daemon already writes for `ws-1..9` when those workspaces have windows but aren't current. The semantic vocabulary name is **dimmed**; the wired class is `.inactive`. Rename to `.opt-dimmed` is deferred until the workspace daemon migrates from `~/.config/waybar/scripts/` to a Nix-managed script — cross-repo coupling would break dimming during the transition window otherwise.

### The hover system (one mechanism, one place)

Every pill's hover is decided by ONE of two rules — never more. The CSS is structured so any future hover behavior fits into this binary.

**Rule A — `opt-hover-bright` (universal default).** A single declaration on `.opt-pill:hover, .opt-pill-child:hover`: `box-shadow: inset 0 0 0 999px @opt-hover-bright` (semi-transparent white film, 0.30 alpha). The film layers OVER each pill's existing background-color — identity preserved (blue brightens to light-blue, red to light-red, neutral to near-white-gray). Every pill gets this for free. **Do not write per-state or per-pin hover declarations to "apply the brighten" — they are redundant; the canonical rule already matches.**

**Rule B — per-pill override (only when the pill has a SPECIFIC hover face).** Today three families override:
- `opt-pushed:hover` — keeps the soft pressed-in shadow AND adds the brighten film via a two-stop `box-shadow: inset 0 2px 5px @opt-pushed-shadow, inset 0 0 0 999px @opt-hover-bright`. Both shadows are inset, both fit inside the pill, both visible at once.
- `opt-plus:hover` — blue surface, plus SVG, `opt-pulse-plus` animation, `color: transparent` to hide the underlying glyph. Used by every `+` pill (Rule 6).
- Any future wired `opt-swap-<kind>` with its own SVG action-reveal — same pattern as opt-plus.

**Unwired swap kinds (`opt-swap-switch`, `opt-swap-cal`, `opt-swap-pct`) deliberately have NO :hover rule.** They inherit Rule A. Their text stays visible; the surface brightens. A preemptive `color: transparent` rule for unwired swaps makes labels vanish into nothing on hover (bit `window`, `clock`, `battery` once — fixed 2026-05-28). Per-swap label-hide belongs INSIDE the per-swap rule that paints the replacement face, not in a shared block.

**The discipline:** when adding a new pill kind, ask "does its hover have a SPECIFIC face?" If no → don't touch hover CSS, Rule A covers it. If yes → write ONE per-pill :hover block that includes ALL the override (color, bg-image, animation, label transparency). Never split hover behavior across multiple shared blocks.

### Action pill (`opt-plus`) — the same-option rule operationalised

**Rule 6 from the README** (same option = same look) is implemented today by the `opt-plus` class. Every `+` pill in the bar carries it:

- `custom/new` (apps launcher) — `opt-pill opt-plus`. Empty label content; the + SVG is the visible glyph at rest.
- `win-move-new` (move-window-to-new-workspace) — `opt-pill-child opt-plus`. Same shape, child surface.
- `ws-current` (workspace pill) — `opt-pill opt-plus opt-swap`. The `opt-swap` modifier hides the + SVG at rest and shows the workspace number instead. On hover, the number disappears and the canonical `+`/blue/`opt-pulse-plus` face appears — pixel-identical to the other two `+` pills at the moment of hover.

CSS contract for `opt-plus`:

- At rest: `background-image: url(plus-{white,black}.svg)` (theme-adapted), `background-size: 14px 14px`, `color: transparent` (label text hidden so the SVG is the only visible glyph), `min-width: 14px` (gives the empty-label pill physical presence).
- On hover: `background-color: @opt-blue`, same SVG, `animation: opt-pulse-plus 1s ease-in-out infinite alternate`.
- `opt-plus.opt-swap` at rest: SVG hidden (`background-image: none`), label visible (`color: @opt-text-on-dark` / `@opt-text-on-light`). Hover reverts to the parent `opt-plus:hover` rule.

When adding a NEW recurring option (kill, shutdown, lock — any verb that will appear in multiple places), name a class for it (`opt-kill`, `opt-shutdown`, …), define its rest + hover faces ONCE in `style.css`, and wire every instance to that single class. Same-option-rule violations are caught at code-review by checking: "are two pills emitting the same verb via different class strings?"

### Tooltips

Every text-bearing pill whose function isn't fully self-evident from icon + label declares `"tooltip": true` and emits a `tooltip` field in its JSON output. The tooltip popup is styled in `style.css` via the bare `tooltip` selector (the popup floats outside `window#waybar`, so the usual ancestor-scoping convention doesn't apply here). GTK's hover delay (~700 ms) is the canonical reveal; we do NOT try to override it — consistency with system-wide GTK feel is more valuable than precision.

Tooltip text rules:

- One word naming what the pill IS — `"Volume"`, `"Screen"`, `"Battery"`, `"Network"`. Current value lives ON the pill, not in the tooltip.
- The tooltip answers "what does this pill do?", not "what's its current state" and not "is there a keyboard shortcut?".
- Forbidden: restating the icon, naming the technology (`"swaylock"`, `"rofi -show drun"`), hinting at hardware keys (`"F3 raises"`), multi-line essays.
- Self-evident pills get `"tooltip": false` (launcher `+`, workspace numbers, focused-window title).
- The quiet-invitation pillar is implemented through PHYSICAL ease (pressing F3 is faster than hunting for the pill), NOT through textual nags. Discovery happens because buttons are physically easier, not because the bar advertises them.

### Hardware-button reflection (pillar 6, operationalised)

The OS reflects user-pressed hardware keys in the bar so the user sees their input acknowledged in the same OPTIONS vocabulary they'd touch with the mouse. This is the surface of pillar 6 — mouse-first, button-easier — made concrete.

**Single source of truth: the permanent home IS the transient home.** Each basic-action concern (volume, brightness, screenshot, mute, media, airplane) is a *single* module with one cache file at `/tmp/waybar-cache/<name>` and two surfacing conditions:

- **Real state present** → the module renders permanently (player open → player pill is up; mute on → audio pill is `opt-pushed`; volume nonzero AND default sink present → audio pill visible). No 4-s timer involved.
- **Hardware key fired AND no permanent state to anchor on** → the module surfaces for **4 s after the last interaction** (key press, hover, click), then collapses to `.empty`. The 4-s timer resets on any subsequent same-key press, hover, or click on the pill.

No separate "transient pill" exists. The daemon writes the same cache file regardless of why the pill is up. When the user sees the audio pill, it always means the same thing.

**Per-concern zone home:** each action has a home zone where the pill lives — both permanent and transient.

| Concern | Zone | Permanent condition | Transient trigger |
|---|---|---|---|
| Volume / mute | SYSTEM | always (default sink exists) | (n/a — permanent) |
| Brightness | SYSTEM | (transient only) | XF86MonBrightness{Up,Down} |
| Airplane / radios | SYSTEM | always (the radios cluster exists) | XF86RFKill (toggles `opt-pushed` on the cluster) |
| Media player | USER (where the user IS — bound to the focused work) | MPRIS player exists | XF86Audio{Play,Pause,Next,Prev} when player exists; if no player, the key is a no-op |
| Screenshot | SYSTEM | (transient only) | screenshot key OR mouse-path option click |

**`opt-flash` lifecycle (CSS).** The daemon writes `opt-flash` in the class list on the snapshot that follows a key press. The CSS animation is one-shot 250 ms, default fill-mode — it plays once and the property reverts to the pill's static styling. The class can sit in the JSON output after the animation completes (GTK won't replay) until the next snapshot. The daemon is *not* required to remove it — it's harmless once played. For rapid same-key repeats where the user expects each press to flash, the daemon must vary the class string between snapshots (e.g., alternate `opt-flash` and `opt-flash-r`); single-class repeats won't re-trigger the animation. (Wire this in the per-key daemon, not in CSS.)

**Screenshot module shape.** Screenshot is fire-and-forget but produces an artifact. The module's transient face shows `"Saved"` (or a short filename) for 4 s after the keystroke. Click opens the image in the user's image viewer. Hover surfaces a cluster of screenshot-related options (open folder, copy path, delete, share, edit). Mouse-path: the explicit screenshot option lives somewhere in the SYSTEM zone or future control-panel row — clicking it triggers the same daemon path the hardware key does, producing the same "Saved" pill response. Single code path, two entry points.

**Hardware coverage stance.** Not every machine has every key. Wire the common ones (volume up/down/mute, brightness up/down, play/pause/next/prev, screenshot, airplane). Less-common keys (keyboard backlight, dedicated mic mute, media-source toggle) get added best-effort as users surface them. Document in the daemon source what's wired and what isn't; do not block shipping on full hardware-key parity. The distro pillar — works for every person — is served better by 80 % of keys working everywhere than by a perfectionist guardrail.

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
# No rebuild needed for the .css / .jsonc themselves. The waybar.nix module
# uses `mkOutOfStoreSymlink`, so ~/.config/waybar/{config.jsonc,style.css}
# symlinks DIRECTLY to /etc/nixos/home/waybar/{config.jsonc,style.css} —
# the source IS the live file. Verify with:
#   readlink -f ~/.config/waybar/style.css
#   # → /etc/nixos/home/waybar/style.css   ← source path, not a /nix/store hash
# If that ever shows a /nix/store/*-hm_style.css path, someone removed
# mkOutOfStoreSymlink from waybar.nix and edits are silently swallowed by
# the store copy until the next `nixos-rebuild switch`. Restore the
# `config.lib.file.mkOutOfStoreSymlink cfg.styleSource` wrapping in the
# module — see waybar.nix's "out-of-store symlinks" header note.

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

1. **Closed budget.** 6 colors + 4 motions + 2 surfaces. No exceptions without written justification in a commit message. **No hard borders anywhere** — `opt-pushed` is a soft top-inset shadow on the pill's existing surface, not an outline.
2. **The pill primitive is the start of every visual.** Deviate only when the deviation is itself a visible semantic (e.g. empty-collapse). Document the deviation in CSS as a comment.
3. **Hover = brighten the rest color.** Universal `box-shadow: inset 0 0 0 999px @opt-hover-bright` overlay, layered over each pill's existing background. State pills (opt-yes/middle/no) brighten via the same overlay; identity preserved. Action pills (`opt-plus`, future kill/shutdown/disable) override with their own complete `:hover` block — never split between shared rules.
4. **Input is acknowledged; context shifts are silent.** Motion runs in response to user action (key press, hover, click) or as a system call for attention the user should resolve (pulse/glow/breathe/pin). Context-driven appearance and disappearance — focused window class changed, audio sink came up, workspace went empty — is instantaneous, no fade, no flash. The bar adapts; it does not perform on its own.
5. **Every text-bearing pill respects `/tmp/glass-mode`** and emits a `light`/`dark` class. Forgetting this makes the pill invisible over half of wallpapers — a silent regression.
6. **Modules don't consult each other.** Each module subscribes to context signals from its source of truth and decides its own visibility. Cross-module coupling is a maintenance smell.
7. **Daemon, not poll, when possible.** Use event-driven sources (`socat hyprland-socket2`, `nmcli monitor`, `pw-mon`, `wl-paste --watch`). Polling is a cost ceiling — fine for low-frequency status (battery every 30 s) but never for reactive UX.
8. **`pkill -RTMIN+N waybar` only on real change.** Dedup the cache write at the writer (in-memory `last_value` compare). The mpris CPU regression of 2026-05-27 was caused by signaling on every tick whether content changed or not.
9. **Atomic file writes.** Every `/tmp/waybar-cache/*` write is `printf '%s' "$content" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"`. Half-written cache files make waybar render empty pills.
10. **Trigger vs action.** Small icon-only pill = trigger (opens a cluster). Long pill displaying a value = action target. Choose explicitly when adding a new pill; the choice is binding for the pill's lifetime.
11. **Expansion direction follows the zone.** Left zone groups → `transition-left-to-right: true`. Right zone groups → `false`. Center zone follows the task-anchor rule (right of task → right, left of task → left).

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
- **Per-swap label hiding belongs INSIDE the per-swap :hover block, not in a shared preemptive rule** (2026-05-28). A shared block like `.opt-swap-switch:hover, .opt-swap-cal:hover, .opt-swap-pct:hover { color: transparent }` makes labels vanish on hover even though those swaps' SVGs aren't wired yet — `window`, `clock`, `battery` text disappeared into nothing on hover for two days. The discipline: when a swap kind gets its SVG, write ONE per-kind `:hover` block that paints background-image AND hides the label AND adds the light-mode label override (4-class specificity to beat the canonical `.opt-pill.light:hover label` rule at 3-class specificity). Until the SVG is wired, the swap kind has NO :hover rule and inherits the universal brighten. Reference impl: `.opt-plus:hover` + `.opt-pill.opt-plus.opt-swap.light:hover label`.
- **Persistent blue (`opt-yes`) is for STATE, not for action verbs** (2026-05-28). The apps launcher used to be `opt-yes` ("primary go action" — but that's a verb, not a state). Under Rule 6 it now uses `opt-plus`. When you find yourself reaching for `opt-yes` to make a button "look like it does something", check: is the blue communicating a state (this thing is good / on / connected) or just decoration on an action verb? If the latter, the action belongs in the same-option family (`opt-plus`, future `opt-kill`, etc.) — not in `opt-yes`.
- **Empty-text custom modules are HIDDEN by waybar** (2026-05-28). Setting `"text":""` in the JSON output causes waybar to hide the module entirely (the GTK button still exists in the layout for hover purposes, but is rendered 0×0 / invisible). Bit the apps launcher and `win-move-new` after the opt-plus refactor — both emitted empty text expecting the CSS background-image to be the visible glyph. Fix: pass a non-empty character (we use the FA plus glyph U+F067 for `opt-plus` pills) and let `.opt-plus { color: transparent; }` hide the text so only the SVG renders. The non-empty text is purely a "keep this pill alive" sentinel.
- **No-op pills must collapse, not visually de-emphasise** (Rule 7, 2026-05-28). When an action would have no effect (move to current WS, switch to current sink, open the already-open app), the pill emits `class: "<theme> empty"` so the CSS empty-collapse rule shrinks it to zero presence. Do NOT use `opacity: 0.4` or `.inactive` for no-op pills — those vocabulary tokens mean "occupied but not selected" (a peer that exists, just isn't current). A no-op is structurally different: the option *cannot* be taken from here. Collapse, don't dim.
- **CSS `font-family` must list CANONICAL font names, not nixpkgs package names** (2026-06-06). Fontconfig matches on the family name embedded in the font file (queryable via `fc-match "<name>" family`), NOT on the nixpkgs package basename. `font-family: font-awesome, meslo-lg, meslo-lgs-nf` silently resolved to DejaVu Sans for ALL three — and fontconfig then did per-glyph substitution to whatever Nerd Font happened to contain each codepoint. Result: text pills (clock) rendered in DejaVu Sans at 13px; icon-only pills (tools, power, battery, warm-cycle, …) rendered in fallback Nerd Fonts whose visual cap-height at 13px is smaller than DejaVu Sans alphanumerics — making every glyph pill look smaller than the clock for months without anyone noticing. The regression became loud when `font-awesome` bumped 6→7 in nixpkgs and the new `"Font Awesome 7 Free"` family name was even further from the package name. **Discipline:** every font name in the CSS must be verified with `fc-match "<exact CSS name>" family` returning that same family — not a fallback. Today's canonical chain on the bar is `"MesloLGS NF", "Font Awesome 7 Free", "Symbols Nerd Font Mono", monospace` (declared system-wide in `/etc/nixos/modules/desktop.nix` `fonts.packages`). When a font package bumps major version, re-run `fc-match` on every name in the chain before claiming the bar still works on a fresh install. Per-pill exception: `#custom-window label` overrides back to `sans-serif` because the focused-window TITLE reads better proportional, not monospace.
- **Standalone `#custom-X { ... }` blocks SHADOW `.opt-pill` via ID specificity** (2026-06-06). A rule like `#custom-dictate { font-size: 12px; padding: 1px 8px; background: transparent; ... }` outranks `window#waybar .opt-pill { font-size: 13px; ... }` because `#id` is more specific than `.class`. Even when the writer puts `opt-pill` in the class array, the standalone block wins on every property it duplicates — making the pill visibly smaller / different geometry than every other pill on the bar. `#custom-dictate` and `#custom-power-resume` both carried 12px standalone blocks; power-resume shipped 2026-06-05 and the regression became visible the next day after the first resume failure pill surfaced. Fix: writers emit `["opt-pill", "dark", ...]` and `#custom-X` rules only carry the STATE deltas the canonical pill genuinely doesn't have (e.g. `.recording` background-color + animation, `.empty` collapse). Rule of thumb: if a property on `#custom-X` exists in `.opt-pill`, delete it from `#custom-X`. Sanity check: `grep -nE '#custom-[a-z-]+ \{' style.css` — every block should be a STATE selector (`.recording`, `.empty`, …), not a bare ID rule re-implementing geometry.

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
