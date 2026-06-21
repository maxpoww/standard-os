# Canvas media-MEGA — mpris truth — design

**Date:** 2026-06-21
**Status:** approved (4 forks decided 2026-06-21 via structured questions; position-handling decided inline)
**TODO entry:** `waybar/TODO.md` NEXT → "Media player module (MPRIS)" — Wave 3 Task 6 deferred completion

## Context

The widgets-canvas dashboard ships in Wave 2+3 with one card still on scaffold: **media-MEGA**. Today `/etc/nixos/home/widgets/scripts/canvas-media.sh` shells out to `playerctl` per field; `eww.yuck:65-72` runs **8 separate defpolls** (source/title/artist/album/status/pos/len/pct) at 1-5 s each — 8 `playerctl` forks per second worst-case while the canvas is open, cover art unwired, `mm-bar-fill` width is full-track CSS only (Wave 2 hint flagged it).

The Wave 3 NEXT entry routed this to `/home/max/mpris-waybar/scripts/mpris-publisher` (the rewrite in progress). Inspection (2026-06-21):

- Publisher **exists, works, writes 7 cache files** (`mpris-info`, `mpris-playpause`, `mpris-volume`, `mpris-selector`, `mpris-prev`, `mpris-next`, `mpris-output`) — but **every one is shaped as a waybar custom-module pill JSON** (`{"text","class","tooltip"}`), not a composite of dashboard fields.
- Publisher **is not running** as a systemd unit. Cache files dated yesterday prove it was launched manually for Wave 3 work and never re-supervised.
- Publisher **does not track position** — pos/len/pct don't exist anywhere in its state. The bar widget didn't need them; the dashboard does.

So the deferred work is bigger than "swap defpolls to cache reads" — it's *publish a new channel*, *add position state*, *supervise the daemon*, *rewire eww*, *delete the scaffold*.

## Scope

In:
- New composite channel `/tmp/waybar-cache/mpris-snapshot.json` (additive — existing 7 pill caches unchanged)
- Publisher gains position state + 1 s ticker on active player when Playing
- Publisher gains `art_path` field reflecting current cover-art file
- Systemd user unit `modules/mpris-publisher.nix`, enabled via `home.nix`
- Canvas eww consumes via `deflisten` + `inotifywait` on `/tmp/waybar-cache/` filtered by basename (composite-module pattern, per `waybar/ARCHITECTURE.md`)
- `media-MEGA` widget rewired off the 8 defpolls; `mm-bar-fill` width interpolated via `:style "min-width: ${pct}%"`
- Delete `/etc/nixos/home/widgets/scripts/canvas-media.sh` (replaced verbatim)
- ARCHITECTURE.md daemon-registry row + (no new RTMIN — publisher does not signal waybar for the composite; canvas owns the subscription)
- TODO.md NEXT → DONE move (Wave 3 Task 6 closes)

Out:
- Touching the 7 existing pill caches (the bar widget exists separately and is not part of this work)
- Migrating the mpris-waybar rewrite to git or finishing any other rewrite work — out of scope; the "wire what works now" path was chosen explicitly
- A waybar-bar MPRIS pill — that lives under the broader "Media player module (MPRIS)" NEXT entry, separate spec when it ships
- `XF86AudioPlay/Pause/Next/Prev` reflection on a bar pill — same NEXT, separate spec
- Cava follow / multi-player selector UI inside the canvas

## Interfaces

### Cache: `/tmp/waybar-cache/mpris-snapshot.json`

```json
{
  "active": true,
  "player": "spotify",
  "source_label": "SPOTIFY · NOW PLAYING",
  "title": "Strobe",
  "artist": "deadmau5",
  "album": "For Lack of a Better Name",
  "status": "Playing",
  "status_glyph": "⏸",
  "pos_sec": 73,
  "len_sec": 633,
  "pct": 11,
  "pos_text": "1:13",
  "len_text": "10:33",
  "art_path": "/tmp/mpris-art/3f8c…b21.jpg",
  "updated": 1782062770
}
```

