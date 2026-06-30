# Canvas Prefs — Apply Flow (Design)

**Date:** 2026-06-25
**Status:** approved-for-planning

## Problem

The CONFIG card in the canvas's `section-max` lists 10 user-account preferences as clickable pref-rows, but every click only fires a placeholder `notify-send 'coming soon'`. Nothing on the canvas actually changes the system.

We want a subset of those prefs to be functional, edit a sidecar `.nix` file, and apply via `nixos-rebuild switch` — with a UX that lets the user make several edits without committing each one, and surfaces the pending decision on the OPTIONS bar (waybar) rather than in the canvas.

## Scope (MVP)

Editable prefs: **Default shell** and **Groups**. Both already exist in the CONFIG card. Both map cleanly to `users.users.max.shell` / `users.users.max.extraGroups`.

Everything else in the CONFIG card stays display-only or `notify-send` for now (display name, password, fingerprint, 2FA, username, home directory, last login, uptime).

Bigger pref surfaces (Hyprland gaps, theme, locale, etc.) are out of scope for this round but the same plumbing should generalize when we add them.

## Architecture

### State files (three, by ownership)

| File | Owner | Purpose |
|---|---|---|
| `~/.config/standardos/staged-prefs.json` | user | Pending changes that have NOT been applied yet. Persists across reboots. |
| `/etc/nixos/standardos-canvas-sidecar.nix` | root | Generated from staging on Apply. Imported by `configuration.nix` so the canvas owns its own slice of system config without touching anything else. |
| `~/.config/standardos/last-error.json` | user | Present only when the last Apply rebuild failed. Holds `{reason, source_prefs[]}` to drive the bar pill's error state. |

Staging schema (extensible — currently 2 keys):
```json
{
  "shell": "zsh",
  "groups": ["wheel", "networkmanager", "audio", "video"]
}
```

### Scripts (six, all in `/etc/nixos/home/scripts/`)

| Script | Purpose |
|---|---|
| `pref-stage <key> <value>` | Atomically merges `{key: value}` into `staged-prefs.json`. Signals waybar via `pkill -RTMIN+<N>` to refresh the standardos-pending module. |
| `pref-choose-shell` | Invokes `rofi -dmenu` with available shells (from `/etc/shells`), pipes the pick to `pref-stage shell`. |
| `pref-choose-groups` | Invokes `rofi -multi-select` with all `getent group` rows, pipes the picks (comma-joined) to `pref-stage groups`. |
| `pref-apply` | Generates `standardos-canvas-sidecar.nix` from staging, runs `sudo nixos-rebuild switch`, on success clears staging + signals waybar, on failure writes `last-error.json` + signals. |
| `pref-dismiss` | Clears `staged-prefs.json`. Signals waybar. |
| `pref-revert` | Clears `last-error.json` AND `staged-prefs.json` (a failed rebuild never wrote real state, so nothing to undo on the system side). Signals waybar. |

Atomic file writes use `tmp + mv -f` per the navigator's hazard list. The signal number for waybar refresh: TBD during planning (pick from the unused RTMIN range; document in `waybar/ARCHITECTURE.md`).

### Eww (canvas)

1. New `defpoll staged-prefs` reads `~/.config/standardos/staged-prefs.json` (1s interval — file is small, change detection is cheap).
2. `pref-row` widget grows a "is this pref currently staged?" branch:
   - If `staged-prefs.has(key)`: render with the staged value AND apply class `.pref-row-pending`.
   - Else: render with the real value (unchanged from today).
3. `.pref-row-pending` style in `eww.scss` reduces `color` alpha on the `.pref-value` label — "fadeish" text per user spec.
4. Click handlers on the two editable rows invoke the rofi chooser scripts:
   - `Default shell` → `pref-choose-shell`
   - `Groups` → `pref-choose-groups`
5. Display-only rows keep their existing `notify-send 'coming soon'` handlers — out of scope.

### Waybar (the bar)

New `custom/standardos-pending` module on the SYSTEM zone (right side, between Notifications bell and the existing system pills). Reads `staged-prefs.json` + `last-error.json` and emits three states:

| State | Trigger | Pill |
|---|---|---|
| Empty | both files absent or empty | `.empty` — pill collapses to zero presence |
| Pending | staging non-empty, no error | "Apply (N)" — N = count of staged keys. Hover reveals a sibling "Dismiss" pill. |
| Error | `last-error.json` present | "Error" + tooltip = truncated last few lines of rebuild stderr. Hover reveals "Revert" / "Edit" siblings. |

