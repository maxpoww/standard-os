# Hypr-context unification — design

**Status:** approved 2026-06-13 (supersedes `2026-05-22-hypr-edge-bg-no-dive-design.md`,
which was never implemented).

**Why now.** Two daemons subscribe to Hyprland state today (`workspace-daemon`
polls `hyprctl` at 1 Hz; `hypr-activities` listens on `socket2`). Both publish
overlapping information for different consumers. `glass-text-daemon` reads the
bg system's PNG cache to infer wallpaper luminance, leaking bg internals into
OPTIONS theming. The bg layer itself runs a four-mode color matrix plus a
toggle CLI (`hypr-dive`) that the user has decided to drop. This spec replaces
the lot with one publisher, one rule, one consumer per concern — aligned with
the rule already written into `waybar/ARCHITECTURE.md` ("Every piece of system
state that more than one module might want lives behind a single daemon").

## Principle

ONE Hyprland subscription. Multiple consumers. The publisher knows nothing
about the consumers; consumers reach into a snapshot and per-pill cache files
that the publisher maintains atomically.

## Components

### 1. `hypr-context-daemon` (new — merge of `workspace-daemon` + `hypr-activities`)

- Single `socket2` subscription, 16 ms inline-debounced.
- On every transition that affects waybar pills, writes the **per-pill cache
  files** the workspace-daemon writes today (`/tmp/waybar-cache/{ws-current,
  ws-1..9, window, win-close, win-minimize, win-swap-right, win-move-trigger,
  win-move-1..9, win-move-new}`) and signals RTMIN+10. waybar config and CSS
  do not change.
- On every transition, ALSO writes the **snapshot**:
  `/tmp/waybar-cache/hypr-context.json`. Atomic write (`tmp + mv`), single line
  JSON, deduped against last-written content. **No signal** for snapshot
  consumers — they `inotifywait` on `/tmp/waybar-cache/` filtered by basename
  `hypr-context.json` (per the composite-module pattern in CLAUDE.md).
- Signal owner stays RTMIN+10 (already allocated to workspace-daemon).
- Runtime: bash + `socat` + one `hyprctl -j` per snapshot at most. No
  per-tick `jq` forks; use bash builtins and a single `jq` call per snapshot
  if needed.

### 2. `hypr-bg-daemon` (new — replaces `hypr-edge-bg` + folds in `glass-text-daemon`)

- `inotifywait` on `/tmp/waybar-cache/` filtered by `hypr-context.json` and on
  the waypaper config path (`~/.config/waypaper/config.ini`).
- On every event, evaluates THE rule (see "BG trigger rule" below).
- If rule fires → sample focused window's top-edge color (`grim | magick`,
  `-depth 8` for Q16 safety) → write `bg_<hex>.png` → `hyprpaper preload →
  wallpaper → unload previous` → write `light|dark` to `/tmp/glass-mode` based
  on hex luminance (ITU-R BT.601).
- If rule does not fire → restore current waypaper image as the wallpaper →
  write `/tmp/glass-mode` from the waypaper's pre-computed luminance (cached
  once when waypaper config changes; see "Waypaper luminance cache" below).
- No polling. Pure transition-driven.
- LRU PNG cache survives unchanged from current `ensure_solid_png` +
  `prune_cache` impl.

### 3. `glass-text-daemon` — **deleted**

Its sole responsibility (writing `/tmp/glass-mode`) moves into the bg daemon,
which is the only party that knows when the visible color behind the bar
changes. The contract file `/tmp/glass-mode` is unchanged: `light` | `dark`,
defaults to `dark` when missing. Every text-bearing pill keeps reading it
exactly as today. The hazard "hardcoded `dark` in pill class" stays unchanged.

## Snapshot schema (`/tmp/waybar-cache/hypr-context.json`)

```json
{
  "ts": 1718297400123,
  "monitor_focused": "DP-1",
  "monitors": [
    {"name": "DP-1", "x": 0, "y": 0, "w": 1920, "h": 1080, "scale": 1.0, "focused_ws": 2}
  ],
  "workspace": {
    "id": 2,
    "monitor": "DP-1",
    "window_count": 1,
    "tiled_count": 1,
    "floating_count": 0,
    "gaps_in": 0,
    "gaps_out": 0,
    "has_fullscreen": false
  },
  "focused": {
    "address": "0x55a1b2c3d4",
    "class": "firefox",
    "title": "GitHub – Mozilla Firefox",
    "x": 0, "y": 22, "w": 1920, "h": 1058,
    "fullscreen": 0,
    "floating": false,
    "pseudo": false,
    "workspace": 2,
    "monitor": "DP-1"
  }
}
```

Fields are the minimum set needed by current consumers (bg rule) and by
known-near-term consumers (per-window context surfacing in NEXT TODO,
fullscreen-aware behaviors). Adding a field later is cheap; removing one is
a contract break.

