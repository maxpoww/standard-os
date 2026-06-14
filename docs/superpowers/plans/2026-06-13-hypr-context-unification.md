# Hypr-context unification — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the duplicated Hyprland-state daemons (`workspace-daemon` + `hypr-activities`) with one `hypr-context-daemon` feeding both waybar pills and a single-rule `hypr-bg-daemon` that also owns `/tmp/glass-mode`. Delete `hypr-dive`, `glass-text-daemon`, and the 4-mode color matrix.

**Architecture:** ONE `socket2` subscription publishes per-pill cache files (waybar pills change nothing) AND a snapshot `/tmp/waybar-cache/hypr-context.json` consumed via inotify by the new bg daemon. The bg daemon evaluates a single geometric rule (workspace has zero gaps + single tiled window covering monitor) and either samples the focused window's top-edge color or restores the waypaper image. Glass-mode is written by the bg daemon at the same moment it changes the visible color.

**Tech Stack:** bash (`socat`, `inotifywait`, `jq`), Hyprland IPC (`hyprctl -j`, `socket2`), `grim` + `imagemagick` for color sampling, `hyprpaper` for wallpaper application, Nix (`writeShellScriptBin`, systemd-user services), the existing `waybar-scripts` derivation pattern from `modules/waybar.nix`.

**Spec:** `docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md` — re-read its "BG trigger rule", "Snapshot schema", and "Migration order" sections before each task.

**Non-negotiables (from memory + skill):**
- Always `sudo nixos-rebuild switch`, never `test` (test reverts on reboot — see [[feedback_nixos_rebuild_switch_not_test]]).
- waybar `style.css` and `config.jsonc` are out-of-store symlinks; edits to them are live (see [[feedback_waybar_source_edits_and_out_of_store_symlinks]]). The daemon scripts in this plan go into the `waybar-scripts` derivation → bundled into `/nix/store` → require rebuild.
- Each task ends with `git add` + commit. Close one stream before opening the next.
- shellcheck `-S error` must pass for every new script (the `waybar-scripts` derivation gates the build).

---

## Pre-flight (run once before Task 1)

- [ ] **P1: Confirm clean tree + clean baseline**

```bash
git -C /etc/nixos/home status -s
```

Expected: empty output. If dirty, stop and resolve before starting.

- [ ] **P2: Capture pre-migration cache snapshot for diff verification**

```bash
mkdir -p /tmp/hypr-context-baseline
for f in /tmp/waybar-cache/ws-current /tmp/waybar-cache/ws-{1..9} /tmp/waybar-cache/window /tmp/waybar-cache/has-window /tmp/waybar-cache/win-{close,minimize,swap-right,move-trigger,move-new} /tmp/waybar-cache/win-move-{1..9}; do
  [ -r "$f" ] && cp "$f" "/tmp/hypr-context-baseline/$(basename "$f").pre"
done
ls /tmp/hypr-context-baseline | wc -l
```

Expected: at least 20 files copied. Used in Task 6 to verify the new daemon emits identical content.

---

## Task 1: Trim `colors.sh` to the keepers + add `hex_luminance` ✓ b1d7c4b

**Files:**
- Modify: `/etc/nixos/home/scripts/lib/colors.sh` (rewrite to ~30 lines)

**Rationale:** `mismatch_hex`, `mix_*`, `luma`, `clamp` are all unused after the dive matrix is dropped. `hex_luminance` moves from `glass-text-daemon.sh` to here so the bg daemon can source it.

- [ ] **Step 1: Rewrite `colors.sh`**

Replace the entire file with:

```bash
#!/usr/bin/env bash
# Shared color helpers for hypr-bg-daemon and any other consumer.
# Pure bash + printf arithmetic; no forks per call.

hex_to_rgb() {
    local h=${1#"#"}
    printf '%d %d %d\n' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

rgb_to_hex() {
    printf '%02x%02x%02x\n' "$1" "$2" "$3"
}

rgb_dist_sq() {
    local dr=$(($1 - $4)) dg=$(($2 - $5)) db=$(($3 - $6))
    printf '%d\n' $((dr * dr + dg * dg + db * db))
}

# ITU-R BT.601 perceived luminance (0-255) from a 6-char hex (no leading #).
# Threshold ≈ 128 is the natural light/dark cutoff for glass-mode.
hex_luminance() {
    local hex=$1
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    echo $(( (r * 299 + g * 587 + b * 114) / 1000 ))
}
```

- [ ] **Step 2: Verify shellcheck passes**

```bash
shellcheck -S error -s bash /etc/nixos/home/scripts/lib/colors.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git -C /etc/nixos/home add scripts/lib/colors.sh
git -C /etc/nixos/home commit -m "colors.sh: trim to keepers + hex_luminance (prep for hypr-context unification)"
```

---

## Task 2: Write `hypr-context-daemon.sh`

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/hypr-context-daemon.sh`

**Rationale:** This is the unified Hyprland-state publisher. ONE `socket2` subscription. Emits per-pill caches (using `pill_write` from `lib/pill.sh`) AND the snapshot file (atomic write, no signal — inotify consumers).

- [ ] **Step 1: Create the file**

```bash
#!/usr/bin/env bash
# hypr-context-daemon — unified Hyprland-state publisher.
#
# Subscribes ONCE to Hyprland's socket2 and emits:
#   - per-pill caches in /tmp/waybar-cache/{ws-*, window, has-window, win-*}
#     for waybar (signal RTMIN+10)
#   - /tmp/waybar-cache/hypr-context.json for inotify consumers (bg, future)
#
# Replaces workspace-daemon.sh (polling) and hypr-activities (socket-broadcast).
# See docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
set -euo pipefail

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

PILL_CACHE_DIR=${PILL_CACHE_DIR:-/tmp/waybar-cache}
mkdir -p "$PILL_CACHE_DIR"

SNAPSHOT="$PILL_CACHE_DIR/hypr-context.json"
LAST_SNAPSHOT=""

HYPR_SIG=${HYPRLAND_INSTANCE_SIGNATURE:?HYPRLAND_INSTANCE_SIGNATURE not set}
HYPR_SOCK2="${XDG_RUNTIME_DIR}/hypr/${HYPR_SIG}/.socket2.sock"

