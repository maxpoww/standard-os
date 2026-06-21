# Brightness daemon — design

**Date:** 2026-06-20
**Status:** approved (anchor + transient choices confirmed 2026-06-20)
**TODO entry:** `waybar/TODO.md` NEXT → "Brightness module — XF86MonBrightnessUp/Down, transient only"

## Context

Brightness today goes through `~/.config/hypr/scripts/brightness.sh` (hyprland-only, ad-hoc) and the canvas DISPLAY slider (`widgets/eww/eww.yuck:99,315` — direct `brightnessctl` polling + writes, scaffold pattern). No daemon owns brightness state; no cache file; no signal. Pressing `XF86MonBrightnessUp/Down` works but bypasses the OPTIONS data model. The canvas slider's 1 s polling forks `brightnessctl` continuously while the canvas is open.

Wave 3 established the daemon-driven-pill pattern for weather/system/notif-history/pomodoro/cal-source: shared `canvas-cache.sh` for atomic write + dedup-signal; one writer per cache file; consumers read the cache. Brightness is the same shape — the canvas DISPLAY slider is the frontend that already exists, the daemon is the missing backend.

The original TODO entry framed this as "transient with no permanent home" (pillar 6 testbed). That framing predates Wave 2; the canvas DISPLAY slider *is* the permanent home now. V0 ships with **no transient bar surfacing** — keyboard discoverability stays opt-in per OPTIONS philosophy, and the canvas slider is the only visual surface. Transient feedback when the canvas is closed can be a follow-up if daily-use friction surfaces it.

## Scope

In:
- `brightness-daemon` (RTMIN+21) owning `/tmp/waybar-cache/brightness.json`
- `brightnessctl-set` wrapper script (up | down | set N) replacing `~/.config/hypr/scripts/brightness.sh`, preserving its night-dim shader teardown behavior
- Hyprland rewire (`XF86MonBrightness{Up,Down}` → wrapper)
- Canvas slider rewire (`bar-display` defpoll reads cache; `:onchange` calls wrapper)
- Nix module `modules/brightness-daemon.nix`, enabled via `home.nix`
- TDD for the daemon's derive function
- ARCHITECTURE.md daemon-registry row + signal-table row for RTMIN+21
- TODO.md NEXT → DONE move

Out:
- Transient bar pill (no mockup, no consumer-facing demand demonstrated yet)
- Auto-open-canvas-on-key-press
- DDC/CI / external monitor support (no external monitors; `ddcutil` not installed)
- Per-keyboard brightness (`kbd_backlight` slider already exists separately, untouched)
- Replacing the `kbd_backlight` defpoll/handler at eww.yuck:106,322 — out of scope

## Interfaces

### Cache: `/tmp/waybar-cache/brightness.json`

```json
{
  "pct": 7,
  "raw": 84,
  "max": 1200,
  "device": "intel_backlight",
  "updated": 1782004500
}
```

- `pct` = `round(raw * 100 / max)`. Matches what `brightnessctl -m` reports today, so the canvas slider's data shape is unchanged.
- `raw` and `max` exposed so consumers can compute non-percent operations if needed.
- `device` constant for v0 (`intel_backlight`). Reserved for future multi-device use.
- `updated` = unix timestamp at write time. Set on every dedup-passing emit.

### Signal: RTMIN+21

Next free per ARCHITECTURE.md signal table (RTMIN+10..+20 taken; +21..+30 free). Fires on `pct` change only — dedup at the writer via `canvas-cache.sh:cache_signal_if_changed`.

### Wrapper: `scripts/brightnessctl-set`

```
brightnessctl-set up        # current + STEP, clamp at MAX
brightnessctl-set down      # current - STEP, clamp at MIN
brightnessctl-set set N     # set to N% directly (0..100)
```

Defaults: `DEVICE=intel_backlight`, `MIN=2`, `MAX=100`, `STEP=5`. Matches existing brightness.sh constants.

Side-effect: when post-change brightness is above 2 % AND `/tmp/night-dim-level` reports a non-zero level, calls `~/.config/waybar/scripts/shader-stack.sh clear dim` and resets `/tmp/night-dim-level` to `0`, then signals waybar (`pkill -RTMIN+10`). This is verbatim the existing brightness.sh teardown logic — moved, not changed. The brightness daemon's own RTMIN+21 fires regardless via the next poll cycle (sub-second latency).

### Daemon: `scripts/brightness-daemon.sh`

1 s poll loop reading `/sys/class/backlight/$DEVICE/{actual_brightness,max_brightness}` directly (sysfs — no `brightnessctl` fork per tick, in keeping with the standard-os hazard list). Writes the cache JSON via `cache_signal_if_changed`. Library-mode hook (`BRIGHTNESS_DAEMON_LIB_ONLY=1`) for the test.

### Hyprland rebind