`gaps_in` / `gaps_out` are the **effective** values for that workspace
(per-workspace overrides applied). Parser uses the technique already in
`hypr-activities`: `hyprctl getoption general:gaps_out -j` returns
`{"custom":"N N N N"}`; split, tonumber, max. See known-hazards entry in the
standard-os skill.

`focused` is `null` when the workspace is empty (no windows).

`has_fullscreen` is published for future consumers (per-window context
surfacing, fullscreen-aware behaviors). The bg trigger rule does NOT consult
it — the geometric conditions below are sufficient.

## BG trigger rule (the only rule)

Paint a solid color **if and only if** ALL of the following hold for the
focused monitor:

1. `workspace.tiled_count == 1`
2. `workspace.floating_count == 0`
3. `workspace.gaps_out == 0`
4. `focused != null` AND `focused.floating == false` AND `focused.pseudo == false`

Otherwise → paint the waypaper image.

**Why no geometric check.** Empirical finding during impl (2026-06-13):
Hyprland reports window geometry in absolute monitor coordinates *including*
waybar's reserved zone, not in usable-area coordinates. A naïve
`focused.y == monitor.y` would never fire. The check could be repaired by
adding `monitor.reserved[top]` to the snapshot and comparing
`focused.y == monitor.y + reserved.top`, but Hyprland's layout system already
guarantees that a single tiled non-floating non-pseudo window with
`gaps_out == 0` fills the entire usable area. The geometric check is
redundant. Dropping it keeps the rule to four pure state-comparisons.

The `fullscreen` field is NOT consulted; if conditions 1–4 hold, fullscreen
mode is the strongest case and color is correct.

**Multi-monitor:** the rule is evaluated per-monitor against that monitor's
focused workspace. Hyprpaper supports per-output wallpaper. First impl may
ship single-monitor only; spec extension for per-output is in "Open
questions" below.

## Waypaper luminance cache

Need: when the bg daemon restores the wallpaper, it must know the wallpaper's
luminance to write `/tmp/glass-mode` without re-sampling on every transition.

Approach: cache it once per waypaper-config change. When inotify fires on
`~/.config/waypaper/config.ini`, the bg daemon resolves the image path,
samples a representative region with `grim`-less `magick <path> -resize 1x1
txt:- -depth 8`, computes luminance, writes the hex+mode to a sidecar file
(`/tmp/waybar-cache/waypaper-luminance.json` or similar). Subsequent restores
read this file directly. ~50 LoC.

## Deletions

- `/etc/nixos/home/scripts/hypr-dive` (file)
- `/etc/nixos/home/scripts/hypr-edge-bg` (file)
- `/etc/nixos/home/scripts/hypr-activities` (file)
- `~/.config/waybar/scripts/workspace-daemon.sh` (file)
- `~/.config/waybar/scripts/glass-text-daemon.sh` (file)
- `/etc/nixos/home/modules/hypr-edge-bg.nix` (file)
- `/etc/nixos/home/tests/hypr-edge-bg-test.nix` (file — re-create after
  unified daemon stabilises; see Open questions)
- All `mismatch_hex` / `mix_*` recipes from `scripts/lib/colors.sh`
- `DEFAULT_HEX`, `SHIFT_PCT`, `CLAMP_LO`, `CLAMP_HI` env vars + 4 nix module
  options (`defaultColor`, `mismatchShiftPct`, `mismatchClampMin`,
  `mismatchClampMax`)
- `dark_theme` gsettings producer pipeline + `glib` runtime dependency

## New / modified files

- **`/etc/nixos/home/modules/hypr-context.nix`** (new) — defines
  `services.hyprContext.enable`, packages the daemon as `writeShellScriptBin`,
  wires `waybar-hypr-context-daemon.service` (User unit). Renames /
  succeeds the workspace-daemon service.
- **`/etc/nixos/home/modules/hypr-bg.nix`** (new) — defines
  `services.hyprBg.enable`, packages the bg daemon as `writeShellScriptBin`,
  wires `waybar-hypr-bg-daemon.service`. `After=` the context daemon.
- **`/etc/nixos/home/scripts/lib/colors.sh`** — trimmed to `hex_to_rgb`,
  `rgb_to_hex`, `rgb_dist_sq`, plus a new `hex_luminance` (moved from
  `glass-text-daemon.sh`).
- **`/etc/nixos/home.nix`** — replace `./home/modules/hypr-edge-bg.nix`
  import with the two new module imports.
- **`/etc/nixos/home/modules/standard-os-resume-user.nix`** line 79 — update
  the resume daemon list: replace `workspace-daemon.sh glass-text-daemon.sh`
  with the two new unit names.
- **`/etc/nixos/home/waybar/ARCHITECTURE.md`** — daemon registry: remove
  `glass-text-daemon` row, rename `workspace-daemon` row to
  `hypr-context-daemon` and expand its "Writes" column to include
  `hypr-context.json`. Add `hypr-bg-daemon` row. Update migration-status
  section. Update the "Hyprland event subscription" prose (the move-to-
  subscribe is now done, not pending).
