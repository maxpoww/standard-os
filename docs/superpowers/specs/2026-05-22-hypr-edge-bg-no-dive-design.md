# hypr-edge-bg: drop the dive paradigm — design

**Date:** 2026-05-22
**Status:** Draft (pending implementation in a later session)
**Author:** brainstorm with max
**Target module:** `/etc/nixos/home/modules/hypr-edge-bg.nix` and its scripts

---

## 1. Motivation

The current background daemon implements a two-state "dive" UX (dive on / dive off) with four paint modes (default / match / mismatch / mixed) driven by an eight-row matrix. In practice we only want **one** observable behavior, all the time:

> The waypaper image is the background **everywhere it is visible**, except in the single case where one tiled window covers the screen edge-to-edge with no visible gaps — then the background is a solid color sampled from that window's top edge so the bar and the window look like one piece.

That removes:
- the `hypr-dive` toggle CLI and its state file,
- the `mismatch` (luma-shifted) and `mixed` (area-weighted RGB mean) paint modes,
- the `default` solid color (`#323246`) used as the dive-on idle background,
- the `SIGUSR1` re-evaluation path tied to dive toggling,
- the `dark_theme` field in the snapshot (only consumed by `mismatch`).

What remains:
- the publisher (`hypr-activities`) — unchanged shape, one field dropped (`dark_theme`),
- the consumer (`hypr-edge-bg`) — single-rule decide(), trimmed env surface,
- the shared color math — only `hex_to_rgb`, `rgb_to_hex`, `luma`, `rgb_dist_sq`, `clamp`.

---

## 2. Behavior specification

### 2.1 The single rule

Let `S` be the most recent publisher snapshot. The consumer paints **match** (top-edge color of the focused window) if and only if **all** of the following are true:

1. `S.flag == 1` — workspace has at least one window
2. `S.window_count == 1` — exactly one window
3. `S.floating == false`
4. `S.pseudo == false`
5. `S.fullscreen < 2` — true fullscreen is excluded (see §2.3)
6. `S.gaps == "off"` — both `gaps_in` and `gaps_out` are zero AND no floating/pseudo presence (publisher already encodes this)

Conditions 3 and 4 are technically redundant with 6 — the publisher (`home/scripts/hypr-activities:159-161`) already promotes `gaps` to `"on"` whenever any focused-workspace client is floating or pseudo. We still check them explicitly in `decide()` as defense-in-depth and to make the rule self-documenting; both interpretations land on the same paint outcome.

Otherwise the consumer paints the **waypaper image** (`S.waypaper_bg`).

If `S.waypaper_bg` is empty or its file is missing AND match doesn't fire, the consumer leaves whatever was last applied. (Edge case — no waypaper configured. We do not paint a hardcoded fallback color anymore.)

### 2.2 Trigger interpretation

The user's choice was "True edge-to-edge (gaps=0 AND single tiled)". On the current machine `gaps_in = 3 3 3 3` and `gaps_out = 2 6 6 6`, so under the new rule **the match branch never fires until the user sets gaps to 0**. That is intentional: the visual semantics is "one window owns every pixel of the monitor", and a 3-pixel border breaks that.

The publisher already computes `S.gaps` correctly (CssBoxStyle parser at `home/scripts/hypr-activities:124-133`). We will trust it and stop re-deriving in the consumer.

### 2.3 Fullscreen

`fullscreen >= 2` (true fullscreen) → **waypaper**. The window covers everything anyway, so the bg is invisible; keeping the waypaper preloaded means there is no flicker when the user un-fullscreens onto a multi-window workspace (already the steady state). `fullscreen == 1` (maximized) falls through to the single rule — maximized still respects gaps, so it usually won't qualify.

### 2.4 Color cadence

When match fires, the daemon continues to **follow the window's content live** at `POLL_INTERVAL` (~10 Hz default) using the existing `read -t POLL_INTERVAL -u "$SOCK_FD"` interleave. The `DIST_THRESHOLD` squared-RGB check and exact-hex fast-exit already short-circuit hyprpaper traffic when the sampled color is stable, so steady-state cost is one `grim`+`magick` tick per `POLL_INTERVAL`.

When match does not fire, the consumer goes idle on the socket (`POLL_ACTIVE=0`) — zero CPU until the next Hyprland event.

### 2.5 What the user sees