`/etc/nixos/home/hypr/modules/Binds.conf:50-51`:

```diff
- bindel = ,XF86MonBrightnessUp,   exec, ~/.config/hypr/scripts/brightness.sh up
- bindel = ,XF86MonBrightnessDown, exec, ~/.config/hypr/scripts/brightness.sh down
+ bindel = ,XF86MonBrightnessUp,   exec, /etc/nixos/home/scripts/brightnessctl-set up
+ bindel = ,XF86MonBrightnessDown, exec, /etc/nixos/home/scripts/brightnessctl-set down
```

### Canvas slider rewire

`widgets/eww/eww.yuck`:

```diff
- (defpoll bar-display :interval "1s" :initial "50"
-   `brightnessctl -m 2>/dev/null | awk -F, '{ sub("%","",$4); print $4 }' | head -1 || echo 50`)
+ (defpoll bar-display :interval "1s" :initial "50"
+   `jq -r '.pct // 50' /tmp/waybar-cache/brightness.json 2>/dev/null || echo 50`)
```

```diff
-                :onchange "brightnessctl set {}% >/dev/null 2>&1"
+                :onchange "/etc/nixos/home/scripts/brightnessctl-set set {} >/dev/null 2>&1"
```

### Cleanup

After the wrapper takes over the hypr bind and the canvas slider, delete `~/.config/hypr/scripts/brightness.sh`. Logic preserved verbatim inside the new wrapper.

## Architecture

Mirrors Wave 3 daemons (pomodoro, cal-source) almost exactly. One file changes per piece:

```
home/scripts/brightness-daemon.sh   poll loop + derive_brightness_json
home/scripts/brightnessctl-set      wrapper (replaces brightness.sh)
home/modules/brightness-daemon.nix  systemd user unit
home/tests/test_brightness_daemon.sh  TDD for derive function
home/hypr/modules/Binds.conf        rebind 2 lines
home/widgets/eww/eww.yuck           bar-display defpoll + onchange
home/waybar/ARCHITECTURE.md         daemon-registry + signal-table rows
home/waybar/TODO.md                 NEXT → DONE move
home.nix                            import + enable
```

No new shared library code — `canvas-cache.sh` already does atomic write + dedup-signal.

## Test plan

`home/tests/test_brightness_daemon.sh` covers `derive_brightness_json` (library-mode source):

- Fixture: writeable temp dir mocking `/sys/class/backlight/<device>/{actual_brightness,max_brightness}`
- Cases:
  - 84/1200 → pct=7
  - 600/1200 → pct=50
  - 1200/1200 → pct=100
  - 0/1200 → pct=0
  - missing actual_brightness → cache shape with `pct:null` (or sentinel), no crash
- Visual smoke (not in unit test): press XF86MonBrightnessUp, observe cache.pct increment by 5; open canvas and observe slider track

## Hazards

- **Race between wrapper and daemon's polling.** The wrapper calls `brightnessctl` and immediately signals the daemon, but the daemon's next read may still see the old value if it lands inside the same 1 s tick. Mitigation: wrapper sends `kill -RTMIN+21` to the daemon AFTER `brightnessctl` returns; daemon's signal handler triggers an immediate cache write. Worst case (signal lost): canvas slider lags 1 tick — acceptable.
- **night-dim teardown lives in the wrapper, not the daemon.** Because the teardown is a side-effect of *user-initiated* brightness change (not a brightness change of any origin). A daemon-side teardown would also fire if something else changed brightness, which would be surprising. Wrapper is the right home.
- **Two backlight devices present (`intel_backlight`, `nvidia_0`).** Existing brightness.sh hardcoded `intel_backlight`; the wrapper inherits that. `nvidia_0` is a phantom from the discrete GPU — touching it would be wrong. Keep hardcoded.
- **kbd_backlight has its own slider + handler (eww.yuck:106,322).** Untouched. If the user wants the same daemon-treatment for keyboard backlight later, it's a small follow-up — the daemon and wrapper can be generalized to take a device parameter.

## Out of scope (follow-ups noted in TODO.md NEXT)

- Transient bar pill for keyboard-only feedback when canvas is closed.
- Multi-device brightness (laptop + DDC external monitors).
- Keyboard backlight daemon (parallel construction).

## Commit shape (single commit, matches Wave 3 pattern)

```
brightness-daemon (RTMIN+21) — canvas slider + XF86 keys read/write through cache
```

Modified: hypr/modules/Binds.conf, widgets/eww/eww.yuck, waybar/ARCHITECTURE.md, waybar/TODO.md
Created: scripts/brightness-daemon.sh, scripts/brightnessctl-set, modules/brightness-daemon.nix, tests/test_brightness_daemon.sh
Deleted: ~/.config/hypr/scripts/brightness.sh (in same commit, with note that logic moved verbatim into brightnessctl-set)
