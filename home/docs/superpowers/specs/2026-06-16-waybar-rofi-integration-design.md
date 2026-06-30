# Waybar ↔ rofi integration

**Date:** 2026-06-16
**Status:** approved (design)
**Bellwether:** `notif-menu`. Five more surfaces follow.

## Soul

OPTIONS is the shell. The user shouldn't be able to tell a difference between waybar and rofi — they're both OPTIONS, just two surfaces of the same language. A rofi menu IS the body of the pill that triggered it, unveiled in place.

Two non-negotiables fall out of that:

1. **A rofi menu always appears under its trigger pill.** Universal mechanism, working across monitors, resolutions, and scale. No drift when sibling pills appear or disappear.
2. **A rofi window styles as a wide pill from the same closed budget.** 6 colors, 4 motions, 2 surfaces, no hard borders. Light/dark via `/tmp/glass-mode`. Bright-hover universal.

## Six surfaces to unify

| # | Surface | Trigger | Current theming |
|---|---|---|---|
| 1 | `notif-menu` (L1/L2) | `notif-bell` on-click | inline `-no-config -theme-str` |
| 2 | apps launcher (`rofi -show drun`) | 5× in `waybar/config.jsonc` + Hyprland `$mod+SPACE` | global `~/.config/rofi/config.rasi` |
| 3 | window switcher | `~/.config/rofi/window-switcher.sh` | TBD per script |
| 4 | restore-minimized | `waybar/scripts/restore-minimized.sh` | global config |
| 5 | reboot/shutdown prompt | `waybar/scripts/standard-os-reboot-prompt` | global config |
| 6 | `notif-rofi` (legacy) | still on PATH | inline `-no-config -theme-str` |

Scope of THIS spec: deliver the three shared artefacts (registry, anchor library, rasi sources) and migrate surface #1 end-to-end. Surfaces 2–6 propagate in subsequent commits, each its own stream per Standard-OS commit discipline.

## Architecture (three artefacts)

### 1. `pill-geom` registry

**Responsibility added to** `/etc/nixos/home/waybar/scripts/lib/pill.sh`.

