# StandardOS — Landscape as a Standalone Surface (Design)

**Date:** 2026-06-26
**Status:** Design (approved A approach + sections 1-2; sections 3-4 folded inline; spec authored autonomously per user instruction "go ahead as far as you can")
**Supersedes nothing.** Refines on top of the shipped v0 Landscape-inside-canvas (`2026-06-25-canvas-landscape-section-design.md`).

## Goal

Promote the Landscape section out of the StandardOS canvas into its own independent eww gtk-layer-shell window. Super+RETURN — previously the canvas opener — becomes the Landscape opener. The Control Center (existing canvas) migrates to `Super+Shift+S`. The existing `Super+Shift+S` (`movewindow d`) migrates to `Super+Alt+S`. Landscape's surface shows nothing but the 9-cell grid — no `section-nav`, no pills, no chrome.

## Why

The v0 Landscape lived inside the canvas because that was the cheapest way to ship A. After using it, the user wants Landscape and the Control Center to be "two completely different things." Cross-surface coupling (one of them goes wrong, the other can't be reached) was the immediate driver. Identity-of-surface — "Super+RETURN is Landscape" vs. "Super+RETURN is the dashboard" — was the underlying one.

## Non-goals

- No new daemon. The shipped `landscape-snap` daemon, its manifest, its inotify watcher, the `canvas-landscape-listen` deflisten source, and the `canvas-jump-ws` click handler remain in place unchanged. Their names stay `canvas-*` for now (rename is a separate stream — would require updating every reference and the change is purely cosmetic).
- No Variant B annotations (workspace number + app captions). Still deferred.
- No change to the snapshot daemon's debounce, capture, or atomic-write logic.
- No upgrade of eww to 0.7+ (would unblock `:namespace` defwindow attribute but is out of scope; design adapts to 0.6.0 instead).
- No rename of `standardos-canvas.service` (currently the name of the eww daemon unit that serves ALL eww windows — misleading once Landscape is a peer surface, but renaming touches every nix module that references it and is unrelated to this work).

## Architecture

Two independent eww gtk-layer-shell windows backed by a single eww daemon (`standardos-canvas.service`):

```
                Hyprland binds
                ─────────────────
                Super+RETURN     ─► landscape-open ─► eww open landscape
                Super+Shift+S    ─► canvas-open    ─► eww open dashboard
                Super+Alt+S      ─► movewindow d  (no surface)

                eww daemon (standardos-canvas.service)
                ┌────────────────────────────────────┐
                │  defwindow landscape  (Super+RET)  │
                │     └─ landscape-grid (3x3)        │
                │                                    │
                │  defwindow dashboard  (Super+Sh+S) │
                │     └─ canvas (section-nav, body)  │
                └────────────────────────────────────┘

                Data plane (shared, unchanged from v0)
                ─────────────────────────────────────
                landscape-snap.service ──atomic mv──► /tmp/standardos/landscape/ws-N.png
                          ▲                                          │
                          │ inotify on open-trigger                  │ inotify on manifest.json
                          │                                          ▼
                          │                            canvas-landscape-listen
                          │                                          │
                          │                                          ▼
                landscape-open touches                       deflisten ws-paths
                /tmp/standardos/landscape/                            │
                open-trigger                                          ▼
                          ▲                                landscape-grid
                canvas-open touches the                       (image :path …)
                same trigger                                          │
                                                              click → canvas-jump-ws N
```

The two surfaces are completely independent at the eww window level. A wedge in one defwidget tree does not affect the other. They share only:
- The eww daemon process (one for the whole shell — restart impacts both).
- The `landscape-snap` data plane (one cache directory, one manifest — both surfaces read from the same place).
- The `canvas-jump-ws` click handler (workspace-agnostic — usable from either surface).
- The `open-trigger` file (both `canvas-open` and `landscape-open` touch it so the focused workspace re-grims on either open).

## Components

### New files

| Path | Responsibility |
|---|---|
| `widgets/scripts/landscape-open` | (1) `mkdir -p /tmp/standardos/landscape && touch /tmp/standardos/landscape/open-trigger` to refresh the focused cell; (2) compute monitor-size via shared `lib/canvas-anchor.sh`; (3) `exec eww open landscape --size "${w}x${h}"`. Mirror of `canvas-open`. |
| `widgets/scripts/landscape-close` | Three-tier dismissal mirroring `canvas-close`. Tier 1: `flock -n`-guarded; `hyprctl dispatch submap reset` first (keyboard always recovers); `eww close landscape`. Tier 2: verify via overlay gtk-layer-shell count decrement; on failure, `systemctl --user restart standardos-canvas.service`. |
| `widgets/scripts/landscape-panic` | Mirror of `canvas-panic`. Skips the graceful verify; uses the same count-decrement check before optionally restarting the service. |
| `tests/wave3/test_landscape_exit_invariant.sh` | Static guard: asserts `:focusable false` on `defwindow landscape`; asserts `submap = landscape-open` block exists with both Esc → `landscape-close` and `$mainMod SHIFT, ESCAPE` → `landscape-panic` binds. Mirror of `test_canvas_exit_invariant.sh`. |

### Modified files

| Path | Change |
|---|---|
| `widgets/eww/eww.yuck` | (a) Remove `landscape` section-pill from `section-nav` (line 172) — section-nav returns to 15 pills. (b) Remove the `(box :visible {current-section == "landscape"} …)` branch from the `canvas` defwidget body. (c) Remove v0 `defwidget ls-cell` and `defwidget landscape-section`. (d) Add `defwidget landscape-grid []` — 3×3 of `(image :path {ws-paths.wsN} :image-width … :image-height …)`, no current-cell highlight, no overlay-empty fallback (daemon's `_blank.svg` already covers cold-start). (e) Add `defwindow landscape :monitor 0 :geometry (geometry :x "0%" :y "0%" :width "100%" :height "100%" :anchor "center") :stacking "overlay" :exclusive false :focusable false (landscape-grid)`. The `:focusable false` is baked in from day one — a 13-line comment block above the defwindow documents why flipping it back will brick the surface (mirroring the canvas comment). |
| `widgets/eww/eww.scss` | Remove `.ls-grid`, `.ls-cell`, `.ls-cell-current`, `.ls-shot`, `.ls-empty` (the v0 rules). Add `window#landscape .lg-grid` (edge-to-edge, 14px gutter via `spacing: 14px`), `window#landscape .lg-cell` (transparent background — the image fills the cell), `window#landscape .lg-shot` (no border-radius — edge-to-edge means cells touch screen edges). Strictly ASCII; grep `[^\x00-\x7f]` before save. |
| `hypr/modules/Binds.conf` | (1) Replace `bind = $mainMod SHIFT, S, movewindow, d` with `bind = $mainMod ALT, S, movewindow, d`. (2) Rebind `Super+RETURN`: `exec /etc/nixos/home/widgets/scripts/landscape-open` + `submap, landscape-open` (was `canvas-open` / `canvas-open`). (3) Add `bind = $mainMod SHIFT, S, exec, /etc/nixos/home/scripts/canvas-open` and `bind = $mainMod SHIFT, S, submap, canvas-open` (new Control Center bind). (4) Add `submap = landscape-open` block: `, ESCAPE, exec, /etc/nixos/home/widgets/scripts/landscape-close` and `$mainMod SHIFT, ESCAPE, exec, /etc/nixos/home/widgets/scripts/landscape-panic`, then `submap = reset`. (5) Update the existing `:focusable false` invariant comment to cover both windows. |
| `hypr/modules/Window_Rules.conf` | Audit existing eww layer rules. Since both surfaces share namespace `gtk-layer-shell` (eww 0.6.0 limitation), existing rules already cover both. No edit needed unless a rule explicitly references a window NAME — in which case add a peer rule for `landscape`. |
| `scripts/canvas-close` | Patch the verify signal: switch from "any gtk-layer-shell surface in overlay → still open" to "overlay gtk-layer-shell surface count did not decrement after close → still open." Necessary because once Landscape exists, the original presence-only check produces false positives. Implementation: snapshot count BEFORE dismiss, snapshot count AFTER (with `sleep 0.15`), verify `after < before`. |
| `scripts/canvas-panic` | Same count-decrement patch as `canvas-close`. |
| `waybar/TODO.md` | Append DONE entry with a Hint line documenting the split, the rebind, the canvas-close verify update, and the rationale. |

### Files reused unchanged

- `scripts/landscape-snap-daemon.sh` — same daemon, same triggers.
- `modules/landscape-snap.nix` — same systemd unit.
- `widgets/scripts/canvas-landscape-listen` — same deflisten source. Its name still references "canvas" but it is workspace-agnostic and serves both surfaces.
- `widgets/scripts/canvas-jump-ws` — workspace-agnostic click handler. The `exec /etc/nixos/home/scripts/canvas-close` line at its end means clicks from Landscape currently invoke `canvas-close`, which closes the dashboard (no-op if dashboard isn't open) but does NOT close the landscape surface. **This is a bug** — must be fixed in the same stream: make `canvas-jump-ws` close whichever surface it was invoked from. See "Click handler routing" below.
- `widgets/svg/_blank.svg` — cold-start placeholder.

### Click handler routing

`canvas-jump-ws` currently hardcodes `exec canvas-close` as its tail. Now there are two surfaces it can be invoked from. Two options considered:

**Option A — heuristic close.** `canvas-jump-ws` calls BOTH `landscape-close` and `canvas-close` (the second is a no-op if dashboard not open, the first is a no-op if landscape not open). Cheapest patch. Slightly wasteful (an extra eww-close-noop per click) but correct.

**Option B — caller passes the surface.** `canvas-jump-ws N landscape` vs. `canvas-jump-ws N dashboard`. Cleaner signature but requires updating every yuck call site.

**Decision: A.** It's two extra timeout-1s noops per click, both of which exit fast because the eww IPC for "close window X not open" returns instantly. Avoids touching call sites in eww.yuck. The script grows by one line.

(If the v0 click handler also covered a future case where Landscape opens from canvas, that would change. Today: the v0 widget is removed from the canvas, so the only callers are Landscape cells.)

## Data flow

### Opening Landscape

1. User presses Super+RETURN.
2. Hyprland dispatches `exec /etc/nixos/home/widgets/scripts/landscape-open` and immediately enters `submap = landscape-open`.
3. `landscape-open` touches `/tmp/standardos/landscape/open-trigger`. The `landscape-snap` daemon's inotify watcher receives it within ms, debounces 300 ms, and re-grims the focused workspace; on success it atomic-writes `ws-N.png` and rewrites `manifest.json`.
4. `landscape-open` `exec`s `eww open landscape --size "${w}x${h}"` using the shared monitor-size helper.
5. The new defwindow renders. `landscape-grid` reads from the existing `deflisten ws-paths` which has already emitted the latest manifest contents. Each `(image :path {ws-paths.wsN})` renders the appropriate PNG (or `_blank.svg` for cells with no snapshot yet).
6. When the daemon finishes its debounced capture and rewrites `manifest.json`, `canvas-landscape-listen`'s inotify watcher fires and re-emits the JSON map. Eww re-evaluates the listener var; the `(image :path)` for the focused cell gets a new `?t=mtime` cache-buster suffix; gtk-image reloads from the new path.

### Closing Landscape (Esc path)

1. Inside `landscape-open` submap, user presses Esc.
2. Hyprland dispatches `exec /etc/nixos/home/widgets/scripts/landscape-close`.
3. `landscape-close` (under `flock -n` lock) runs Tier 3 first: `hyprctl dispatch submap reset` — keyboard recovers immediately, regardless of what eww does.
4. Tier 1: `eww close landscape` with 1-s timeout.
5. Verify: snapshot BEFORE count of overlay gtk-layer-shell surfaces (captured at start, before any close attempt); snapshot AFTER count (after `sleep 0.15`); if AFTER < BEFORE → verified.
6. If not verified → Tier 2: `systemctl --user restart standardos-canvas.service`. Eww daemon respawns within ~1 s; both dashboard AND landscape surfaces (if any) disappear cleanly with the daemon. User left in clean keyboard state (Tier 3 already ran).

### Closing Landscape (click path)

1. User clicks any cell. Eww eventbox fires `/etc/nixos/home/widgets/scripts/canvas-jump-ws N`.
2. `canvas-jump-ws` validates N ∈ [1-9], dispatches `hyprctl workspace N`, then `exec`s a "close both surfaces" tail.
3. Same Esc-path verify + Tier 2 logic applies in each close script.

### Coexistence

Both windows can be open simultaneously. Landscape opens at `:stacking "overlay"`, so does dashboard. Hyprland stacks them in open-order within the overlay layer. The user sees whichever was opened most recently on top. Each submap's Esc dismisses ONLY the surface its open script created — `landscape-close` only `eww close landscape`, `canvas-close` only `eww close dashboard`. The count-decrement verify works correctly because both surfaces leave the overlay layer at the same time only when the eww daemon itself restarts (Tier 2 of either close), in which case count drops to 0 from whatever it was — still a valid decrement.

## Error handling

Per StandardOS rule 4: input is acknowledged, context shifts are silent.

- `grim` failures inside the daemon → silent; daemon logs only; no error pill.
- Daemon crashes → systemd `Restart=always RestartSec=5 StartLimitBurst=20/300s` respawns.
- `eww open landscape` hangs mid-handshake (the 2026-06-25 wedge mode) → Tier 2 fires on next close attempt; user is never trapped.
- `hyprctl layers` times out → treat as "could not verify"; escalate to Tier 2 conservatively.
- `canvas-jump-ws` called with an invalid N → exit 1 silently, no dispatch.
- Both surfaces open, user closes landscape, dashboard's stale `:focusable false` and submap state both still match dashboard's open script. No interaction.

## Testing

### Static guard test

New `tests/wave3/test_landscape_exit_invariant.sh` mirrors `test_canvas_exit_invariant.sh`. It checks:

1. `defwindow landscape` has `:focusable false` (regex match in `widgets/eww/eww.yuck`).
2. `submap = landscape-open` block exists in `hypr/modules/Binds.conf`.
3. Inside that block, both `, ESCAPE, exec, .*landscape-close` and `$mainMod SHIFT, ESCAPE, exec, .*landscape-panic` lines are present.
4. The `landscape-open` script ends with `eww open landscape` (not `eww open dashboard` or any other window).

Failing this test means an invariant got removed and the surface is at risk of becoming non-dismissable. Pairs with the existing canvas test in the same `tests/wave3/` directory.

### Manual acceptance

After `nixos-rebuild switch`, reload eww, reload Hyprland binds:

1. Super+Alt+S → focused window moves down. (movewindow d migrated.)
2. Super+Shift+S → Control Center opens (15-pill section-nav, NO Landscape pill).
3. Esc in Control Center → CC closes, layer count drops.
4. Super+RETURN → Landscape opens — 3×3 grid edge-to-edge, no other UI on screen.
5. Esc in Landscape → Landscape closes, layer count drops.
6. Open Landscape, then open Control Center (Super+Shift+S) → both visible (CC on top). Esc → CC closes, Landscape remains. Esc again → Landscape closes.
7. Click cell 3 in Landscape → workspace 3, both surfaces gone.
8. From workspace 3, Super+RETURN → Landscape opens with the ws-3 cell now reflecting ws-3's content (since `open-trigger` re-grimmed it).
9. `hyprctl layers` after each close confirms the corresponding surface is gone.
10. Hard test: open both surfaces, then `pkill -STOP eww` to simulate a wedge, then Esc twice. Tier 2 should restart standardos-canvas.service within ~2 s; both surfaces gone; user in clean state.

### Hazard audit (mirroring v0)

- [ ] Cache writes atomic (`tmp + mv -f`)? Inspect `landscape-snap-daemon.sh` — unchanged, still passes.
- [ ] Inotify watches the DIRECTORY with `--format '%f'`? Same as v0.
- [ ] `eww.scss` strictly ASCII? `grep -P '[^\x00-\x7f]' /etc/nixos/home/widgets/eww/eww.scss; echo $?` → must be `1`.
- [ ] No new error pill on OPTIONS? Confirm: no pill emission paths added in this stream.
- [ ] `nixos-rebuild switch` (not `test`)? Required after Binds.conf change (hypr config not live).
- [ ] `:focusable false` on the NEW defwindow landscape from day one? Static test asserts.
- [ ] Count-decrement verify pattern correctly handles both single-surface and multi-surface case? Manual acceptance step 6 covers this.

## Open implementation-time decisions

1. **`landscape-grid` cell sizing.** Edge-to-edge with `spacing: 14px` between cells. Inside each cell, image is `:image-width <screen-w/3 - 10>` ish and `:image-height <screen-h/3 - 10>`. Tune visually after first render. Width/height passed as defvar-fed values, computed from monitor size at first render — or eww does auto-fill via `:halign "fill" :valign "fill"` on the parent box. Try the auto-fill path first; fall back to hardcoded sizes only if gtk-image doesn't scale.

2. **Whether to make `landscape-open` also reset stale dashboard state.** No — Landscape and dashboard are siblings; opening Landscape says nothing about dashboard. If user wants Landscape-while-CC-also-open, that should work. Coexistence is feature, not bug.

3. **Rename `canvas-landscape-listen` and `canvas-jump-ws` to drop the `canvas-` prefix.** Deferred — pure rename touching multiple call sites, separate stream.

## Spec self-review

- **Placeholders.** None remain. Cell sizing (open-decision 1) is explicitly flagged as "tune visually after first render" — not a placeholder, a deliberate just-in-time choice.
- **Contradictions.** None. Components section, Architecture diagram, and Data flow all reference the same files and the same data plane.
- **Scope.** One stream — split-out, rebind, verify-update. Does not bleed into canvas-prefs polish (still deferred per memory), does not touch Variant B annotations, does not rename data-plane files.
- **Ambiguity.** Click-handler routing decision is explicit (Option A — heuristic close). Verify signal switch is explicit (count decrement). Both surfaces share the eww daemon by design, called out explicitly.
