# Brightness daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a Wave-3-pattern brightness-daemon (RTMIN+21) that owns `/tmp/waybar-cache/brightness.json`, replacing the existing direct-`brightnessctl` polling on the canvas DISPLAY slider and the ad-hoc `~/.config/hypr/scripts/brightness.sh` shim.

**Architecture:** One daemon + one wrapper + four small edits. Daemon polls `/sys/class/backlight/intel_backlight/{actual,max}_brightness` on a 1 s tick, dedup-emits the cache via `canvas-cache.sh`. Wrapper script (`brightnessctl-set`) is the single writer — called by both Hyprland XF86 binds and the canvas slider's `:onchange`; preserves the night-dim shader teardown. Pattern mirrors `pomodoro-daemon` / `cal-source-daemon` from Wave 3 nearly line-for-line.

**Tech Stack:** bash, brightnessctl, sysfs, jq, systemd user units, Nix (home-manager modules), eww (yuck), Hyprland (Binds.conf).

## Global Constraints

- Pattern: Wave 3 daemon-driven pill (shared `scripts/lib/canvas-cache.sh` for atomic write + dedup-signal; one writer per cache file).
- Cache path: `/tmp/waybar-cache/brightness.json`.
- Cache shape: `{pct:int, raw:int, max:int, device:"intel_backlight", updated:int}`.
- Signal: RTMIN+21 (next free per `waybar/ARCHITECTURE.md` signal table; +10..+20 taken, +21..+30 free).
- Device hardcoded to `intel_backlight` (laptop only, no DDC/CI).
- Steps: `MIN=2, MAX=100, STEP=5` — verbatim from existing `brightness.sh`.
- Night-dim teardown side-effect lives in the wrapper (user-initiated only), not the daemon.
- TDD: write failing test → see RED → implement → see GREEN → commit.
- Always `sudo nixos-rebuild switch` to deploy (never `test` — per StandardOS rebuild rule).
- After implementation lands, the wrapper deletes `~/.config/hypr/scripts/brightness.sh` in the same commit.
- `home.nix` (outside the `/etc/nixos/home` git repo) gets the new import + `services.brightnessDaemon.enable = true;` lines; not in git, just edited.

---

## File map

| File | Action | Purpose |
|---|---|---|
| `scripts/brightness-daemon.sh` | Create | 1 s sysfs poll → cache write + RTMIN+21 dedup-signal; library mode for tests |
| `scripts/brightnessctl-set` | Create | Single writer (`up`/`down`/`set N`); replaces `~/.config/hypr/scripts/brightness.sh`; preserves night-dim teardown |
| `modules/brightness-daemon.nix` | Create | Systemd user unit (mirrors `pomodoro-daemon.nix`) |
| `tests/test_brightness_daemon.sh` | Create | TDD against `derive_brightness_json` with fixture sysfs paths |
| `hypr/modules/Binds.conf` | Modify (2 lines) | Rebind XF86MonBrightness{Up,Down} to wrapper |
| `widgets/eww/eww.yuck` | Modify (2 small edits) | `bar-display` defpoll reads cache; `:onchange` calls wrapper |
| `waybar/ARCHITECTURE.md` | Modify | New daemon-registry row + signal-table row (RTMIN+21) |
| `waybar/TODO.md` | Modify | Move NEXT entry → new DONE entry above the 2026-06-20 dimmed-rename entry |
| `~/.config/hypr/scripts/brightness.sh` | Delete (Task 5) | Logic moved verbatim to wrapper |
| `/etc/nixos/home.nix` | Modify (2 lines, outside repo) | Import + enable new service |

Tasks 1–4 are sequenced (test → daemon → wrapper → Nix wire-up). Task 5 is the canvas/hypr rewire + cleanup. Task 6 is ARCHITECTURE.md + TODO.md graduation.

---

## Task 1: Write the failing test

**Files:**
- Create: `tests/test_brightness_daemon.sh`

**Interfaces:**
- Consumes: nothing (test stubs the script under test)
- Produces: a runnable test that imports the daemon in library mode and asserts on `derive_brightness_json` outputs. Task 2 implements the function until this passes.

- [ ] **Step 1: Write the failing test**

Create `/etc/nixos/home/tests/test_brightness_daemon.sh`:

