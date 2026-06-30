# Canvas Landscape section — 3×3 workspace exposé

**Status:** spec, 2026-06-25
**Author:** indeepandes
**Scope:** new section in the StandardOS canvas (Super+RETURN dashboard) showing a 3×3 grid of workspace thumbnails, click-to-jump.

---

## Problem

The canvas section-nav today routes between Max (built) and 14 v31 settings placeholders. There is no "look at all my workspaces at once" view anywhere in StandardOS. Hyprland's bar pills show numbers and busy state but no visual content.

A workspace exposé inside the canvas gives a single keyboard path (Super+RETURN, click Landscape, click target ws) to *see* and *switch* without learning a separate keybind or installing the `hyprexpo` plugin.

## Scope (v0)

In scope:

- New 16th pill `Landscape` appended to `section-nav` after `location`.
- New `landscape-section` widget rendering a 3×3 grid of workspaces 1–9, row-major.
- Each cell shows a cached PNG of "what that workspace looked like the last time you were there", or a flat empty surface if no cache exists.
- Current workspace cell carries a soft top-inset shadow (`opt-pushed` visual language) — no border, no color shift.
- Universal `opt-hover-bright` hover film on every cell.
- Click cell → `hyprctl dispatch workspace N` → close canvas via existing `canvas-close` script.
- New `landscape-snap-daemon` (systemd-user) captures the currently-focused workspace as `/tmp/standardos/landscape/ws-N.png` on window events (debounced 300 ms) and on canvas-open trigger.
- Home Manager module `landscape-snap.nix` wires the daemon.

Out of scope (v0):

- Multi-monitor. v0 captures the focused output only. Workspaces on other monitors will show empty until visited as the focused workspace. A v1 enhancement can iterate `hyprctl monitors -j` and grim each.
- Hover-reveal of window list / close buttons (Variant B annotations). Deferred per user "build A, improve later" decision.
- Workspaces 10+. The grid is fixed at 9 cells; workspaces 10+ exist but are not visualized.
- Special workspaces (`scratchpad`, `magic`, etc.). Ignored.
- Animation between cached and live snapshot of current cell. Static image swap is sufficient.

## Architecture

Three concrete additions plus minor edits to existing files:

```
/etc/nixos/home/scripts/landscape-snap-daemon.sh   ← new daemon
/etc/nixos/home/modules/landscape-snap.nix         ← new HM module
/etc/nixos/home/widgets/scripts/canvas-jump-ws     ← new click handler
/etc/nixos/home/widgets/eww/eww.yuck               ← edited (section pill + widget + deflisten)
/etc/nixos/home/widgets/eww/eww.scss               ← edited (grid + cell + current styling)
/etc/nixos/home.nix                                ← enable services.landscapeSnap (outside the repo, edited in-place)
```

Cache layout (`/tmp/standardos/landscape/`, tmpfs, volatile):

```
ws-1.png … ws-9.png      ← latest PNG per workspace, atomic tmp+mv
manifest.json            ← {"ws1_mtime": <epoch>, …, "ws9_mtime": <epoch>}
open-trigger             ← touched by eww onload; daemon inotify-watches and grims current
```

### Data flow

```
Hyprland IPC ──socat──► landscape-snap-daemon
                           │
                           │ window event arrives (openwindow / closewindow /
                           │ movewindow / windowtitle / fullscreen)
                           │
                           ▼ debounce 300 ms
                       grim -o $focused_monitor $tmp_png
                           │
                           ▼ mv -f $tmp_png ws-$N.png
                       update manifest.json (atomic)
                           │
                           ▼
                    inotifywait on manifest.json
                           │
                eww deflisten reads → defvar `ws-paths`
                           │
                ┌──────────┼──────────┐
                ▼          ▼          ▼
            ws-1 cell  ws-2 cell  …  (image :path {ws-paths.ws1 + "?t=" + ws-paths.ws1_mtime})
```

Canvas-open trigger path:

```
canvas-open script ─► touch /tmp/standardos/landscape/open-trigger
                          │
                          ▼ daemon inotify branch
                       grim the current workspace immediately
                       (so the "you are here" cell is fresh)
```

### Image refresh trick (eww cache-buster)

Eww's `(image :path ...)` caches by path string. To force re-render when the file on disk changes but the path doesn't, the `deflisten` emits paths with an mtime query suffix:

```json
{"ws1": "/tmp/standardos/landscape/ws-1.png?t=1782420000",
 "ws2": "/tmp/standardos/landscape/ws-2.png?t=1782420015",
 …}
```

GTK's `GdkPixbuf` loader ignores the `?t=…` suffix when reading the file, but eww's path-string-equality check sees a new string and re-renders. If this fails on this gtk-pixbuf version, the fallback is symlinks: daemon writes `ws-1-<mtime>.png` and atomically `ln -sfn ws-1-<mtime>.png ws-1.png`; eww deflisten emits the timestamped target path directly. Decide which works during implementation (cheap to swap).

## Components

### `landscape-snap-daemon.sh`

