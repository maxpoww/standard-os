# Notification center — spine design

**Date:** 2026-06-06
**Status:** Approved (pending user review of this written doc).
**Scope:** The spine only. Drawer, DND toggle, focus modes, per-app rules, action buttons, 2FA copy, sound, app-icon rendering are deferred to follow-up specs — each one composes onto this spine without changing it.

---

## Purpose

Surface freedesktop notifications inside the OPTIONS bar vocabulary. The bar is the shell (Rule 5); notifications must therefore appear as pills, not as detached popup boxes. The spine answers four questions:

1. Where does a notification *arrive* visually?
2. What's its *resting* representation while unread?
3. How does *critical* differ from *normal*?
4. What does a *click* do?

Everything else — the drawer / list view, DND, focus modes, per-app rules, sound, icon rendering — is intentionally deferred.

---

## Daemon choice: mako, popups OFF

mako stays as the DBus daemon (`org.freedesktop.Notifications`). It owns:

- DBus capture (mature spec implementation).
- History persistence (`makoctl history`, `makoctl list`).
- DND modes (`makoctl mode -t dnd`).
- Per-app config sections (`[app-name=…]`).
- Urgency awareness (0 / 1 / 2).
- Action invocation (`makoctl invoke <id> <action>`).

mako does **NOT** own anything visible. Its popup output is disabled with `max-visible = 0`. OPTIONS owns 100 % of the visible surface.