Every `pill_write <name> <text> <classes> [tooltip]` ALSO writes a single keyed JSON record to `/tmp/waybar-cache/pill-geom.json` (atomic tmp+mv, dedup'd to avoid signal churn).

Schema:
```json
{
  "notif-bell":  { "x": 420, "y": 25, "w": 28, "monitor": "eDP-1" },
  "notif-dnd":   { "x": 0,   "y": 25, "w": 0,  "monitor": "eDP-1" },
  "apps":        { "x": 960, "y": 25, "w": 32, "monitor": "eDP-1" }
}
```

- `x`, `y`, `w` in **logical** screen pixels (monitor's coord space, scale unapplied).
- `.empty` pills emit `w: 0` and are skipped in cumulative-width computation for siblings.
- `monitor` is the focused-monitor name at emit time, read from `/tmp/waybar-cache/hypr-context.json`.

Width is **estimated** at emit time from constants in pill.sh:

```bash
PILL_PAD_X=8          # padding-left + padding-right (combined)
FONT_ADVANCE_PX=8     # average glyph advance for the bar font at 13pt
# w = PILL_PAD_X + (char_count * FONT_ADVANCE_PX)
```

Both constants tunable in one place; ±10px error acceptable (visual center-under-pill, not pixel-exact).

X is computed from zone start + cumulative `w` of preceding rendered siblings in the same zone. Zone starts come from the bar layout (USER zone starts at monitor.x; SYSTEM zone ends at monitor.x + monitor.w; TASK zone center = monitor.w/2). The cumulative walk reads the existing pill-geom entries for siblings — so it's eventually-consistent (after a few render cycles).

### 2. `rofi-anchor.sh` library

**New file:** `/etc/nixos/home/scripts/lib/rofi-anchor.sh`.

Exports:

```bash
# Reads pill-geom.json for the current focused monitor; computes
# (x_offset, y_offset) anchoring rofi's top-center to the pill's
# bottom-center + 4px gap. Prints a -theme-str fragment ready to
# pass to rofi as one argument.
rofi_anchor_for <pill-id>
# stdout: -theme-str 'window { location: northwest; anchor: north; x-offset: 420px; y-offset: 29px; }'

# Reads /tmp/glass-mode (default "dark"). Prints absolute path
# to the matching options-{mode}.rasi file.
rofi_theme_for_mode
# stdout: /etc/nixos/home/rofi/options-dark.rasi

# Convenience composition for launchers:
rofi_launch <pill-id> <prompt> [extra rofi args...]
# Reads stdin → rofi -theme $(theme) $(anchor) -dmenu -i -p "$prompt" "$@"
```

Fallback behavior:
- Pill not in registry → centered on trigger pill's zone end (USER zone right edge, TASK zone center, SYSTEM zone left edge), computed from monitor geometry.
- `/tmp/glass-mode` missing → `dark`.
- `hypr-context.json` missing → first monitor's geometry, no scale correction.

### 3. Shared rasi sources

**New directory:** `/etc/nixos/home/rofi/`, Nix-managed via the existing home-manager rofi module (to be added).

Files:

- `options-base.rasi` — shape, sizing, surface tokens for the wide-pill container, row template, action-row pill template, section-header style, universal bright-hover film. Mirrors `waybar/style.css`'s `@opt-*` palette.
- `options-light.rasi` — `@import "options-base.rasi"` + light-mode color overrides.
- `options-dark.rasi` — `@import "options-base.rasi"` + dark-mode color overrides.

Old `~/.config/rofi/config.rasi` becomes a `mkOutOfStoreSymlink` → `options-dark.rasi` (default for invocations that don't pass `-theme`, e.g. Hyprland's `$mod+SPACE` before its launcher gets the anchor treatment). The existing standalone `~/.config/rofi/` git repo continues to hold non-theme assets (`offers/`, `window-helper.sh`, `window-switcher.sh`); only `config.rasi` migrates.

## Visual treatment (wide-pill container)

The notif-menu rofi window IS a wide pill from the OPTIONS family.

| Element | Rest face | Hover face |
|---|---|---|
| Window | Parent surface (light/dark), `border-radius` matching `.opt-pill`, no border | n/a |
| Row (default) | Transparent background, light/dark text color from glass-mode | `background-color: @opt-hover-bright` (white 0.30 alpha) — universal bright-hover |
| Action row (verbs) | Child surface, rounded — reads as opt-plus-style action pill | Bright-hover film on top |
| Section header | Smaller font, lower opacity, non-selectable (rofi `urgent` state) | n/a |
| Notification row | Plain text + `\0icon\x1f<app_name>` icon metadata | Bright-hover film |

Window width: 480 logical px for notif-menu (tunable per surface).

Action rows are emitted by `notif-rofi-format.sh` with a leading marker. Concrete encoding (literal prefix consumed at format time vs. `\0meta` row metadata) is selected at implementation time inside the bellwether stream, based on what rofi's row tokenizer accepts without colliding with the existing `\0icon\x1f<app>` icon metadata. Section headers continue using the existing dim-non-selectable rendering pattern.

## Per-launcher pattern (notif-menu example)

Inside `notif-menu`'s `run_rofi`:

```bash
source /etc/nixos/home/scripts/lib/rofi-anchor.sh

run_rofi() {
    local prompt=$1
    local anchor; anchor=$(rofi_anchor_for notif-bell)
    local theme; theme=$(rofi_theme_for_mode)
    rofi -theme "$theme" $anchor -dmenu -i -p "$prompt" -no-custom -format i \
        -theme-str 'window { width: 480px; }' \
        -kb-cancel "Escape,MouseSecondary"
}
```

The existing inline `-theme-str` block (window/inputbar/listview/element rules) is deleted — that styling now lives in `options-{light,dark}.rasi`.

## Light/dark behavior

- `pill_write` already reads `/tmp/glass-mode` to emit the `light` / `dark` class on text-bearing pills.
- `rofi_theme_for_mode` reads the same file and picks the matching .rasi.
- If glass-mode flips WHILE rofi is open: rofi can't reload its theme; popup stays in old mode until close. Acceptable — popups are short-lived.

## Multi-monitor

- Registry stores `monitor` per pill entry.
- Launcher reads `hypr-context.json` for the current focused monitor; looks up the trigger pill's entry on that monitor.
- If the trigger pill exists only on a non-focused monitor: rofi still opens on the focused monitor (because rofi follows the focused output by default), anchored under the corresponding zone start/center/end of the focused monitor's geometry (fallback path).

## Error handling

- Missing pill-geom entry → zone-relative fallback anchor.
- Missing /tmp/glass-mode → dark.
- pill-geom.json corrupt or unparseable → zone-relative fallback, log to stderr (visible in `journalctl --user -u waybar`).
- Atomic write contract (tmp+mv) shared with all other cache writes; consumer never sees a half-written file.

## Verification (the OPTIONS checklist)

Before claiming done:

- [ ] Visual A/B: notif-menu open over a waybar screenshot — wide-pill container, action rows, hover film all read as one family. Light AND dark.
- [ ] Anchor: open notif-menu over each monitor configuration at hand (1× internal at 200% scale). Confirm visually-centered-under-bell.
- [ ] Empty-collapse: induce a `notif-action-*` pill to go `.empty`; confirm bell anchor X reflects shifted siblings on next launch.
- [ ] Glass-mode flip between launches: confirm theme follows.
- [ ] No regression to existing rofi surfaces (apps launcher, reboot prompt, etc.) — they still launch with the OLD global config.rasi until their migration commit. (Migration to shared base is OUT OF SCOPE here.)
- [ ] Class arrays still emitted correctly (no string-class regressions from pill.sh changes).
- [ ] `pill-geom.json` is updated atomically; no half-writes observed under high pill-update load (e.g. workspace switch storm).
- [ ] TODO.md entry moved to DONE with Hint lines pointing at this spec + the resulting plan.

## Out of scope (deferred to follow-up commits)

- Migrating apps launcher (5 sites + Hyprland keybind) to shared theme + anchor.
- Migrating window switcher, restore-minimized, reboot prompt, notif-rofi legacy.
- Deleting `~/.config/rofi/config.rasi` or its standalone git repo (kept until all migrations done).
- The `notif-rofi-format.sh` action-row marker mechanism — concrete encoding decided at implementation time inside the bellwether stream.

## Hazards

- Hand-built JSON for `pill-geom.json` must use array literals if any string contains spaces — same trap as the `class` field (see Standard-OS hazards).
- `pill-geom` writes must dedup — every emit shouldn't trigger waybar-side signals unless the previous content differs (avoid the mpris 130% CPU regression pattern).
- Action-row marker must survive rofi's row tokenizer (no nul, no `\x1f` collisions with the existing icon metadata).
- `rofi -theme-str` arguments are space-sensitive; `$anchor` must be a single shell argument (use `eval` or array expansion, NOT bare `$anchor` if it contains spaces — design choice deferred to implementation).
- The 4px gap below the bar may collide with existing pill drawer expansion if the user hovers a sibling — verify rofi popup sits ABOVE the bar drawer in layer-shell ordering.
- Glass-mode flip during a long-running rofi session (rare, but: idle reboot-prompt sitting open while screen dims): popup carries stale theme. Accepted.

## Commits

Bellwether stream ships as ONE commit (per Standard-OS commit discipline: close a stream before opening the next), containing:
- pill.sh registry write
- `lib/rofi-anchor.sh`
- `/etc/nixos/home/rofi/options-{base,light,dark}.rasi`
- Nix module wiring (xdg.configFile / home-manager rofi config)
- `notif-menu` launcher rewrite (inline `-theme-str` removed, library calls added)
- `notif-rofi-format.sh` action-row marker addition
- TODO.md entry promoted from… (none yet — goes straight to DONE per the unplanned-completion rule, with Hint lines pointing here and at the plan).