- **`/etc/nixos/home/waybar/TODO.md`** — move "Workspace-daemon migration
  to Nix" from NEXT to DONE (this work absorbs it). Move "Composite-module
  pattern" to DONE (bg daemon is the reference impl).
- **`/etc/nixos/home/waybar/CLAUDE.md`** — update the glass-mode contract
  text to name the bg daemon as the writer (currently names
  glass-text-daemon).

## Migration order (cutover safety)

The bar must not blank during the cutover. Order matters.

1. Land `hypr-context-daemon` alongside the existing `workspace-daemon`
   (both running, both writing the same cache files — daemons dedup, no
   duplicate signals because the existing daemon also dedups). Verify
   identical output via diff over 60 s of user activity.
2. Stop + disable `workspace-daemon.service`. waybar pills unaffected
   (cache files now sourced from new daemon).
3. Land `hypr-bg-daemon` alongside `hypr-edge-bg`. Disable `hypr-dive` first
   (the dive state will be ignored). The two bg daemons WILL fight over
   hyprpaper — keep this window ≤ 2 minutes.
4. Stop + disable `hypr-edge-bg.service` and `hypr-activities.service`.
5. Stop + disable `glass-text-daemon.service`. The bg daemon now owns
   `/tmp/glass-mode`. Verify pills still render correctly under both light
   and dark wallpapers.
6. Delete the obsolete files (per "Deletions" above).
7. Update docs (ARCHITECTURE.md, CLAUDE.md, TODO.md).
8. Commit each step as its own commit per Standard-OS commit discipline
   (close one stream before opening the next).

## Out of scope (explicit)

- **Per-monitor independent bg colors** in this first cut. Single-monitor
  setups work fully; multi-monitor falls back to whatever the focused
  monitor dictates. Promotion to per-output is a follow-up.
- **Animated transitions** between solid and waypaper. Per "silent context
  shift" rule, the swap is instantaneous. No fades.
- **Sampling cadence while rule holds.** Transition-driven only; bg does NOT
  follow scrolling content. Confirmed by user.
- **Replacing waypaper.** The user keeps waypaper as the wallpaper selector.

## Open questions (resolved during implementation)

1. **~~`focused.y` reporting under waybar's exclusive zone.~~** Resolved
   2026-06-13: Hyprland reports absolute monitor coordinates, NOT
   usable-area. Rule simplified to four state checks (no geometry); see
   "BG trigger rule" above.
2. **Test fixture rewrite.** `hypr-edge-bg-test.nix` exercises the old
   matrix. Rewrite as `hypr-bg-test.nix` once the new daemon stabilises;
   ship without integration tests in the first cut to keep the cutover
   atomic.
3. **~~`hypr-context-daemon` source location.~~** Resolved during plan
   writing: the daemon lives at `waybar/scripts/hypr-context-daemon.sh`
   and is bundled into the existing `waybar-scripts` derivation in
   `modules/waybar.nix` — same pattern as `workspace-daemon.sh`,
   `glass-text-daemon.sh`. shellcheck-gated by the derivation.

## Salvage map (what comes from where)

| Salvaged | From | Goes into |
|---|---|---|
| `socket2` subscription + 16 ms debounce | `hypr-activities` | `hypr-context-daemon` |
| Effective-gaps parser (`hyprctl getoption ... -j` split/max) | `hypr-activities` | `hypr-context-daemon` |
| Per-pill cache schema + atomic write + RTMIN+10 signal | `workspace-daemon.sh` | `hypr-context-daemon` |
| `grim` + `magick` top-edge sampler | `hypr-edge-bg` | `hypr-bg-daemon` |
| `hyprpaper preload → wallpaper → unload` cycle + hex fast-exit | `hypr-edge-bg` | `hypr-bg-daemon` |
| LRU PNG cache | `hypr-edge-bg` | `hypr-bg-daemon` |
| `hex_luminance` (ITU-R BT.601) | `glass-text-daemon.sh` | `scripts/lib/colors.sh` |
| `hex_to_rgb`, `rgb_to_hex`, `rgb_dist_sq` | `scripts/lib/colors.sh` | kept in place |

## Acceptance criteria

- One Hyprland `socket2` subscription is open on the system (verify with
  `ss -xp | grep socket2`). Zero `hyprctl` polling loops.
- `/tmp/waybar-cache/hypr-context.json` is present, valid JSON, updates on
  every Hyprland transition.
- waybar pills render identically pre- and post-migration. No regressions
  in the workspace pills, window pill, or win-move cluster.
- `/tmp/glass-mode` continues to flip between `light` and `dark` correctly
  as the bg behind the bar changes.
- BG color matches the focused window's top edge IFF the six trigger
  conditions hold; restores waypaper image otherwise.
- CPU at idle ≤ pre-migration baseline.
- All workspace-daemon + glass-text-daemon + hypr-activities +
  hypr-edge-bg + hypr-dive services are absent (`systemctl --user
  list-units` shows none of them).