Rejected: swaync (its built-in panel + popups are a parallel visual world we'd be permanently suppressing); custom-daemon-from-scratch (weeks of work re-implementing mako).

---

## Bar layout changes

Two changes to `config.jsonc`:

**USER zone** — `tray` migrates from SYSTEM into USER, between `workspaces` and `active-window`:

```
[ group/workspaces   tray   group/active-window ]
       ⬑ workspaces       ⬑ focused-window pill at right edge of USER
```

**SYSTEM zone** — `custom/notif` is the LEFTMOST item, immediately left of the planet (`group/group-2`); `tray` leaves:

```
[ custom/notif   group/group-2   group/group-power   custom/power-resume
  custom/clock   custom/battery   custom/night-dimmer   group/screen-type-group
  custom/dictate ]
```

**Semantic note (non-blocking):** tray in USER zone is a conscious deviation from `CLAUDE.md` — USER is "where the user IS" (workspaces + focus + per-window actions); tray is persistent system state, which is SYSTEM-zone semantics. The user picked this placement deliberately; recording it here so future readers don't try to "fix" it back.

---

## Architecture & data flow

```
DBus client (any app)
        │  org.freedesktop.Notifications.Notify
        ▼
    ┌────────────┐    fr.emersion.mako signals    ┌──────────────────┐
    │   mako     │ ─────────────────────────────▶ │ notif-daemon.sh  │
    │ popups OFF │   (Notify + Dismissed +        │ (bash, event-    │
    │ history ON │    ModeChanged)                │  driven)         │
    └─────┬──────┘                                └─────────┬────────┘
          ▲                                                 │
          │ makoctl invoke / dismiss                        ▼ atomic write
          │                                  /tmp/waybar-cache/notif
          │                                                 │
          │                                                 ▼ pkill -RTMIN+12
          └──────── ~/.config/waybar/    ┌────────────────────────┐
                    scripts/notif-       │ custom/notif pill      │
                    click.sh ───────────▶│ (SYSTEM zone, leftmost)│
                                         └────────────────────────┘
```

**Signal:** RTMIN+12. Registered in `ARCHITECTURE.md` as `notif-daemon` (currently marked FREE).

**Cache file format** (`/tmp/waybar-cache/notif`):

```json
{
  "text": "<glyph or 'App · Title'>",
  "class": ["opt-pill", "dark", "<state classes>"],
  "tooltip": "<body or summary>"
}
```

`class` is a JSON array per the known hazard ("space-separated string is treated as a single GTK class").

---

## Pill state machine

ONE waybar module, six states. Every state is expressible in the existing OPTIONS vocabulary — no new colours, motions, surfaces, or borders are introduced.

| State | Trigger | `text` | `class` |
|---|---|---|---|
| **Empty** | no unread, no recent arrival | `""` | (waybar hides) |
| **Rest — normal unread** | ≥1 unread, none critical | bell glyph | `opt-pill dark opt-pin-green` |
| **Rest — critical unread** | ≥1 critical unread | bell glyph | `opt-pill dark opt-pin-orange` |
| **Transient — normal arrival** | normal/low fires; not in DND | ` App · Title` | `opt-pill dark opt-flash` |
| **Transient — critical arrival** | critical fires (DND irrelevant) | ` App · Title` | `opt-pill dark opt-no opt-pulse-orange opt-flash` |
| **Acked critical** | hover during transient-critical | ` App · Title` | `opt-pill dark opt-no opt-pin-orange` (motion stopped) |

### Bell glyph

Font Awesome solid bell, U+F0F3 (`` in MesloLGS NF). Verify byte sequence with `od -An -c` before paste (the glyph-bytes-look-empty hazard).

### Timing (daemon-owned, NOT CSS)

- **Normal / low transient:** visible 4 s. Hover extends; pill stays visible while hovered. Click invokes default DBus action and dismisses (see §Click handling).
- **Critical transient:** stays visible until hover (spec mandate: do not auto-expire). After hover-out, 4 s grace, then collapses to rest face with `opt-pin-orange` retained on the bell glyph.
- **Multiple criticals queued:** pill shows the LATEST critical. `opt-pin-orange` at rest persists until ALL critical entries are dismissed.
- **No timer animations in CSS.** The CSS rules for `opt-pulse-orange`, `opt-flash`, `opt-pin-*` already exist; the daemon simply writes / replaces the class strings at the right moments.

### DND interaction

`makoctl mode | grep -q dnd` is the DND check.

- **Critical:** still surfaces as `transient-critical`. Spec piercing.
- **Normal / low:** no transient pill. The notification still lands in mako's history. If it becomes the only unread, the rest face updates to `opt-pin-green`.

---

## Click handling

`~/.config/waybar/scripts/notif-click.sh` is a thin dispatcher. The pill emits two click handlers in `config.jsonc`:

```jsonc
"on-click":       "~/.config/waybar/scripts/notif-click.sh invoke",
"on-click-right": "~/.config/waybar/scripts/notif-click.sh drawer"
```

| Click | Rest face | Transient face |
|---|---|---|
| Left | `makoctl dismiss-all` (interim — see below) | `makoctl invoke <latest-id>` (default action) + dismiss |
| Right | `notif-click.sh drawer` → **no-op placeholder** until drawer ships | same placeholder |

**Interim rest-click handler.** Until the drawer follow-up ships, the rest face's left-click runs `makoctl dismiss-all` — clears all unread, pin colour clears. Explicitly chosen over "unclickable until drawer ships": the user always has SOME way to clear the pin without dropping to a shell. The seam is documented here so when the drawer arrives, this line is the obvious one to swap.

---

## Implementation seams (file inventory)

```
/etc/nixos/home/modules/notif-center.nix         ← new HM module — the spine wiring
/etc/nixos/home/waybar/config.jsonc              ← +1 entry: custom/notif
                                                  ← layout edit: tray → USER zone
/etc/nixos/home/waybar/scripts/notif-click.sh    ← new — thin click dispatcher
/etc/nixos/home/waybar/ARCHITECTURE.md           ← RTMIN+12 registered to notif-daemon
/etc/nixos/home.nix                              ← +1 import for the HM module
```

### `notif-center.nix` shape

Standard project pattern: typed options, `enable` flag, `services.options.notifCenter.enable`. The daemon is a `pkgs.writeShellScriptBin` wrapped as a `systemd.user.service` with `Restart = always; RestartSec = 1`. Curated `PATH` via `lib.makeBinPath` includes: `dbus`, `mako`, `coreutils`, `procps`.

```nix
{ config, lib, pkgs, ... }:
let cfg = config.services.options.notifCenter; in {
  options.services.options.notifCenter = {
    enable        = lib.mkEnableOption "OPTIONS notification center spine";
    waybarSignal  = lib.mkOption { type = lib.types.int; default = 12;
                                   description = "RTMIN+N waybar signal."; };
    transientMs   = lib.mkOption { type = lib.types.int; default = 4000;
                                   description = "Auto-collapse for normal/low (ms)."; };
  };

  config = lib.mkIf cfg.enable {
    services.mako = {
      enable = true;
      settings = {
        max-visible      = 0;   # no popups — OPTIONS owns the surface
        default-timeout  = 0;   # history keeps everything
        history          = 1;
        # Per-app rules belong to the per-app-rules follow-up spec.
      };
    };

    home.packages = [ notifDaemon ];   # writeShellScriptBin
    systemd.user.services.notif-daemon = { … };
  };
}
```

### `notif-daemon.sh` shape (bash, event-driven)

Hazard checklist baked in:

- Strict header: `#!/usr/bin/env bash` + `set -uo pipefail`.
- Open the DBus FD ONCE via `exec {DBUS_FD}< <(dbus-monitor …)`; read with `read -u "$DBUS_FD"`.
- `read -t "$IDLE_TICK"` to interleave timer ticks (4 s collapse logic) with event reads.
- `recompute_state()` queries `makoctl list -f '{id}\t{summary}\t{app-name}\t{urgency}'` and walks the output with bash builtins (no per-tick `jq` / `awk` / `head` / `tr` forks).
- `write_cache()` does `printf '%s' "$json" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"`, then `pkill -RTMIN+12 waybar` ONLY when the rendered string changed (dedup against `LAST_RENDERED`).
- `class` is emitted as a JSON ARRAY literal — `"class":["opt-pill","dark","opt-pin-orange"]`. Never a space-separated string (waybar/GTK 3 hazard).
- Initial state computed via `recompute_state` at daemon start, before the first blocking read. Inotify-style "first event arrived before watcher started" trap doesn't apply, but the equivalent "daemon restarted mid-session with unread already in mako" trap does.

Three event handlers feed `recompute_state` + `render_cache_for_current_state` + `write_cache_if_changed`:

```bash
on_arrival()  { latest_id="$1"; latest_urgency="$2"; … }
on_dismiss()  { dismissed_id="$1"; … }
on_mode_change() { dnd="$(makoctl mode | grep -qx dnd && echo 1 || echo 0)"; … }
```

The state machine table in §"Pill state machine" is the authoritative spec; `render_cache_for_current_state` is the encoding of that table.

### `custom/notif` waybar entry (config.jsonc)

```jsonc
"custom/notif": {
    "exec":           "cat /tmp/waybar-cache/notif 2>/dev/null",
    "return-type":    "json",
    "format":         "{}",
    "interval":       "once",
    "signal":         12,
    "tooltip":        true,
    "on-click":       "~/.config/waybar/scripts/notif-click.sh invoke",
    "on-click-right": "~/.config/waybar/scripts/notif-click.sh drawer"
}
```

### `notif-click.sh` shape

```bash
#!/usr/bin/env bash
set -uo pipefail
action="${1:-invoke}"
case "$action" in
  invoke)
    # Read /tmp/waybar-cache/notif. If state is a transient (class includes
    # opt-flash or opt-pulse-orange or opt-pin-orange WITH wide text):
    #   makoctl invoke "$(makoctl list | head -…id…)"
    # Else (rest face): makoctl dismiss-all   ← interim until drawer ships.
    ;;
  drawer)
    : # No-op placeholder. Drawer ships in follow-up spec.
    ;;
esac
```

---

## Verification / acceptance criteria

The spine ships when ALL of the following pass on a fresh `systemctl --user restart waybar.service notif-daemon.service`:

1. `notify-send --urgency=low "low test"` → no transient pill (low + DND-off both go silent in the spine; low surfaces in history only). Bell at rest with `opt-pin-green`.
2. `notify-send --urgency=normal "normal test"` → transient pill `" notify-send · normal test"` with `opt-flash` for 4 s, then collapses; bell rest face shows `opt-pin-green`.
3. `notify-send --urgency=critical "critical test"` → transient pill `opt-no opt-pulse-orange opt-flash`, stays animating; hover → motion stops → 4 s post-hover → collapses to bell rest face with `opt-pin-orange` retained.
4. `makoctl mode -t dnd` then critical → still pierces (transient-critical as above).
5. `makoctl mode -t dnd` then normal → no transient; rest face updates.
6. Click on transient → `makoctl invoke` fires + transient clears.
7. Click on rest face → `makoctl dismiss-all` runs, pin clears, pill goes empty.
8. Right-click → no-op (placeholder until drawer).

Audit per the project hazards:

- `grep -nE '#custom-notif \{' style.css` returns nothing (the pill must inherit pure `.opt-pill` geometry; no standalone block).
- `class` is emitted as a JSON array in every cache write (`jq -r '.class | type' /tmp/waybar-cache/notif` returns `array`).
- `dark` is in every non-empty class output (light/dark adaptation contract).
- Bell-glyph rendering verified by `od -An -c` on the script source (Nerd Font byte hazard).
- `pkill -RTMIN+12 waybar` fires ONLY when the rendered cache string changes (dedup at writer; no CPU regression like mpris 2026-05-27).

---

## Out of scope — follow-up specs

Each item below is named for its eventual spec. None of them changes the spine; they all *compose onto* it.

1. **The drawer / list view.** Right-click the pill → group-drawer expands left (right-zone rule, `transition-left-to-right: false`) showing the last N notifications as `opt-pill-child` items. Each child = one notification, click dismisses, hover surfaces actions.
2. **DND toggle on the pill.** `opt-pushed` modifier when DND is engaged. Hardware-key bindable. Critical pierces unchanged.
3. **Focus modes** (macOS-style profiles: Work / Sleep / Gaming) with schedules + per-app exclusions. Composes on DND.
4. **Per-app rules + junk filter.** Default-on silencers for print-job / NetworkManager-connect / package-mgr noise, declared in `services.mako.settings.[app-name=…]` blocks in the Nix module.
5. **Action buttons.** Notification `actions` rendered as child pills inside the drawer.
6. **2FA / OTP code extraction.** Regex over body → `wl-copy` → surface as `opt-glow-green` (offer) on the pill.
7. **Sound.** Honor `sound-name` + `suppress-sound` hints via `canberra-gtk-play`; DND silences. Default OFF in the spine — silence-by-default fits the OPTIONS aesthetic.
8. **App icon rendering.** `image-path` hint as the pill glyph during transient. Closed-budget exception that needs explicit justification before adoption.

---

## Hazards specific to this spine (added to `waybar/CLAUDE.md` "Known hazards" when spine ships)

- **`dbus-monitor` on `org.freedesktop.Notifications` sees the call BEFORE mako processes it.** The `Notify` line on the bus arrives before the notification has an ID in `makoctl list` output. The implementation plan must verify mako's actual D-Bus API surface (does `fr.emersion.mako` emit post-processing signals? if not, the daemon waits ~50 ms after a `Notify` event before calling `recompute_state`). The robust fallback — short tick delay — always works regardless of mako's signal coverage.
- **mako's `Dismissed` signal fires both on explicit dismissal AND on `default-timeout` expiry.** When timeout is `0` (our config), only explicit dismiss fires. If the user ever overrides the timeout in a per-app block, the daemon may see surprise Dismissed events; recompute_state is idempotent so this is fine, but worth a comment in the daemon source.
- **`opt-flash` re-trigger on rapid same-class repeat.** CSS animations don't re-fire if the class string is unchanged. Rapid arrivals of the same urgency need to alternate between `opt-flash` and `opt-flash-r` (or include a counter in the class) — same trick documented in `CLAUDE.md` for hardware-button reflection. Handle in `render_cache_for_current_state`.
