# Waybar ↔ rofi integration — bellwether (notif-menu) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rofi indistinguishable from waybar inside OPTIONS by (a) anchoring every rofi popup under its trigger pill via a per-pill geometry registry, and (b) giving notif-menu the OPTIONS wide-pill visual treatment. Ship as the bellwether commit; the five remaining rofi surfaces propagate in later streams.

**Architecture:** Three shared artefacts — (1) `pill-geom` per-pill JSON entries written by `pill.sh::pill_write` on every emit; (2) `rofi-anchor.sh` library exporting `rofi_anchor_for`, `rofi_theme_for_mode`, `rofi_launch`; (3) `options-{base,light,dark}.rasi` mirroring the waybar `@opt-*` palette. notif-menu is the bellwether consumer; its inline `-theme-str` block is deleted and replaced with library calls.

**Tech Stack:** bash (pill.sh, rofi-anchor.sh, notif-menu, tests), Nix home-manager (modules/rofi.nix), rofi rasi (options-*.rasi), jq for read-only JSON queries (no jq in pill.sh hot path — per-pill files avoid that).

**Spec:** `docs/superpowers/specs/2026-06-16-waybar-rofi-integration-design.md`.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `/etc/nixos/home/waybar/scripts/lib/pill.sh` | Modify | Constants (PILL_PAD_X, FONT_ADVANCE_PX). New `pill_estimate_width`. New `pill_emit_geom`. `pill_write` calls `pill_emit_geom` after the cache write. |
| `/etc/nixos/home/scripts/lib/rofi-anchor.sh` | Create | `rofi_anchor_for`, `rofi_theme_for_mode`, `rofi_launch`. Reads `pill-geom/`, `hypr-context.json`, `/tmp/glass-mode`. |
| `/etc/nixos/home/rofi/options-base.rasi` | Create | Shape + sizing + row templates + bright-hover. Imports color tokens from light/dark file. |
| `/etc/nixos/home/rofi/options-light.rasi` | Create | `@import "options-base.rasi"` + light palette. |
| `/etc/nixos/home/rofi/options-dark.rasi` | Create | `@import "options-base.rasi"` + dark palette. |
| `/etc/nixos/home/modules/rofi.nix` | Create | home-manager module: declares the .rasi files in `/etc/nixos/home/rofi/` as out-of-store symlinks under `~/.config/rofi/`. |
| `/etc/nixos/home/hyprland-home.nix` (or wherever modules import) | Modify | Add `./modules/rofi.nix` to imports. |
| `/etc/nixos/home/scripts/lib/notif-rofi-format.sh` | Modify | Add action-row marker: `format_rofi_action LABEL` emits a row with a single leading `\x02` byte (rofi-safe sentinel). |
| `/etc/nixos/home/scripts/notif-menu` | Modify | `run_rofi` replaced with sourced-library version. Inline `-theme-str` deleted. |
| `/etc/nixos/home/tests/pill-geom-test.sh` | Create | Tests for `pill_estimate_width` + `pill_emit_geom`. |
| `/etc/nixos/home/tests/rofi-anchor-test.sh` | Create | Tests for `rofi_anchor_for` + `rofi_theme_for_mode`. |
| `/etc/nixos/home/tests/notif-rofi-test.sh` | Modify | Add tests for `format_rofi_action`. |
| `/etc/nixos/home/waybar/TODO.md` | Modify | Add entry under DONE with Hint lines for spec + plan. |

Per-pill geometry files live at `/tmp/waybar-cache/pill-geom/<name>.json` — one file per pill, atomic tmp+mv, no jq merge required.

---

## Task 1: Pill width estimator + constants in pill.sh

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/lib/pill.sh`
- Create: `/etc/nixos/home/tests/pill-geom-test.sh`

- [ ] **Step 1: Write the failing test for `pill_estimate_width`**

Create `/etc/nixos/home/tests/pill-geom-test.sh`:
```bash
#!/usr/bin/env bash
# pill-geom-test.sh — unit tests for pill.sh geometry helpers
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Set cache dir to a temp location so we don't clobber the live cache.
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export PILL_CACHE_DIR="$TEST_TMP/waybar-cache"
export PILL_GLASS_FILE="$TEST_TMP/glass-mode"
export PILL_GEOM_HYPR_CTX="$TEST_TMP/hypr-context.json"
mkdir -p "$PILL_CACHE_DIR"
echo "dark" > "$PILL_GLASS_FILE"
cat > "$PILL_GEOM_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":1600,"h":1000,"scale":2.0,"focused_ws":1}]}
EOF

# shellcheck source=../waybar/scripts/lib/pill.sh
source "$HERE/../waybar/scripts/lib/pill.sh"

pass=0; fail=0
check() {
    local label="$1"; shift
    if "$@"; then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else          fail=$((fail+1)); printf '✗ %s\n' "$label"
    fi
}

# pill_estimate_width: padding + (chars * font advance)
# Defaults: PILL_PAD_X=8, FONT_ADVANCE_PX=8
w=$(pill_estimate_width "")
check "[empty text width = PILL_PAD_X]" test "$w" -eq 8

w=$(pill_estimate_width "abc")
check "[3 chars width = 8 + 3*8 = 32]" test "$w" -eq 32

