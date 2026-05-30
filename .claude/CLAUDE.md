# CLAUDE.md — Hyprland & NixOS Desktop Automation

## Project Overview
This project builds highly optimized, production-grade bash automation for the **Hyprland** ecosystem on **NixOS** (channel-based Home Manager, no flakes). The anchor implementation is `hypr-edge-bg`: a dive-aware background daemon that, depending on dive state and per-workspace context, paints either the user's `waypaper` image or a derived solid color on every monitor with no flicker, in real time, while continuously following window-content color changes.

Three processes:
- **`hypr-activities`** — single publisher of workspace state. Owns every `hyprctl`/`gsettings`/`inotifywait` read; broadcasts an atomic JSON snapshot file + an AF_UNIX socket with a 16 ms inline debounce.
- **`hypr-edge-bg`** — single consumer. Streams the activities socket, runs the dive matrix, and drives `hyprpaper`. Polls the active mode every `POLL_INTERVAL` seconds for live color tracking.
- **`hypr-dive`** — toggle CLI (`on` / `off` / `toggle` / `status`). Atomic state write + targeted `SIGUSR1` to the consumer.

## Dive UX Paradigm
Two persistent user experiences, toggled via `hypr-dive on|off|toggle` and persisted across reboots in `$XDG_STATE_HOME/hypr-edge-bg/dive`.

- **Normal (dive off)** — the user's `waypaper` image is the background everywhere it's visible (empty workspace, gapson workspaces, fullscreen pre-load). The only solid color used is the **match** color when a single window covers the screen with no gaps, painting under the transparent waybar so window-and-bar look like one piece.
- **Dive on** — no image is ever shown. Four solid colors:
  - **default** (`#323246`) — empty workspace, true fullscreen.
  - **match** — top-edge sample of the focused window when gaps are off.
  - **mismatch** — luma-aware shift of the match color (darkened in dark theme, lightened in light), clamped to `[30, 225]`. Used when gaps are on with a single window for contrast.
  - **mixed** — area-weighted linear-RGB mean of every window's top edge on the focused workspace. Used when gaps are on with ≥2 windows to soften inter-window contrast.

The dive matrix is the single source of truth — see [`scripts/hypr-edge-bg`](../scripts/hypr-edge-bg) `decide()`.

| flag | fullscreen | gaps | wc | dive | bg                       |
|------|------------|------|----|------|--------------------------|
| 0    | -          | -    | 0  | off  | waypaper image           |
| 0    | -          | -    | 0  | on   | default `#323246`        |
| 1    | ≥ 2        | -    | -  | off  | waypaper image           |
| 1    | ≥ 2        | -    | -  | on   | default `#323246`        |
| 1    | < 2        | off  | ≥1 | -    | match (top-edge sample)  |
| 1    | < 2        | on   | ≥1 | off  | waypaper image           |
| 1    | < 2        | on   | 1  | on   | mismatch (luma-shifted)  |
| 1    | < 2        | on   | ≥2 | on   | mixed (area-weighted)    |

`fs=1` (maximized) **falls through** the matrix — only `fs >= 2` (true fullscreen) freezes color updates. Maximized still respects gaps.

## Components