Shape rules:
- `active=false` is the "no player" state. In that state every other field is `""` / `0` / `null`. Eww collapses the media-MEGA frame via the existing `.empty` mechanism (`media-MEGA` widget conditionally classed `empty` when `active=false`).
- `status_glyph` mirrors today's `canvas-media.sh status` semantics: `Playing → ⏸` (button shows what tapping does), `Paused → ⏵`, else `⏵`.
- `pos_sec` / `len_sec` integers; `pct = (pos * 100) / len` clamped 0..100; `pos_text` / `len_text` `MM:SS` formatted. Eww binds to text and pct independently — no derived computation in widgets.
- `art_path` is `/tmp/mpris/current` when an active player has art, empty string otherwise. The publisher *already* maintains this symlink atomically (`update_art_symlink()`, `mpris-publisher:583-596`) — it always points at the current active player's art file, swapped via `ln + mv` so consumers never see a half-state. Eww image widget reads the stable path directly; no per-bus art tracking needed in the composite.
- `updated` unix timestamp at every emit (used for staleness debugging; canvas doesn't render it).

### No new RTMIN signal

The composite is canvas-only. The canvas owns the subscription via `inotifywait`; waybar never reads this file. Reusing an RTMIN slot would be pure noise.

The 7 existing pill caches keep their existing RTMIN (whatever the bar widget uses — out of scope) — those are not modified.

### Listener: `scripts/canvas-mpris-listen`

```bash
#!/usr/bin/env bash
# Eww deflisten source for /tmp/waybar-cache/mpris-snapshot.json.
# Prints the file on stdout once at startup, then again on every atomic update.
set -u
CACHE_DIR=/tmp/waybar-cache
SNAP=mpris-snapshot.json
EMPTY='{"active":false,"player":"","source_label":"","title":"","artist":"","album":"","status":"","status_glyph":"⏵","pos_sec":0,"len_sec":0,"pct":0,"pos_text":"—:—","len_text":"—:—","art_path":"","updated":0}'

emit_once() {
    cat "$CACHE_DIR/$SNAP" 2>/dev/null || echo "$EMPTY"
}
emit_once

# Watch the parent dir, filter by basename — per ARCHITECTURE.md composite-module
# hazard: tmp+mv unlinks the inode, so per-file watches die after first write.
exec inotifywait -m -q --format '%f' -e close_write,moved_to "$CACHE_DIR" \
    | while IFS= read -r f; do
        [[ $f == "$SNAP" ]] && emit_once
    done
```

Single subscription replaces 8 defpolls. Idle screens cost zero forks.

### Publisher additions

In `/home/max/mpris-waybar/scripts/mpris-publisher`:

1. New associative arrays `P_POS_SEC[bus]`, `P_LEN_SEC[bus]`. Length comes from `playerctl metadata --format '{{ mpris:length }}'` and only changes per-track, so it lives alongside existing per-track state populated by `apply_metadata`. Position is volatile and lives on its own ticker (below).
2. New `position_ticker_loop` background loop: every 1 s when `[[ -n $ACTIVE && ${P_STATUS[$ACTIVE]:-} == Playing ]]`, run `playerctl --player=$ACTIVE position 2>/dev/null` → update `P_POS_SEC[$ACTIVE]` → call `write_snapshot_composite`. When idle (no Playing active), `sleep 1` without forking playerctl. Started from the main init block, before the `while true` event loop, alongside `info_marquee_loop &`.
3. New `write_snapshot_composite()` function. Builds the documented JSON shape from `P_*` arrays + `/tmp/mpris/current` symlink, writes via tmp+mv to `/tmp/waybar-cache/mpris-snapshot.json`. Dedup via in-memory `_LAST_COMPOSITE` byte-equal check (same pattern as `_LAST_SNAPSHOT` at `mpris-publisher:640`).
4. Existing `write_snapshot` calls `write_snapshot_composite` at its tail (after `write_cava_target_inline`). Position ticker calls it directly between snapshots.

Art path: the publisher *already* maintains `/tmp/mpris/current` as the canonical "active player's art" symlink (`update_art_symlink` at `mpris-publisher:583-596`). The composite just emits the symlink path verbatim when `ACTIVE` is non-empty; eww's image widget follows the symlink on every snapshot update. No per-bus art tracking added; no new state.

### Systemd unit: `modules/mpris-publisher.nix`

Pattern matches the Wave 3 daemons (e.g. `modules/system-daemon.nix`). Service body:

```
ExecStart = "${pkgs.bash}/bin/bash /home/max/mpris-waybar/scripts/mpris-publisher";
Restart = "on-failure";
RestartSec = "2s";
```

Dependencies: `graphical-session.target`. PartOf same.

The script path is out-of-Nix-store (the mpris-waybar repo is not a flake input). This is intentional and matches how `~/.config/waybar/scripts/` daemons currently work — the user actively iterates the script and wants live edits without rebuilds. A future "publish mpris-waybar as a flake input" cleanup is out of scope.

### Canvas widget rewire

`/etc/nixos/home/widgets/eww/eww.yuck`:

Delete lines 65-72 (the 8 `media-*` defpolls).

Add:
```
(deflisten mpris-snapshot
  :initial '{"active":false,"player":"","source_label":"","title":"","artist":"","album":"","status":"","status_glyph":"⏵","pos_sec":0,"len_sec":0,"pct":0,"pos_text":"—:—","len_text":"—:—","art_path":"","updated":0}'
  `/etc/nixos/home/widgets/scripts/canvas-mpris-listen`)
```

In the `media-mega-frame` widget body, replace every `media-title` / `media-artist` / `media-status` / `media-pos` / `media-len` / `media-source` / `media-album` reference with the corresponding `mpris-snapshot.<field>` access. Add `:class "media-mega ${mpris-snapshot.active == "true" ? "" : "empty"}"` to the outer box. Add cover art:

```
(image :class "mm-art" :path {mpris-snapshot.art_path ?: ""}
       :image-width 92 :image-height 92)
```

Progress bar width (Wave 2 follow-up folded in):
```
(box :class "mm-bar" :hexpand true
  (box :class "mm-bar-fill" :hexpand false
       :style "min-width: ${mpris-snapshot.pct}%;"))
```

### Cleanup

Delete `/etc/nixos/home/widgets/scripts/canvas-media.sh` in the same commit. Listener supersedes it.

## Architecture

Five files change, three files appear, one deletes:

```
home/widgets/eww/eww.yuck                  defpolls → deflisten + listen script
home/widgets/eww/eww.scss                  +.mm-art rule + (existing .mm-bar-fill width selector OK)
home/widgets/scripts/canvas-mpris-listen   NEW: inotify deflisten source
home/widgets/scripts/canvas-media.sh       DELETED
home/modules/mpris-publisher.nix           NEW: systemd user unit
home/home.nix                              import mpris-publisher.nix
home/waybar/ARCHITECTURE.md                daemon-registry row (mpris-publisher)
home/waybar/TODO.md                        NEXT → DONE (Wave 3 Task 6 closes)
/home/max/mpris-waybar/scripts/mpris-publisher   +P_POS_SEC/P_LEN_SEC/P_ART_PATH, +position_ticker_loop, +write_snapshot_composite
```

The composite-module pattern is the ARCHITECTURE.md-named pattern (`waybar/ARCHITECTURE.md` "composite module"). No new shared library needed; `canvas-cache.sh` is for daemons writing on RTMIN — irrelevant here.

## Test plan

The publisher is not git-versioned and is bash; TDD against `derive_*` is awkward when state lives in process-global associative arrays. Practical plan:

1. **Unit-ish: composite JSON shape.** Add a library-mode env (`MPRIS_PUB_LIB_ONLY=1`) that loads functions without starting the event loop. Test fixture sets `ACTIVE=spotify`, fills the `P_*[spotify]` arrays, calls `write_snapshot_composite`, asserts the JSON matches the documented shape (jq schema check).
2. **Smoke: position ticker.** With `MPRIS_PUB_LIB_ONLY=1`, set `P_STATUS[spotify]=Playing`, call one tick of `position_ticker_loop` body (factored as `position_ticker_step`), assert `P_POS_SEC[spotify]` updated and snapshot reflects it.
3. **Visual smoke (not automated):** start a song → open canvas → confirm title/artist/album/status/progress update in real-time; pause → confirm status glyph flips and progress freezes; swap players → confirm source_label changes; close all players → confirm media-MEGA collapses.

## Hazards

- **inotifywait on the file path dies after first tmp+mv.** Mitigated: listener watches the parent dir `/tmp/waybar-cache/` with `--format '%f'`, filters by basename. Same pattern named in `waybar/ARCHITECTURE.md` composite-module section and the standard-os skill hazard list.
- **Position ticker storms write_snapshot_composite when Playing.** Mitigated by byte-equal dedup at write — only the file actually changes when `pos_sec` advances (true every second), and that's intended. The pill caches dedup independently and skip their writes when nothing pill-relevant changed; CPU stays low.
- **`playerctl --player=$ACTIVE position` can fail mid-tick** (player exits between tick start and call). Mitigated: tick body wraps in `|| true`, missing position leaves `P_POS_SEC[$ACTIVE]` at its last value for one cycle, then `write_snapshot` runs from the bus-gone event and reframes the composite (active=false).
- **Eww deflisten requires the script to stay running.** Mitigated: `exec inotifywait -m` blocks until eww kills it. No respawn loop needed inside the script — eww restarts the deflisten on script exit.
- **Cover-art file may be evicted by publisher's `evict_art_cache` while eww still references its path.** Mitigated: eww re-reads on every snapshot update; when the art is replaced, snapshot is re-emitted with the new path. Eviction races leave a stale `art_path` briefly; eww shows a missing-image placeholder for one tick. Acceptable.
- **`mpris-snapshot.json` initial-value mismatch with listener default.** Mitigated: both define the same EMPTY JSON literal; if they ever drift, the listener `emit_once` overwrites within ms of eww startup. Functional impact: cosmetic only.
- **Systemd unit starts before publisher's deps (pipewire, dbus user bus) are up.** Mitigated: `After=pipewire.service dbus.socket`, `Wants=pipewire.service`, plus the publisher's own `Restart=on-failure` + `RestartSec=2s` covers transient races at session start.
- **`.empty` collapse on media-MEGA must use `font-size: 0` per skill hazard.** The card has labels; without `font-size: 0` the cleared text still reserves width. Existing `.mm-*` rules need the `.empty` cascade added.
- **No-error-pill rule.** Listener swallows failures (`cat || echo $EMPTY`). Publisher already logs failures to journalctl only. No notify-send, no red pill anywhere.

## Out of scope (follow-ups noted in TODO.md NEXT)

- Waybar-bar MPRIS pill + XF86AudioPlay/Pause/Next/Prev reflection (the other half of the NEXT entry, separate spec when designed).
- Migrating mpris-waybar to a git repo + nix flake input.
- Cava follow / multi-player UX inside the canvas.
- Replacing the 7 pill JSONs with the composite (would couple bar work to dashboard work; bar can read composite later if it wants).

## Commit shape (single commit, matches Wave 3 pattern)

```
wave3: canvas-media reads mpris-publisher composite truth (Task 6 deferred — closed)
```

Modified: widgets/eww/eww.yuck, widgets/eww/eww.scss, home.nix, waybar/ARCHITECTURE.md, waybar/TODO.md, /home/max/mpris-waybar/scripts/mpris-publisher
Created: widgets/scripts/canvas-mpris-listen, modules/mpris-publisher.nix
Deleted: widgets/scripts/canvas-media.sh