| Scenario | Bg |
|---|---|
| Empty workspace | waypaper |
| Floating-only / pseudo-only | waypaper |
| ≥2 tiled windows | waypaper |
| 1 tiled window, gaps_in>0 OR gaps_out>0 | waypaper |
| 1 tiled window, gaps_in=0 AND gaps_out=0 | **match (live)** |
| True fullscreen (fs≥2) | waypaper |

No state to toggle. No CLI. No persistence beyond the cache.

---

## 3. Component-level changes

### 3.1 `home/scripts/hypr-edge-bg` (consumer)

Replace `decide()` and adjacent state with the single-rule version. Concretely:

```bash
decide() {
    local snap=$1
    POLL_ACTIVE=0

    local raw header monitors clients_tbl
    local flag fs gaps addr waypaper_bg wc floating_b pseudo_b
    raw=$(jq -r '
        "\(.flag)\t\(.fullscreen)\t\(.gaps)\t\(.address // "")\t\(.waypaper_bg // "")\t\(.window_count // 0)\t\(.floating // false)\t\(.pseudo // false)",
        (.monitors | tojson),
        ((.clients // []) | map([.address, (.at[0]|tostring), (.at[1]|tostring), (.size[0]|tostring), (.size[1]|tostring)] | join("|"))[])
    ' <<<"$snap" 2>/dev/null) || return 0
    {
        IFS= read -r header
        IFS= read -r monitors
        clients_tbl=$(cat)
    } <<<"$raw"
    IFS=$'\t' read -r flag fs gaps addr waypaper_bg wc floating_b pseudo_b <<<"$header"

    # Single sample rule: exactly one tiled non-fullscreen window with no gaps.
    if [[ $flag == "1" && ${fs:-0} -lt 2 && $gaps == "off" \
          && $floating_b == "false" && $pseudo_b == "false" && ${wc:-0} -eq 1 ]]; then
        local hex
        hex=$(sample_active_from_table "$addr" "$clients_tbl")
        if [[ -n $hex ]]; then
            apply_color "$hex" "$monitors"
            POLL_ACTIVE=1
            return
        fi
    fi

    # Default: waypaper everywhere it's visible.
    apply_waypaper_image "$waypaper_bg" "$monitors"
}
```

Delete:
- `read_dive` / `write_dive_off` / `DIVE` global / `STATE_FILE` / `STATE_DIR`
- `mismatch` branch + reference to `dark`/`SHIFT_PCT`/`CLAMP_LO`/`CLAMP_HI`
- mixed branch + `WIN_COLOR` per-window cache (only useful for mixed-mode)
- `trap reeval USR1` and `reeval()` (no toggle to listen for)
- env vars: `HYPR_EDGE_BG_DEFAULT`, `HYPR_EDGE_BG_SHIFT_PCT`, `HYPR_EDGE_BG_CLAMP_LO`, `HYPR_EDGE_BG_CLAMP_HI`
- `LIB_DIR` sourcing of `colors.sh` is **kept** — still needed for `hex_to_rgb` / `rgb_dist_sq` used inside `apply_color`'s distance check.

Add: a `-depth 8` flag to the `magick - -resize 1x1! txt:-` pipeline in `sample_top_edge` for ImageMagick Q16 portability across the distro. (Not biting on this machine but cheap insurance for the distro target — flagged in CLAUDE.md as mandatory.)

### 3.2 `home/scripts/hypr-activities` (publisher)

Minimal changes. Remove the dark-theme producer + state:

- delete the `gsettings monitor … color-scheme` pipeline producing `theme|…` lines
- delete `read_dark_from_gsettings` and the `DARK` global
- delete `--argjson dark` and the `dark_theme` field from the `jq -nc` snapshot
- delete the `theme)` case in the event-loop switch

Everything else (FIFO discipline, debounce, `gaps` CssBoxStyle parsing, `waypaper_changed` flag, AF_UNIX broadcast) is **kept as-is** — the publisher's shape was already correct; only the consumer was misreading it.

The `waypaper_changed` field becomes a no-op for the consumer (nothing to dive-off) but the publisher still emits it; an inotify-driven snapshot refresh still propagates so the new waypaper path takes effect immediately. We can either keep emitting it (zero cost, future-proof) or strip it for cleanliness. **Decision: keep it emitted but stop reading it in the consumer.** Removing the inotify pipeline would break the "swap waypaper image and it just updates" behavior.

### 3.3 `home/scripts/hypr-dive` (toggle CLI)

**Delete the file.**

### 3.4 `home/scripts/lib/colors.sh`

Keep:
- `hex_to_rgb`, `rgb_to_hex`, `clamp`, `luma`, `rgb_dist_sq`

