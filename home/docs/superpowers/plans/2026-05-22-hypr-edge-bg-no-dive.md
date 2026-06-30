# hypr-edge-bg: drop the dive paradigm — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the eight-row dive matrix with a single rule — paint the waypaper image everywhere except when one tiled window covers the screen with no visible gaps, in which case paint a live-sampled top-edge solid color.

**Architecture:** Two-process pipeline (`hypr-activities` publisher → `hypr-edge-bg` consumer). The publisher's snapshot shape is unchanged except for dropping `dark_theme`. The consumer's `decide()` becomes a one-branch rule using the publisher's `gaps` field directly. The `hypr-dive` CLI, the dive state file, the `SIGUSR1` toggle, the `mismatch`/`mixed` paint modes, the `default` solid color, and the `dark_theme` plumbing are all removed.

**Tech Stack:** Bash (long-running daemons, `set -uo pipefail`), Nix / NixOS home-manager modules, `jq`, `grim`, `magick` (ImageMagick), `hyprctl`, `hyprpaper`, `socat`, `inotify-tools`, `shellcheck` + `shfmt` for lint/format, `nixosTest` for integration.

**Spec:** `/etc/nixos/home/docs/superpowers/specs/2026-05-22-hypr-edge-bg-no-dive-design.md`

**Working dir convention:** All paths are absolute. `/etc/nixos` is root-owned by default on this system; the prep task takes ownership for the duration of the work, the wrap-up task restores it.

**No-git note:** `/etc/nixos` is not a git repository. The plan uses `nixos-rebuild switch --dry-build` and `nix-instantiate --parse` as checkpoint gates between tasks instead of commits. If the implementer wants commits, run `git init` inside `/etc/nixos/home/` as part of Task 0 and follow each task with `git add -A && git commit -m "<task>"`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `/etc/nixos/home/scripts/lib/colors.sh` | Shared integer color math | Trim to 3 helpers (`hex_to_rgb`, `rgb_to_hex`, `rgb_dist_sq`) |
| `/etc/nixos/home/tests/colors-test.sh` | Unit tests for color math | Drop assertions for removed helpers |
| `/etc/nixos/home/scripts/hypr-activities` | Sole reader of Hyprland/gsettings/inotify; emits JSON snapshot + AF_UNIX broadcast | Remove gsettings producer + `DARK` state + `dark_theme` field |
| `/etc/nixos/home/scripts/hypr-edge-bg` | Consumer of activities snapshot; drives `hyprpaper` per the rule | Replace `decide()` with single-rule; delete dive state + USR1 + mismatch/mixed; add `-depth 8`; gate log |
| `/etc/nixos/home/scripts/hypr-dive` | Toggle CLI | Delete |
| `/etc/nixos/home/modules/hypr-edge-bg.nix` | Home-manager module wiring | Drop 4 options + `hyprDiveBin` package + 4 env vars + `glib` runtime dep |
| `/etc/nixos/home/tests/hypr-edge-bg-test.nix` | nixosTest scaffold | Replace 4 dive scenarios with 5 mode-free scenarios |
| `/etc/nixos/home/.claude/CLAUDE.md` | Project doc | Rewrite to match new behavior; reconcile drift |

---

## Task 0: Prep workspace

**Files:**
- Modify (ownership): `/etc/nixos` (entire tree, chown to max for editing)

- [ ] **Step 1: Confirm starting state**

Run:
```bash
systemctl --user is-active hypr-activities hypr-edge-bg
ls /etc/nixos/home/scripts/hypr-dive
stat -c '%U:%G' /etc/nixos
```
Expected: both services `active`, `hypr-dive` file present, owner currently `root:root`.

- [ ] **Step 2: Take ownership for the duration of the work**

Run:
```bash
sudo chown -R max:users /etc/nixos
```
Expected: returns silently. Re-run `stat -c '%U:%G' /etc/nixos` → `max:users`.

- [ ] **Step 3: Capture a baseline snapshot for rollback**

Run:
```bash
cp -a /etc/nixos /tmp/nixos-backup-$(date +%Y%m%d-%H%M%S)
```
Expected: returns silently. This lets you `cp -a /tmp/nixos-backup-…/. /etc/nixos/` if anything goes wrong before the final rebuild.

- [ ] **Step 4: Save current live verification facts**

Run:
```bash
hyprctl getoption general:gaps_in -j
hyprctl getoption general:gaps_out -j
hyprctl hyprpaper listactive
cat ~/.config/waypaper/config.ini | grep ^wallpaper
```
Expected: gaps non-zero (`"custom":"3 3 3 3"` and `"custom":"2 6 6 6"` at time of writing), some wallpaper currently active on each monitor, a wallpaper path in the waypaper config. Note these — Task 10 verification compares against them.

---

## Task 1: Trim `colors.sh` to the three helpers we still use

**Files:**
- Modify: `/etc/nixos/home/scripts/lib/colors.sh`

- [ ] **Step 1: Replace the file with the trimmed version**

Overwrite `/etc/nixos/home/scripts/lib/colors.sh` with **exactly** this content:

```bash
#!/usr/bin/env bash
# Color math helpers — sourced by hypr-edge-bg. Integer arithmetic only.

hex_to_rgb() {
    local h=${1#"#"}
    printf '%d %d %d\n' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

rgb_to_hex() {
    printf '%02x%02x%02x\n' "$1" "$2" "$3"
}

# Squared Euclidean distance in RGB.
rgb_dist_sq() {
    local dr=$(($1 - $4)) dg=$(($2 - $5)) db=$(($3 - $6))
    printf '%d\n' $((dr * dr + dg * dg + db * db))
}
```

