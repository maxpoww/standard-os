# OPTIONS — Foundation pass design

**Date:** 2026-05-28
**Status:** approved, ready for implementation
**Scope:** style.css + config.jsonc + ~/.config/waybar/scripts (deep refactor — this is the base every future option builds on)

## Why

The README defines a 6-color + 3-motion + 2-surface budget and a single pill primitive. The implementation does not yet honor the budget:

- Hover paints a generic gray-violet for every pill instead of "current color brighter."
- Per-pill literals (red 0.60, yellow 0.50, blue 0.55, green 0.50, hard `#6666ff` etc.) violate the closed budget.
- The declared `@opt-*` tokens are unused; all literals are inline.
- Pre-OPTIONS keyframes (`blink`, `shine`, `pulse-plus`) replace the canonical `opt-pulse` / `opt-glow` / `opt-breathe`.
- Child surface (warm `rgba(70,50,50,.30)`) declared but unused — drawer children still wear parent surface.
- Style is targeted by `#custom-<id>` lists hundreds of lines long; every new module re-edits three giant comma-lists.

Result: the bar looks close to the spec but breaks the rules in ways that block scale. Every future option would inherit the inconsistency.

This foundation pass fixes the bones: a small class vocabulary, a tokenized CSS engine, a shared helper library, and a daemon convention. After this lands, adding a new option = emit the right classes; CSS does the rest.

## Class vocabulary (the contract)

Every pill emits a `class` field that is a space-separated set of classes from this closed set. CSS targets ONLY these classes — `#custom-<id>` selectors are reserved for pill-specific assets (swap-icon URLs) and nothing else.

### Structure — one required

| Class | Surface | Used by |
|---|---|---|
| `opt-pill` | parent (`rgba(50,50,70,.30)`, cool) | top-level pills sitting permanently on the bar |
| `opt-pill-child` | child (`rgba(70,50,50,.30)`, warm) | pills revealed inside an expanded drawer |

The parent/child distinction is declared by the emitter — not derived from the GTK DOM — because waybar's drawer mechanism doesn't expose an "I'm an expanded child" state to CSS.

### Theme — one required (glass-text-daemon driven)

| Class | Text |
|---|---|
| `dark` | white (default; for dark wallpapers) |
| `light` | dark + soft white text-shadow (for light wallpapers) |

### State — zero or one (mutually exclusive, persistent)

| Class | Paint | Meaning |
|---|---|---|
| `opt-yes` | blue (`@opt-blue-state` at rest, `@opt-blue` on hover) | YES / on / connected / good |
| `opt-middle` | yellow (`@opt-yellow-state` / `@opt-yellow`) | MIDDLE / partial / attention |
| `opt-no` | red (`@opt-red-state` / `@opt-red`) | NO / off / destructive |
| *(none)* | baseline surface | most pills, most of the time |

**Blue is always good.** Baseline (no state class) is the resting "I have nothing to say about this" surface. A healthy bar reads predominantly blue + baseline, with yellow/red only where the system genuinely has something noteworthy.

### Animation — zero or one (additive, transient)

| Class | Cadence | Default tone | Meaning |
|---|---|---|---|
| `opt-pulse` | ~1 Hz | orange | urgent — look now |
| `opt-glow` | ~2 s fade-in/hold/out | green | offer — the system has a suggestion |
| `opt-breathe` | ~6 s sine | violet | ambient healthy — background activity |

Tone overrides (`opt-tone-red` / `opt-tone-yellow` / `opt-tone-blue`) swap the destination color to the same-family alternative. Rare; canonical pairings cover 90% of cases.

### Empty (collapse)

`empty` collapses the pill to zero width, zero opacity, zero font-size. Existing convention; keep.

### Hover-swap (the "ws-current concept")

`opt-swap` declares the pill morphs on hover: rest face = information (e.g. current WS number), hover face = action (e.g. "+" to make a new one). Single shared CSS mechanic; one per-pill rule names the action glyph and tone.

```css
.opt-swap:hover label { color: transparent; text-shadow: none; }
.opt-swap:hover {
    background-repeat: no-repeat;
    background-position: center;
    background-size: 14px 14px;
}
.opt-swap-plus:hover {
    background-image: url(".../plus-white.svg");
    animation: opt-pulse-blue 1s ease-in-out infinite alternate;
}
.opt-swap-plus.light:hover { background-image: url(".../plus-black.svg"); }
```

Day-one swap pills:

| Pill | Rest face | Hover face | Class |
|---|---|---|---|
| `ws-current` | current WS number | "+" → go to empty | `opt-swap-plus` |
| `window` (focused) | app icon | switcher glyph | `opt-swap-switch` |
| `clock` | time | calendar glyph | `opt-swap-cal` |
| `battery` | battery icon | percent reading | `opt-swap-pct` |