Delete:
- `mismatch_hex`
- `mix_init`, `mix_add`, `mix_finalize`
- `MIX_R` / `MIX_G` / `MIX_B` / `MIX_A` globals
- `luma` and `clamp` (only callers were `mismatch_hex`; once it's gone these are unused and shellcheck will flag them)

After the trim, `colors.sh` contains exactly: `hex_to_rgb`, `rgb_to_hex`, `rgb_dist_sq`. Update `tests/colors-test.sh` assertions to match.

### 3.5 `home/modules/hypr-edge-bg.nix`

Options to **delete**:
- `defaultColor`
- `mismatchShiftPct`
- `mismatchClampMin`
- `mismatchClampMax`

Options to **keep**:
- `sampleHeight`
- `sampleWidthMax`
- `distanceThreshold`
- `pollIntervalSec`
- `cacheSize`
- `waypaperConfigPath` (still consumed by `hypr-activities` for inotify)

`home.packages`:
- remove `hyprDiveBin` from the list
- remove the `mkScript "hypr-dive"` invocation

`systemd.user.services.hypr-edge-bg.Service.Environment`:
- remove `HYPR_EDGE_BG_DEFAULT`, `HYPR_EDGE_BG_SHIFT_PCT`, `HYPR_EDGE_BG_CLAMP_LO`, `HYPR_EDGE_BG_CLAMP_HI`
- keep `HYPR_EDGE_BG_SAMPLE_H`, `HYPR_EDGE_BG_SAMPLE_W_MAX`, `HYPR_EDGE_BG_DIST_THRESHOLD`, `HYPR_EDGE_BG_POLL_INTERVAL`, `HYPR_EDGE_BG_CACHE_SIZE`

`runtimeDeps`:
- `glib` (gsettings) can be removed from the consumer's path; the publisher no longer reads gsettings either. **Remove `glib` from `runtimeDeps`.**

The two `systemd.user.services` (publisher + consumer) keep their `Restart=always`, `PartOf=graphical-session.target`, `After=` chain. `Requires=` on the consumer for the publisher is kept.

### 3.6 `home/tests/hypr-edge-bg-test.nix`

Replace the four "dive on / dive off" scenarios with five mode-free scenarios:

1. Empty workspace + waypaper present → expect `hyprpaper wallpaper <waypaper>`.
2. One tiled window, `gaps=off`, sample hex `aabbcc` → expect `hyprpaper preload .../bg_aabbcc.png` then `wallpaper`.
3. One tiled window, `gaps=on` → expect `hyprpaper wallpaper <waypaper>` (no sample call).
4. Two tiled windows, `gaps=off` → expect `hyprpaper wallpaper <waypaper>`.
5. One floating window, `gaps=off` → expect `hyprpaper wallpaper <waypaper>`.

Drop dark-theme stub and dive-state-file setup from the fixtures.

### 3.7 `home/tests/colors-test.sh`

Remove any assertions that exercise `mismatch_hex` or `mix_*`. Keep `hex_to_rgb` / `rgb_to_hex` / `rgb_dist_sq` / `luma` assertions.

### 3.8 `home/.claude/CLAUDE.md`

Rewrite the document to match the new simpler reality:
- "Three processes" → "Two processes" (drop hypr-dive)
- "Dive UX Paradigm" section → replaced with a one-paragraph "Background rule" section stating §2.1
- Dive matrix table → replaced with the §2.5 table
- Drop "State Persistence & Toggles" subsection (no more dive state)
- Drop the `mismatch` / `mixed` color recipes in "Color Math Recipes"
- Drop the `--kill-who=main` hazard line (no SIGUSR1 toggle anymore — but the comment in the file about why USR1 was a hazard can be kept as historical, OR removed entirely; **decision: remove**, since the surface no longer exists)
- Drop `defaultColor` / `mismatchShiftPct` / clamp rows from the Module Options table
- Reconcile drift while we're here: `cacheSize` filename pattern is `bg_<hex>.png` (not `c-<hex>-<WxH>.png`); `distanceThreshold` default is `25`; `sampleHeight` default `2`; `sampleWidthMax` is a pixel cap (`300`) not a ratio. Update the doc to match the code.

---

## 4. Data flow (after change)

```
                       gaps_in/out         active/clients/monitors
                          │                       │
                          ▼                       ▼
              ┌──────────────────────────────────────┐
              │           hypr-activities            │
              │  - subscribes to Hyprland socket2    │
              │  - inotify on waypaper config.ini    │
              │  - 16 ms inline debounce             │
              │  - emits JSON snapshot + AF_UNIX     │
              └──────────────────────────────────────┘
                                │
                snapshot every  │  AF_UNIX socket
                event-debounced │  (multi-consumer)
                                ▼
              ┌──────────────────────────────────────┐
              │             hypr-edge-bg             │
              │  decide(): single-rule paint         │
              │  POLL_ACTIVE=1 only when match fires │
              │  apply_color / apply_waypaper_image  │
              └──────────────────────────────────────┘
                                │
                                ▼  hyprctl hyprpaper preload/wallpaper/unload
                          ┌──────────┐
                          │ hyprpaper│
                          └──────────┘
```

No third process. No state file. The only persistence is the LRU PNG cache at `/tmp/hypr-edge-bg/`.

---

## 5. Migration

After the rebuild lands:

```
sudo nixos-rebuild switch
systemctl --user daemon-reload
systemctl --user restart hypr-activities hypr-edge-bg
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/hypr-edge-bg"   # delete orphaned dive state
```

Verification:
- With `gaps_in=3 3 3 3` (current) + one window → desktop shows the ChatGPT waypaper. ✓
- `hyprctl keyword general:gaps_in 0` then `hyprctl keyword general:gaps_out 0`, focus a single window → solid color matching its top edge appears, follows on scroll. ✓
- Restart `hypr-activities` while consumer is running → consumer reconnects (publisher's socket has `unlink-early,reuseaddr,fork`, consumer is `Restart=always`). ✓
- Open a second window → snap back to waypaper. ✓
- True-fullscreen the window → invisible bg change to waypaper; un-fullscreen → match resumes if no gaps. ✓

---

## 6. Testing

- **Unit**: `bash home/tests/colors-test.sh` — must pass after the trim (4 helpers).
- **Lint**: `shellcheck -s bash -a home/scripts/hypr-edge-bg home/scripts/hypr-activities home/scripts/lib/colors.sh` — silent.
- **Format**: `shfmt -w -s -i 4 …` over the three remaining scripts.
- **Module parse**: `nix-instantiate --parse home/modules/hypr-edge-bg.nix`.
- **Integration (manual)**: the five scenarios in §5 verification.
- **NixOS test**: `nix-build home/tests/hypr-edge-bg-test.nix` — five updated scenarios pass.

---

## 7. Non-goals (out of scope for this change)

- Painting surfaces other than the wallpaper (waybar background, GTK accent, window borders).
- Per-workspace background memory.
- Animated transitions between waypaper ↔ solid color (still an instant `hyprpaper wallpaper` swap; flicker-free is already guaranteed by the preload-then-wallpaper-then-unload order).
- Sampling regions other than the top edge (e.g. dominant color of the whole window).

If any of these come up later, they are separate spec docs.

---

## 8. Risks & open questions

- **No fallback color**: if the user has no waypaper configured AND match doesn't fire, the consumer does nothing on that tick. In practice hyprpaper retains whatever was last loaded; on first boot with no waypaper there is simply no background. Acceptable for a distro that ships a default wallpaper, but the distro work needs to guarantee one. **Action item for distro packaging**, not this change.
- **`fullscreen=1` (maximized) edge case**: a maximized window with `gaps_in=0` and one window on the workspace will match. That is consistent with the rule ("one window owns every pixel") and is what we want. Documented above for clarity.
- **Log noise**: the current `decide()` logs every tick (~10/s when active). After the change we should gate the `log` call on state transition (last-applied identity differs from previous) — already a natural fit since `apply_image` short-circuits on identity match. **Implementation detail; will gate during the change.**

---

## 9. File-by-file summary

| File | Change |
|---|---|
| `home/modules/hypr-edge-bg.nix` | Drop 4 options, drop hyprDive bin + env vars, drop glib dep |
| `home/scripts/hypr-edge-bg` | Replace `decide()`, delete dive state, USR1, mismatch/mixed, add `-depth 8` |
| `home/scripts/hypr-activities` | Drop gsettings producer + DARK + dark_theme field |
| `home/scripts/hypr-dive` | **Delete** |
| `home/scripts/lib/colors.sh` | Delete `mismatch_hex`, `mix_*`, MIX_* globals |
| `home/tests/hypr-edge-bg-test.nix` | Replace 4 scenarios with 5 mode-free scenarios |
| `home/tests/colors-test.sh` | Drop mismatch/mix assertions |
| `home/.claude/CLAUDE.md` | Rewrite to match new behavior |