```bash
#!/usr/bin/env bash
# test_brightness_daemon — TDD for the sysfs read + JSON derive path.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/brightness-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BRIGHTNESS_DAEMON_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Fixture: a temp dir mocking /sys/class/backlight/<device>/
FAKE_DEV="$TMP/intel_backlight"
mkdir -p "$FAKE_DEV"

# Case 1: 84/1200 → pct=7
echo 1200 > "$FAKE_DEV/max_brightness"
echo 84   > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000000)
check "84/1200 pct=7"  "$(printf '%s' "$out" | jq -r .pct)"  "7"
check "84/1200 raw=84" "$(printf '%s' "$out" | jq -r .raw)"  "84"
check "84/1200 max=1200" "$(printf '%s' "$out" | jq -r .max)" "1200"
check "84/1200 device" "$(printf '%s' "$out" | jq -r .device)" "intel_backlight"
check "84/1200 updated" "$(printf '%s' "$out" | jq -r .updated)" "1782000000"

# Case 2: 600/1200 → pct=50
echo 600 > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000001)
check "600/1200 pct=50" "$(printf '%s' "$out" | jq -r .pct) " "50 "

# Case 3: 1200/1200 → pct=100
echo 1200 > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000002)
check "1200/1200 pct=100" "$(printf '%s' "$out" | jq -r .pct)" "100"

# Case 4: 0/1200 → pct=0
echo 0 > "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000003)
check "0/1200 pct=0" "$(printf '%s' "$out" | jq -r .pct)" "0"

# Case 5: missing actual_brightness → graceful null/0 (no crash)
rm -f "$FAKE_DEV/actual_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000004)
check "missing actual → pct null" "$(printf '%s' "$out" | jq -r '.pct // "null"')" "null"

# Case 6: missing max_brightness → graceful null (no division by zero)
echo 84 > "$FAKE_DEV/actual_brightness"
rm -f "$FAKE_DEV/max_brightness"
out=$(derive_brightness_json "$FAKE_DEV" intel_backlight 1782000005)
check "missing max → pct null" "$(printf '%s' "$out" | jq -r '.pct // "null"')" "null"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

Note: case 2 asserts on `"50 "` (jq -r output + trailing space marker) — that's intentional to make the assert literal-comparison-safe with whatever `jq -r` returns plus the `check` function's quoting. If `jq` strips the trailing newline, expected stays `"50"` without the space; adjust at execution time if RED for the wrong reason.

- [ ] **Step 2: Make the test runnable and run it (expect RED)**

```
chmod +x /etc/nixos/home/tests/test_brightness_daemon.sh
bash /etc/nixos/home/tests/test_brightness_daemon.sh
```

Expected: source failure (`No such file or directory` for `scripts/brightness-daemon.sh`). This is the RED gate.

- [ ] **Step 3: Commit the failing test**

```bash
cd /etc/nixos/home && git add tests/test_brightness_daemon.sh && git commit -m "brightness-daemon: failing test for derive_brightness_json (TDD red)"
```

---

## Task 2: Implement the daemon (test goes GREEN)

**Files:**
- Create: `scripts/brightness-daemon.sh`

**Interfaces:**
- Consumes: `scripts/lib/canvas-cache.sh` → `cache_signal_if_changed <cache_path> <content> <signal_int>`
- Produces:
  - Function `derive_brightness_json <sysfs_device_dir> <device_name> <unix_ts>` returning one JSON line (consumed by Task 1's test and by the main loop)
  - Long-running main loop writing `/tmp/waybar-cache/brightness.json` and firing RTMIN+21 on `pct` change
  - Library-mode hook: `BRIGHTNESS_DAEMON_LIB_ONLY=1` source skips the main loop
- The wrapper (Task 3) and the Nix module (Task 4) consume this — names must match.

- [ ] **Step 1: Implement `scripts/brightness-daemon.sh`**

Create `/etc/nixos/home/scripts/brightness-daemon.sh`:

```bash
#!/usr/bin/env bash
# brightness-daemon — sole writer of /tmp/waybar-cache/brightness.json.
#
# Reads /sys/class/backlight/intel_backlight/{actual,max}_brightness on a
# 1 s tick. Writes via canvas-cache.sh:cache_signal_if_changed so the cache
# touches AND the RTMIN+21 signal fire only when pct actually changes.
#
# Cache shape:
#   { "pct": <int 0..100|null>,
#     "raw": <int|null>,
#     "max": <int|null>,
#     "device": "intel_backlight",
#     "updated": <unix_ts> }
#
# Library mode: BRIGHTNESS_DAEMON_LIB_ONLY=1 source defines
# derive_brightness_json without entering the loop. The test (Task 1) uses
# this hook.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