### Example pill specs

```
"opt-pill dark"                          → neutral baseline pill, white text
"opt-pill light opt-yes"                 → blue state, dark text (light wallpaper)
"opt-pill dark opt-no opt-pulse"         → red state, pulsing orange (battery critical)
"opt-pill dark opt-yes opt-breathe"      → blue state, breathing violet (battery full)
"opt-pill-child light"                   → bare child pill in a drawer
"opt-pill dark empty"                    → collapsed slot
```

## Day-one state mapping

### USER zone

| Pill | Class | Notes |
|---|---|---|
| `ws-current` | `opt-pill opt-swap-plus` | neutral parent surface at rest; hover swaps to "+" with the canonical `opt-pulse-plus` animation (bg-size 14→10, blue ladder). NO `opt-yes` at rest — the WS module's visual identity is the number on baseline surface, not a permanent blue highlight. (Rolled back from a brief detour where ws-current had `opt-yes` — the user's feedback: "use the WS animation as a base for other applications, but don't change THIS module".) |
| `ws-1..9` (current) | `opt-pill` (theme only) | drawer siblings use parent surface, NOT child — they're peer locations, not sub-options of ws-current. Current ws has no extra class; the difference vs inactive is opacity, not paint. |
| `ws-1..9` (populated) | `opt-pill inactive` | parent surface, dimmed via `inactive` opacity 0.45 |
| `ws-1..9` (empty) | `opt-pill empty` | collapsed slot |
| `window` (focused) | `opt-pill opt-swap-switch` | value pill, hover → task-switcher glyph |
| `win-close` | `opt-pill-child opt-no` | destructive → red |
| `win-minimize` | `opt-pill-child` | non-destructive, baseline |
| `win-swap-right` | `opt-pill-child` | positional, baseline |
| `win-move-trigger` | `opt-pill-child` | drawer trigger, baseline |
| `win-move-1..9` | `opt-pill-child` | deeper drawer, baseline |
| `win-move-new` | `opt-pill-child opt-yes` | "create new" → blue |

### TASK zone

| Pill | Class | Notes |
|---|---|---|
| `new` (launcher "+") | `opt-pill opt-yes` | THE primary "go" action — always blue |
| `hidden` | `opt-pill-child` | drawer companion to launcher |
| `window` (center value) | `opt-pill opt-swap-switch` | baseline value, hover swap |
| `x` (restore) | `opt-pill` | baseline trigger |

### SYSTEM zone

| Pill | Class | Notes |
|---|---|---|
| `tools` | `opt-pill` | group trigger, baseline |
| `blue` (BT trigger) | `opt-pill` | baseline until BT daemon ships |
| `kill`, `scan`, `more` | `opt-pill-child` | BT drawer children |
| `wifi` (trigger) | `opt-pill` | baseline until WiFi daemon ships |
| `kill2`, `scan2`, `more2` | `opt-pill-child` | WiFi drawer children |
| `night-dimmer` | on = `opt-pill opt-yes`, off = `opt-pill` | toggle |
| `warm-cycle` | on = `opt-pill opt-yes`, off = `opt-pill` | trigger of screen-type group |
| `shader-paper`, `shader-newspaper` | on = `opt-pill-child opt-yes`, off = `opt-pill-child` | drawer children |
| `clock` | `opt-pill opt-swap-cal` | value, hover swap |
| `battery` (full) | `opt-pill opt-yes opt-breathe opt-swap-pct` | breathing healthy |
| `battery` (20-100%) | `opt-pill opt-swap-pct` | calm baseline |
| `battery` (10-20%) | `opt-pill opt-middle opt-glow opt-swap-pct` | attention |
| `battery` (<10%) | `opt-pill opt-no opt-pulse opt-swap-pct` | urgent |
| `dictate` (idle) | `opt-pill empty` | hidden |
| `dictate` (recording) | `opt-pill opt-yes opt-breathe` | alive, ongoing |
| `dictate` (transcribing) | `opt-pill opt-middle opt-glow` | processing |
| `power` | `opt-pill` baseline; hover = `opt-no` | destructive, but the destructiveness is only on commit |
| `reboot` | `opt-pill-child` | drawer child, baseline |
| `lock` | `opt-pill-child` | drawer child, baseline |

## CSS engine

style.css collapses to roughly:

- `@define-color` declarations for the full token set (only place rgba literals appear)
- One `.opt-pill { ... }` rule for parent surface base
- One `.opt-pill-child { ... }` rule for child surface base
- One `.opt-pill:hover` / `.opt-pill-child:hover` rule for the canonical "current color brighter" rule, written per-state-color (baseline hover, yes hover, middle hover, no hover) — same hue brighter, 35% white border
- One rule each for `.opt-yes`, `.opt-middle`, `.opt-no` rest-state paint
- One rule each for `.opt-pulse`, `.opt-glow`, `.opt-breathe` (default tones)
- One rule each for `.opt-tone-red`, `.opt-tone-yellow`, `.opt-tone-blue` (only matters when combined with a motion class)
- One rule for `.opt-swap` shared mechanic; one per swap kind for the action glyph
- One rule for `.light label` (dark text) and one for `.light:hover label`
- One rule for `.empty` collapse
- Keep `.opt-pill` collapse for `window#waybar.empty` cascading (focused-window-cluster collapse, existing)

Total: ~30 selectors, down from ~600 lines of comma-lists.

## Daemon convention

### Helper library

`~/.config/waybar/scripts/lib/pill.sh`:

```bash
pill_theme       # reads /tmp/glass-mode, defaults "dark"
pill_class ...   # joins variadic non-empty class names with single spaces
pill_emit text classes [tooltip]    # prints JSON to stdout
pill_write cache-name text classes [tooltip]   # atomic write + dedup + RTMIN+10
```

### Inline wrappers

`~/.config/waybar/scripts/pill <text> [class ...]` — emits `{"text":"<text>","class":"opt-pill <theme> <classes...>"}`. Used in `exec` of static pills.

`~/.config/waybar/scripts/pill-child <text> [class ...]` — same, with `opt-pill-child` base. Used inside drawers.

### Daemon-driven modules

`workspace-daemon.sh` and other writer scripts source `lib/pill.sh` and call `pill_write` per cache file. Each cache file holds one JSON object; the daemon dedupes against the previous content and only signals waybar on real change.

### config.jsonc shape

Inline single-shot:

```jsonc
"exec": "~/.config/waybar/scripts/pill '<glyph>'"
"exec": "~/.config/waybar/scripts/pill-child '<glyph>' opt-yes"
```

Daemon-driven:

```jsonc
"exec": "cat /tmp/waybar-cache/<name> 2>/dev/null"
```

## What gets deleted

- `#custom-<id>` hover hue-swaps (red 0.60, yellow 0.50, blue 0.55, green 0.50) — replaced by state classes + canonical hover.
- Power group hue paints (`#6666ff`, `#66ff66`, `#ff9999`) + `blink` keyframe — replaced by baseline + per-pill hover state where semantic.
- `shine` keyframe — replaced by `opt-glow-green` / `opt-glow-yellow` keyframes already declared.
- `pulse-plus` (the "+" hover pulse on ws-current) — replaced by `opt-pulse-blue` (blue is always good — the ws-current swap is a "go" suggestion, not urgency).
- Per-module comma-lists for the pill primitive (~114 lines), hover (~190 lines), light-text (~450 lines!) — replaced by 4 class rules.
- Inline `m=$(cat /tmp/glass-mode 2>/dev/null || echo dark); printf '{"text":"...","class":"%s"}' "$m"` everywhere — replaced by the `pill` wrapper.

## Out of scope

- Implementing BT / WiFi state daemons (the trigger pills stay baseline).
- Mpris module (already removed; its real-time signal RTMIN+12 is freed for future use).
- Multi-row "control panel" waybar instances.
- New options beyond what's currently on the bar.
- Migrating scripts/ into the Home Manager module via `writeShellScriptBin` (tracked separately).

## Risks

- `opt-swap-pct` for battery requires a real percent reading — currently the exec emits an icon. The exec needs the percent in `text` (so it appears at rest) and CSS hides label on hover. Manageable; just an exec change.
- Empty pill collapse cascades across the active-window group via `window#waybar.empty`. That selector stays. Adding pill-child classes to the same elements doesn't break it.
- Action-glyph SVGs for swap pills (plus / switch / cal / pct) — `plus-white.svg` and `plus-black.svg` already exist at `~/.config/waybar/icons/`. Need to verify the other three or fall back to font glyphs (Nerd Font has switcher / calendar / percent).

## Verification

- `jq . /etc/nixos/home/waybar/config.jsonc` returns valid JSON.
- `systemctl --user restart waybar` returns with status active.
- Manual: hover each pill; rest face shows info, hover face shows brighter SAME color (never a hue swap). Workspaces drawer reveals child-surface pills. Battery low → glow green; battery critical → pulse orange.
- `journalctl --user -u waybar -f` shows no GTK-CSS parse errors.

## Migration breadcrumb (post-spec)

The CLAUDE.md "Migration breadcrumbs" section gets updated to:

- ✓ Parent vs child surface differentiation — applied via `opt-pill` / `opt-pill-child`
- ✓ Color/motion budget — fully tokenized, all literals removed
- ✓ Three-zone explicit labelling — already present in config.jsonc; no change
- ✓ Hover = current color brighter — canonical rule live