That deletes `clamp`, `luma`, `mismatch_hex`, `mix_init`, `mix_add`, `mix_finalize`, and the `MIX_*` globals.

- [ ] **Step 2: Lint**

Run:
```bash
shellcheck -s bash -a /etc/nixos/home/scripts/lib/colors.sh
```
Expected: no output (silent).

- [ ] **Step 3: Format**

Run:
```bash
shfmt -d -s -i 4 /etc/nixos/home/scripts/lib/colors.sh
```
Expected: no output (already formatted). If there's diff output, run with `-w` instead of `-d` to apply.

---

## Task 2: Update `colors-test.sh` so only the kept helpers are asserted

**Files:**
- Modify: `/etc/nixos/home/tests/colors-test.sh`

- [ ] **Step 1: Run the existing test to see the failures the trim caused**

Run:
```bash
HYPR_EDGE_BG_LIB=/etc/nixos/home/scripts/lib bash /etc/nixos/home/tests/colors-test.sh
```
Expected: at least some failures — any assertion that called `mismatch_hex`, `mix_init`, `mix_add`, `mix_finalize`, `luma`, or `clamp` now errors with `command not found`. The remaining `hex_to_rgb`/`rgb_to_hex`/`rgb_dist_sq` assertions should pass.

- [ ] **Step 2: Read the current test file**