Subscribes to Hyprland IPC via `socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock`. Reads events line by line.

Event triggers (debounced 300 ms together):

- `openwindow>>`
- `closewindow>>`
- `movewindow>>`
- `windowtitle>>` (filtered: only emit if it's the focused window — avoids capturing on background-tab title flips)
- `fullscreen>>`
- `workspace>>` (also re-snapshots the new current after the swap settles)

Also inotify-watches `/tmp/standardos/landscape/open-trigger`; on modify, immediately grim the current ws.

Capture:

```bash
focused_mon=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
focused_ws=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .activeWorkspace.id')
[ "$focused_ws" -ge 1 ] && [ "$focused_ws" -le 9 ] || return
tmp=/tmp/standardos/landscape/ws-$focused_ws.png.tmp
grim -o "$focused_mon" -s 0.4 "$tmp" 2>/dev/null \
  && mv -f "$tmp" "/tmp/standardos/landscape/ws-$focused_ws.png" \
  && touch_manifest
```

`-s 0.4` scales to 40% of native res — keeps each PNG under ~200 KB and reduces grim CPU.

`touch_manifest()` rebuilds `manifest.json` from `stat -c %Y ws-*.png`, atomically swaps. This single file is what eww watches — cheaper than 9 separate watches.

Hazards mitigated:

- Atomic writes (tmp + mv) — partial PNG never visible.
- Debounce — title flips during scroll won't pummel grim.
- `[ -ge 1 -le 9 ]` guard — special workspaces (`-99` scratchpad) silently ignored.
- `2>/dev/null` on grim — disconnected output won't spam logs (handled by falling back to empty cell).

### `landscape-snap.nix`

Standard daemon module, mirrors `brightness-daemon.nix`:

```nix
{ config, lib, pkgs, ... }:
let cfg = config.services.landscapeSnap;
in {
  options.services.landscapeSnap.enable =
    lib.mkEnableOption "StandardOS landscape snapshot daemon (3x3 workspace exposé)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.landscape-snap = {
      Unit.Description = "StandardOS landscape snapshot daemon";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.grim}/bin:${pkgs.jq}/bin:${pkgs.socat}/bin:${pkgs.inotify-tools}/bin:${pkgs.hyprland}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/landscape-snap-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
```

Host-side enable in `/etc/nixos/home.nix` (one line: `services.landscapeSnap.enable = true;` next to the existing `services.brightnessDaemon.enable = true;` at line 62). `/etc/nixos/home.nix` is outside the in-repo tree and not under git — edited in place per the same pattern as every other StandardOS daemon.

### `canvas-jump-ws` (click handler)

```bash
#!/usr/bin/env bash
# Usage: canvas-jump-ws <N>  — jump to workspace N then close the canvas.
n=$1
[[ "$n" =~ ^[1-9]$ ]] || exit 1
hyprctl dispatch workspace "$n" >/dev/null
exec /etc/nixos/home/scripts/canvas-close
```

`exec` so the canvas-close script replaces this shell — no extra process hang.

### Eww section pill + widget

Append to `section-nav` (eww.yuck:165):

```yuck
(section-pill :id "landscape" :label "Landscape")
```

Append to canvas section-body (eww.yuck:483) — note this section needs a real widget, NOT a `section-slot`-wrapped placeholder, so it follows the `section-max` inline pattern:

```yuck
(box :visible {current-section == "landscape"} :orientation "vertical"
     :hexpand true :vexpand true :halign "fill" :valign "fill"
  (landscape-section))
```

New deflisten near the existing `canvas-mpris-listen`:

```yuck
(deflisten ws-paths
  :initial "{}"
  `/etc/nixos/home/widgets/scripts/canvas-landscape-listen`)
```

New widget definition `landscape-section` — 3 rows of 3 cells, each cell an eventbox wrapping an overlay (image with empty-surface fallback below). The current-cell soft-inset shadow is applied via class composition: `:class {focused-ws == "1" ? "ls-cell ls-cell-current" : "ls-cell"}`.

`focused-ws` is a defpoll on `hyprctl activeworkspace -j | jq -r .id` at 1 s — cheap, doesn't need event subscription since the canvas only matters when open.

### Eww listener `canvas-landscape-listen`

```bash
#!/usr/bin/env bash
# Watch manifest.json, emit JSON map of {wsN: "<path>?t=<mtime>"} on every change.
dir=/tmp/standardos/landscape
mkdir -p "$dir"
emit() {
  local out='{'
  for n in 1 2 3 4 5 6 7 8 9; do
    local f="$dir/ws-$n.png"
    if [ -r "$f" ]; then
      local m
      m=$(stat -c %Y "$f")
      out+="\"ws$n\":\"$f?t=$m\","
    else
      out+="\"ws$n\":\"\","
    fi
  done
  echo "${out%,}}"
}
emit
inotifywait -m -e close_write,moved_to --format '%f' "$dir" 2>/dev/null | \
  while read -r name; do
    [ "$name" = "manifest.json" ] && emit
  done
```

Eww uses empty-path cells as the "no snapshot" signal and renders the flat-surface fallback box.

### Eww-onload open trigger

Wire `canvas-open` script (existing) to also `touch /tmp/standardos/landscape/open-trigger` so the daemon refreshes the current cell immediately when the canvas appears.

### Eww styling (eww.scss)

ASCII-only per the standing rule. Add a block near the end:

```scss
.ls-grid {
  padding: 14px;
}
.ls-cell {
  background: @opt-surface-parent;
  border-radius: 10px;
  min-width: 240px;
  min-height: 150px;
  /* universal opt-hover-bright applies via existing rule */
}
.ls-cell-current {
  /* opt-pushed visual: soft top-inset shadow on existing surface. */
  box-shadow: inset 0 6px 18px -4px @opt-pushed-shadow;
}
.ls-shot {
  border-radius: 10px;
}
.ls-empty {
  /* visible when no cached image exists — flat surface, no glyph */
  background: @opt-surface-child;
  border-radius: 10px;
}
```

Light-mode `.light .ls-cell-current` etc. — Landscape carries no text, so the long light-text selector blocks don't need to learn about it. Verification checklist item 3 is N/A here.

## Edge cases

| Case | Behavior |
|---|---|
| First run after reboot, no cache exists | All 9 cells render as empty surface. As user visits workspaces, cells fill in. |
| Workspace N exists but never focused since reboot | Empty cell. Acceptable. |
| Workspace N doesn't exist as a Hyprland object | Same as never-visited: empty cell. No special handling needed. |
| Daemon crashed / disabled | All cells freeze on their last cached PNG. Canvas still renders, click-to-jump still works (it goes through `hyprctl` directly, not the daemon). |
| Hyprland restarted | `HYPRLAND_INSTANCE_SIGNATURE` changes — daemon's socat read returns EOF. `Restart=always` + `RestartSec=5` brings it back. Restart picks up the new signature from env. |
| User has 12 workspaces | Cells 1–9 work normally; workspaces 10–12 are invisible from this section. They still show on the bar pills as today. |
| Special workspace focused (`-99`) | The `[1-9]` guard skips the capture branch silently. Cell for the underlying base workspace stays at its last good snapshot. |
| Output disconnected (laptop closed, external unplugged) | `grim` fails (output gone). Stderr suppressed; cell freezes on last cached PNG. When the output reattaches and user visits a workspace, snapshot resumes. |
| Cache filesystem full | grim errors out, cell freezes. tmpfs at `/tmp` is RAM-backed; if it fills, much bigger problems than this section. |
| eww cache-buster trick fails on this GTK version | Fall back to symlinks-to-timestamped-files (decided at implementation time, see Architecture §Image refresh trick). |

## Testing / verification

Manual (the v0 acceptance test):

1. `nixos-rebuild switch` after enabling `services.landscapeSnap`.
2. Visit workspaces 1, 2, 3 — populate each with at least one window.
3. Open canvas (Super+RETURN).
4. Click `Landscape` pill — section renders.
5. Cells 1, 2, 3 show their respective contents (current = whichever you were on at canvas open, with soft inset shadow).
6. Cells 4–9 show flat empty surfaces.
7. Click cell 2 — canvas closes, you land on workspace 2.
8. Reopen canvas → Landscape — current cell now reflects ws 2.

Hazard audits per `waybar/CLAUDE.md` "Verification before claiming done":

- [ ] Cache writes atomic (`tmp + mv -f`)? — yes, in `landscape-snap-daemon.sh`.
- [ ] Inotify watches the DIRECTORY (`--format '%f'`), not individual file paths? — yes, watches `$dir` filtered by basename.
- [ ] `set -u` + `declare -A foo` not used (no associative arrays in this daemon)? — N/A.
- [ ] `eww.scss` block strictly ASCII (grep `[^\x00-\x7f]`)? — yes, no glyphs or em-dashes added.
- [ ] No `jq` in tight hot loops? — `jq` only called inside the debounce window (per snapshot), not per event line.
- [ ] No new error pill on OPTIONS? — confirmed; grim failures are silent.
- [ ] `nixos-rebuild switch` (not `test`)? — yes; daemon needs the unit on disk.

TODO.md update: this work is unplanned (not on TODO today), so it goes straight to DONE with a Hint line when it ships, per the work-map contract.

## Open implementation-time decisions

1. **Cache-buster trick vs. symlink fallback.** Try `?t=<mtime>` query suffix first; if eww/gtk fails to refresh, swap to timestamped symlinks. Both supported by the listener script — only the path-construction line changes.
2. **Cell `min-width` / `min-height`.** Tuned in eww.scss to match the canvas's `section-body` width. Start with 240×150 (16:10), iterate visually once it renders.
3. **`grim -s 0.4` scale factor.** 40% is a guess; adjust if cells look pixelated or if disk pressure surprises us.
4. **Section-pill label.** "Landscape" — could become a glyph + label combo to match other planned sections. Plain text for v0.