DEVICE="${BRIGHTNESS_DEVICE:-intel_backlight}"
SYSFS_DIR="/sys/class/backlight/${DEVICE}"
CACHE=/tmp/waybar-cache/brightness.json
SIG=21
POLL_INTERVAL="${BRIGHTNESS_POLL_INTERVAL:-1}"
mkdir -p "$(dirname "$CACHE")"

# derive_brightness_json <sysfs_dir> <device_name> <unix_ts>
#   sysfs_dir must contain actual_brightness + max_brightness files.
#   Missing/unreadable files → pct/raw/max emit as JSON null (no crash,
#   no division-by-zero).
derive_brightness_json() {
    local dir="$1" device="$2" now="$3"
    local raw_str max_str raw max pct_arg raw_arg max_arg

    raw_str=$(cat "$dir/actual_brightness" 2>/dev/null || true)
    max_str=$(cat "$dir/max_brightness" 2>/dev/null || true)

    if [[ "$raw_str" =~ ^[0-9]+$ ]]; then raw="$raw_str"; else raw=""; fi
    if [[ "$max_str" =~ ^[0-9]+$ && "$max_str" -gt 0 ]]; then max="$max_str"; else max=""; fi

    if [[ -n "$raw" && -n "$max" ]]; then
        local pct=$(( (raw * 100 + max / 2) / max ))   # rounded
        pct_arg="--argjson pct $pct"
        raw_arg="--argjson raw $raw"
        max_arg="--argjson max $max"
    else
        pct_arg="--argjson pct null"
        raw_arg=$( [[ -n "$raw" ]] && printf -- '--argjson raw %s' "$raw" || printf -- '--argjson raw null' )
        max_arg=$( [[ -n "$max" ]] && printf -- '--argjson max %s' "$max" || printf -- '--argjson max null' )
    fi

    # shellcheck disable=SC2086
    jq -nc $pct_arg $raw_arg $max_arg \
       --arg device "$device" \
       --argjson updated "$now" \
       '{pct:$pct, raw:$raw, max:$max, device:$device, updated:$updated}'
}