Run:
```bash
cat /etc/nixos/home/tests/colors-test.sh
```
Identify which assertion blocks reference the deleted helpers. (This step is informational — you need to see the file's structure before editing.)

- [ ] **Step 3: Remove every assertion block that calls a deleted helper**

Edit `/etc/nixos/home/tests/colors-test.sh`: delete every test block whose body invokes `mismatch_hex`, `mix_init`, `mix_add`, `mix_finalize`, `luma`, or `clamp`. Keep the file's prologue (shebang, `set -e`, the `HYPR_EDGE_BG_LIB`-based `source` line, any `pass`/`fail` helper functions, and the exit/summary code). Keep every assertion block that exercises `hex_to_rgb`, `rgb_to_hex`, or `rgb_dist_sq`.

If the resulting file has fewer than three assertion blocks, add the missing ones using these templates:

```bash
# hex_to_rgb basic
out=$(hex_to_rgb "1a2b3c")
[[ $out == "26 43 60" ]] || { echo "hex_to_rgb 1a2b3c -> $out"; exit 1; }

# rgb_to_hex roundtrip
out=$(rgb_to_hex 26 43 60)
[[ $out == "1a2b3c" ]] || { echo "rgb_to_hex 26 43 60 -> $out"; exit 1; }

# rgb_dist_sq squared distance
out=$(rgb_dist_sq 10 20 30 13 24 35)
# (10-13)^2 + (20-24)^2 + (30-35)^2 = 9 + 16 + 25 = 50
[[ $out == "50" ]] || { echo "rgb_dist_sq -> $out"; exit 1; }
```

- [ ] **Step 4: Run the trimmed test, expect pass**

Run:
```bash
HYPR_EDGE_BG_LIB=/etc/nixos/home/scripts/lib bash /etc/nixos/home/tests/colors-test.sh
```
Expected: exit 0, all remaining assertions pass.

- [ ] **Step 5: Lint the test script**

Run:
```bash
shellcheck -s bash -a /etc/nixos/home/tests/colors-test.sh
```
Expected: silent.

---

## Task 3: Strip the gsettings / dark-theme plumbing from `hypr-activities`

**Files:**
- Modify: `/etc/nixos/home/scripts/hypr-activities`

- [ ] **Step 1: Delete the gsettings producer pipeline**

Open `/etc/nixos/home/scripts/hypr-activities`. Delete the entire block (currently lines 46–52 of the file at spec time):

```bash
# gsettings dark-theme stream → tag each line with `theme|`.
(
    gsettings monitor org.gnome.desktop.interface color-scheme | while IFS= read -r line; do
        printf 'theme|%s\n' "$line"
    done
) >"$EVENT_FIFO" 2>/dev/null &
PIPELINE_PIDS+=($!)
```

- [ ] **Step 2: Delete the `DARK` global + reader function**

In the same file, delete these lines (currently 83–92 area):

```bash
DARK=0
```

```bash
read_dark_from_gsettings() {
    local v
    v=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || printf "''")
    if [[ $v == *prefer-dark* ]]; then DARK=1; else DARK=0; fi
}
```

Delete the bootstrap call as well (currently line 110):

```bash
read_dark_from_gsettings
```

- [ ] **Step 3: Drop the `dark_theme` field from the snapshot builder**

Inside `build_snapshot()`'s `jq -nc` invocation, delete the `--argjson dark "$DARK" \` argument line, and delete the `dark_theme: ($dark==1),` line from the `'{ ... }'` object literal. Every other field in the snapshot stays.

- [ ] **Step 4: Drop the `theme)` case from the event-loop switch**

In the `while true; do … done` event-loop, delete this case block:

```bash
theme)
    read_dark_from_gsettings
    PENDING=1
    ;;
```

- [ ] **Step 5: Lint**

Run:
```bash
shellcheck -s bash -a /etc/nixos/home/scripts/hypr-activities
```
Expected: silent. If shellcheck flags `DARK` or `read_dark_from_gsettings` as unused, that means a deletion was missed — re-scan.

- [ ] **Step 6: Format**

Run:
```bash
shfmt -d -s -i 4 /etc/nixos/home/scripts/hypr-activities
```
Expected: no diff. Apply with `-w` if needed.

- [ ] **Step 7: Smoke-parse via bash**

Run:
```bash
bash -n /etc/nixos/home/scripts/hypr-activities
```
Expected: silent (syntax OK).

---

## Task 4: Rewrite `hypr-edge-bg` to the single rule

**Files:**
- Modify: `/etc/nixos/home/scripts/hypr-edge-bg`

- [ ] **Step 1: Delete dive-state plumbing**

Open `/etc/nixos/home/scripts/hypr-edge-bg`. Delete these declarations (currently around lines 12, 36-38):

```bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-edge-bg"
STATE_FILE="$STATE_DIR/dive"
```

```bash
DIVE="off"
```

And remove `"$STATE_DIR"` from the `mkdir -p` line so it becomes:

```bash
mkdir -p "$CACHE_DIR"
```

Delete the helper functions:

```bash
read_dive() { ... }
write_dive_off() { ... }
```

- [ ] **Step 2: Delete env-var declarations for the dive / mismatch surface**

Delete these lines from the header block (currently around lines 17, 22–24):

```bash
DEFAULT_HEX="${HYPR_EDGE_BG_DEFAULT:-323246}"
SHIFT_PCT="${HYPR_EDGE_BG_SHIFT_PCT:-40}"
CLAMP_LO="${HYPR_EDGE_BG_CLAMP_LO:-30}"
CLAMP_HI="${HYPR_EDGE_BG_CLAMP_HI:-225}"
```

- [ ] **Step 3: Delete the SIGUSR1 trap and `reeval()`**

Delete:

```bash
reeval() {
    read_dive
    if [[ -n $LAST_SNAP ]]; then
        decide "$LAST_SNAP"
    elif [[ -r $SNAPSHOT ]]; then
        LAST_SNAP=$(cat "$SNAPSHOT")
        [[ -n $LAST_SNAP ]] && decide "$LAST_SNAP"
    fi
}

trap reeval USR1
```

- [ ] **Step 4: Delete the `WIN_COLOR` per-window cache**

The mixed-mode bypass used it; with mixed removed it has no callers. Delete:

```bash
# shellcheck disable=SC2034  # WIN_COLOR is read via ${WIN_COLOR[$addr]:-} in decide()
declare -A WIN_COLOR=() # address → hex (per-window match cache)
```

- [ ] **Step 5: Replace `decide()` with the single-rule version**

Locate the current `decide()` (the long function starting `decide() {` and ending with its closing brace just before `sample_active_from_table()`). Replace it **entirely** with:

```bash
# --- decision logic -----------------------------------------------------
# Single rule: exactly one tiled non-fullscreen window with gaps=off → match
# (live-sampled top-edge color). Every other state → waypaper image.
#
# One jq invocation per tick: emit a fixed header (scalars + monitors json
# on their own lines) followed by a clients table (one row per line).
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

    # Single sample rule: exactly one tiled non-fullscreen window with gaps=off.
    # Conditions 3 (!floating) and 4 (!pseudo) are redundant with gaps=="off"
    # because the publisher already promotes gaps to "on" for floating/pseudo,
    # but we check them here as self-documenting defense-in-depth.
    if [[ $flag == "1" \
          && ${fs:-0} -lt 2 \
          && $gaps == "off" \
          && $floating_b == "false" \
          && $pseudo_b == "false" \
          && ${wc:-0} -eq 1 ]]; then
        local hex
        hex=$(sample_active_from_table "$addr" "$clients_tbl")
        if [[ -n $hex ]]; then
            apply_color "$hex" "$monitors"
            POLL_ACTIVE=1
            return
        fi
    fi

    # Default branch — waypaper everywhere it would be visible.
    apply_waypaper_image "$waypaper_bg" "$monitors"
}
```

- [ ] **Step 6: Add `-depth 8` to the grim/magick pipeline**

Locate `sample_top_edge()`. Change its body's `magick` line from:

```bash
        magick - -resize '1x1!' txt:- 2>/dev/null |
```

to:

```bash
        magick - -depth 8 -resize '1x1!' txt:- 2>/dev/null |
```

(Q16 ImageMagick — on this machine the unflagged output is already 8-bit, but the distro target may ship a Q16 build. `-depth 8` makes the pipeline portable.)

- [ ] **Step 7: Gate `decide:` log on state change**

`apply_image` already has a fast-exit on identity match (`[[ $identity == "$LAST_APPLIED" ]] && return`). Move the per-tick `log "decide: …"` lines so they fire **only** when the consumer is about to call into `apply_color` or `apply_waypaper_image` for the first time after a state change. Concrete change: delete all the existing `log "decide: …"` lines inside `decide()`, and instead add a single log inside `apply_image()` right after the `[[ $identity == "$LAST_APPLIED" ]] && return;` line:

```bash
    log "apply: $identity (monitors=$(jq -r '[.[].name]|join(",")' <<<"$monitors_json"))"
```

That way the log fires once per actual change, not 10×/s during steady-state polling.

- [ ] **Step 8: Boot path — remove `read_dive` call and dive-aware initial paint**

Locate the section after `exec {SOCK_FD}< <(socat …)`. Currently it reads:

```bash
read_dive
[[ -r $SNAPSHOT ]] && LAST_SNAP=$(cat "$SNAPSHOT")
[[ -n $LAST_SNAP ]] && decide "$LAST_SNAP"
```

Replace with:

```bash
[[ -r $SNAPSHOT ]] && LAST_SNAP=$(cat "$SNAPSHOT")
[[ -n $LAST_SNAP ]] && decide "$LAST_SNAP"
```

- [ ] **Step 9: Lint**

Run:
```bash
shellcheck -s bash -a /etc/nixos/home/scripts/hypr-edge-bg
```
Expected: silent. Any "referenced but not assigned" warning for `DIVE`, `DEFAULT_HEX`, `SHIFT_PCT`, `CLAMP_LO`, `CLAMP_HI`, `STATE_FILE`, `STATE_DIR`, or `WIN_COLOR` means a deletion was missed — re-scan.

- [ ] **Step 10: Format**

Run:
```bash
shfmt -d -s -i 4 /etc/nixos/home/scripts/hypr-edge-bg
```
Expected: no diff. Apply with `-w` if needed.

- [ ] **Step 11: Smoke-parse via bash**

Run:
```bash
bash -n /etc/nixos/home/scripts/hypr-edge-bg
```
Expected: silent.

---

## Task 5: Update the home-manager module

**Files:**
- Modify: `/etc/nixos/home/modules/hypr-edge-bg.nix`

- [ ] **Step 1: Remove `glib` from `runtimeDeps`**

In the `runtimeDeps = with pkgs; [ … ];` list, delete the line:

```nix
    glib # gsettings
```

- [ ] **Step 2: Remove the `hyprDiveBin` derivation**

Delete the line:

```nix
  hyprDiveBin = mkScript "hypr-dive" ./../scripts/hypr-dive;
```

This must happen before the script file is deleted in Task 6, otherwise the next Nix evaluation will fail on the dangling `./../scripts/hypr-dive` reference.

- [ ] **Step 3: Drop the four removed options from `options.services.hyprEdgeBg`**

Delete these option blocks **in full**:

```nix
    defaultColor = lib.mkOption { ... };
    mismatchShiftPct = lib.mkOption { ... };
    mismatchClampMin = lib.mkOption { ... };
    mismatchClampMax = lib.mkOption { ... };
```

Keep all other options (`enable`, `sampleHeight`, `sampleWidthMax`, `distanceThreshold`, `pollIntervalSec`, `cacheSize`, `waypaperConfigPath`).

- [ ] **Step 4: Drop `hyprDiveBin` from `home.packages`**

Change:

```nix
    home.packages = [ hyprActivitiesBin hyprEdgeBgBin hyprDiveBin ];
```

to:

```nix
    home.packages = [ hyprActivitiesBin hyprEdgeBgBin ];
```

- [ ] **Step 5: Drop the four env vars from the consumer service**

Inside `systemd.user.services.hypr-edge-bg.Service.Environment`, delete these entries:

```nix
          "HYPR_EDGE_BG_DEFAULT=${cfg.defaultColor}"
          "HYPR_EDGE_BG_SHIFT_PCT=${toString cfg.mismatchShiftPct}"
          "HYPR_EDGE_BG_CLAMP_LO=${toString cfg.mismatchClampMin}"
          "HYPR_EDGE_BG_CLAMP_HI=${toString cfg.mismatchClampMax}"
```

Keep `HYPR_EDGE_BG_SAMPLE_H`, `HYPR_EDGE_BG_SAMPLE_W_MAX`, `HYPR_EDGE_BG_DIST_THRESHOLD`, `HYPR_EDGE_BG_POLL_INTERVAL`, `HYPR_EDGE_BG_CACHE_SIZE`.

- [ ] **Step 6: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/home/modules/hypr-edge-bg.nix
```
Expected: the file content prints to stdout (no error). Any parse error means a `;` or `}` mismatch — fix before continuing.

---

## Task 6: Delete `hypr-dive`

**Files:**
- Delete: `/etc/nixos/home/scripts/hypr-dive`

- [ ] **Step 1: Confirm no remaining references**

Run:
```bash
grep -rn 'hypr-dive\|hyprDive' /etc/nixos/home/ 2>/dev/null
```
Expected: zero lines outside of comments. If anything still references it (e.g. in `.claude/CLAUDE.md`), that's fine for now — Task 8 rewrites CLAUDE.md. The check here is for **Nix and Bash callers**.

If the grep returns Nix or shell references besides CLAUDE.md, stop and fix them before proceeding.

- [ ] **Step 2: Delete the script**

Run:
```bash
rm /etc/nixos/home/scripts/hypr-dive
```
Expected: silent. Re-run the grep — only `CLAUDE.md` mentions should remain.

---

## Task 7: Rewrite the nixosTest scenarios

**Files:**
- Modify: `/etc/nixos/home/tests/hypr-edge-bg-test.nix`

- [ ] **Step 1: Overwrite the file**

Replace `/etc/nixos/home/tests/hypr-edge-bg-test.nix` with this content:

```nix
{ pkgs ? import <nixpkgs> { } }:

# nixosTest scaffold for hypr-edge-bg under the single-rule paint model.
# Each scenario writes a snapshot into the activities snapshot file and
# checks that the consumer would route to either match or waypaper.
#
# Full daemon orchestration in a VM requires Hyprland, which isn't reasonable
# inside a NixOS test. This file therefore demonstrates the fixture shape
# for each scenario; the live verification in the plan's Task 10 is the
# real proof. Unit-level math is covered deterministically by
# tests/colors-test.sh.

pkgs.nixosTest {
  name = "hypr-edge-bg";

  nodes.machine = { config, pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      bash coreutils gawk gnused jq imagemagick
    ];

    environment.etc."hypr-edge-bg-stubs/hyprctl".source = pkgs.writeShellScript "hyprctl" ''
      printf '%s ' "$@" >>/tmp/hyprctl-call.log
      printf '\n' >>/tmp/hyprctl-call.log
      case "$1 $2" in
        "hyprpaper preload"|"hyprpaper wallpaper"|"hyprpaper unload") printf 'ok' ;;
        *) echo '{}' ;;
      esac
    '';

    environment.etc."hypr-edge-bg-stubs/grim".source = pkgs.writeShellScript "grim" ''
      hex=$(cat /tmp/fixtures/grim-hex 2>/dev/null || echo aabbcc)
      ${pkgs.imagemagick}/bin/magick -size 1x1 "xc:#$hex" png:-
    '';
  };

  testScript = ''
    machine.start()
    machine.succeed("mkdir -p /tmp/fixtures /run/user/0 /tmp/hypr-edge-bg")
    machine.succeed("export XDG_RUNTIME_DIR=/run/user/0")
    machine.succeed("ln -sf /etc/hypr-edge-bg-stubs/hyprctl /usr/local/bin/hyprctl || true")
    machine.succeed("touch /tmp/fixtures/wp.jpg")

    # === Scenario 1: empty workspace → waypaper ===
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":0,"window_count":0,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"off","class":"","address":"","at":[0,0],"size":[0,0],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":false}
      JSON
    """)

    # === Scenario 2: one tiled window, gaps=off, sample aabbcc → match ===
    machine.succeed("echo aabbcc > /tmp/fixtures/grim-hex")
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":1,"window_count":1,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"off","class":"foo","address":"0xaaa","at":[0,0],"size":[1920,1080],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[{"address":"0xaaa","at":[0,0],"size":[1920,1080],"workspace":{"id":1}}],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":false}
      JSON
    """)

    # === Scenario 3: one tiled window, gaps=on → waypaper ===
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":1,"window_count":1,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"on","class":"foo","address":"0xaaa","at":[0,0],"size":[1920,1080],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[{"address":"0xaaa","at":[0,0],"size":[1920,1080],"workspace":{"id":1}}],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":false}
      JSON
    """)

    # === Scenario 4: two tiled windows, gaps=off → waypaper ===
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":1,"window_count":2,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"off","class":"foo","address":"0xaaa","at":[0,0],"size":[960,1080],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[{"address":"0xaaa","at":[0,0],"size":[960,1080],"workspace":{"id":1}},{"address":"0xbbb","at":[960,0],"size":[960,1080],"workspace":{"id":1}}],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":false}
      JSON
    """)

    # === Scenario 5: one floating window, gaps=off (publisher promotes to on) → waypaper ===
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":1,"window_count":1,"workspace":1,"fullscreen":0,"floating":true,"pseudo":false,"grouped":false,"gaps":"on","class":"foo","address":"0xaaa","at":[100,100],"size":[600,400],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[{"address":"0xaaa","at":[100,100],"size":[600,400],"workspace":{"id":1}}],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":false}
      JSON
    """)
  '';
}
```

- [ ] **Step 2: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/home/tests/hypr-edge-bg-test.nix
```
Expected: file content prints, no parse error.

---

## Task 8: Rewrite `CLAUDE.md` to match the new behavior

**Files:**
- Modify: `/etc/nixos/home/.claude/CLAUDE.md`

- [ ] **Step 1: Read the current file once to confirm layout**

Run:
```bash
cat /etc/nixos/home/.claude/CLAUDE.md | head -60
```
Expected: the existing doc, organized in sections (Project Overview, Dive UX Paradigm, Components, Build/Test/Format, Architecture & Code Style, Module Options, Coding Directives, Known Hazards).

- [ ] **Step 2: Overwrite with the rewritten content**

Replace `/etc/nixos/home/.claude/CLAUDE.md` with **exactly** this content:

````markdown
# CLAUDE.md — Hyprland & NixOS Desktop Automation

## Project Overview
This project builds production-grade bash automation for the **Hyprland** ecosystem on **NixOS** (channel-based Home Manager, no flakes). The anchor implementation is `hypr-edge-bg`: a background daemon that paints the user's `waypaper` image as the desktop background everywhere it is visible, except in one specific case where it paints a live-sampled solid color instead.

Two processes:
- **`hypr-activities`** — single publisher of workspace state. Owns every `hyprctl`/`inotifywait` read; broadcasts an atomic JSON snapshot file + an AF_UNIX socket with a 16 ms inline debounce.
- **`hypr-edge-bg`** — single consumer. Streams the activities socket, runs the single-rule decision, and drives `hyprpaper`. Polls the active mode every `POLL_INTERVAL` seconds for live color tracking.

There is no toggle, no state file, no `hypr-dive` CLI. The behavior is the same all the time.

## The Background Rule
The waypaper image is the background everywhere it is visible, **except** when **all** of the following are true:

1. exactly one window on the focused workspace,
2. that window is tiled (not floating, not pseudo),
3. the workspace has no visible gaps (`gaps_in == 0 AND gaps_out == 0`),
4. the focused window is not in true fullscreen (`fullscreen < 2`).

In that single case, the bg is a solid color sampled live from the focused window's top edge.

| Scenario | Bg |
|---|---|
| Empty workspace | waypaper |
| Floating-only / pseudo-only | waypaper |
| ≥2 tiled windows | waypaper |
| 1 tiled window, gaps_in>0 OR gaps_out>0 | waypaper |
| 1 tiled window, gaps_in=0 AND gaps_out=0 | **match (live top-edge sample)** |
| True fullscreen (fs≥2) | waypaper |

## Components

- **`scripts/hypr-activities`** — event publisher. Subscribes to Hyprland `socket2` and `inotifywait` on the waypaper config. Holds two FIFOs open with `<>` (`EVENT_FIFO`, `BROADCAST_FIFO`) so producers never EPIPE. Inline 16 ms debounce in the main loop (no subshell — state mutations propagate). Emits `$XDG_RUNTIME_DIR/hypr-activities.json` (atomic `tmp+mv`) and broadcasts on `$XDG_RUNTIME_DIR/hypr-activities.sock` (AF_UNIX, multi-consumer via `socat ... fork,reuseaddr,unlink-early`). **Sole owner of `hyprctl` reads**.
- **`scripts/hypr-edge-bg`** — background driver. Opens the activities socket on a numbered FD via `exec {SOCK_FD}< <(socat -u …)` and uses `read -t POLL_INTERVAL -u "$SOCK_FD"` so the main loop interleaves event-driven snapshots with poll ticks while in match mode (`POLL_ACTIVE=1`). Idle states (waypaper) keep `POLL_ACTIVE=0` and the loop blocks on the socket — zero CPU. **One** `jq` invocation per tick extracts every scalar + `monitors` JSON + a flat `addr|x|y|w|h` clients table. Drives `hyprpaper` via `preload → wallpaper → unload <previous>`. LRU-bounded `/tmp/hypr-edge-bg/` solid-PNG cache with deterministic filenames `bg_<HEX>.png`. Squared-RGB threshold (`DIST_THRESHOLD=25`) plus exact-hex fast-exit skip no-op updates.
- **`scripts/lib/colors.sh`** — shared integer-only color math (hex/RGB conversion, squared distance). Sourced by `hypr-edge-bg` and unit tests via `HYPR_EDGE_BG_LIB`.
- **`modules/hypr-edge-bg.nix`** — Home Manager module wiring two scripts as `systemd.user.services` (`hypr-activities` → `hypr-edge-bg`) with typed `options` and a curated `lib.makeBinPath` (`socat`, `jq`, `grim`, `imagemagick`, `hyprland`, `hyprpaper`, `inotify-tools`). **Both services use `Restart=always`** — clean exits (socket EOF when publisher restarts, FIFO ENOENT under cleanup race) need recovery just like crashes.
- **`tests/colors-test.sh`** — deterministic unit tests for the three color math helpers (no external deps).
- **`tests/hypr-edge-bg-test.nix`** — `nixosTest` scaffold with stubs for `hyprctl` and `grim`; demonstrates fixture shape for the five paint scenarios.

## Build, Test & Format
- **Lint**: `shellcheck -s bash -a <script>` — all bash scripts must be silent.
- **Format**: `shfmt -w -s -i 4 <script>` (4-space indentation, simplify).
- **Unit tests**: `HYPR_EDGE_BG_LIB=/etc/nixos/home/scripts/lib bash /etc/nixos/home/tests/colors-test.sh`.
- **Module parse-check**: `nix-instantiate --parse modules/hypr-edge-bg.nix`.
- **Rebuild**: `sudo nixos-rebuild switch`. There is **no** standalone `home-manager` CLI here.
- **Restart services after rebuild**: `systemctl --user daemon-reload && systemctl --user restart hypr-activities hypr-edge-bg`. Order matters — publisher first, consumer second.
- **Log viewing**: `journalctl --user -u hypr-activities -u hypr-edge-bg -f`.
- **Live snapshot**: `jq . $XDG_RUNTIME_DIR/hypr-activities.json`.
- **Tail broadcast**: `socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr-activities.sock`.

## Architecture & Code Style

### NixOS Declarative Immutability
- **Home Manager modules** (`*.nix`): expose typed `options` → `config`; wrap scripts as `systemd.user.services`.
- **Service lifecycle**: bind to `graphical-session.target` with `PartOf` + `After`; chain dependent services with `Requires` + `After`. Use `Restart=always; RestartSec=1`.
- **Dependency injection**: `pkgs.writeShellScriptBin` + `lib.makeBinPath`. Pass `HYPR_EDGE_BG_LIB` env so scripts locate sourced libraries when relocated to `/nix/store`.
- **No FHS assumptions**: never hardcode `/usr/bin` or `/bin`. PATH is curated, not inherited.
- **Channel vs flake**: this project is **channel-based** (`<home-manager/nixos>`). The user's `home.nix` lives at `/etc/nixos/home.nix` and imports project modules by relative path.

### Hyprland IPC & Quirks
- **socket2 for events**: `socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -`. Subscribe to `activewindow*`, `openwindow`, `closewindow`, `movewindow`, `windowtitlev2`, `fullscreen`, `workspace`, `focusedmon`, `changefloatingmode`, `configreloaded`, `monitoradded`, `monitorremoved`. Never poll for events.
- **Centralised reads**: only `hypr-activities` calls `hyprctl`. Other consumers read the JSON snapshot or the broadcast socket.
- **Window state semantics**: `fullscreen` level `2` = true fullscreen (waypaper under, invisible). `fullscreen=1` = maximized (still respects gaps; falls through the rule). `floating`/`pseudo` imply visible gaps; publisher promotes `gaps` to `"on"`.
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
- **Coalescing**: 16 ms inline debounce.
- **FIFO discipline**: when several producers feed one FIFO and one main-shell loop reads it, **open the FIFO once on a numbered FD with `exec {FD}<>fifo`** and read with `read -u "$FD"`. Re-opening with `<"$FIFO"` per iteration leaves a per-iteration gap during which writers see EPIPE; eventually the cleanup unlinks the FIFO and the next reopen returns ENOENT, killing the script.
- **Atomic file writes**: `printf '%s' "$snap" >file.tmp && mv -f file.tmp file`.

### Color-Following Polling
- **POLL_ACTIVE flag**: `decide()` sets `POLL_ACTIVE=1` in match; `0` everywhere else.
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
          decide "$LAST_SNAP"
      fi
  done
  ```

### Waypaper Path Handling
- **Silent fallback**: `inotifywait -e close_write,modify,moved_to ~/.config/waypaper/config.ini` → publisher snapshots include the latest path. Consumer picks it up on the next snapshot.
- **Tilde paths**: `waypaper`'s `config.ini` may contain `wallpaper = ~/Downloads/...`. Bash's `[[ -e $path ]]` does NOT expand `~`, so the publisher must do it: `[[ $v == "~" || $v == "~/"* ]] && v="$HOME${v#"~"}"` (with `# shellcheck disable=SC2088`).

### Bash Development
- **Strict header**:
  ```bash
  #!/usr/bin/env bash
  set -uo pipefail
  ```
  Use `set -uo` (no `-e`) for long-running daemons that must survive transient JSON parse failures; reserve `set -euo pipefail` for short batch scripts.
- **Trailing newlines matter**: any function meant to be consumed by `read -r` MUST emit a trailing `\n`. Always `printf '...\n'`, never `printf '...'`.
- **`jq` is expensive**: each invocation costs 4–10 ms of bash + jq startup. **Coalesce** — emit every needed scalar + nested JSON + flattened tables in ONE jq call, then parse with `read`/`IFS='|' read`.
- **Fast-exit hot paths**: `[[ $hex == "$LAST_HEX" ]] && return 0` before any RGB math, jq, or hyprctl. Cache `MON_NAMES` indexed by the monitors-blob string so the steady-state has zero forks.
- **`trap` on EXIT**: clean sockets, FIFOs, temp PNGs, child PIDs. Close opened FDs (`exec {FD}<&-`).
- **Logs to stderr**: `printf '[name] %s\n' "$*" >&2`. Gate per-tick logs on state change — the publisher and consumer both run hot; an unconditional log inside the inner loop floods the journal.

### ImageMagick Pipeline
- **`-depth 8` is mandatory**: NixOS may ship ImageMagick **Q16** (16-bit channels). Without `-depth 8`, `magick - txt:-` may emit pixels as `#AAAABBBBCCCC` (12 hex chars), and `substr(…, 1, 6)` after stripping `#` returns `AAAABB` instead of `AABBCC` — every sample silently corrupted.
- **Top-edge sample**: `sw = min(w, SAMPLE_W_MAX)` (default `300px`), centered: `sx = x + (w - sw)/2`. Geometry `${sx},${y} ${sw}x${SAMPLE_H}`. Narrow-center capture avoids title-bar gradients and is much faster than a full-width strip.

### Color Math Recipe (only one left)
- **Match (top-edge sample)**:
  ```bash
  grim -g "$geom" - 2>/dev/null \
    | magick - -depth 8 -resize 1x1! txt:- 2>/dev/null \
    | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^#[0-9A-Fa-f]+$/) { sub(/^#/,"",$i); print substr($i,1,6); exit } }'
  ```
- **Skip thresholds**: exact-hex fast-exit first; squared RGB distance < `DIST_THRESHOLD` (default `25`) ≈ imperceptible; skip the hyprpaper cycle.

## Module Options (current)
| Option | Default | Notes |
|---|---|---|
| `sampleHeight` | `2` | Pixels of vertical strip sampled from the window top edge. |
| `sampleWidthMax` | `300` | Max pixels (centered) of window width sampled. Narrower = faster. |
| `distanceThreshold` | `25` | Squared-RGB skip threshold. |
| `pollIntervalSec` | `"0.1"` | Color-following poll cadence in match mode. |
| `cacheSize` | `16` | Max retained PNGs in `/tmp/hypr-edge-bg`. |
| `waypaperConfigPath` | `${xdg.configHome}/waypaper/config.ini` | inotify target. |

## Coding Directives (priority order)
1. **Declarative First** — every tool is a Home Manager module with typed options and a `systemd.user.service`. `Restart=always; RestartSec=1` on long-lived daemons.
2. **Event-Driven, Polled Where Needed** — IPC subscriptions for state changes; polling reserved for the color-following inner mode (`POLL_ACTIVE=1`). The publisher never polls.
3. **One Publisher, Many Consumers** — centralise external-tool reads in `hypr-activities`. No other process calls `hyprctl`.
4. **Atomic & Idempotent** — every state mutation is `tmp + mv`. Daemons can be restarted safely.
5. **One jq Per Tick, Fast-Exit First** — coalesce extracts; check `hex == LAST_HEX` before any work; cache monitor metadata.
6. **Selective Hyprpaper Lifecycle** — `preload → wallpaper → unload <previous>`. Deterministic temp filenames. Never `unload all`. Never unload the waypaper image.
7. **FIFO Once, Read by FD** — open with `exec {FD}<>"$FIFO"`, read with `read -u "$FD"`. Re-opening per iteration is a footgun.
8. **Inline Debounce, No Subshells for State** — `read -t DEBOUNCE_S` with a `PENDING` flag. Background subshells trap mutations; never run `emit_snapshot` inside `( ... ) &`.
9. **Lightweight Math** — integer-only RGB arithmetic. Squared distance for thresholding.
10. **Concise & Documented** — minimal, heavily commented bash. Comments explain *why* (Hyprland quirk, ImageMagick Q16, subshell trap), not *what*. Assume NixOS/Hyprland literacy.

## Known Hazards (do not regress)
- `-depth 8` on every `magick … txt:-` consumer of grim output.
- Gap parser must handle CssBoxStyle `.custom`.
- Open `EVENT_FIFO` and `BROADCAST_FIFO` once with `<>`, read by FD.
- `emit_snapshot` runs in main shell. State resets in subshells are silently lost.
- Tilde-expand `~` in waypaper config (`[[ -e ]]` does NOT expand).
- Fullscreen freeze branch: `fs >= 2` only.
- `fs=1` (maximized) falls through the rule.
- Gate `decide:` / per-tick logs on state-change identity — unconditional log inside a 10 Hz loop floods journald.
````

- [ ] **Step 3: Sanity check**

Run:
```bash
grep -n 'hypr-dive\|mismatch\|mixed\|dive' /etc/nixos/home/.claude/CLAUDE.md
```
Expected: zero matches. Any hit means a stale phrase survived the rewrite.

---

## Task 9: Rebuild, restart, cleanup, restore ownership

**Files:**
- Modify (state): `~/.local/state/hypr-edge-bg` (delete)
- Modify (ownership): `/etc/nixos` (restore to root)

- [ ] **Step 1: Dry build to surface Nix-level errors before committing**

Run:
```bash
sudo nixos-rebuild dry-build 2>&1 | tail -40
```
Expected: no error. If there's an undefined option (e.g. `services.hyprEdgeBg.defaultColor` still referenced somewhere upstream), find and remove the consumer; then re-run.

- [ ] **Step 2: Switch**

Run:
```bash
sudo nixos-rebuild switch
```
Expected: completes without error. The home-manager activation re-symlinks the services.

- [ ] **Step 3: Reload and restart services in order**

Run:
```bash
systemctl --user daemon-reload
systemctl --user restart hypr-activities
systemctl --user restart hypr-edge-bg
```
Expected: both return silently. Check status:
```bash
systemctl --user is-active hypr-activities hypr-edge-bg
```
Expected: two lines of `active`.

- [ ] **Step 4: Delete the orphaned dive state**

Run:
```bash
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/hypr-edge-bg"
```
Expected: silent.

- [ ] **Step 5: Restore ownership of `/etc/nixos`**

Run:
```bash
sudo chown -R root:root /etc/nixos
```
Expected: silent.

---

## Task 10: Live verification of the five acceptance scenarios

Verify against the live machine. Use the Hyprland keybind `Super+Q` (or whatever spawns/kills windows in this config) and `hyprctl keyword` for ad-hoc gap changes.

- [ ] **Step 1: Scenario A — current gap config (`gaps_in=3 3 3 3`), one tiled window → waypaper**

Setup: close all but one tiled window on workspace 1.

Run:
```bash
hyprctl hyprpaper listactive
```
Expected: the value contains the waypaper image path (e.g. `/home/max/Downloads/ChatGPT Image Apr 30, 2026, 09_47_10 AM.png`), NOT a `/tmp/hypr-edge-bg/bg_*.png`. Visually confirm the wallpaper image is shown.

- [ ] **Step 2: Scenario B — gaps=0, one tiled window → match (live follow)**

Run:
```bash
hyprctl keyword general:gaps_in 0
hyprctl keyword general:gaps_out 0
```
Then move/focus a single tiled window. Run:
```bash
hyprctl hyprpaper listactive
```
Expected: the value now contains `/tmp/hypr-edge-bg/bg_<HEX>.png`. Scroll the focused window's contents (e.g. scroll a browser, change a terminal screen) — the hex in the filename should change as the top-edge color changes (re-run `listactive` to observe; the daemon polls at 10 Hz).

Reset gaps when done:
```bash
hyprctl keyword general:gaps_in "3 3 3 3"
hyprctl keyword general:gaps_out "2 6 6 6"
```

- [ ] **Step 3: Scenario C — true fullscreen → waypaper**

With gaps reset to non-zero, fullscreen the focused window (`Super+F` or equivalent). Visually: the window covers everything (bg is invisible). Un-fullscreen — bg should still show the waypaper image (no flicker, no leftover solid color).

- [ ] **Step 4: Scenario D — two tiled windows → waypaper**

Open a second window in the workspace. Run:
```bash
hyprctl hyprpaper listactive
```
Expected: waypaper image, not `bg_*`.

- [ ] **Step 5: Scenario E — floating window → waypaper**

Toggle the focused window to floating (`Super+V` or equivalent). Run `hyprctl hyprpaper listactive`. Expected: waypaper, not `bg_*`.

- [ ] **Step 6: Confirm no journal spam**

Run:
```bash
journalctl --user -u hypr-edge-bg --since "1 minute ago" --no-pager | wc -l
```
Expected: low double-digit count or less. Hundreds of identical `decide:` lines per minute means Step 7 of Task 4 (log gating) was missed.

- [ ] **Step 7: Confirm `hypr-dive` is gone**

Run:
```bash
which hypr-dive 2>&1
ls /etc/nixos/home/scripts/hypr-dive 2>&1
```
Expected: `which` returns "not found" (or empty), `ls` returns "No such file or directory".

- [ ] **Step 8: Confirm orphaned dive state is gone**

Run:
```bash
ls "${XDG_STATE_HOME:-$HOME/.local/state}/hypr-edge-bg" 2>&1
```
Expected: "No such file or directory".

---

## Done. The single rule is the new behavior. There is no toggle.