- **`scripts/hypr-activities`** — event publisher. Subscribes to Hyprland `socket2`, `gsettings monitor` (dark theme), and `inotifywait` on the waypaper config. Holds two FIFOs open with `<>` (`EVENT_FIFO`, `BROADCAST_FIFO`) so producers never EPIPE. Inline 16 ms debounce in the main loop (no subshell — state mutations propagate). Emits `$XDG_RUNTIME_DIR/hypr-activities.json` (atomic `tmp+mv`) and broadcasts on `$XDG_RUNTIME_DIR/hypr-activities.sock` (AF_UNIX, multi-consumer via `socat ... fork,reuseaddr,unlink-early`). **Sole owner of `hyprctl` reads**.
- **`scripts/hypr-edge-bg`** — background driver. Opens the activities socket on a numbered FD via `exec {SOCK_FD}< <(socat -u …)` and uses `read -t POLL_INTERVAL -u "$SOCK_FD"` so the main loop interleaves event-driven snapshots with poll ticks while a color-following mode is active (`POLL_ACTIVE=1`). Idle states (default / waypaper / fullscreen) keep `POLL_ACTIVE=0` and the loop blocks on the socket — zero CPU. **One** `jq` invocation per tick extracts every scalar + `monitors` JSON + a flat `addr|x|y|w|h` clients table. Drives `hyprpaper` via `preload → wallpaper → unload <previous>`. LRU-bounded `/tmp/hypr-edge-bg/` solid-PNG cache with deterministic filenames `c-<hex>-<WxH>.png`. Squared-RGB threshold (`DIST_THRESHOLD=100`) plus exact-hex fast-exit skip no-op updates.
- **`scripts/hypr-dive`** — toggle CLI. Atomic state write (`mktemp`-style `tmp + mv`) plus `systemctl --user kill --kill-who=main -s SIGUSR1 hypr-edge-bg.service`. **`--kill-who=main` is mandatory** — the default `all` would also signal the `socat` running in `< <(...)`, which has no USR1 trap, dies, the read loop EOFs, and the daemon exits cleanly with no recovery.
- **`scripts/lib/colors.sh`** — shared integer-only color math (hex/RGB conversion with trailing newline, BT.601 luma, squared distance, luma-aware mismatch, area-weighted RGB mean accumulator). Sourced by `hypr-edge-bg` and the unit tests via `HYPR_EDGE_BG_LIB`.
- **`modules/hypr-edge-bg.nix`** — Home Manager module wiring the three scripts as `systemd.user.services` (`hypr-activities` → `hypr-edge-bg`) with typed `options` and a curated `lib.makeBinPath` (`socat`, `jq`, `grim`, `imagemagick`, `hyprland`, `hyprpaper`, `inotify-tools`, `glib`). **Both services use `Restart=always`** — clean exits (socket EOF when publisher restarts, FIFO ENOENT under cleanup race) need recovery just like crashes.
- **`tests/colors-test.sh`** — deterministic unit tests for the color math (10 assertions, no external deps).
- **`tests/hypr-edge-bg-test.nix`** — `nixosTest` scaffold with stubs for `hyprctl`, `grim`, `hyprpaper`, `gsettings`.

## Build, Test & Format
- **Lint**: `shellcheck -s bash -a <script>` — all four bash scripts must be silent.
- **Format**: `shfmt -w -s -i 4 <script>` (4-space indentation, simplify).
- **Unit tests**: `bash tests/colors-test.sh` — 10/10 must pass.
- **Module parse-check**: `nix-instantiate --parse modules/hypr-edge-bg.nix`.
- **Rebuild (HM-as-NixOS-module setup, this machine)**: `sudo nixos-rebuild switch`. There is **no** standalone `home-manager` CLI here.
- **Restart services after rebuild**: `systemctl --user daemon-reload && systemctl --user restart hypr-activities hypr-edge-bg`. Order matters — publisher first, consumer second.
- **Log viewing**: `journalctl --user -u hypr-activities -u hypr-edge-bg -f`.
- **Live snapshot**: `jq . $XDG_RUNTIME_DIR/hypr-activities.json`.
- **Tail broadcast**: `socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr-activities.sock`.

## Architecture & Code Style

### NixOS Declarative Immutability
- **Home Manager modules** (`*.nix`): expose typed `options` → `config`; wrap scripts as `systemd.user.services`.
- **Service lifecycle**: bind to `graphical-session.target` with `PartOf` + `After`; chain dependent services with `Requires` + `After`. Use `Restart=always; RestartSec=1` on long-lived daemons — clean exits from upstream restarts still warrant recovery.
- **Dependency injection**: `pkgs.writeShellScriptBin` + `lib.makeBinPath`. Pass `HYPR_EDGE_BG_LIB` env so scripts locate sourced libraries when relocated to `/nix/store`.
- **No FHS assumptions**: never hardcode `/usr/bin` or `/bin`. PATH is curated, not inherited.
- **Channel vs flake**: this project is **channel-based** (`<home-manager/nixos>`). The user's `home.nix` lives at `/etc/nixos/home.nix` and imports project modules by absolute path.