[[ -n "${BRIGHTNESS_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# SIGUSR1 → bump POKE flag so the next loop iteration writes immediately
# without waiting for the sleep. The wrapper sends SIGUSR1 right after
# brightnessctl returns to push the cache forward sub-second.
POKE=0
trap 'POKE=1' USR1

while true; do
    cache_signal_if_changed "$CACHE" \
        "$(derive_brightness_json "$SYSFS_DIR" "$DEVICE" "$(date +%s)")" \
        "$SIG"
    if (( POKE )); then
        POKE=0
        continue   # skip sleep, immediate re-poll
    fi
    sleep "$POLL_INTERVAL"
done
```

- [ ] **Step 2: Make executable**

```
chmod +x /etc/nixos/home/scripts/brightness-daemon.sh
```

- [ ] **Step 3: Run the test (expect GREEN)**

```
bash /etc/nixos/home/tests/test_brightness_daemon.sh
```

Expected: all PASS. If case 2's pct assertion mis-trips due to literal trailing-space encoding, fix the test assertion (drop the trailing space) — the impl is correct.

- [ ] **Step 4: Commit the daemon implementation**

```bash
cd /etc/nixos/home && git add scripts/brightness-daemon.sh && git commit -m "brightness-daemon: sysfs poll + RTMIN+21 dedup-signal (TDD green)"
```

---

## Task 3: Wrapper script (single writer)

**Files:**
- Create: `scripts/brightnessctl-set`

**Interfaces:**
- Consumes: `brightnessctl` (in nixos PATH), `~/.config/waybar/scripts/shader-stack.sh` (existing — night-dim teardown), `/tmp/night-dim-level` (existing state file)
- Produces: A one-shot CLI. Usage:
  - `brightnessctl-set up`        — current + STEP, clamp at MAX
  - `brightnessctl-set down`      — current − STEP, clamp at MIN
  - `brightnessctl-set set N`     — set to N% directly (0..100)
  Exit 0 on success, non-zero on argument error. Side-effects: brightness changed; night-dim slot cleared if post-change pct > 2 AND `/tmp/night-dim-level` != 0; sends `kill -USR1` to the brightness-daemon PID (best-effort) so the cache catches up sub-second.

- [ ] **Step 1: Write the wrapper**

Create `/etc/nixos/home/scripts/brightnessctl-set`:

```bash
#!/usr/bin/env bash
# brightnessctl-set — single writer for brightness changes.
#
# Called by:
#   - Hyprland XF86MonBrightness{Up,Down} (see hypr/modules/Binds.conf)
#   - Canvas DISPLAY slider's :onchange (see widgets/eww/eww.yuck)
#
# Replaces ~/.config/hypr/scripts/brightness.sh (deleted in the same
# commit as this script lands). All logic preserved verbatim including
# the night-dim shader teardown that tears down the dim slot once
# brightness climbs above the 2% floor.
set -euo pipefail

DEVICE="intel_backlight"
MIN=2
MAX=100
STEP=5
NIGHT_DIM_STATE="/tmp/night-dim-level"

usage() {
    cat <<EOF >&2
usage: brightnessctl-set {up|down|set N}
  up        : current + ${STEP}%, clamp at ${MAX}%
  down      : current - ${STEP}%, clamp at ${MIN}%
  set N     : set to N% directly (${MIN}..${MAX})
EOF
    exit 2
}

# Compute target as percent of max.
cur_max=$(brightnessctl -d "$DEVICE" max)
cur_raw=$(brightnessctl -d "$DEVICE" get)
current=$(( cur_raw * 100 / cur_max ))

case "${1:-}" in
    up)
        target=$(( current + STEP ))
        (( target > MAX )) && target=$MAX
        ;;
    down)
        target=$(( current - STEP ))
        (( target < MIN )) && target=$MIN
        ;;
    set)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || usage
        target="$2"
        (( target < MIN )) && target=$MIN
        (( target > MAX )) && target=$MAX
        ;;
    *) usage ;;
esac

brightnessctl -d "$DEVICE" set "${target}%" -q

# Night-dim teardown: once brightness climbs off the 2% floor, clear the
# dim shader slot. Route through shader-stack so we only clear the dim
# slot — any active texture shader (paper/newspaper) is preserved.
# Writing decoration:screen_shader directly was the source of the
# paper-vs-dim stomping bug (see notes in old brightness.sh).
if (( target > 2 )); then
    level=$(cat "$NIGHT_DIM_STATE" 2>/dev/null || echo 0)
    if (( level > 0 )); then
        /home/max/.config/waybar/scripts/shader-stack.sh clear dim >/dev/null 2>&1 || true
        printf '0' > "$NIGHT_DIM_STATE"
        pkill -RTMIN+10 waybar 2>/dev/null || true
    fi
fi