Click actions:
- Apply → `pref-apply` (blocks for rebuild duration — show spinner via `opt-flash` or similar)
- Dismiss → `pref-dismiss`
- Revert → `pref-revert`
- Edit → `canvas-open` (re-pop the canvas; staged values still visible in faded text since we don't clear staging on Edit)

### NixOS module

New file `modules/standardos-canvas-prefs.nix` adds:

```nix
{ config, lib, pkgs, ... }: {
  # Import the sidecar that the canvas writes to. The sidecar starts
  # as a no-op `{ }` so the first import always succeeds even before
  # any pref has been staged + applied.
  imports = [ /etc/nixos/standardos-canvas-sidecar.nix ];

  # Passwordless sudo for canvas-driven rebuilds. The canvas runs as
  # the user `max`; the rebuild script needs root. Tradeoff documented
  # in 2026-06-25 design: any process running as `max` can also run
  # nixos-rebuild — acceptable for a single-user box.
  security.sudo.extraRules = [{
    users = [ "max" ];
    commands = [{
      command = "/run/current-system/sw/bin/nixos-rebuild";
      options = [ "NOPASSWD" ];
    }];
  }];
}
```

The sidecar file is created with safe initial content on first install:

```nix
{ config, lib, pkgs, ... }: { }
```

## Flow

**Happy path**
1. User opens canvas (Super+RETURN). CONFIG shows `Default shell: bash`, `Groups: wheel · networkmanager · ...`.
2. User clicks `Default shell` → rofi opens with shell list → user picks `zsh` → `pref-stage shell zsh` writes staging → eww refreshes → pref-row now shows `zsh` in faded text.
3. User clicks `Groups` → rofi multi-select opens → user toggles `audio` ON → `pref-stage groups [wheel, networkmanager, ..., audio]` → faded.
4. User presses Esc → canvas closes (standard behavior — no extra prompt). Bar pill `Apply (2)` appears on the right.
5. User clicks Apply → bar pill shows working state → `pref-apply` runs → rebuild succeeds → staging cleared → bar pill hides → next canvas open shows the new values as the real (non-faded) values.

**Error path**
6. (At step 5) Rebuild fails because group `idontexist` was staged.
7. `pref-apply` captures stderr, parses out the failing reason, writes `last-error.json = {reason: "group 'idontexist' does not exist", source_prefs: ["groups"]}`.
8. Bar pill morphs to error state. Tooltip shows the reason.
9. User clicks Edit → canvas opens with staged values still in faded text → user fixes Groups → presses Esc → bar pill re-arms in pending state → Apply again.
10. (Alternative) User clicks Revert → staging + error cleared → system stays exactly as it was before any of this.

## Error handling

`pref-apply` runs `sudo nixos-rebuild switch 2>&1 | tee ~/.local/state/standardos/last-rebuild.log`. Last error parsing is best-effort regex on the log tail:

- `error: group '(.+)' does not exist` → `"Group '$1' does not exist"`
- `error: user '(.+)' does not exist` → `"User '$1' does not exist"`
- `error: (.+):\d+:\d+: (.+)` → `"Nix syntax: $2"`
- fallback: last 200 chars of stderr, prefixed `Rebuild failed: `

The full log stays at `~/.local/state/standardos/last-rebuild.log` for inspection.

## Closed-budget compliance (per navigator)

The bar pill needs three readable states (empty / pending / error) without extending the palette beyond the existing 6 colors:

- **Pending** state: `$primary-blue` background (the same blue that section-pill-active already uses). One-shot `opt-flash` motion on first appearance.
- **Error** state: `$standout-violet` background. Pin variant `opt-pin-violet` after the first motion cycle (per the pin lifecycle pattern documented in `waybar/README.md → Pins`).
- **Empty** state: `.empty` collapses to zero presence (per `empty-collapse` pattern).

No new colors. No new motions. The error state uses the existing pin family.

## Open questions baked-in (defaults — revise on review)

1. **Where in SYSTEM zone?** Default: immediately right of the Notifications bell, left of the existing system pills. Easy to relocate.
2. **Rebuild blocks UI for ~30-60s — feedback?** Default: bar pill shows `opt-flash` for the duration, button is non-interactive until the rebuild process exits.
3. **Existing staging vs. fresh open behavior** — when user opens canvas with active staging, pref-rows render the staged value (faded). When user clicks a faded row and picks a new value, staging is overwritten — no merge of pick-then-pick history.
4. **Reverting an applied pref** — out of scope. After Apply, the system has the new value and there's no "undo last apply" affordance in this round. The user would re-edit and re-apply.

## Files (planning preview)

New:
- `/etc/nixos/standardos-canvas-sidecar.nix` (initial no-op; canvas overwrites)
- `/etc/nixos/home/modules/standardos-canvas-prefs.nix` (module: sudo rule + sidecar import)
- `/etc/nixos/home/scripts/pref-stage`
- `/etc/nixos/home/scripts/pref-choose-shell`
- `/etc/nixos/home/scripts/pref-choose-groups`
- `/etc/nixos/home/scripts/pref-apply`
- `/etc/nixos/home/scripts/pref-dismiss`
- `/etc/nixos/home/scripts/pref-revert`
- `/etc/nixos/home/waybar/scripts/standardos-pending-daemon.sh` (or equivalent — emits JSON for the waybar module)

Modified:
- `/etc/nixos/home/widgets/eww/eww.yuck` (new defpoll, pref-row variant, two onclicks)
- `/etc/nixos/home/widgets/eww/eww.scss` (`.pref-row-pending` style)
- `/etc/nixos/home/waybar/config.jsonc` (register `custom/standardos-pending`)
- `/etc/nixos/home/waybar/style.css` (pill styling — uses existing `.opt-pill` family)
- `/etc/nixos/configuration.nix` (import `modules/standardos-canvas-prefs.nix`)

## Out of scope

- Reverting an already-applied pref (no "undo")
- Per-user prefs beyond `max` (single-user box assumption)
- Hyprland / waybar / theme / locale / hostname prefs (future round)
- Diffing the sidecar before Apply (would be nice but isn't blocking)
- Conflict resolution if user hand-edits `standardos-canvas-sidecar.nix` between canvas Apply runs