# Effective-gap parser (handles both old int form and new per-side string form).
PARSE_GAP='
    if has("int") and (.int|type)=="number" then .int
    elif has("custom") and (.custom|type)=="string" and .custom != "" then
        ((.custom | split(" ") | map(tonumber? // 0) | max) // 0)
    else 0 end
'

# Build snapshot — single jq invocation per emit.
build_snapshot() {
    local active monitors workspaces clients gaps_in gaps_out ts
    active=$(hyprctl activewindow -j 2>/dev/null) || return 1
    monitors=$(hyprctl monitors -j 2>/dev/null) || return 1
    workspaces=$(hyprctl workspaces -j 2>/dev/null) || return 1
    clients=$(hyprctl clients -j 2>/dev/null) || return 1
    gaps_in=$(hyprctl getoption general:gaps_in -j 2>/dev/null | jq -r "$PARSE_GAP" 2>/dev/null || printf 0)
    gaps_out=$(hyprctl getoption general:gaps_out -j 2>/dev/null | jq -r "$PARSE_GAP" 2>/dev/null || printf 0)
    ts=$(date +%s%3N)

    jq -nc \
        --argjson ts "$ts" \
        --argjson monitors "$monitors" \
        --argjson clients "$clients" \
        --argjson active "$active" \
        --argjson gaps_in "$gaps_in" \
        --argjson gaps_out "$gaps_out" \
        '
        ($monitors | map(select(.focused == true)) | .[0] // null) as $mf |
        ($mf.name // null) as $mfn |
        ($mf.activeWorkspace.id // null) as $wsid |
        ($clients | map(select(.workspace.id == $wsid))) as $wsc |
        {
          ts: $ts,
          monitor_focused: $mfn,
          monitors: ($monitors | map({
            name: .name, x: .x, y: .y, w: .width, h: .height,
            scale: .scale, focused_ws: .activeWorkspace.id
          })),
          workspace: {
            id: $wsid,
            monitor: $mfn,
            window_count: ($wsc | length),
            tiled_count: ($wsc | map(select(.floating == false)) | length),
            floating_count: ($wsc | map(select(.floating == true)) | length),
            gaps_in: $gaps_in,
            gaps_out: $gaps_out,
            has_fullscreen: (($wsc | map(select(.fullscreen > 0)) | length) > 0)
          },
          focused: (
            if ($active | type) == "object" and ($active | has("address")) then {
              address: $active.address,
              class: $active.class,
              title: $active.title,
              x: ($active.at[0] // 0),
              y: ($active.at[1] // 0),
              w: ($active.size[0] // 0),
              h: ($active.size[1] // 0),
              fullscreen: ($active.fullscreen // 0),
              floating: ($active.floating // false),
              pseudo: ($active.pseudo // false),
              workspace: ($active.workspace.id // null),
              monitor: ($active.monitor // null)
            } else null end
          )
        }'
}

emit_snapshot() {
    local snap
    snap=$(build_snapshot) || return 0
    [[ $snap == "$LAST_SNAPSHOT" ]] && return 0
    printf '%s' "$snap" >"$SNAPSHOT.tmp" && mv -f "$SNAPSHOT.tmp" "$SNAPSHOT"
    LAST_SNAPSHOT=$snap
    # No signal — snapshot consumers use inotify on $PILL_CACHE_DIR.
}

# ===== Per-pill cache writers (same content as the old workspace-daemon) =====

emit_pills() {
    local active workspaces ws_current focused_class focused_title
    active=$(hyprctl activewindow -j 2>/dev/null) || return 0
    workspaces=$(hyprctl workspaces -j 2>/dev/null) || return 0
    ws_current=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .activeWorkspace.id // 0' 2>/dev/null)
    ws_current=${ws_current:-0}

    # has-window pill
    local has_window=0
    if [[ $(jq -r 'type' <<<"$active") == "object" && $(jq -r 'has("address")' <<<"$active") == "true" ]]; then
        has_window=1
    fi

    # ws-current — number of focused WS, opt-plus opt-swap face
    pill_write "ws-current" "$ws_current" "opt-pill dark opt-plus opt-swap"

    # ws-1..9 — empty / inactive / occupied (occupied != current)
    local i exists
    for i in 1 2 3 4 5 6 7 8 9; do
        exists=$(jq --argjson n "$i" '[.[] | select(.id == $n)] | length' <<<"$workspaces")
        if [[ $i -eq $ws_current ]]; then
            # Current WS is rendered by ws-current; ws-N collapses
            pill_write "ws-$i" "" "opt-pill empty"
        elif [[ $exists -gt 0 ]]; then
            pill_write "ws-$i" "$i" "opt-pill dark inactive"
        else
            pill_write "ws-$i" "" "opt-pill empty"
        fi
    done

    # window pill — focused window class or empty
    if [[ $has_window -eq 1 ]]; then
        focused_class=$(jq -r '.class // ""' <<<"$active")
        pill_write "window" "$focused_class" "opt-pill dark opt-swap-switch"
    else
        pill_write "window" "" "opt-pill dark opt-swap-switch"
    fi

    # has-window — used by per-window action gates
    local hw_content="$has_window"
    local hw_path="$PILL_CACHE_DIR/has-window"
    local hw_prev=""
    [[ -r $hw_path ]] && hw_prev=$(cat "$hw_path" 2>/dev/null)
    if [[ $hw_content != "$hw_prev" ]]; then
        printf '%s' "$hw_content" >"$hw_path.tmp" && mv -f "$hw_path.tmp" "$hw_path"
    fi

    # win-* action pills — visible only when has-window
    if [[ $has_window -eq 1 ]]; then
        pill_write "win-close" "󰅖" "opt-pill-child dark opt-no"
        pill_write "win-minimize" "󰍶" "opt-pill-child dark opt-middle"
        pill_write "win-swap-right" "" "opt-pill-child dark"
        pill_write "win-move-trigger" "󰯍" "opt-pill-child dark opt-yes"
        pill_write "win-move-new" "" "opt-pill-child dark opt-plus"
    else
        for n in close minimize swap-right move-trigger move-new; do
            pill_write "win-$n" "" "opt-pill-child empty"
        done
    fi

    # win-move-1..9 — valid targets (exists AND not current AND has window)
    for i in 1 2 3 4 5 6 7 8 9; do
        exists=$(jq --argjson n "$i" '[.[] | select(.id == $n)] | length' <<<"$workspaces")
        if [[ $has_window -eq 1 && $i -ne $ws_current && $exists -gt 0 ]]; then
            pill_write "win-move-$i" "$i" "opt-pill-child dark opt-yes"
        else
            pill_write "win-move-$i" "" "opt-pill-child empty"
        fi
    done
}

# ===== Event loop =====

DEBOUNCE_S=0.016
PENDING=0

flush() {
    emit_pills
    emit_snapshot
    PENDING=0
}

# Subscribe to socket2 in a coprocess so the read in the main loop has a timeout.
exec {SOCK_FD}< <(socat -u "UNIX-CONNECT:$HYPR_SOCK2" - 2>/dev/null)

# Initial emit at startup (cold cache).
flush

while IFS= read -r -t "$DEBOUNCE_S" -u "$SOCK_FD" line || true; do
    if [[ -n ${line:-} ]]; then
        case "${line%%>>*}" in
            activewindow|activewindowv2|openwindow|closewindow|movewindow|\
            windowtitlev2|fullscreen|workspace|workspacev2|focusedmon|\
            changefloatingmode|configreloaded|monitoradded|monitorremoved)
                PENDING=1
                ;;
        esac
        line=""
        continue
    fi
    # Read timed out (DEBOUNCE_S of silence). If events pending → flush.
    if (( PENDING )); then
        flush
    fi
done
```

- [ ] **Step 2: Verify shellcheck passes**

```bash
shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/hypr-context-daemon.sh
```

Expected: no output, exit 0. Fix any ERROR-severity findings before continuing.

- [ ] **Step 3: Dry-run to verify snapshot builds**

```bash
bash -c 'source /etc/nixos/home/waybar/scripts/hypr-context-daemon.sh & sleep 2; kill %1 2>/dev/null; cat /tmp/waybar-cache/hypr-context.json | jq .'
```

This will fail because the script's exec loop doesn't terminate, but if started in a real shell session you can also test it manually:

```bash
HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/$UID/hypr | head -1) /etc/nixos/home/waybar/scripts/hypr-context-daemon.sh &
PID=$!
sleep 3
jq . /tmp/waybar-cache/hypr-context.json
kill $PID
```

Expected: a valid JSON snapshot with `monitor_focused`, `monitors`, `workspace`, `focused` keys. The focused window's `x`, `y`, `w`, `h` should match `hyprctl activewindow -j | jq '{x:.at[0], y:.at[1]}'`.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add waybar/scripts/hypr-context-daemon.sh
git -C /etc/nixos/home commit -m "waybar: hypr-context-daemon (unified socket2 publisher)"
```

---

## Task 3: Add `hypr-context-daemon` to the `waybar-scripts` derivation

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix` (shellcheck list + install loop)

**Rationale:** The script must be bundled into the `waybar-scripts` derivation so it's wrapped with the right PATH and shellcheck-gated. Follow the existing pattern (`workspace-daemon.sh` is already in the `*.sh` glob).

- [ ] **Step 1: Inspect the shellcheck line + install loop**

```bash
grep -n 'shellcheck -S error\|^    for f in \*\.sh' /etc/nixos/home/modules/waybar.nix
```

Note the two lines. `hypr-context-daemon.sh` is matched by `*.sh` — no change needed to the install loop. But: also verify the new daemon name is among the extensionless list if it isn't a `.sh` file (it is, so it's covered by the glob).

- [ ] **Step 2: Confirm nothing to edit (`.sh` glob covers it)**

The `*.sh` glob in both `shellcheck` and the install `for f` loop already picks up `hypr-context-daemon.sh`. No edit needed in `waybar.nix`.

- [ ] **Step 3: Skip (no edit; no commit)**

---

## Task 4: Write `modules/hypr-context.nix`

**Files:**
- Create: `/etc/nixos/home/modules/hypr-context.nix`

**Rationale:** Defines the systemd-user service that runs the daemon as `waybar-hypr-context-daemon.service`. Replaces the role of the (un-Nix-managed) `workspace-daemon.sh` service.

- [ ] **Step 1: Create the module**

```nix
# Hypr-context daemon — unified Hyprland-state publisher.
# Source: waybar/scripts/hypr-context-daemon.sh (bundled into the
# `waybar-scripts` derivation in modules/waybar.nix).
# See docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
{ config, lib, pkgs, ... }:

let
  cfg = config.services.hyprContext;
  waybarScripts = config.programs.waybar.package or null;
  # The daemon binary is installed by the waybar-scripts derivation as
  # /nix/store/.../bin/hypr-context-daemon (via makeWrapper). Resolve it
  # through the same derivation that owns the other waybar scripts.
in
{
  options.services.hyprContext = {
    enable = lib.mkEnableOption "Unified Hyprland-state publisher (waybar pills + snapshot)";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.waybar-hypr-context-daemon = {
      Unit = {
        Description = "Hyprland unified context publisher (waybar pills + hypr-context.json)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        # Path resolved via waybar-scripts derivation (installed by modules/waybar.nix).
        ExecStart = "/etc/profiles/per-user/${config.home.username}/bin/hypr-context-daemon";
        Restart = "always";
        RestartSec = 1;
        # Hot-loop safety: socket reconnect on Hyprland restart.
        StartLimitBurst = 20;
        StartLimitIntervalSec = 300;
      };
    };
  };
}
```

**Note on `ExecStart` path:** if the user is `max`, this resolves to `/etc/profiles/per-user/max/bin/hypr-context-daemon`. The `waybar-scripts` derivation puts the wrapped binary into `$out/bin/`, which Home Manager installs into the user's profile path. Confirm at runtime with `which hypr-context-daemon`.

- [ ] **Step 2: Commit (do not enable yet — Task 5 wires it via home.nix)**

```bash
git -C /etc/nixos/home add modules/hypr-context.nix
git -C /etc/nixos/home commit -m "modules: hypr-context.nix (systemd-user service for unified publisher)"
```

---

## Task 5: Wire `hypr-context` into `home.nix` and rebuild

**Files:**
- Modify: `/etc/nixos/home.nix` (add module import + enable)

**Rationale:** Import the new module alongside the existing `hypr-edge-bg.nix` (which we are NOT removing yet — both daemons must coexist briefly for diff verification).

- [ ] **Step 1: Inspect current imports section**

```bash
grep -n 'imports\|hypr-edge-bg\|home/modules/' /etc/nixos/home.nix | head -20
```

Note where module imports live (around line 14).

- [ ] **Step 2: Add the import**

In `/etc/nixos/home.nix`, find the line:

```nix
    ./home/modules/hypr-edge-bg.nix
```

Add directly after it (preserving the existing line for now):

```nix
    ./home/modules/hypr-context.nix
```

And in the same file, in the module-config section (find any `services.X.enable = true;` block, typically near the bottom), add:

```nix
  services.hyprContext.enable = true;
```

- [ ] **Step 3: Rebuild**

```bash
sudo nixos-rebuild switch
```

Expected: build succeeds, no errors. If shellcheck fails inside `waybar-scripts`, revisit Task 2 Step 2.

- [ ] **Step 4: Verify the service started**

```bash
systemctl --user status waybar-hypr-context-daemon.service --no-pager | head -15
which hypr-context-daemon
```

Expected: service active (running); `which` returns a path in `/etc/profiles/per-user/<user>/bin/`.

- [ ] **Step 5: Verify the snapshot is being written**

```bash
jq . /tmp/waybar-cache/hypr-context.json | head -30
```

Expected: valid JSON with `monitor_focused`, `monitors`, `workspace`, `focused`. Trigger a change (focus another window) and re-run — fields should update.

- [ ] **Step 6: Commit**

```bash
git -C /etc/nixos/home add home.nix
git -C /etc/nixos/home commit -m "home.nix: enable hypr-context (alongside legacy workspace-daemon for diff)"
```

---

## Task 6: Diff verification — both publishers writing identical pill caches

**Files:** none modified — verification only.

**Rationale:** Both `workspace-daemon` (old) and `hypr-context-daemon` (new) are writing to `/tmp/waybar-cache/`. The later-running daemon's `mv -f` wins per cache file, but the content must be identical. Verify before disabling the old one.

- [ ] **Step 1: Watch both daemons for 60s, capture state**

Trigger some workspace activity (switch workspaces, focus different windows, open and close a window) for ~30 s. Then:

```bash
mkdir -p /tmp/hypr-context-newcheck
for f in /tmp/waybar-cache/ws-current /tmp/waybar-cache/ws-{1..9} /tmp/waybar-cache/window /tmp/waybar-cache/has-window /tmp/waybar-cache/win-{close,minimize,swap-right,move-trigger,move-new} /tmp/waybar-cache/win-move-{1..9}; do
  [ -r "$f" ] && cp "$f" "/tmp/hypr-context-newcheck/$(basename "$f").post"
done
diff <(cd /tmp/hypr-context-baseline && ls | sort) <(cd /tmp/hypr-context-newcheck && ls -1 | sed 's/\.post$/.pre/' | sort)
```

Expected: empty diff (same file set).

- [ ] **Step 2: Spot-check content shapes**

```bash
for n in ws-current ws-1 window has-window win-close win-move-1; do
  echo "=== $n ==="
  cat "/tmp/waybar-cache/$n" 2>/dev/null
  echo
done
```

Expected: every JSON has `text` + `class` arrays. `class` is an ARRAY not a string (per the GTK 3 hazard in the skill).

- [ ] **Step 3: Verify waybar is rendering correctly (visual)**

Eyeball the bar. Switch workspaces. Confirm:
- Current WS pill shows the right number with `opt-plus opt-swap` look (the canonical `+` swap face on hover).
- Inactive WS pills appear for occupied non-current workspaces.
- Empty WS pills collapse to zero presence.
- `window` pill shows focused-window class.
- `win-close/minimize/...` pills appear when a window exists, collapse otherwise.

If anything renders wrong: STOP. Re-read Task 2's pill emission code against the JSON shapes in the spec's snapshot section. Likely culprit: misplaced class token or wrong pill type (`opt-pill` vs `opt-pill-child`).

- [ ] **Step 4: No commit (verification only)**

---

## Task 7: Disable the legacy `workspace-daemon.service`

**Files:** none modified — runtime change only (file deletion is later in Task 13).

**Rationale:** The new daemon owns the cache files. The legacy daemon is now redundant.

- [ ] **Step 1: Disable**

```bash
systemctl --user disable --now waybar-workspace-daemon.service
systemctl --user status waybar-workspace-daemon.service --no-pager | head -5
```

Expected: status shows `inactive (dead)` and `disabled`.

- [ ] **Step 2: Verify cache still updates**

Switch workspaces a few times.

```bash
stat -c '%Y' /tmp/waybar-cache/ws-current
sleep 2
hyprctl dispatch workspace +1 >/dev/null
sleep 1
stat -c '%Y' /tmp/waybar-cache/ws-current
hyprctl dispatch workspace -1 >/dev/null
```

Expected: mtime advances after the workspace switch.

- [ ] **Step 3: No commit (state change only; file removals come in Task 13)**

---

## Task 8: Write `hypr-bg-daemon.sh`

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/hypr-bg-daemon.sh`

**Rationale:** The new bg daemon. Subscribes to the snapshot file via inotify and to the waypaper config. Evaluates the geometric rule. Paints color (and writes `/tmp/glass-mode`) or restores waypaper image.

- [ ] **Step 1: Create the file**

```bash
#!/usr/bin/env bash
# hypr-bg-daemon — single-rule background painter.
#
# Trigger rule (paint solid color of focused-window top-edge sample):
#   workspace.tiled_count == 1
#   workspace.floating_count == 0
#   workspace.gaps_out == 0
#   focused != null AND not floating AND not pseudo
#   focused.y == monitor.y AND focused spans monitor width
# Else: restore waypaper image.
#
# Also owns /tmp/glass-mode (replacing glass-text-daemon).
# Source: docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
set -euo pipefail

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../../scripts/lib/colors.sh
. /etc/nixos/home/scripts/lib/colors.sh

PILL_CACHE_DIR=${PILL_CACHE_DIR:-/tmp/waybar-cache}
SNAPSHOT="$PILL_CACHE_DIR/hypr-context.json"
GLASS_MODE_FILE=${GLASS_MODE_FILE:-/tmp/glass-mode}
BG_CACHE_DIR=${BG_CACHE_DIR:-/tmp/hypr-edge-bg}
WAYPAPER_CFG=${WAYPAPER_CFG:-$HOME/.config/waypaper/config.ini}
WAYPAPER_LUM_CACHE="$BG_CACHE_DIR/waypaper-luminance.json"

SAMPLE_H=${HYPR_BG_SAMPLE_H:-2}
SAMPLE_W_MAX=${HYPR_BG_SAMPLE_W_MAX:-300}
DIST_THRESHOLD=${HYPR_BG_DIST_THRESHOLD:-25}
CACHE_SIZE=${HYPR_BG_CACHE_SIZE:-16}
GLASS_THRESHOLD=128

mkdir -p "$BG_CACHE_DIR"

LAST_APPLIED=""     # "image:/path" or "color-img:/path"
LAST_HEX=""
LAST_MODE=""
WAYPAPER_IMG=""
WAYPAPER_LUM=""
MON_NAMES=""
LAST_MONITORS=""

# ----- helpers (lifted verbatim from hypr-edge-bg + glass-text-daemon) -----

ensure_solid_png() {
    local hex=$1
    local f="$BG_CACHE_DIR/bg_${hex}.png"
    if [[ ! -s $f ]]; then
        magick -size 100x100 "xc:#$hex" "$f"
    fi
    touch "$f"
    printf '%s' "$f"
}

prune_cache() {
    local count
    count=$(find "$BG_CACHE_DIR" -maxdepth 1 -type f -name 'bg_*.png' | wc -l)
    if ((count <= CACHE_SIZE)); then return; fi
    local extra=$((count - CACHE_SIZE))
    find "$BG_CACHE_DIR" -maxdepth 1 -type f -name 'bg_*.png' -printf '%T@ %p\n' |
        sort -n | head -n "$extra" | awk '{ $1=""; sub(/^ /,""); print }' |
        xargs -r rm -f
}

sample_top_edge() {
    local x=$1 y=$2 w=$3
    local sw=$((w < SAMPLE_W_MAX ? w : SAMPLE_W_MAX))
    ((sw < 1)) && sw=1
    local sx=$((x + (w - sw) / 2))
    local geom="${sx},${y} ${sw}x${SAMPLE_H}"
    grim -g "$geom" - 2>/dev/null |
        magick - -depth 8 -resize '1x1!' txt:- 2>/dev/null |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^#[0-9A-Fa-f]+$/) {
                    sub(/^#/, "", $i)
                    print substr($i, 1, 6)
                    exit
                }
            }
        }'
}

set_glass_mode() {
    local mode=$1
    [[ $mode == "$LAST_MODE" ]] && return 0
    printf '%s' "$mode" >"$GLASS_MODE_FILE.tmp" && mv -f "$GLASS_MODE_FILE.tmp" "$GLASS_MODE_FILE"
    LAST_MODE=$mode
}

apply_image() {
    local img=$1 monitors_json=$2 identity=$3
    [[ $identity == "$LAST_APPLIED" ]] && return 0
    if [[ $monitors_json != "$LAST_MONITORS" || -z $MON_NAMES ]]; then
        MON_NAMES=$(jq -r '.[].name' <<<"$monitors_json")
        LAST_MONITORS="$monitors_json"
    fi
    hyprctl hyprpaper preload "$img" >/dev/null 2>&1 || true
    local mon
    while IFS= read -r mon; do
        [[ -z $mon ]] && continue
        hyprctl hyprpaper wallpaper "$mon,$img" >/dev/null 2>&1 || true
    done <<<"$MON_NAMES"
    if [[ -n $LAST_APPLIED && $LAST_APPLIED != "$identity" ]]; then
        local prev=${LAST_APPLIED#image:}
        prev=${prev#color-img:}
        if [[ $prev != "$img" && $prev != "$WAYPAPER_IMG" ]]; then
            hyprctl hyprpaper unload "$prev" >/dev/null 2>&1 || true
        fi
    fi
    LAST_APPLIED="$identity"
}

apply_color() {
    local hex=$1 monitors_json=$2
    [[ $hex == "$LAST_HEX" ]] && return 0
    if [[ -n $LAST_HEX ]]; then
        local r1 g1 b1 r2 g2 b2 d
        read -r r1 g1 b1 < <(hex_to_rgb "$hex")
        read -r r2 g2 b2 < <(hex_to_rgb "$LAST_HEX")
        d=$(rgb_dist_sq "$r1" "$g1" "$b1" "$r2" "$g2" "$b2")
        if ((d < DIST_THRESHOLD)); then return 0; fi
    fi
    local img lum mode
    img=$(ensure_solid_png "$hex")
    apply_image "$img" "$monitors_json" "color-img:$img"
    LAST_HEX="$hex"
    lum=$(hex_luminance "$hex")
    if ((lum > GLASS_THRESHOLD)); then mode="light"; else mode="dark"; fi
    set_glass_mode "$mode"
    prune_cache
}

apply_waypaper() {
    local monitors_json=$1
    [[ -z $WAYPAPER_IMG || ! -r $WAYPAPER_IMG ]] && return 0
    apply_image "$WAYPAPER_IMG" "$monitors_json" "image:$WAYPAPER_IMG"
    LAST_HEX=""
    [[ -n $WAYPAPER_LUM ]] && {
        local mode
        if ((WAYPAPER_LUM > GLASS_THRESHOLD)); then mode="light"; else mode="dark"; fi
        set_glass_mode "$mode"
    }
}

# ----- waypaper config tracking -----

read_waypaper_config() {
    # Extract `wallpaper = /path/to/image` (waypaper writes ini format).
    local img
    img=$(grep -E '^\s*wallpaper\s*=' "$WAYPAPER_CFG" 2>/dev/null | sed -E 's/^\s*wallpaper\s*=\s*//' | head -1)
    img=${img//\"/}
    img=${img%$'\r'}
    if [[ -n $img && $img != "$WAYPAPER_IMG" ]]; then
        WAYPAPER_IMG=$img
        compute_waypaper_luminance
    fi
}

compute_waypaper_luminance() {
    [[ -z $WAYPAPER_IMG || ! -r $WAYPAPER_IMG ]] && { WAYPAPER_LUM=""; return; }
    local hex
    hex=$(magick "$WAYPAPER_IMG" -depth 8 -resize '1x1!' txt:- 2>/dev/null |
          awk '{ for (i=1;i<=NF;i++) if ($i ~ /^#[0-9A-Fa-f]+$/) { sub(/^#/,"",$i); print substr($i,1,6); exit } }')
    [[ -z $hex ]] && { WAYPAPER_LUM=""; return; }
    WAYPAPER_LUM=$(hex_luminance "$hex")
    # Cache for warm-start (optional).
    printf '{"img":"%s","hex":"%s","lum":%s}\n' "$WAYPAPER_IMG" "$hex" "$WAYPAPER_LUM" \
        >"$WAYPAPER_LUM_CACHE.tmp" && mv -f "$WAYPAPER_LUM_CACHE.tmp" "$WAYPAPER_LUM_CACHE"
}

# ----- rule evaluation + dispatch -----

evaluate_and_apply() {
    [[ -r $SNAPSHOT ]] || return 0
    local snap
    snap=$(cat "$SNAPSHOT" 2>/dev/null) || return 0

    # Rule = 4 state checks (no geometry — Hyprland reports absolute coords
    # which would require knowing waybar's reserved zone; layout guarantees
    # a single tiled non-floating non-pseudo window with gaps_out=0 fills
    # the usable area regardless).
    local vals
    vals=$(jq -r '
        [
          .workspace.tiled_count,
          .workspace.floating_count,
          .workspace.gaps_out,
          (.focused == null),
          (if .focused == null then "false" else (.focused.floating | tostring) end),
          (if .focused == null then "false" else (.focused.pseudo | tostring) end),
          (if .focused == null then 0 else .focused.x end),
          (if .focused == null then 0 else .focused.y end),
          (if .focused == null then 0 else .focused.w end)
        ] | @tsv
    ' <<<"$snap" 2>/dev/null) || return 0

    local tc fc go fnull ffloat fpseudo fx fy fw
    IFS=$'\t' read -r tc fc go fnull ffloat fpseudo fx fy fw <<<"$vals"

    # apply_image only needs monitor names — keep this minimal.
    local monitors_json
    monitors_json=$(jq -c '.monitors | map({name})' <<<"$snap")

    local fire=1
    [[ $fnull == "true" ]] && fire=0
    [[ $tc -ne 1 ]] && fire=0
    [[ $fc -ne 0 ]] && fire=0
    [[ $go -ne 0 ]] && fire=0
    [[ $ffloat != "false" ]] && fire=0
    [[ $fpseudo != "false" ]] && fire=0

    if (( fire )); then
        local hex
        hex=$(sample_top_edge "$fx" "$fy" "$fw")
        if [[ -n $hex ]]; then
            apply_color "$hex" "$monitors_json"
        fi
    else
        apply_waypaper "$monitors_json"
    fi
}

# ----- main loop -----

# Seed waypaper info.
read_waypaper_config
# Seed first evaluation.
evaluate_and_apply

# Watch snapshot file + waypaper config for changes.
inotifywait -m -q \
    --format '%w%f' \
    -e close_write,moved_to \
    "$PILL_CACHE_DIR" "$(dirname "$WAYPAPER_CFG")" 2>/dev/null |
while IFS= read -r path; do
    case "$path" in
        "$SNAPSHOT")
            evaluate_and_apply
            ;;
        "$WAYPAPER_CFG")
            read_waypaper_config
            evaluate_and_apply
            ;;
    esac
done
```

- [ ] **Step 2: Verify shellcheck passes**

```bash
shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/hypr-bg-daemon.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git -C /etc/nixos/home add waybar/scripts/hypr-bg-daemon.sh
git -C /etc/nixos/home commit -m "waybar: hypr-bg-daemon (single-rule painter, owns glass-mode)"
```

---

## Task 9: Add `hypr-bg-daemon` to the `waybar-scripts` derivation

**Files:** none modified — `*.sh` glob already covers it.

- [ ] **Step 1: Confirm covered by glob**

The install loop and shellcheck both use `*.sh` for `.sh`-suffixed scripts. `hypr-bg-daemon.sh` matches. No edit needed.

- [ ] **Step 2: Skip (no edit; no commit)**

---

## Task 10: Write `modules/hypr-bg.nix`

**Files:**
- Create: `/etc/nixos/home/modules/hypr-bg.nix`

- [ ] **Step 1: Create the module**

```nix
# Hypr-bg daemon — single-rule background painter, owns /tmp/glass-mode.
# Source: waybar/scripts/hypr-bg-daemon.sh (bundled into waybar-scripts).
# See docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
{ config, lib, pkgs, ... }:

let
  cfg = config.services.hyprBg;
in
{
  options.services.hyprBg = {
    enable = lib.mkEnableOption "Hyprland single-rule background painter";

    sampleHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Pixels of vertical strip sampled from the window's top edge.";
    };

    sampleWidthMax = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Max pixels of window width to sample (centered).";
    };

    distanceThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Squared-RGB difference below which color updates are skipped.";
    };

    cacheSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = "Max retained solid-color PNGs in /tmp/hypr-edge-bg.";
    };

    waypaperConfigPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/waypaper/config.ini";
      description = "Path to waypaper config; watched for wallpaper changes.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.waybar-hypr-bg-daemon = {
      Unit = {
        Description = "Hyprland single-rule background painter + glass-mode owner";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" "waybar-hypr-context-daemon.service" "hyprpaper.service" ];
        Requires = [ "waybar-hypr-context-daemon.service" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "/etc/profiles/per-user/${config.home.username}/bin/hypr-bg-daemon";
        Restart = "always";
        RestartSec = 1;
        StartLimitBurst = 20;
        StartLimitIntervalSec = 300;
        Environment = [
          "HYPR_BG_SAMPLE_H=${toString cfg.sampleHeight}"
          "HYPR_BG_SAMPLE_W_MAX=${toString cfg.sampleWidthMax}"
          "HYPR_BG_DIST_THRESHOLD=${toString cfg.distanceThreshold}"
          "HYPR_BG_CACHE_SIZE=${toString cfg.cacheSize}"
          "WAYPAPER_CFG=${cfg.waypaperConfigPath}"
        ];
      };
    };
  };
}
```

- [ ] **Step 2: Commit**

```bash
git -C /etc/nixos/home add modules/hypr-bg.nix
git -C /etc/nixos/home commit -m "modules: hypr-bg.nix (single-rule painter, owns glass-mode)"
```

---

## Task 11: Wire `hypr-bg` into `home.nix` and rebuild

**Files:**
- Modify: `/etc/nixos/home.nix` (add import + enable)

- [ ] **Step 1: Add the import + enable**

In `/etc/nixos/home.nix`, alongside the `./home/modules/hypr-context.nix` line added in Task 5, add:

```nix
    ./home/modules/hypr-bg.nix
```

And add to the config section:

```nix
  services.hyprBg.enable = true;
```

- [ ] **Step 2: Rebuild**

```bash
sudo nixos-rebuild switch
```

Expected: build succeeds.

- [ ] **Step 3: Verify the service is up**

```bash
systemctl --user status waybar-hypr-bg-daemon.service --no-pager | head -15
```

Expected: active (running). If failed, `journalctl --user -u waybar-hypr-bg-daemon -n 50` for diagnostics.

- [ ] **Step 4: Verify the rule fires correctly**

Set up a workspace with one tiled window covering the screen (e.g., open one terminal and ensure `gaps_out = 0` in your Hyprland config — temporarily override if needed):

```bash
hyprctl keyword general:gaps_out 0
# Open a single terminal, focus it, make sure no other windows on the WS.
sleep 1
cat /tmp/glass-mode
journalctl --user -u waybar-hypr-bg-daemon -n 5 --no-pager
ls -lt /tmp/hypr-edge-bg/bg_*.png | head -3
```

Expected: glass-mode contains `dark` or `light` (depending on terminal color); a new `bg_<hex>.png` exists. The bar's edge color matches the terminal's top edge.

Then add a second window OR set gaps_out > 0:

```bash
hyprctl keyword general:gaps_out 8
sleep 2
ls -lt /tmp/hypr-edge-bg/bg_*.png | head -3
```

Expected: hyprpaper now displays the waypaper image (the bar's edge shows wallpaper). `/tmp/glass-mode` reflects the waypaper's luminance.

Restore your normal gaps_out value before continuing.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add home.nix
git -C /etc/nixos/home commit -m "home.nix: enable hypr-bg (alongside legacy hypr-edge-bg for cutover)"
```

---

## Task 12: Disable legacy `hypr-edge-bg`, `hypr-activities`, `glass-text-daemon`

**Files:** none modified — runtime change only.

**Rationale:** Two bg daemons running simultaneously will fight over `hyprpaper`. Keep this window short — the new daemon is verified working in Task 11. Disable the legacy stack in one step.

- [ ] **Step 1: Disable all three**

```bash
systemctl --user disable --now hypr-edge-bg.service hypr-activities.service waybar-glass-text-daemon.service
systemctl --user status hypr-edge-bg.service hypr-activities.service waybar-glass-text-daemon.service --no-pager 2>&1 | grep -E '(Active|Loaded):' | head -10
```

Expected: all three are `inactive (dead)` and `disabled`. (Some unit names may differ slightly — adjust based on `systemctl --user list-unit-files | grep -E 'hypr|glass'`.)

- [ ] **Step 2: Verify glass-mode still flips correctly**

Switch wallpaper to a clearly light image via waypaper, then back to a dark one:

```bash
sleep 2; cat /tmp/glass-mode  # after light wallpaper
# Switch back
sleep 2; cat /tmp/glass-mode  # after dark wallpaper
```

Expected: glass-mode flips between `light` and `dark` correctly. Pills still render readable text in both modes.

- [ ] **Step 3: Verify bg rule still works**

Repeat Task 11 Step 4 (rule-fire and rule-not-fire scenarios). Expected: identical behavior.

- [ ] **Step 4: No commit (state change only)**

---

## Task 13: Delete obsolete source files

**Files (delete):**
- `/etc/nixos/home/scripts/hypr-dive`
- `/etc/nixos/home/scripts/hypr-edge-bg`
- `/etc/nixos/home/scripts/hypr-activities`
- `/etc/nixos/home/waybar/scripts/workspace-daemon.sh`
- `/etc/nixos/home/waybar/scripts/glass-text-daemon.sh`
- `/etc/nixos/home/modules/hypr-edge-bg.nix`
- `/etc/nixos/home/tests/hypr-edge-bg-test.nix`

- [ ] **Step 1: Delete the files (via git rm so it's tracked)**

```bash
cd /etc/nixos/home
git rm scripts/hypr-dive scripts/hypr-edge-bg scripts/hypr-activities \
       waybar/scripts/workspace-daemon.sh waybar/scripts/glass-text-daemon.sh \
       modules/hypr-edge-bg.nix \
       tests/hypr-edge-bg-test.nix
```

- [ ] **Step 2: Commit**

```bash
git -C /etc/nixos/home commit -m "remove legacy hypr-edge-bg stack (dive, activities, workspace-daemon, glass-text)"
```

---

## Task 14: Remove `hypr-edge-bg.nix` import from `home.nix`

**Files:**
- Modify: `/etc/nixos/home.nix` (remove one line + the corresponding `services.hyprEdgeBg.enable`)

- [ ] **Step 1: Remove the import**

In `/etc/nixos/home.nix`, delete the line:

```nix
    ./home/modules/hypr-edge-bg.nix
```

And delete any `services.hyprEdgeBg.enable = true;` line (if present in the config section).

- [ ] **Step 2: Rebuild**

```bash
sudo nixos-rebuild switch
```

Expected: build succeeds. Module removal does not affect the new daemons.

- [ ] **Step 3: Commit**

```bash
git -C /etc/nixos/home add home.nix
git -C /etc/nixos/home commit -m "home.nix: drop legacy hypr-edge-bg module import"
```

---

## Task 15: Update `standard-os-resume-user.nix` daemon list

**Files:**
- Modify: `/etc/nixos/home/modules/standard-os-resume-user.nix` (line 79)

**Rationale:** The resume script lists user daemons to restart after suspend. Update to reflect the new daemon names. (The script restarts by basename of `.sh` file or service unit — match the local convention.)

- [ ] **Step 1: Inspect the current line**

```bash
sed -n '75,85p' /etc/nixos/home/modules/standard-os-resume-user.nix
```

Note the exact construct that lists `workspace-daemon.sh glass-text-daemon.sh` — it may iterate `.service` names or basenames.

- [ ] **Step 2: Replace daemon list**

Change:

```bash
for d in workspace-daemon.sh glass-text-daemon.sh; do
```

To:

```bash
for d in waybar-hypr-context-daemon.service waybar-hypr-bg-daemon.service; do
```

**Note:** if the surrounding script uses basename-based `pkill` rather than `systemctl --user restart`, adjust to whichever form fits the existing pattern. Read 30 lines around line 79 before editing.

- [ ] **Step 3: Rebuild**

```bash
sudo nixos-rebuild switch
```

- [ ] **Step 4: Test resume behavior (best-effort — actual suspend is destructive)**

Manually trigger the resume script to verify both new daemons restart cleanly:

```bash
systemctl --user restart waybar-hypr-context-daemon.service waybar-hypr-bg-daemon.service
sleep 2
systemctl --user is-active waybar-hypr-context-daemon.service waybar-hypr-bg-daemon.service
```

Expected: both `active`.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add modules/standard-os-resume-user.nix
git -C /etc/nixos/home commit -m "standard-os-resume-user: restart new hypr-context + hypr-bg daemons"
```

---

## Task 16: Reboot + final acceptance

**Files:** none — verification only.

**Rationale:** Per memory ([[feedback_nixos_rebuild_switch_not_test]]), `switch` activates units in RAM AND updates the boot symlink; only a reboot proves the new units survive a fresh boot. Critical for daemons that auto-start under `graphical-session.target`.

- [ ] **Step 1: Reboot**

Save any in-flight work. Then:

```bash
sudo reboot
```

- [ ] **Step 2: Post-reboot — verify all daemons came up**

```bash
systemctl --user is-active waybar.service waybar-hypr-context-daemon.service waybar-hypr-bg-daemon.service
```

Expected: three `active` lines.

- [ ] **Step 3: Verify no zombie services from the legacy stack**

```bash
systemctl --user list-units --all | grep -E 'hypr-(dive|edge-bg|activities)|glass-text|workspace-daemon'
```

Expected: empty output (no surviving units).

- [ ] **Step 4: Verify the bar renders correctly + glass-mode behavior**

Eyeball the bar through one light/dark wallpaper toggle and one rule-fire/rule-break workspace transition. Confirm:
- All waybar pills render (workspaces, window, win-action cluster).
- `/tmp/glass-mode` flips correctly when wallpaper changes.
- Bg color matches focused window when the trigger conditions hold; restores waypaper image otherwise.

- [ ] **Step 5: Verify CPU baseline**

```bash
top -b -n 1 | head -20
```

Expected: combined CPU% of `hypr-context-daemon` + `hypr-bg-daemon` at idle ≤ baseline of old `workspace-daemon` + `hypr-activities` + `hypr-edge-bg` + `glass-text-daemon`.

- [ ] **Step 6: No commit (verification only)**

---

## Task 17: Update `waybar/ARCHITECTURE.md` (daemon registry + sections)

**Files:**
- Modify: `/etc/nixos/home/waybar/ARCHITECTURE.md` — Context-daemon-registry section, Hyprland-event-subscription section, Migration-status section.

- [ ] **Step 1: Update the "Live daemons" table (~line 65)**

Replace the `workspace-daemon` row with:

```markdown
| **hypr-context-daemon** | `waybar-hypr-context-daemon.service` | `waybar/scripts/hypr-context-daemon.sh` (bundled in `waybar-scripts`) | `/tmp/waybar-cache/{ws-current, ws-1..9, window, has-window, win-close, win-minimize, win-swap-right, win-move-trigger, win-move-1..9, win-move-new, hypr-context.json}` | RTMIN+10 (per-pill caches only — snapshot consumers use inotify) |
```

Replace the `glass-text-daemon` row with:

```markdown
| **hypr-bg-daemon** | `waybar-hypr-bg-daemon.service` | `waybar/scripts/hypr-bg-daemon.sh` (bundled in `waybar-scripts`) | `/tmp/glass-mode` (light\|dark), `/tmp/hypr-edge-bg/bg_<hex>.png` (cache) | none — inotify-driven from `hypr-context.json` and waypaper config |
```

- [ ] **Step 2: Update the "Hyprland event subscription" section (~line 182)**

The section currently says "when we tighten this, the move is to subscribe." Replace the second paragraph (around line 199) with:

```markdown
The `hypr-context-daemon` subscribes to socket2 directly with the 16 ms
inline-debounce pattern (originally from `hypr-activities`). The earlier
`workspace-daemon` polling design and the separate `hypr-activities` publisher
were unified by `docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md`.
```

- [ ] **Step 3: Update the "Migration status" section (lines 242+)**

- Add new ✓ entry: `✓ Hypr-context unification — workspace-daemon + hypr-activities merged into hypr-context-daemon (socket2 event-driven)`
- Add new ✓ entry: `✓ Composite-module pattern with inotify on /tmp/waybar-cache/ — hypr-bg-daemon is the reference impl`
- Change the entry `✓ Glass-text adaptive text` description to add: `(/tmp/glass-mode now written by hypr-bg-daemon — glass-text-daemon was retired 2026-06-13)`

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add waybar/ARCHITECTURE.md
git -C /etc/nixos/home commit -m "ARCHITECTURE: hypr-context unification — registry, event-subscription, migration status"
```

---

## Task 18: Update `waybar/CLAUDE.md` (glass-mode contract paragraph)

**Files:**
- Modify: `/etc/nixos/home/waybar/CLAUDE.md` — wherever it names `glass-text-daemon` as the writer of `/tmp/glass-mode`.

- [ ] **Step 1: Find references to glass-text-daemon**

```bash
grep -n "glass-text-daemon\|glass-text" /etc/nixos/home/waybar/CLAUDE.md
```

For each hit, change the writer attribution from `glass-text-daemon` to `hypr-bg-daemon`. The contract (light|dark file, default dark when missing, atomic write) is unchanged — only the writer name moves.

- [ ] **Step 2: Update the cross-project hazard (line ~503 per skill notes)**

Replace the warning about "unloading the waypaper image breaks glass-text-daemon's luminance tracking" with one that reflects the new world:

```markdown
- The `hypr-bg-daemon` owns `/tmp/glass-mode`. When it restores the waypaper
  image, it reads the cached waypaper luminance (`waypaper-luminance.json`)
  rather than re-sampling. If the waypaper-luminance cache is missing on
  startup, the daemon recomputes from the current `WAYPAPER_IMG`.
```

- [ ] **Step 3: Commit**

```bash
git -C /etc/nixos/home add waybar/CLAUDE.md
git -C /etc/nixos/home commit -m "CLAUDE: hypr-bg-daemon owns /tmp/glass-mode (was glass-text-daemon)"
```

---

## Task 19: Update `waybar/TODO.md` (move two items NEXT → DONE)

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md` — NEXT and DONE sections.

- [ ] **Step 1: Move "Workspace-daemon migration to Nix" from NEXT to DONE**

Locate the NEXT entry (per Pre-flight read, around line 71):

```markdown
- **Workspace-daemon migration to Nix** — moves the daemon into the OPTIONS
  module under `pkgs.writeShellScriptBin` with proper PATH curation.
```

Delete from NEXT. Add to DONE (top of DONE list):

```markdown
- **Hypr-context unification (2026-06-13)** — absorbed workspace-daemon-to-Nix
  migration. workspace-daemon + hypr-activities merged into
  `hypr-context-daemon` (socket2 event-driven, bundled via `waybar-scripts`).
  Hint: spec at `docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md`,
  plan at `docs/superpowers/plans/2026-06-13-hypr-context-unification.md`.
```

- [ ] **Step 2: Move "Composite-module pattern" from NEXT to DONE**

Delete from NEXT:

```markdown
- **Composite-module pattern** — inotify on `/tmp/waybar-cache/` for pills
  that subscribe to multiple upstream channels. Reference impl:
  `/home/max/mpris-waybar/`.
```

Add to DONE:

```markdown
- **Composite-module pattern (2026-06-13)** — `hypr-bg-daemon` is the
  reference impl: `inotifywait` on `/tmp/waybar-cache/` filtered by basename,
  recomputes on `hypr-context.json` or waypaper-config change. Hint: see the
  `inotifywait -m -q --format '%w%f' -e close_write,moved_to ...` loop in
  `waybar/scripts/hypr-bg-daemon.sh`.
```

- [ ] **Step 3: Commit**

```bash
git -C /etc/nixos/home add waybar/TODO.md
git -C /etc/nixos/home commit -m "TODO: workspace-daemon-to-Nix + composite-module → DONE (absorbed by unification)"
```

---

## Post-completion

- [ ] **Push all commits**

```bash
git -C /etc/nixos/home push origin main
```

- [ ] **Final acceptance audit** (matches spec's "Acceptance criteria")

```bash
# One socket2 subscription only
ss -xp 2>/dev/null | grep -c socket2  # expect 1

# Snapshot is being written
test -f /tmp/waybar-cache/hypr-context.json && jq -e '.monitor_focused' /tmp/waybar-cache/hypr-context.json >/dev/null && echo OK

# No legacy services
systemctl --user list-units --all 2>/dev/null | grep -cE 'hypr-(dive|edge-bg|activities)|glass-text|workspace-daemon'  # expect 0

# Glass-mode still flips
cat /tmp/glass-mode
```

Expected: 1 / OK / 0 / `light` or `dark`.

---

## Notes for future plan readers

- **`ExecStart` paths** assume the user is `max` (`/etc/profiles/per-user/max/bin/...`). If multi-user, parameterize via `config.home.username` (already done in the `hypr-bg.nix` Nix expression).
- **Test fixture** (`tests/hypr-bg-test.nix`) is intentionally not part of this plan. Spec defers it. Add after the daemon stabilises.
- **Multi-monitor independent bg colors** are explicitly out of scope. The current `apply_color` paints the same color on every monitor (preserved from `hypr-edge-bg` behavior). Per-monitor bg is a follow-up plan.
- **If something breaks mid-cutover** (e.g., Task 12 leaves you without a working bar), restart the legacy services: `systemctl --user enable --now hypr-edge-bg.service hypr-activities.service waybar-workspace-daemon.service waybar-glass-text-daemon.service`. They are still installed by Nix until Task 14 (the `hypr-edge-bg.nix` import removal). The Nix module only goes away once you delete the import.