w=$(pill_estimate_width "hello world")
check "[11 chars width = 8 + 11*8 = 96]" test "$w" -eq 96

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit $(( fail > 0 ))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /etc/nixos/home/tests/pill-geom-test.sh`
Expected: FAIL with `pill_estimate_width: command not found` (or all checks failing).

- [ ] **Step 3: Add constants and `pill_estimate_width` to pill.sh**

In `/etc/nixos/home/waybar/scripts/lib/pill.sh`, add after the `PILL_GLASS_FILE` line:

```bash
# Per-pill geometry registry — used by rofi-anchor.sh to anchor popups
# under their trigger pill. Each pill_write emits a small JSON record
# to PILL_GEOM_DIR/<name>.json (one file per pill — avoids jq merging
# in the hot loop). Width is estimated from text length; X is computed
# later by the rofi anchor library walking sibling widths.
PILL_GEOM_DIR="${PILL_GEOM_DIR:-/tmp/waybar-cache/pill-geom}"
PILL_GEOM_HYPR_CTX="${PILL_GEOM_HYPR_CTX:-/tmp/waybar-cache/hypr-context.json}"
PILL_PAD_X="${PILL_PAD_X:-8}"            # left+right padding combined (logical px)
PILL_FONT_ADVANCE_PX="${PILL_FONT_ADVANCE_PX:-8}"  # avg glyph width at 13pt bar font
```

Then add this function after `pill_json_escape`:

```bash
# Estimate visual width of a pill in logical screen pixels.
# Returns PILL_PAD_X + (char_count * PILL_FONT_ADVANCE_PX).
# Used by the geometry registry to predict where each pill sits, so
# rofi popups can be anchored under their trigger. Error budget ~±10px.
pill_estimate_width() {
    local text="${1:-}"
    local n=${#text}
    printf '%d' $(( PILL_PAD_X + n * PILL_FONT_ADVANCE_PX ))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /etc/nixos/home/tests/pill-geom-test.sh`
Expected: 3 pass, 0 fail.

---

## Task 2: `pill_emit_geom` writer (atomic, dedup'd)

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/lib/pill.sh`
- Modify: `/etc/nixos/home/tests/pill-geom-test.sh`

- [ ] **Step 1: Add failing tests for `pill_emit_geom`**

Append to `/etc/nixos/home/tests/pill-geom-test.sh` BEFORE the `printf '\n--- %d pass...` line:

```bash
# pill_emit_geom <name> <width> [monitor] — writes pill-geom/<name>.json
pill_emit_geom "notif-bell" 28
check "[geom file created]" test -r "$PILL_GEOM_DIR/notif-bell.json"
check "[width recorded]" test -n "$(grep -F '"w":28' "$PILL_GEOM_DIR/notif-bell.json")"
check "[monitor defaulted from hypr-context]" test -n "$(grep -F '"monitor":"eDP-1"' "$PILL_GEOM_DIR/notif-bell.json")"

# Explicit monitor override
pill_emit_geom "notif-bell" 30 "DP-1"
check "[explicit monitor overrides]" test -n "$(grep -F '"monitor":"DP-1"' "$PILL_GEOM_DIR/notif-bell.json")"

# .empty pill emits w:0 even when text length suggests otherwise
pill_emit_geom "notif-action-1" 0
check "[empty pill w=0]" test -n "$(grep -F '"w":0' "$PILL_GEOM_DIR/notif-action-1.json")"

# Atomic write — tmp file does not linger after a successful write
check "[no .tmp leftover]" ! test -e "$PILL_GEOM_DIR/notif-bell.json.tmp"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /etc/nixos/home/tests/pill-geom-test.sh`
Expected: 4 new checks fail with `pill_emit_geom: command not found`.

- [ ] **Step 3: Implement `pill_emit_geom` in pill.sh**

Add after `pill_estimate_width`:

```bash
# Resolve the focused monitor's name from hypr-context.json. Returns
# empty if hypr-context is missing or unparseable — callers fall back
# to "".
pill_geom_focused_monitor() {
    local ctx
    [ -r "$PILL_GEOM_HYPR_CTX" ] || { printf ''; return; }
    ctx=$(cat "$PILL_GEOM_HYPR_CTX" 2>/dev/null) || { printf ''; return; }
    # Extract "monitor_focused":"<name>" without a jq fork.
    # Pattern: matches the literal key + value, captures the name.
    if [[ $ctx =~ \"monitor_focused\":\"([^\"]+)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Emit a per-pill geometry record. One file per pill — avoids jq merging
# in the pill_write hot path. Atomic via tmp+mv. Caller passes the
# already-estimated width (0 for .empty pills); monitor is the focused
# monitor's name, defaulting to whatever hypr-context publishes.
pill_emit_geom() {
    local name="$1"
    local w="$2"
    local monitor="${3:-}"
    [ -z "$monitor" ] && monitor=$(pill_geom_focused_monitor)
    mkdir -p "$PILL_GEOM_DIR"
    local f="$PILL_GEOM_DIR/$name.json"
    local content; content=$(printf '{"w":%d,"monitor":"%s"}' "$w" "$monitor")
    local prev=""; [ -r "$f" ] && prev=$(cat "$f" 2>/dev/null)
    [ "$content" = "$prev" ] && return 0
    printf '%s' "$content" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash /etc/nixos/home/tests/pill-geom-test.sh`
Expected: 7 pass, 0 fail.

---

## Task 3: Hook `pill_emit_geom` into `pill_write`

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/lib/pill.sh`
- Modify: `/etc/nixos/home/tests/pill-geom-test.sh`

- [ ] **Step 1: Add failing integration test**

Append to `/etc/nixos/home/tests/pill-geom-test.sh` BEFORE the `printf '\n--- %d pass...` line:

```bash
# pill_write must also emit geometry. Width estimated from the text.
rm -f "$PILL_GEOM_DIR"/*.json 2>/dev/null
pill_write "notif-bell" "" "opt-pill dark opt-yes"
check "[pill_write emits geom even with empty text]" test -r "$PILL_GEOM_DIR/notif-bell.json"
check "[empty-text width = PILL_PAD_X]" test -n "$(grep -F '"w":8' "$PILL_GEOM_DIR/notif-bell.json")"

pill_write "ws-current" "5" "opt-pill dark"
check "[1-char text width = 16]" test -n "$(grep -F '"w":16' "$PILL_GEOM_DIR/ws-current.json")"

# .empty class → width 0 in the geom file
pill_write "notif-action-1" "Mute" "opt-pill empty"
check "[.empty pill w=0 in geom]" test -n "$(grep -F '"w":0' "$PILL_GEOM_DIR/notif-action-1.json")"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /etc/nixos/home/tests/pill-geom-test.sh`
Expected: 4 new checks fail (either no file written, or wrong width).

- [ ] **Step 3: Modify `pill_write` to call `pill_emit_geom`**

In `/etc/nixos/home/waybar/scripts/lib/pill.sh`, replace `pill_write`'s body. The new function:

```bash
pill_write() {
    local name="$1"; shift
    mkdir -p "$PILL_CACHE_DIR"
    local cache="$PILL_CACHE_DIR/$name"
    local text="${1:-}"
    local classes_str="${2:-}"
    local content prev=""
    content="$(pill_emit "$@")"
    [ -r "$cache" ] && prev="$(cat "$cache" 2>/dev/null)"

    # Geometry registry: width=0 when the pill is .empty (collapsed,
    # no visual footprint), otherwise estimated from text length.
    # Emitted EVERY call (not gated by content dedup) so that a width
    # change in another sibling can trigger this pill's geom refresh
    # via the natural waybar tick cadence. pill_emit_geom is internally
    # dedup'd so unchanged widths don't churn disk.
    local geom_w=0
    case " $classes_str " in
        *" empty "*) geom_w=0 ;;
        *)           geom_w=$(pill_estimate_width "$text") ;;
    esac
    pill_emit_geom "$name" "$geom_w"

    [ "$content" = "$prev" ] && return 0
    printf '%s' "$content" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
    pkill -RTMIN+10 waybar 2>/dev/null || true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash /etc/nixos/home/tests/pill-geom-test.sh`
Expected: 10 pass, 0 fail.

- [ ] **Step 5: Smoke test — restart waybar and verify live registry**

Run:
```bash
systemctl --user restart waybar
sleep 2
ls /tmp/waybar-cache/pill-geom/ | head -20
cat /tmp/waybar-cache/pill-geom/notif-bell.json
```
Expected: directory exists with files for every active pill. notif-bell.json has w + monitor.

---

## Task 4: `rofi-anchor.sh` library — `rofi_theme_for_mode`

**Files:**
- Create: `/etc/nixos/home/scripts/lib/rofi-anchor.sh`
- Create: `/etc/nixos/home/tests/rofi-anchor-test.sh`

- [ ] **Step 1: Write the failing test**

Create `/etc/nixos/home/tests/rofi-anchor-test.sh`:
```bash
#!/usr/bin/env bash
# rofi-anchor-test.sh — unit tests for lib/rofi-anchor.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_TMP=$(mktemp -d); trap 'rm -rf "$TEST_TMP"' EXIT

export ROFI_THEME_DIR="$TEST_TMP/rofi-themes"
export ROFI_GLASS_FILE="$TEST_TMP/glass-mode"
export ROFI_GEOM_DIR="$TEST_TMP/pill-geom"
export ROFI_HYPR_CTX="$TEST_TMP/hypr-context.json"
mkdir -p "$ROFI_THEME_DIR" "$ROFI_GEOM_DIR"
: > "$ROFI_THEME_DIR/options-light.rasi"
: > "$ROFI_THEME_DIR/options-dark.rasi"

# shellcheck source=../scripts/lib/rofi-anchor.sh
source "$HERE/../scripts/lib/rofi-anchor.sh"

pass=0; fail=0
check() {
    local label="$1"; shift
    if "$@"; then pass=$((pass+1)); printf '✓ %s\n' "$label"
    else          fail=$((fail+1)); printf '✗ %s\n' "$label"
    fi
}

# rofi_theme_for_mode — reads /tmp/glass-mode, prints absolute theme path.
echo "light" > "$ROFI_GLASS_FILE"
out=$(rofi_theme_for_mode)
check "[light glass → light theme]" test "$out" = "$ROFI_THEME_DIR/options-light.rasi"

echo "dark" > "$ROFI_GLASS_FILE"
out=$(rofi_theme_for_mode)
check "[dark glass → dark theme]" test "$out" = "$ROFI_THEME_DIR/options-dark.rasi"

# Missing glass-mode file defaults to dark
rm -f "$ROFI_GLASS_FILE"
out=$(rofi_theme_for_mode)
check "[missing glass → dark theme]" test "$out" = "$ROFI_THEME_DIR/options-dark.rasi"

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit $(( fail > 0 ))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /etc/nixos/home/tests/rofi-anchor-test.sh`
Expected: FAIL with `rofi-anchor.sh: No such file or directory`.

- [ ] **Step 3: Create rofi-anchor.sh with `rofi_theme_for_mode`**

Create `/etc/nixos/home/scripts/lib/rofi-anchor.sh`:
```bash
#!/usr/bin/env bash
# rofi-anchor.sh — anchor rofi popups under their trigger pill and pick
# the right light/dark theme. Sourced by launcher scripts (notif-menu,
# apps launcher wrapper, reboot prompt, etc.). The launcher invokes
# rofi with the result as extra args:
#
#   source /etc/nixos/home/scripts/lib/rofi-anchor.sh
#   ANCHOR=$(rofi_anchor_for notif-bell)
#   THEME=$(rofi_theme_for_mode)
#   rofi -theme "$THEME" $ANCHOR -dmenu ... < rows
#
# All paths are configurable via env so the test harness can sandbox.

ROFI_THEME_DIR="${ROFI_THEME_DIR:-/etc/nixos/home/rofi}"
ROFI_GLASS_FILE="${ROFI_GLASS_FILE:-/tmp/glass-mode}"
ROFI_GEOM_DIR="${ROFI_GEOM_DIR:-/tmp/waybar-cache/pill-geom}"
ROFI_HYPR_CTX="${ROFI_HYPR_CTX:-/tmp/waybar-cache/hypr-context.json}"
ROFI_BAR_HEIGHT="${ROFI_BAR_HEIGHT:-25}"     # logical px, matches monitor reserved
ROFI_GAP_PX="${ROFI_GAP_PX:-4}"               # gap between bar bottom and rofi top
ROFI_DEFAULT_WIDTH="${ROFI_DEFAULT_WIDTH:-480}"  # default window width in logical px

# Pick the right theme file based on /tmp/glass-mode. Default "dark"
# when missing/unreadable (matches pill_theme's defensive default).
rofi_theme_for_mode() {
    local mode=""
    [ -r "$ROFI_GLASS_FILE" ] && mode=$(cat "$ROFI_GLASS_FILE" 2>/dev/null)
    case "$mode" in
        light) printf '%s/options-light.rasi' "$ROFI_THEME_DIR" ;;
        *)     printf '%s/options-dark.rasi'  "$ROFI_THEME_DIR" ;;
    esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /etc/nixos/home/tests/rofi-anchor-test.sh`
Expected: 3 pass, 0 fail.

---

## Task 5: `rofi-anchor.sh` — `rofi_anchor_for` (with zone layout)

**Files:**
- Modify: `/etc/nixos/home/scripts/lib/rofi-anchor.sh`
- Modify: `/etc/nixos/home/tests/rofi-anchor-test.sh`

**Important:** `notif-bell` lives in `modules-right` (SYSTEM zone), which waybar packs LEFT-to-right starting from the right edge of TASK zone. The full SYSTEM list (verified from `waybar/config.jsonc:55-72`) is in render order:

```
tray, group/notif-widepill, group/notif, group/group-2, group/group-power,
custom/update-pending, custom/waybar-self-test, custom/power-resume,
custom/clock, custom/battery, custom/night-dimmer, group/screen-type-group,
custom/dictate
```

The bellwether resolver only needs to position `notif-bell`. Strategy: encode the SYSTEM zone as a flat list of LEAF pill identifiers (groups expanded), use `pill-geom/<name>.json` widths where available, and a small constant for non-pill modules (`tray`). Position is `zone_left_edge + cumulative_width_before(target) + target_w/2`, where `zone_left_edge = monitor.x + monitor.w - total_zone_width`.

- [ ] **Step 1: Write failing tests**

Append to `/etc/nixos/home/tests/rofi-anchor-test.sh` BEFORE the final `printf` line:

```bash
# rofi_anchor_for <pill-id> — reads pill-geom + hypr-context and prints
# a rofi -theme-str fragment that positions rofi's top-center under the
# pill's bottom-center + ROFI_GAP_PX.

# Set up a fake monitor + a minimal SYSTEM zone for the test:
# [tray=60, notif-widepill=0, notif-dnd=0, notif-bell=28].
# total_zone_width = 60 + 0 + 0 + 28 = 88
# zone_left_edge = 1600 - 88 = 1512
# bell cumulative_before = 60 + 0 + 0 = 60
# bell start X = 1512 + 60 = 1572
# bell center X = 1572 + 14 = 1586
# rofi x_offset (window width 480) = 1586 - 240 = 1346
cat > "$ROFI_HYPR_CTX" <<'EOF'
{"monitor_focused":"eDP-1","monitors":[{"name":"eDP-1","x":0,"y":0,"w":1600,"h":1000,"scale":2.0,"focused_ws":1}]}
EOF
printf '{"w":0,"monitor":"eDP-1"}'  > "$ROFI_GEOM_DIR/notif-widepill.json"
printf '{"w":0,"monitor":"eDP-1"}'  > "$ROFI_GEOM_DIR/notif-dnd.json"
printf '{"w":28,"monitor":"eDP-1"}' > "$ROFI_GEOM_DIR/notif-bell.json"

# The test config sets only [tray, widepill, dnd, bell] in the SYSTEM
# zone — narrower than production but exercises the same algorithm.
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd notif-bell"
# tray's width is a fixed constant (no pill-geom entry).
export ROFI_TRAY_WIDTH=60

out=$(rofi_anchor_for notif-bell)
check "[anchor output non-empty]" test -n "$out"
check "[anchor contains x-offset 1346]" test -n "$(echo "$out" | grep -Eo 'x-offset:1346px')"
check "[anchor contains y-offset]" test -n "$(echo "$out" | grep -Eo 'y-offset:29px')"
check "[anchor sets location northwest]" test -n "$(echo "$out" | grep -F 'location:northwest')"
check "[anchor sets anchor north]" test -n "$(echo "$out" | grep -F 'anchor:north')"

# Pill not in any zone array → fallback path.
# Fallback cx = monitor_right - DEFAULT_WIDTH = 1600 - 480 = 1120.
# x_offset = cx - DEFAULT_WIDTH/2 = 1120 - 240 = 880.
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd"
out=$(rofi_anchor_for notif-bell)
check "[fallback anchor still set]" test -n "$out"
check "[fallback x-offset = (mon_w - default - default/2) = 880]" \
    test -n "$(echo "$out" | grep -Eo 'x-offset:880px')"
# Restore for any later tests
export ROFI_ZONE_SYSTEM_OVERRIDE="tray notif-widepill notif-dnd notif-bell"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /etc/nixos/home/tests/rofi-anchor-test.sh`
Expected: 7 new checks fail with `rofi_anchor_for: command not found`.

- [ ] **Step 3: Implement zone layout + `rofi_anchor_for`**

Append to `/etc/nixos/home/scripts/lib/rofi-anchor.sh`:

```bash
# SYSTEM zone layout — leaf pill names in render order (left-to-right
# as the eye scans, which matches waybar's modules-right list with
# groups expanded). Source-of-truth: waybar/config.jsonc:55-72.
# Maintenance: any time modules-right changes, update this list.
ROFI_ZONE_SYSTEM=(
    tray
    notif-widepill notif-dnd
    notif-bell notif-dismiss notif-action-1 notif-action-2 notif-action-3
    # group/group-2 children — fill as needed
    # group/group-power children — fill as needed
    update-pending waybar-self-test power-resume
    clock battery night-dimmer
    # group/screen-type-group children — fill as needed
    dictate
)

# Width constants for non-pill modules (no pill-geom entry).
# Tray width is roughly icon_count * icon_size; 60 is a reasonable
# estimate for the typical 2-4 tray icons on this system.
ROFI_TRAY_WIDTH="${ROFI_TRAY_WIDTH:-60}"

# Extract a single integer field from a JSON object using a regex.
# Returns 0 if not found. Avoids forking jq for simple reads.
_rofi_json_int() {
    local json="$1" key="$2"
    if [[ $json =~ \"$key\":[[:space:]]*([0-9]+) ]]; then
        printf '%d' "${BASH_REMATCH[1]}"
    else
        printf '0'
    fi
}

# Extract a single string field from a JSON object using a regex.
_rofi_json_str() {
    local json="$1" key="$2"
    if [[ $json =~ \"$key\":[[:space:]]*\"([^\"]+)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Resolve focused monitor's (x, w) from hypr-context.json. Falls back
# to (0, 1920) when context is missing — better than blank.
_rofi_focused_monitor() {
    local ctx focused mon_blob mon_x mon_w
    [ -r "$ROFI_HYPR_CTX" ] || { printf '0 1920'; return; }
    ctx=$(cat "$ROFI_HYPR_CTX" 2>/dev/null) || { printf '0 1920'; return; }
    focused=$(_rofi_json_str "$ctx" monitor_focused)
    if [[ $ctx =~ \{\"name\":\"${focused}\"[^}]*\} ]]; then
        mon_blob="${BASH_REMATCH[0]}"
    else
        printf '0 1920'; return
    fi
    mon_x=$(_rofi_json_int "$mon_blob" x)
    mon_w=$(_rofi_json_int "$mon_blob" w)
    printf '%d %d' "$mon_x" "$mon_w"
}

# Width of a single module: pill-geom entry if available, else a
# hardcoded constant for known non-pill modules, else 0.
_rofi_module_width() {
    local name="$1" f="$ROFI_GEOM_DIR/$1.json" content
    case "$name" in
        tray) printf '%d' "$ROFI_TRAY_WIDTH"; return ;;
    esac
    [ -r "$f" ] || { printf '0'; return; }
    content=$(cat "$f" 2>/dev/null) || { printf '0'; return; }
    _rofi_json_int "$content" w
}

# Compute the target pill's center X by walking the SYSTEM zone array
# left-to-right, accumulating widths. The zone's left edge is anchored
# to the monitor's right edge minus the zone's total width.
#
# ROFI_ZONE_SYSTEM_OVERRIDE (space-separated list) replaces the array
# for testing — production code never sets it.
_rofi_pill_center_x() {
    local target="$1" mon_x="$2" mon_w="$3"
    local -a zone
    if [ -n "${ROFI_ZONE_SYSTEM_OVERRIDE:-}" ]; then
        # shellcheck disable=SC2206
        zone=( ${ROFI_ZONE_SYSTEM_OVERRIDE} )
    else
        zone=( "${ROFI_ZONE_SYSTEM[@]}" )
    fi
    local i name w total=0 cum_before=0 target_w=0 found=0
    for name in "${zone[@]}"; do
        w=$(_rofi_module_width "$name")
        if [ "$name" = "$target" ]; then
            target_w=$w
            cum_before=$total
            found=1
        fi
        total=$(( total + w ))
    done
    [ "$found" = 0 ] && return 1
    local zone_left=$(( mon_x + mon_w - total ))
    printf '%d' $(( zone_left + cum_before + target_w / 2 ))
}

# Print a rofi -theme-str fragment that anchors rofi's top-center to
# the target pill's bottom-center + ROFI_GAP_PX. Fallback: a
# zone-center anchor (monitor center of SYSTEM zone, approximated as
# monitor right - DEFAULT_WIDTH).
rofi_anchor_for() {
    local pill="$1"
    local mon mon_x mon_w
    mon=$(_rofi_focused_monitor); read -r mon_x mon_w <<<"$mon"
    local cx
    if cx=$(_rofi_pill_center_x "$pill" "$mon_x" "$mon_w"); then
        :  # cx set
    else
        cx=$(( mon_x + mon_w - ROFI_DEFAULT_WIDTH ))
    fi
    local x_offset=$(( cx - ROFI_DEFAULT_WIDTH / 2 ))
    local y_offset=$(( ROFI_BAR_HEIGHT + ROFI_GAP_PX ))
    printf -- '-theme-str window{location:northwest;anchor:north;x-offset:%dpx;y-offset:%dpx;}' \
        "$x_offset" "$y_offset"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash /etc/nixos/home/tests/rofi-anchor-test.sh`
Expected: 10 pass, 0 fail.

---

## Task 6: `rofi-anchor.sh` — `rofi_launch` convenience

**Files:**
- Modify: `/etc/nixos/home/scripts/lib/rofi-anchor.sh`

- [ ] **Step 1: Add `rofi_launch` convenience wrapper**

Append to `/etc/nixos/home/scripts/lib/rofi-anchor.sh`:

```bash
# rofi_launch <pill-id> [extra-rofi-args...] — sources theme + anchor
# and invokes rofi -dmenu. Stdin is piped to rofi (rows). Stdout is
# rofi's selected entry (whatever the caller asks for via -format).
# Callers should pass -p/-format/-no-custom/etc. themselves; this
# wrapper only injects -theme and the anchor -theme-str.
rofi_launch() {
    local pill="$1"; shift
    local theme anchor
    theme=$(rofi_theme_for_mode)
    anchor=$(rofi_anchor_for "$pill")
    # $anchor expands to multiple shell words; intentional — it must be
    # split into ("-theme-str", "window{...}"). Use word-splitting here.
    rofi -theme "$theme" $anchor -dmenu "$@"
}
```

- [ ] **Step 2: Smoke-check the convenience wrapper**

No automated test — `rofi_launch` is a thin shell of `rofi`, exercised end-to-end via notif-menu in Task 11. Verify the function definition with:
```bash
bash -n /etc/nixos/home/scripts/lib/rofi-anchor.sh
```
Expected: no parse error.

---

## Task 7: Shared rasi sources — base + light + dark

**Files:**
- Create: `/etc/nixos/home/rofi/options-base.rasi`
- Create: `/etc/nixos/home/rofi/options-light.rasi`
- Create: `/etc/nixos/home/rofi/options-dark.rasi`

- [ ] **Step 1: Read the @opt-* palette tokens from style.css**

Run:
```bash
grep -nE '@define-color|opt-(yes|no|middle|hover-bright|pin-)|opt-pushed-border' \
    /etc/nixos/home/waybar/style.css | head -40
```
Expected: see the canonical color values for each token. Copy these into the new rasi files. (Run this BEFORE writing the rasi — the rasi colors must match exactly.)

- [ ] **Step 2: Write `options-base.rasi`**

Create `/etc/nixos/home/rofi/options-base.rasi`. The light/dark files
will set the palette `*` constants this base imports; here we define
shape, sizing, row templates, and the universal bright-hover film.

```rasi
/*
 * options-base.rasi — shared shape and surface rules for every rofi
 * surface in OPTIONS. The light and dark theme files @import this and
 * set @opt-surface-parent / @opt-surface-child / @opt-text constants.
 *
 * Soul rule: rofi IS a wide pill from the OPTIONS family.
 * - Window: parent surface, rounded, NO hard border (Rule 3).
 * - Selected row: white film 0.30 alpha (universal bright-hover).
 * - Action rows (verbs): child surface, rounded, action verb in text.
 * - Notif rows (records): transparent rest, icon + text.
 * - Section headers: smaller font, dim, non-selectable.
 */

configuration {
    font: "meslo-ng 13";
    show-icons: true;
    me-select-entry: "MouseSecondary";
    me-accept-entry: "MousePrimary";
    hover-select: true;
    click-to-exit: true;
}

* {
    background-color: transparent;
    text-color:       @opt-text;
    border:           0px;            /* Rule 3: no hard borders */
}

/* Window — the wide pill container. Position is overridden by the
   launcher's -theme-str (x-offset/y-offset/location/anchor). */
window {
    width:            480px;
    padding:          6px;
    background-color: @opt-surface-parent;
    border-radius:    14px;
}

mainbox {
    padding: 0;
    spacing: 4px;
    children: ["listview"];
}

listview {
    spacing:      2px;
    scrollbar:    false;
    fixed-height: 0;
    lines:        12;
}

/* Row, default — transparent at rest; hover film provides selection. */
element {
    padding:       4px 10px;
    border-radius: 10px;
    cursor:        pointer;
}

element-text {
    background-color: transparent;
    text-color:       inherit;
    highlight:        inherit;
}

element-icon {
    padding: 0 6px 0 0;
    size:    1.6em;
}

/* Universal bright-hover — selected row gets a white 0.30 alpha film
   over whatever surface is beneath. Matches waybar's .opt-pill:hover. */
element selected.normal,
element selected.active,
element selected.urgent {
    background-color: @opt-hover-bright;
    text-color:       @opt-text;
}

/* Action rows — emitted by format_rofi_action with a leading \x02
   sentinel. rofi treats them as `active` rows; we give them the child
   surface so they read as action pills. */
element normal.active {
    background-color: @opt-surface-child;
    border-radius:    10px;
}

/* Section headers — emitted with the existing dim-non-selectable
   format. rofi treats them as `urgent` rows; we make them small + dim
   and non-clickable visually. */
element normal.urgent {
    background-color: transparent;
    text-color:       @opt-text-dim;
    padding:          2px 10px 0;
    cursor:           default;
}
element normal.urgent element-text {
    text-color: @opt-text-dim;
}
```

- [ ] **Step 3: Write `options-dark.rasi`**

```rasi
/* options-dark.rasi — dark glass mode palette. Token values mirror
   the @opt-* @define-color block in waybar/style.css for dark mode. */

* {
    opt-surface-parent: rgba(40,  40,  50,  0.72);
    opt-surface-child:  rgba(20,  20,  28,  0.62);
    opt-hover-bright:   rgba(255, 255, 255, 0.30);
    opt-text:           rgba(255, 255, 255, 1.00);
    opt-text-dim:       rgba(255, 255, 255, 0.55);
}

@import "options-base.rasi"
```

- [ ] **Step 4: Write `options-light.rasi`**

```rasi
/* options-light.rasi — light glass mode palette. */

* {
    opt-surface-parent: rgba(245, 245, 250, 0.78);
    opt-surface-child:  rgba(225, 225, 235, 0.70);
    opt-hover-bright:   rgba(255, 255, 255, 0.50);
    opt-text:           rgba(15,  15,  20,  1.00);
    opt-text-dim:       rgba(15,  15,  20,  0.55);
}

@import "options-base.rasi"
```

- [ ] **Step 5: Manual visual check — launch rofi with each theme**

Run (after Task 8 wires Nix; or directly with absolute paths):
```bash
echo -e "alpha\nbeta\ngamma" | rofi -theme /etc/nixos/home/rofi/options-dark.rasi -dmenu -p test
echo -e "alpha\nbeta\ngamma" | rofi -theme /etc/nixos/home/rofi/options-light.rasi -dmenu -p test
```
Expected: rounded container, light/dark surface, bright film on selected row, no hard borders.

**Tune the rasi here** if a token value doesn't match its waybar counterpart visually. Iterate until the rofi popup feels indistinguishable from a wide pill on the bar.

---

## Task 8: Nix module wiring — `modules/rofi.nix`

**Files:**
- Create: `/etc/nixos/home/modules/rofi.nix`
- Modify: `/etc/nixos/home/hyprland-home.nix` (or whichever file imports the modules — verify with `grep -l notif-center.nix /etc/nixos/home/*.nix`)

- [ ] **Step 1: Read an existing simple module for the pattern**

Run: `cat /etc/nixos/home/modules/hypr-bg.nix` (or `keyring-unlocked.nix`). Familiarise with mkOutOfStoreSymlink usage in this repo.

- [ ] **Step 2: Create `modules/rofi.nix`**

```nix
# rofi.nix — declares the OPTIONS-coherent rofi theme files. The source
# .rasi files live next to waybar/style.css at /etc/nixos/home/rofi/ so
# they remain easy to iterate on. They symlink directly into the user's
# ~/.config/rofi/ via mkOutOfStoreSymlink — same pattern as waybar.nix.
{ config, pkgs, lib, ... }:
let
  rofiSrc = /etc/nixos/home/rofi;
in
{
  home.packages = [ pkgs.rofi ];

  # The three theme files. ~/.config/rofi/config.rasi defaults to the
  # dark theme for invocations that don't pass -theme (e.g. Hyprland's
  # $mod+SPACE before its launcher gets the rofi-anchor.sh treatment).
  xdg.configFile = {
    "rofi/options-base.rasi".source  = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-base.rasi";
    "rofi/options-light.rasi".source = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-light.rasi";
    "rofi/options-dark.rasi".source  = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-dark.rasi";
    "rofi/config.rasi".source        = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-dark.rasi";
  };
}
```

- [ ] **Step 3: Import the new module**

Find the existing importer:
```bash
grep -l "modules/waybar.nix" /etc/nixos/home/*.nix /etc/nixos/configuration.nix 2>/dev/null
```

In the file that imports `modules/waybar.nix`, add `./modules/rofi.nix` to the same imports list.

- [ ] **Step 4: nixos-rebuild switch (NOT test — per the Standard-OS memory)**

Run: `sudo nixos-rebuild switch`
Expected: build succeeds, `~/.config/rofi/options-{base,light,dark}.rasi` now exist as out-of-store symlinks pointing at `/etc/nixos/home/rofi/*.rasi`.

Verify:
```bash
readlink -f ~/.config/rofi/options-dark.rasi
# expect: /etc/nixos/home/rofi/options-dark.rasi
```

---

## Task 9: Action-row formatter in `notif-menu-format.sh`

**Files:**
- Modify: `/etc/nixos/home/scripts/lib/notif-menu-format.sh`
- Modify: `/etc/nixos/home/tests/notif-menu-format-test.sh` (existing)

**Note:** notif-menu uses `lib/notif-menu-format.sh` (the active library), NOT `lib/notif-rofi-format.sh` (which is the legacy `notif-rofi` library). The legacy file is untouched in this stream.

**Rofi -dmenu limitation:** rofi cannot apply per-row backgrounds via the rasi alone in `-dmenu` mode — element states are not addressable by row content. The pragmatic shipping route for the bellwether is **Pango markup in the row text**: action rows emit a Pango-bold label with a leading chevron glyph (▸). This makes action rows visually distinct without rofi state hacks. The "child-surface paint" goal from the spec is acknowledged as a follow-up iteration; the bellwether ships with bold + chevron distinction, which the user can iterate on visually after seeing it live.

- [ ] **Step 1: Add failing test for `fmt_l1_action`**

Append to `/etc/nixos/home/tests/notif-menu-format-test.sh` BEFORE the final pass/fail printf:

```bash
# fmt_l1_action LABEL — emits a Pango-marked action row that rofi
# (with -markup-rows / pango-markup) renders bold with a leading
# chevron glyph. Visual distinction from notification rows.
out=$(fmt_l1_action "Dismiss all unread")
check "[action row contains label]" test -n "$(echo "$out" | grep -F 'Dismiss all unread')"
check "[action row has Pango bold markup]" test -n "$(echo "$out" | grep -F '<b>')"
check "[action row has leading chevron glyph]" test -n "$(echo "$out" | grep -F '▸')"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /etc/nixos/home/tests/notif-menu-format-test.sh`
Expected: 3 new checks fail with `fmt_l1_action: command not found`.

- [ ] **Step 3: Implement `fmt_l1_action`**

In `/etc/nixos/home/scripts/lib/notif-menu-format.sh`, add at the end (after `fmt_l2_separator`):

```bash
# fmt_l1_action LABEL — emits an L1 row for an action (verb-style
# button like "Dismiss all unread", "Clear history"). Rendered by
# rofi with -markup-rows true: Pango bold + leading chevron glyph
# makes it read as an action distinct from plain notification rows.
# Pairs with the populate_l1 caller (see notif-menu — Task 10).
fmt_l1_action() {
    local label="$1"
    printf '<b>▸ %s</b>' "$label"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash /etc/nixos/home/tests/notif-menu-format-test.sh`
Expected: existing checks pass + 3 new pass, 0 fail.

---

## Task 10: Rewire `notif-menu` `run_rofi` to use shared theme + anchor

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-menu`

- [ ] **Step 1: Locate the current `run_rofi` function**

Run:
```bash
grep -n "^run_rofi()" /etc/nixos/home/scripts/notif-menu
```
Expected: ~ line 390.

- [ ] **Step 2: Replace `run_rofi` with the sourced-library version**

Replace the entire `run_rofi()` function body (currently has inline `-no-config -theme-str '...'`) with:

```bash
# Sourced at top of file once — see "shellcheck source" block below.
# rofi_anchor_for/rofi_theme_for_mode handle anchor + theme; this
# function only owns the run-time prompt and stdin pipe. -markup-rows
# is required for fmt_l1_action's Pango-bold action rows to render.
run_rofi() {
    local prompt="$1"
    local theme; theme=$(rofi_theme_for_mode)
    local anchor; anchor=$(rofi_anchor_for notif-bell)
    rofi -theme "$theme" $anchor -dmenu -i -p "$prompt" -no-custom -format i \
        -markup-rows \
        -me-select-entry MouseSecondary \
        -me-accept-entry MousePrimary \
        2>/dev/null
}
```

And add near the other `source` lines at the top of the file (after the existing `source "$LIB_DIR/notif-hypr.sh"` line):

```bash
# shellcheck source=lib/rofi-anchor.sh
source /etc/nixos/home/scripts/lib/rofi-anchor.sh
```

- [ ] **Step 2.5: Wire action rows in populate_l1**

In `/etc/nixos/home/scripts/notif-menu`, locate populate_l1 (line ~79). The current bare emission:

```bash
put_row $idx "dismiss_all"
printf 'Dismiss all unread\n'
```

Replace the `printf` line with the formatter:

```bash
put_row $idx "dismiss_all"
fmt_l1_action "Dismiss all unread"; printf '\n'
```

The `kind_at[$idx]` mapping (set by `put_row`) is unchanged — dispatch still routes by kind, not by row text — so the existing flow tests in `notif-menu-flow-test.sh` continue to work. The only difference visible to the user is the Pango-bold + ▸ glyph on the action row.

- [ ] **Step 3: Run the existing notif-menu flow test**

Run: `bash /etc/nixos/home/tests/notif-menu-flow-test.sh`
Expected: all existing checks pass. The flow test calls run_rofi with a stub `rofi` function (CALL_LOG) — verify the stub still captures prompt + stdin correctly.

If the test stub asserts on specific rofi flags that no longer match (`-no-config` is gone), update the test's grep to match the new flags. The flow assertions (selection routing, dispatch) should not change.

- [ ] **Step 4: Smoke test live — open notif-menu**

Click the bell pill OR run:
```bash
notif-menu
```
Verify visually:
- [ ] Rofi opens centered horizontally near the bell pill (not centered on screen).
- [ ] Light/dark theme matches `/tmp/glass-mode`.
- [ ] Rounded wide-pill shape, no hard borders.
- [ ] Hovering a row shows the bright film.

If the anchor X is off by more than ~30px, tune `PILL_PAD_X` or `PILL_FONT_ADVANCE_PX` constants in `pill.sh` (Task 1) until visual alignment matches.

---

## Task 11: TODO.md — promote straight to DONE, single stream commit

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Append to the DONE section**

Add at the top of the DONE section (most recent first):

```markdown
- **2026-06-16** — **rofi unified with OPTIONS — bellwether ships on notif-menu.**
  Three new shared artefacts: pill-geom registry in pill.sh (per-pill
  files at /tmp/waybar-cache/pill-geom/), rofi-anchor.sh library
  (rofi_anchor_for, rofi_theme_for_mode, rofi_launch), and
  options-{base,light,dark}.rasi mirroring the waybar @opt-* palette.
  notif-menu's inline `-no-config -theme-str` deleted; the bell popup
  now opens under the bell pill, with light/dark following glass-mode.
  Five remaining rofi surfaces (apps launcher, window switcher,
  restore-minimized, reboot-prompt, notif-rofi legacy) follow as
  separate streams.
  **Hint:** spec at `docs/superpowers/specs/2026-06-16-waybar-rofi-integration-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-16-waybar-rofi-integration.md`.
  **Hint:** pill-geom is written by pill.sh::pill_write on every emit;
  one JSON file per pill avoids jq merge in the hot loop.
  **Hint:** rofi-anchor.sh's zone layout list is currently SYSTEM-only
  (encodes notif-widepill → notif-dnd → notif-bell). Other zones will
  be added as their pills need rofi popups.
  **Hint:** action-row marker is a leading \t (tab) in
  format_rofi_action; the row's child-surface paint is set via the
  rofi element-state, populated in notif-menu's populate_l1.
```

- [ ] **Step 2: Pre-commit verification — run all tests + lint**

Run:
```bash
bash /etc/nixos/home/tests/pill-geom-test.sh
bash /etc/nixos/home/tests/rofi-anchor-test.sh
bash /etc/nixos/home/tests/notif-rofi-test.sh
bash /etc/nixos/home/tests/notif-menu-flow-test.sh
bash -n /etc/nixos/home/scripts/lib/rofi-anchor.sh
bash -n /etc/nixos/home/waybar/scripts/lib/pill.sh
bash -n /etc/nixos/home/scripts/notif-menu
```
Expected: all pass, no parse errors.

- [ ] **Step 3: Pre-commit verification — OPTIONS checklist (from spec)**

- [ ] Anchor visually correct on each monitor in use (open notif-menu, verify centering).
- [ ] Light/dark theme follows glass-mode flips between launches.
- [ ] Empty-collapse: trigger a sibling pill to go `.empty`, verify bell anchor shifts.
- [ ] No regression to existing rofi surfaces (apps launcher, reboot prompt still open with OLD global config behavior — they haven't been migrated yet).
- [ ] `class` arrays still emitted as JSON arrays from `pill_emit` (no string-class regression).

- [ ] **Step 4: Commit the bellwether stream as one commit**

```bash
cd /etc/nixos/home && git add -A
git status
# Verify ONLY this stream's files are staged.
git commit -m "$(cat <<'EOF'
waybar↔rofi: unify notif-menu under OPTIONS surface

Bellwether stream of the broader rofi-as-OPTIONS push. Adds:
- pill-geom registry written by pill_write to /tmp/waybar-cache/pill-geom/
- rofi-anchor.sh library (rofi_anchor_for, rofi_theme_for_mode, rofi_launch)
- shared options-{base,light,dark}.rasi mirroring the @opt-* palette
- modules/rofi.nix declaring the .rasi files via out-of-store symlinks
- format_rofi_action marker for action-row rendering
- notif-menu run_rofi rewritten to use the shared theme + bell anchor

The user can't tell rofi from waybar on notif-menu now. Five remaining
rofi surfaces (apps launcher, window switcher, restore-minimized,
reboot-prompt, notif-rofi legacy) migrate as separate streams.

Spec: docs/superpowers/specs/2026-06-16-waybar-rofi-integration-design.md
Plan: docs/superpowers/plans/2026-06-16-waybar-rofi-integration.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git status
```

Expected: working tree clean.

---

## Verification summary

After Task 11:
- Tests: `pill-geom-test.sh`, `rofi-anchor-test.sh`, `notif-rofi-test.sh`, `notif-menu-flow-test.sh` all green.
- Live: notif-menu opens anchored under the bell, themed by glass-mode, no hard borders.
- Tree: single commit, TODO.md DONE updated with Hints.
- Out of scope (next streams): apps launcher migration, window switcher, restore-minimized, reboot-prompt, notif-rofi legacy.

## Known follow-ups (NOT in this plan)

- Encode USER and TASK zones in `rofi-anchor.sh::ROFI_ZONE_*` arrays when their pills (apps, ws-current, win-* actions) gain rofi popups.
- Migrate `rofi -show drun` invocations to source `rofi-anchor.sh` and pass the apps pill as anchor.
- Migrate `window-switcher.sh`, `restore-minimized.sh`, `standard-os-reboot-prompt` to the shared theme + anchor.
- Delete `notif-rofi` legacy binary once nothing on PATH calls it (verify with `grep -rn notif-rofi /etc/nixos/home/`).