### Hyprland IPC & Quirks
- **socket2 for events**: `socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -`. Subscribe to `activewindow*`, `openwindow`, `closewindow`, `movewindow`, `windowtitlev2`, `fullscreen`, `workspace`, `focusedmon`, `changefloatingmode`, `configreloaded`, `monitoradded`, `monitorremoved`. Never poll for events.
- **Centralised reads**: only `hypr-activities` calls `hyprctl`. Other consumers read the JSON snapshot or the broadcast socket.
- **Window state semantics**: `fullscreen` level `2` = true fullscreen (freeze color updates, but pre-set the target so scrolling to gapsoff/empty doesn't flicker). `fullscreen=1` = maximized (still respects gaps; falls through the matrix). `floating`/`pseudo` imply visible gaps even when global gaps are 0.
- **Gaps option format (CRITICAL)**: `hyprctl getoption general:gaps_in -j` returns Hyprland's CssBoxStyle as `{"custom":"3 3 3 3","set":true}` — a space-separated string, not `{"int":3}`. Plain `tonumber?` on `.custom` returns null and silently treats gaps as 0. The parser must split and take `max`:
  ```jq
  if has("int") and (.int|type)=="number" then .int
  elif has("custom") and (.custom|type)=="string" and .custom != "" then
      ((.custom | split(" ") | map(tonumber? // 0) | max) // 0)
  else 0 end
  ```
- **Hyprpaper lifecycle (flicker-safe)**: `preload` new → `wallpaper` per monitor → `unload <previous-path>`. **Never `unload all`** — flickers. Use deterministic filenames so cache hits skip `magick` entirely. Never unload the waypaper image (track its path so `apply_image` excludes it from selective unload).

### Multi-Process IPC Pattern
- **One publisher, many consumers**: `hypr-activities` owns the truth.
- **Two surfaces**: atomic JSON snapshot (`tmp + mv`) + streaming AF_UNIX socket via `socat ... UNIX-LISTEN:<path>,fork,reuseaddr,unlink-early`.
- **Coalescing**: 16 ms inline debounce. The previous design — `( sleep 0.016 ; emit_snapshot ) &` — was buggy: emit ran in a subshell so `WAYPAPER_CHANGED=0` and similar resets were trapped inside; the parent's flag stayed `1` forever and the silent dive-off fired on every nudge.
- **FIFO discipline**: when several producers feed one FIFO and one main-shell loop reads it, **open the FIFO once on a numbered FD with `exec {FD}<>fifo`** and read with `read -u "$FD"`. Re-opening with `<"$FIFO"` per iteration leaves a per-iteration gap during which writers see EPIPE; eventually the cleanup unlinks the FIFO and the next reopen returns ENOENT, killing the script.
- **Atomic file writes**: `printf '%s' "$snap" >file.tmp && mv -f file.tmp file`.

### Color-Following Polling
- **POLL_ACTIVE flag**: `decide()` sets `POLL_ACTIVE=1` in match/mismatch/mixed; `0` everywhere else.
- **Main loop**:
  ```bash
  exec {SOCK_FD}< <(socat -u "UNIX-CONNECT:$SOCKET" - 2>/dev/null)
  while true; do
      snap=""
      if ((POLL_ACTIVE)); then
          read -t "$POLL_INTERVAL" -u "$SOCK_FD" -r snap || true
      else
          read -u "$SOCK_FD" -r snap || break  # systemd restarts us
      fi
      if [[ -n $snap ]]; then
          LAST_SNAP="$snap"; decide "$snap"
      elif ((POLL_ACTIVE)) && [[ -n $LAST_SNAP ]]; then
          decide "$LAST_SNAP" "poll"
      fi
  done
  ```
- **Mixed mode bypass**: in `phase=poll`, skip `WIN_COLOR` cache and re-sample every window so content changes propagate.
- **Cost ceiling**: each tick = `(jq ~4 ms) + (N × grim+magick ~50 ms each) + apply_color`. Wayland screencopy roundtrip is the floor; you can't beat ~25 ms per `grim`. Realistic rates: ~6 Hz match, ~4 Hz mixed (2 windows). The `DIST_THRESHOLD=100` squared check + exact-hex fast-exit eliminates hyprpaper traffic when the color is stable, so steady-state CPU is under 1 %.

### State Persistence & Toggles
- **Persistent user state** → `$XDG_STATE_HOME/hypr-edge-bg/dive` (single-line file, atomic `tmp+mv`).
- **Runtime sockets/snapshots** → `$XDG_RUNTIME_DIR/hypr-activities.{json,sock}`.
- **Toggle pattern**: state file write + `systemctl --user kill --kill-who=main -s SIGUSR1 hypr-edge-bg.service`. **`--kill-who=main` is required** — without it, SIGUSR1 hits every process in the cgroup including the `socat` child of process substitution, which dies and brings down the daemon. Never restart the daemon on toggle.
- **Silent fallback**: `inotifywait -e close_write,modify,moved_to ~/.config/waypaper/config.ini` → publisher sets `waypaper_changed=true` in the next snapshot → consumer notices `waypaper_changed && DIVE==on`, calls `write_dive_off`, logs once. Note: `waypaper_changed` is one-shot — the publisher resets it after the snapshot is built, in the **main shell** (NOT a subshell).
- **Tilde paths**: `waypaper`'s `config.ini` may contain `wallpaper = ~/Downloads/...`. Bash's `[[ -e $path ]]` does NOT expand `~`, so the publisher must do it: `[[ $v == "~" || $v == "~/"* ]] && v="$HOME${v#"~"}"` (with `# shellcheck disable=SC2088`).

### Bash Development
- **Strict header**:
  ```bash
  #!/usr/bin/env bash
  set -uo pipefail
  ```
  Use `set -uo` (no `-e`) for long-running daemons that must survive transient JSON parse failures; reserve `set -euo pipefail` for short batch scripts.
- **Trailing newlines matter**: any function meant to be consumed by `read -r` MUST emit a trailing `\n`. Always `printf '...\n'`, never `printf '...'`.
- **`jq` is expensive**: each invocation costs 4–10 ms of bash + jq startup. **Coalesce** — emit every needed scalar + nested JSON + flattened tables in ONE jq call, then parse with `read`/`IFS='|' read`. The previous decide() ran ~14 jqs per tick (~70 ms wall) and capped polling at 1–2 Hz; one jq drops it to 4 ms and 4–6 Hz.
- **Fast-exit hot paths**: `[[ $hex == "$LAST_HEX" ]] && return 0` before any RGB math, jq, or hyprctl. Cache `MON_W`/`MON_H`/`MON_NAMES` indexed by the monitors-blob string so the steady-state has zero forks.
- **`declare -A` caches keyed by window address**: avoid redundant `grim` calls. Bypass on `phase=poll` so live content changes still propagate.
- **`trap` on EXIT**: clean sockets, FIFOs, temp PNGs, child PIDs. Close opened FDs (`exec {FD}<&-`).
- **Logs to stderr**: `printf '[name] %s\n' "$*" >&2`. Stdout reserved for UI output (e.g. `hypr-dive status`).

### ImageMagick Pipeline
- **`-depth 8` is mandatory**: NixOS ships ImageMagick **Q16** (16-bit channels) by default. Without `-depth 8`, `magick - txt:-` emits pixels as `#AAAABBBBCCCC` (12 hex chars), and `head -c 6` after stripping `#` returns `AAAABB` instead of `AABBCC` — every sample silently corrupted.
- **Lowercase normalisation**: `tr 'A-F' 'a-f'` after the sample so cache filenames (`c-<hex>-WxH.png`) don't double up between sample-derived (uppercase from magick) and math-derived (lowercase from `rgb_to_hex`) hexes.
- **Top-edge sample (60 % center)**: `sw = w * SAMPLE_W_RATIO / 100`, capped at `SAMPLE_W_MAX=400`. Geometry `${sx},${y} ${sw}x${SAMPLE_H}` where `sx = x + (w - sw)/2`. The 60 % center avoids title-bar gradients and rounded-corner aliasing on the far edges.

### Color Math Recipes
- **Match (top-edge sample)**:
  ```bash
  grim -g "$geom" - 2>/dev/null \
    | magick - -depth 8 -resize 1x1! txt:- 2>/dev/null \
    | awk 'NR==2{print $3}' | sed 's/#//' | head -c 6 \
    | tr 'A-F' 'a-f'
  ```
- **Mismatch (luma-aware)**: shift luma by `±SHIFT_PCT` in the dark/light direction, clamp to `[CLAMP_LO, CLAMP_HI]` (defaults `[30, 225]`), then scale RGB by `outL/L`. Pure integer ops.
- **Mixed (area-weighted)**: linear-RGB mean weighted by window pixel area. No gamma correction — overkill for the visual goal, 5× faster.
- **Skip thresholds**: exact-hex fast-exit first; squared RGB distance < 100 ≈ imperceptible; skip the hyprpaper cycle.

## Module Options (current)
| Option | Default | Notes |
|---|---|---|
| `defaultColor` | `"323246"` | Hex without `#`. Dive-on default bg. |
| `sampleHeight` | `1` | Pixels of vertical strip sampled. |
| `sampleWidthRatioPct` | `60` | % of window width centered on top-edge sampling. |
| `mismatchShiftPct` | `40` | Luma shift % for mismatch derivation. |
| `mismatchClampMin` | `30` | Lower clamp for mismatch luma. |
| `mismatchClampMax` | `225` | Upper clamp. |
| `distanceThreshold` | `100` | Squared-RGB skip threshold. |
| `pollIntervalSec` | `"0.1"` | Color-following poll cadence. |
| `cacheSize` | `16` | Max retained PNGs in `/tmp/hypr-edge-bg`. |
| `waypaperConfigPath` | `${xdg.configHome}/waypaper/config.ini` | inotify target. |

## Coding Directives (priority order)
1. **Declarative First** — every tool is a Home Manager module with typed options and a `systemd.user.service`. `Restart=always; RestartSec=1` on long-lived daemons.
2. **Event-Driven, Polled Where Needed** — IPC subscriptions for state changes; polling reserved for the color-following inner mode (`POLL_ACTIVE=1`). The publisher never polls.
3. **One Publisher, Many Consumers** — centralise external-tool reads in `hypr-activities`, broadcast via JSON snapshot + AF_UNIX socket. No other process calls `hyprctl`.
4. **Atomic & Idempotent** — every state mutation is `tmp + mv`. Daemons can be restarted safely. Toggles signal (`SIGUSR1 --kill-who=main`); they never restart.
5. **One jq Per Tick, Fast-Exit First** — coalesce extracts; check `hex == LAST_HEX` before any work; cache monitor metadata.
6. **Selective Hyprpaper Lifecycle** — `preload → wallpaper → unload <previous>`. Deterministic temp filenames. Never `unload all`. Never unload the waypaper image.
7. **FIFO Once, Read by FD** — open with `exec {FD}<>"$FIFO"`, read with `read -u "$FD"`. Re-opening per iteration is a footgun.
8. **Inline Debounce, No Subshells for State** — `read -t DEBOUNCE_S` with a `PENDING` flag. Background subshells trap mutations; never run `emit_snapshot` (or anything that mutates parent state) inside `( ... ) &`.
9. **Lightweight Math** — integer-only RGB arithmetic. BT.601 luma. Squared distance for thresholding.
10. **Concise & Documented** — minimal, heavily commented bash. Comments explain *why* (Hyprland quirk, ImageMagick Q16, kill-who, subshell trap), not *what*. Assume NixOS/Hyprland literacy.

## Known Hazards (do not regress)
- `--kill-who=main` on every `systemctl kill` to a Type=simple daemon that uses `< <(...)`.
- `-depth 8` on every `magick … txt:-` consumer of grim output.
- `tr 'A-F' 'a-f'` after every sampled hex.
- Gap parser must handle CssBoxStyle `.custom`.
- Open `EVENT_FIFO` and `BROADCAST_FIFO` once with `<>`, read by FD.
- `emit_snapshot` runs in main shell. State resets in subshells are silently lost.
- Tilde-expand `~` in waypaper config (`[[ -e ]]` does NOT expand).
- Fullscreen freeze branch: `fs >= 2` only.
- `fs=1` (maximized) falls through the matrix.