# Nudge the brightness-daemon so the cache catches up sub-second instead
# of waiting up to a full poll interval.
pkill -USR1 -f '/scripts/brightness-daemon\.sh' 2>/dev/null || true
```

- [ ] **Step 2: Make executable**

```
chmod +x /etc/nixos/home/scripts/brightnessctl-set
```

- [ ] **Step 3: Smoke-test from CLI (daemon not running yet)**

```
/etc/nixos/home/scripts/brightnessctl-set set 50
brightnessctl -d intel_backlight get
```

Expected: second command returns roughly `600` (= 50% of 1200). Restore your preferred brightness afterward.

- [ ] **Step 4: Commit the wrapper**

```bash
cd /etc/nixos/home && git add scripts/brightnessctl-set && git commit -m "brightness: brightnessctl-set wrapper (single writer; preserves night-dim teardown)"
```

---

## Task 4: Nix module + home.nix wire-up + rebuild

**Files:**
- Create: `modules/brightness-daemon.nix`
- Modify (outside repo, not committed): `/etc/nixos/home.nix` — add import + `services.brightnessDaemon.enable = true;`

**Interfaces:**
- Consumes: `scripts/brightness-daemon.sh` (Task 2). PATH includes brightnessctl, jq, procps, coreutils, bash so the daemon's `pkill` and other tools resolve.
- Produces: `pomodoro-daemon`-shaped systemd user unit at `~/.config/systemd/user/brightness-daemon.service` after rebuild.

- [ ] **Step 1: Write the Nix module**

Create `/etc/nixos/home/modules/brightness-daemon.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.brightnessDaemon;
in
{
  options.services.brightnessDaemon.enable =
    lib.mkEnableOption "StandardOS brightness daemon (sysfs poll + RTMIN+21 cache)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.brightness-daemon = {
      Unit = {
        Description = "StandardOS brightness daemon (sysfs poll + RTMIN+21 cache)";
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.brightnessctl}/bin:${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/brightness-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
```

- [ ] **Step 2: Edit `/etc/nixos/home.nix` — add import + enable**

In the `imports = [ ... ]` block, insert one line after the `cal-source-daemon.nix` entry:

```nix
    ./home/modules/cal-source-daemon.nix
    ./home/modules/brightness-daemon.nix
    ./home/hosts/STDOS.nix
```

Below the `services.calSourceDaemon.enable = true;` line, add:

```nix
  services.calSourceDaemon.enable = true;
  services.brightnessDaemon.enable = true;
```

- [ ] **Step 3: Parse-check Nix files**

```
nix-instantiate --parse /etc/nixos/home/modules/brightness-daemon.nix > /dev/null
nix-instantiate --parse /etc/nixos/home.nix > /dev/null
```

Expected: both silent (exit 0).

- [ ] **Step 4: Rebuild + verify daemon active**

```
sudo nixos-rebuild switch
systemctl --user is-active brightness-daemon.service
jq . /tmp/waybar-cache/brightness.json
```

Expected: `active`; cache JSON populated with current brightness state (pct should match `brightnessctl -d intel_backlight get` × 100 / max, rounded).

- [ ] **Step 5: Verify wrapper → daemon round-trip**

```
/etc/nixos/home/scripts/brightnessctl-set up
sleep 0.5
jq -c '{pct, raw, updated}' /tmp/waybar-cache/brightness.json
/etc/nixos/home/scripts/brightnessctl-set down
sleep 0.5
jq -c '{pct, raw, updated}' /tmp/waybar-cache/brightness.json
```

Expected: pct moves up by ~5, then back down by ~5. `updated` timestamp advances each call. Confirms the USR1-poke shortens the read latency.

- [ ] **Step 6: Commit the Nix module**

```bash
cd /etc/nixos/home && git add modules/brightness-daemon.nix && git commit -m "brightness-daemon: nix module (systemd user unit)"
```

(home.nix lives outside `/etc/nixos/home/.git` and is not committed.)

---

## Task 5: Rewire consumers + delete the old shim

**Files:**
- Modify: `hypr/modules/Binds.conf` (lines 50-51)
- Modify: `widgets/eww/eww.yuck` (defpoll at line 99-100; onchange at line 316)
- Delete: `~/.config/hypr/scripts/brightness.sh`

**Interfaces:**
- Consumes: `/etc/nixos/home/scripts/brightnessctl-set` (Task 3); `/tmp/waybar-cache/brightness.json` (Task 2 output)
- Produces: Hyprland XF86 binds + canvas slider read/write are now both routed through the new wrapper and cache. The old `brightness.sh` is gone.

- [ ] **Step 1: Rebind Hyprland XF86 keys**

Edit `/etc/nixos/home/hypr/modules/Binds.conf` — replace lines 50-51:

```
bindel = ,XF86MonBrightnessUp,   exec, /etc/nixos/home/scripts/brightnessctl-set up
bindel = ,XF86MonBrightnessDown, exec, /etc/nixos/home/scripts/brightnessctl-set down
```

- [ ] **Step 2: Repoint canvas DISPLAY slider to the cache**

Edit `/etc/nixos/home/widgets/eww/eww.yuck`. Replace the `bar-display` defpoll (lines 99-100):

```yuck
(defpoll bar-display :interval "1s" :initial "50"
  `jq -r '.pct // 50' /tmp/waybar-cache/brightness.json 2>/dev/null || echo 50`)
```

And the slider's `:onchange` (line 316):

```yuck
                :onchange "/etc/nixos/home/scripts/brightnessctl-set set {} >/dev/null 2>&1")
```

- [ ] **Step 3: Delete the old shim**

```
rm ~/.config/hypr/scripts/brightness.sh
```

- [ ] **Step 4: Rebuild + reload Hyprland + restart canvas**

```
sudo nixos-rebuild switch
hyprctl reload
systemctl --user restart standardos-canvas.service
```

(`nixos-rebuild` deploys the new Binds.conf into the home-manager managed hypr config; per StandardOS memory, hypr config needs rebuild, not just `hyprctl reload`. The reload here is the activation step after deploy.)

- [ ] **Step 5: End-to-end smoke**

```
# baseline
jq -c '{pct}' /tmp/waybar-cache/brightness.json

# simulate the key (same exec the bind runs)
/etc/nixos/home/scripts/brightnessctl-set up && sleep 0.3 && jq -c '{pct}' /tmp/waybar-cache/brightness.json
/etc/nixos/home/scripts/brightnessctl-set down && sleep 0.3 && jq -c '{pct}' /tmp/waybar-cache/brightness.json

# the real keypress path (only if you have a free moment to press the keys —
# otherwise rely on the wrapper smoke above; the bind just calls the wrapper)
```

Open the canvas; verify the DISPLAY slider visually tracks the cache (slider thumb position matches `pct`). Slide it and verify `brightnessctl -d intel_backlight get` reflects the change.

- [ ] **Step 6: Commit the rewire**

```bash
cd /etc/nixos/home && git add hypr/modules/Binds.conf widgets/eww/eww.yuck && git commit -m "brightness: rewire hypr XF86 binds + canvas slider through brightnessctl-set + cache"
```

(The deletion of `~/.config/hypr/scripts/brightness.sh` is outside the git repo and not part of this commit. Note it in the commit body.)

Refined commit message body:

```
brightness: rewire hypr XF86 binds + canvas slider through brightnessctl-set + cache

Hyprland XF86MonBrightness{Up,Down} now exec brightnessctl-set, which is also
what the canvas DISPLAY slider's :onchange calls. The slider's defpoll now
reads /tmp/waybar-cache/brightness.json (written by brightness-daemon) instead
of forking brightnessctl every second.

Also deleted ~/.config/hypr/scripts/brightness.sh (outside this repo) — its
night-dim-teardown logic moved verbatim into brightnessctl-set.
```

---

## Task 6: ARCHITECTURE.md + TODO.md graduation

**Files:**
- Modify: `waybar/ARCHITECTURE.md` (daemon registry table + signal table)
- Modify: `waybar/TODO.md` (remove NEXT entry; add DONE entry above the 2026-06-20 dimmed-rename entry)

**Interfaces:**
- Consumes: nothing
- Produces: ARCHITECTURE.md and TODO.md reflect the shipped state. RTMIN+21 marked taken; +22..+30 still free. TODO entry for "Brightness module" moves from NEXT to DONE.

- [ ] **Step 1: Add a daemon-registry row to ARCHITECTURE.md**

Open `/etc/nixos/home/waybar/ARCHITECTURE.md`. After the `cal-source-daemon` row (the last in the "Live daemons" table), insert:

```
| **brightness-daemon** | `brightness-daemon.service` (via `home/modules/brightness-daemon.nix`) | `home/scripts/brightness-daemon.sh` | `/tmp/waybar-cache/brightness.json` (shape: `{pct, raw, max, device, updated}`) | RTMIN+21 (1 s sysfs poll of `/sys/class/backlight/intel_backlight/{actual,max}_brightness`; dedup at writer — fires only on pct change. SIGUSR1 from `brightnessctl-set` triggers immediate re-poll, dropping wrapper→cache latency below 1 s.) |
```

- [ ] **Step 2: Update the signal table**

Find the `RTMIN+21..+30` line. Replace with:

```
| RTMIN+21 | brightness-daemon (live, 2026-06-20) | Display brightness — fires on pct change only |
| RTMIN+22..+30 | **FREE** | future expansion |
```

- [ ] **Step 3: Move the TODO.md entry**

Open `/etc/nixos/home/waybar/TODO.md`.

Delete the NEXT entry (currently in the NEXT section):

```
- **Brightness module** — `XF86MonBrightnessUp/Down`, transient only (no
  permanent state). Tests the "transient with no permanent home" half of
  pillar 6.
```

Above the existing `## DONE` → `- **2026-06-20** — **\`inactive\` → \`opt-dimmed\` class rename.\*\*` block, insert this new DONE entry:

```
- **2026-06-20** — **brightness-daemon (RTMIN+21) — canvas DISPLAY slider
  + XF86 keys read/write through cache truth.** Wave-3-pattern daemon
  owns `/tmp/waybar-cache/brightness.json`; `brightnessctl-set` wrapper
  is the single writer (called by Hyprland XF86MonBrightness{Up,Down}
  binds and by the canvas slider's :onchange). Replaces direct
  `brightnessctl` forks from the canvas slider's defpoll (1 s shell-out
  → cache read) and consolidates the ad-hoc `~/.config/hypr/scripts/brightness.sh`
  shim into the wrapper. Night-dim shader teardown above the 2 % floor
  preserved verbatim — it's user-initiated, so it lives in the wrapper,
  not the daemon. Pillar 6 transient-only framing in the original NEXT
  entry was superseded by Wave 2: the canvas DISPLAY slider IS the
  permanent home now; v0 ships with no transient bar surfacing
  (keyboard discoverability remains opt-in).
  **Hint:** Daemon SIGUSR1 hook (sent by the wrapper post-`brightnessctl`)
  shortens wrapper→cache latency below 1 s without changing the steady-state
  poll interval.
  **Hint:** RTMIN+21 newly claimed from the FREE pool; signal table in
  `waybar/ARCHITECTURE.md` is now authoritative through +21; +22..+30 free.
  **Hint:** spec at
  `docs/superpowers/specs/2026-06-20-brightness-daemon-design.md`;
  plan at
  `docs/superpowers/plans/2026-06-20-brightness-daemon.md`.
```

- [ ] **Step 4: Commit the graduation**

```bash
cd /etc/nixos/home && git add waybar/ARCHITECTURE.md waybar/TODO.md && git commit -m "brightness: ARCHITECTURE.md row + RTMIN+21 signal entry + TODO graduation"
```

- [ ] **Step 5: Push (optional, user-driven)**

```
git -C /etc/nixos/home push origin main
```

---

## Self-review

**1. Spec coverage:**
- Cache shape `{pct, raw, max, device, updated}` — Task 1 (asserted) + Task 2 (implemented). ✓
- RTMIN+21 — Task 2 (signal const) + Task 4 (verify cache exists) + Task 6 (registered). ✓
- 1 s sysfs poll — Task 2. ✓
- `brightnessctl-set` wrapper with up/down/set semantics — Task 3. ✓
- Night-dim teardown preserved — Task 3 (verbatim from existing). ✓
- Hyprland rebind — Task 5 step 1. ✓
- Canvas slider rewire — Task 5 step 2. ✓
- Delete old `brightness.sh` — Task 5 step 3. ✓
- Nix module mirrors pomodoro — Task 4. ✓
- TDD against `derive_brightness_json` with fixture sysfs — Task 1. ✓
- Out-of-scope items (transient pill, multi-device, kbd_backlight) — not in any task. ✓ (intentional)

**2. Placeholder scan:**
No "TBD", "TODO", "appropriate error handling", "similar to Task N", "implement later". One in-line note in Task 1 about the case-2 trailing-space encoding is a known-risk callout, not a placeholder — the test code is fully written and the fallback ("drop the trailing space") is concrete.

**3. Type consistency:**
- `derive_brightness_json <sysfs_dir> <device_name> <unix_ts>` — same signature in Task 1 test, Task 2 impl, and Task 2's main loop call.
- Cache shape `{pct, raw, max, device, updated}` — same keys in spec, Task 1 asserts, Task 2 emit, Task 6 ARCHITECTURE row.
- Signal const `SIG=21` matches RTMIN+21 in module Description + ARCHITECTURE.md.
- Wrapper subcommands `up | down | set N` consistent across Task 3 (usage), Task 5 (Hyprland binds use `up`/`down`; canvas onchange uses `set {}`), and the spec.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-20-brightness-daemon.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task with two-stage review between tasks. Best for this plan because Tasks 1–3 and 6 are pure local edits (no shared state worth a long-context subagent), but Task 4 + 5 need sudo for the rebuild — which the executing-session has to surface back to the human anyway. Subagent-per-task keeps each commit's review surface tiny.

2. **Inline Execution** — execute the tasks in this session using `superpowers:executing-plans`. Faster if you want to watch the changes live and the session has the bandwidth.

Which approach?
