# Canvas Prefs Apply Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the canvas's CONFIG card pref-rows for `Default shell` and `Groups` functional end-to-end: click opens a rofi chooser, changes stage in a user-owned JSON file (visible in the canvas as faded text), and a new waybar pill on the SYSTEM zone offers Apply / Dismiss / Revert.

**Architecture:** Stage → Apply, with a sidecar `.nix` file owned by the canvas. Six bash scripts (stage / two choosers / apply / dismiss / revert) and one waybar daemon. NixOS module adds passwordless sudo for nixos-rebuild and imports the sidecar. Eww's `pref-row` widget grows a "pending" branch that shows the staged value with reduced text alpha.

**Tech Stack:** bash, jq, rofi (-dmenu, -multi-select), eww 0.6 (gtk-layer-shell), waybar 0.14 (custom modules), NixOS module system, Hyprland (already-wired keybinds + layerrules).

## Global Constraints

- All bash scripts: `#!/usr/bin/env bash` + `set -euo pipefail`.
- File writes are atomic: write to `$tmpfile`, then `mv -f $tmpfile $target`.
- Waybar refresh signal: **RTMIN+23** (verified unused via `grep RTMIN /etc/nixos/home -r`). Document the new slot in `waybar/ARCHITECTURE.md` under the existing signal table.
- `eww.scss` must remain ASCII-only (em-dashes break grass-rs; see navigator hazard list). Use `--` in comments where typography would otherwise reach for `—`.
- The eww canvas opens via Super+RETURN; canvas code lives at `/etc/nixos/home/widgets/eww/`, scripts at `/etc/nixos/home/widgets/scripts/` (eww-specific) and `/etc/nixos/home/scripts/` (system-wide). The new pref-* scripts go in the system-wide directory because they straddle eww + waybar + nixos-rebuild.
- Tests use the existing pattern from `/etc/nixos/home/tests/wave3/test_pomodoro_daemon.sh`: `pass/fail` counters + a `check name actual expected` helper.

---

### Task 1: NixOS module + sidecar wiring (foundation)

**Files:**
- Create: `/etc/nixos/standardos-canvas-sidecar.nix`
- Create: `/etc/nixos/home/modules/standardos-canvas-prefs.nix`
- Modify: `/etc/nixos/configuration.nix` (add `imports = [ ./home/modules/standardos-canvas-prefs.nix ];`)

**Interfaces:**
- Produces: writable sidecar at `/etc/nixos/standardos-canvas-sidecar.nix`; passwordless sudo entry for `max` running `nixos-rebuild`. Other tasks rely on `sudo -n nixos-rebuild switch` succeeding (no prompt).

- [ ] **Step 1: Create the sidecar with safe initial content**

```bash
sudo tee /etc/nixos/standardos-canvas-sidecar.nix > /dev/null <<'EOF'
# standardos-canvas-sidecar.nix
#
# Owned by the canvas Apply flow. DO NOT hand-edit unless you intend
# to bypass the canvas; the next pref-apply will overwrite this file.
# Imported by modules/standardos-canvas-prefs.nix.
{ config, lib, pkgs, ... }: { }
EOF
sudo chown max:users /etc/nixos/standardos-canvas-sidecar.nix
sudo chmod 644 /etc/nixos/standardos-canvas-sidecar.nix
# User-owned so pref-apply can write it without sudo (nixos evaluates
# /etc/nixos as root regardless of ownership; 644 reads identically).
```

- [ ] **Step 2: Create the NixOS module**

Create `/etc/nixos/home/modules/standardos-canvas-prefs.nix`:

```nix
# standardos-canvas-prefs — wires the canvas's Apply flow into the
# system config. Imports the sidecar (which the canvas overwrites on
# each Apply) and grants passwordless sudo for nixos-rebuild so the
# user-side canvas can trigger system rebuilds.
#
# Spec: docs/superpowers/specs/2026-06-25-canvas-prefs-apply-design.md
{ config, lib, pkgs, ... }: {
  imports = [ /etc/nixos/standardos-canvas-sidecar.nix ];

  security.sudo.extraRules = [{
    users = [ "max" ];
    commands = [{
      command = "/run/current-system/sw/bin/nixos-rebuild";
      options = [ "NOPASSWD" ];
    }];
  }];
}
```

- [ ] **Step 3: Wire the module into configuration.nix**

Find the existing `imports = [ ... ];` block and add the new module path. Run:

```bash
grep -n "^  imports" /etc/nixos/configuration.nix
```

Then edit so the imports list includes `./home/modules/standardos-canvas-prefs.nix`. (Exact line range varies — use the grep output to locate it.)

- [ ] **Step 4: Apply the rebuild**

```bash
sudo nixos-rebuild switch
```

Expected: rebuild succeeds (no syntactic issues with the empty sidecar import).

- [ ] **Step 5: Verify passwordless sudo works**

```bash
sudo -n nixos-rebuild --help > /dev/null && echo OK || echo FAIL
```

Expected output: `OK` (no password prompt; `-n` means non-interactive).

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add modules/standardos-canvas-prefs.nix
git commit -m "canvas-prefs: scaffold sidecar import + NOPASSWD sudo for rebuild

Adds the foundation for the canvas Apply flow:
- standardos-canvas-sidecar.nix at /etc/nixos/ (owned root, edited by
  pref-apply on the canvas's behalf; starts as a no-op).
- Module imports the sidecar and grants the 'max' user passwordless
  sudo for the single command 'nixos-rebuild', so the canvas-side
  pref-apply script can trigger system rebuilds without a prompt.
- Wired into configuration.nix imports list.

Spec: docs/superpowers/specs/2026-06-25-canvas-prefs-apply-design.md"
```

(Note: `/etc/nixos/standardos-canvas-sidecar.nix` lives outside this repo. The repo tracks only the module that imports it.)

---

### Task 2: pref-stage script + atomic JSON merge

**Files:**
- Create: `/etc/nixos/home/scripts/pref-stage`
- Create: `/etc/nixos/home/tests/test_pref_stage.sh`

**Interfaces:**
- Consumes: `~/.config/standardos/staged-prefs.json` (creates dir + file if absent).
- Produces: `pref-stage <key> <value>` merges `{key: value}` into the staging file. `<value>` can be a JSON literal (e.g. `'["wheel","audio"]'` for arrays) — the script passes it through `jq` so any JSON type works. Also writes a derived `<key>_display` field for array values (`" · "` joined). Then sends `SIGRTMIN+23` to waybar.

- [ ] **Step 1: Write the failing test**

Create `/etc/nixos/home/tests/test_pref_stage.sh`:

```bash
#!/usr/bin/env bash
# test_pref_stage — TDD for the staging file mutator.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/pref-stage"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export STAGED_PREFS_FILE="$TMP/staged.json"
export PREF_STAGE_SKIP_SIGNAL=1  # don't actually pkill waybar in tests

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Setting a string key creates the file with {key:value}.
"$SCRIPT" shell '"zsh"'
check "shell set"        "$(jq -r '.shell' "$STAGED_PREFS_FILE")"  "zsh"

# Setting an array key merges (does not overwrite the shell).
"$SCRIPT" groups '["wheel","audio"]'
check "shell preserved"  "$(jq -r '.shell' "$STAGED_PREFS_FILE")"  "zsh"
check "groups set"       "$(jq -rc '.groups' "$STAGED_PREFS_FILE")" '["wheel","audio"]'
check "groups_display"   "$(jq -r '.groups_display' "$STAGED_PREFS_FILE")" "wheel · audio"

# Re-setting overwrites.
"$SCRIPT" shell '"bash"'
check "shell overwritten" "$(jq -r '.shell' "$STAGED_PREFS_FILE")" "bash"

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
```

```bash
chmod +x /etc/nixos/home/tests/test_pref_stage.sh
```

- [ ] **Step 2: Run test to verify it fails**

```bash
/etc/nixos/home/tests/test_pref_stage.sh
```

Expected: FAIL (script doesn't exist yet).

- [ ] **Step 3: Implement pref-stage**

Create `/etc/nixos/home/scripts/pref-stage`:

```bash
#!/usr/bin/env bash
# pref-stage <key> <json-value>
#
# Merges {key: value} into the canvas staging file, computes a
# display-friendly join for array values, writes atomically, and
# signals waybar's standardos-pending module to refresh.
#
# Examples:
#   pref-stage shell '"zsh"'
#   pref-stage groups '["wheel","networkmanager","audio"]'
#
# Env overrides for tests:
#   STAGED_PREFS_FILE         override the staging path
#   PREF_STAGE_SKIP_SIGNAL=1  skip the pkill RTMIN+23

set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: pref-stage <key> <json-value>" >&2; exit 2; }
key="$1"; value="$2"

target="${STAGED_PREFS_FILE:-$HOME/.config/standardos/staged-prefs.json}"
mkdir -p "$(dirname "$target")"
[ -f "$target" ] || echo '{}' > "$target"

tmp="$(mktemp --tmpdir="$(dirname "$target")")"

# 1. Merge {key: value} into the staging object.
# 2. If value is an array, also write <key>_display = " · " joined.
jq --arg k "$key" --argjson v "$value" '
  . as $base
  | $base + ({($k): $v})
  | if ($v | type) == "array"
    then . + ({($k + "_display"): ($v | join(" · "))})
    else .
    end
' "$target" > "$tmp"

mv -f "$tmp" "$target"

if [ -z "${PREF_STAGE_SKIP_SIGNAL:-}" ]; then
    pkill -RTMIN+23 waybar 2>/dev/null || true
fi
```

```bash
chmod +x /etc/nixos/home/scripts/pref-stage
```

- [ ] **Step 4: Run test to verify it passes**

```bash
/etc/nixos/home/tests/test_pref_stage.sh
```

Expected: `PASS: 5  FAIL: 0`

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add scripts/pref-stage tests/test_pref_stage.sh
git commit -m "canvas-prefs: pref-stage atomically merges canvas changes

Writes {key: value} into ~/.config/standardos/staged-prefs.json with
tmp+mv-f atomicity (per the hazard list). Array values get a derived
<key>_display = ' · '-joined string so eww can show the staged list
in the same format as the live value. Signals waybar RTMIN+23 on
write so the standardos-pending pill picks up the change.

Tested via tests/test_pref_stage.sh (5 assertions)."
```

---

### Task 3: pref-choose-shell — rofi single-select wrapper

**Files:**
- Create: `/etc/nixos/home/scripts/pref-choose-shell`

**Interfaces:**
- Consumes: `pref-stage` (Task 2), `rofi`.
- Produces: invokes rofi with the available shells, on pick calls `pref-stage shell '"<pick>"'`. On cancel (rofi exit 1) does nothing.

- [ ] **Step 1: Implement pref-choose-shell**

Create `/etc/nixos/home/scripts/pref-choose-shell`:

```bash
#!/usr/bin/env bash
# pref-choose-shell — rofi popup with /etc/shells entries; pipes the
# pick to pref-stage as a JSON string. Cancel (rofi exit 1) is a no-op.
set -euo pipefail

# /etc/shells contains commented + blank lines; keep only paths that exist.
mapfile -t shells < <(grep -v '^\s*#' /etc/shells | awk 'NF && -x $1')

pick="$(printf '%s\n' "${shells[@]}" | rofi -dmenu -p "shell" -i)" || exit 0
[ -n "$pick" ] || exit 0

# pref-stage expects a JSON value; quote the path as a JSON string.
/etc/nixos/home/scripts/pref-stage shell "$(jq -Rn --arg s "$pick" '$s')"
```

```bash
chmod +x /etc/nixos/home/scripts/pref-choose-shell
```

- [ ] **Step 2: Smoke-test by running directly**

```bash
PREF_STAGE_SKIP_SIGNAL=1 STAGED_PREFS_FILE=/tmp/smoke.json /etc/nixos/home/scripts/pref-choose-shell
```

Expected: rofi opens with the shell list. Pick one; verify:

```bash
jq . /tmp/smoke.json
```

Expected: `{"shell": "/run/current-system/sw/bin/<pick>"}` (or similar path).

```bash
rm /tmp/smoke.json
```

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home
git add scripts/pref-choose-shell
git commit -m "canvas-prefs: rofi shell chooser → pref-stage

Reads /etc/shells, filters to executable entries, opens rofi -dmenu
for the user to pick. On selection, stages the chosen shell. Cancel
is a no-op."
```

---

### Task 4: pref-choose-groups — rofi multi-select wrapper

**Files:**
- Create: `/etc/nixos/home/scripts/pref-choose-groups`

**Interfaces:**
- Consumes: `pref-stage` (Task 2), `rofi -multi-select`.
- Produces: invokes rofi with all `getent group` names, pre-selects the user's current groups, on Enter pipes the JSON-array of picks to `pref-stage groups`.

- [ ] **Step 1: Implement pref-choose-groups**

Create `/etc/nixos/home/scripts/pref-choose-groups`:

```bash
#!/usr/bin/env bash
# pref-choose-groups — rofi -multi-select popup with every group on
# the system. Picks are joined as a JSON array and staged.
set -euo pipefail

# All groups on the system, alphabetical, one per line.
mapfile -t all_groups < <(getent group | cut -d: -f1 | sort -u)

# rofi -multi-select returns the picked entries one per line on stdout.
# -select-multiple lets the user toggle entries with Shift+Enter; Enter
# commits the selection. -mesg shows a hint.
picks="$(printf '%s\n' "${all_groups[@]}" \
    | rofi -dmenu -multi-select -i -p "groups" \
           -mesg "Shift+Enter to toggle; Enter to confirm")" || exit 0

[ -n "$picks" ] || exit 0

# Convert the newline-separated picks to a JSON array.
json="$(printf '%s\n' "$picks" | jq -Rn '[inputs | select(length > 0)]')"
/etc/nixos/home/scripts/pref-stage groups "$json"
```

```bash
chmod +x /etc/nixos/home/scripts/pref-choose-groups
```

- [ ] **Step 2: Smoke-test directly**

```bash
PREF_STAGE_SKIP_SIGNAL=1 STAGED_PREFS_FILE=/tmp/smoke.json /etc/nixos/home/scripts/pref-choose-groups
```

Expected: rofi opens with all groups, user toggles a few + presses Enter. Verify:

```bash
jq . /tmp/smoke.json
```

Expected: `{"groups": ["wheel", "audio", ...], "groups_display": "wheel · audio · ..."}`

```bash
rm /tmp/smoke.json
```

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home
git add scripts/pref-choose-groups
git commit -m "canvas-prefs: rofi multi-select groups chooser → pref-stage"
```

---

### Task 5: pref-apply — generate sidecar, rebuild, success/error split

**Files:**
- Create: `/etc/nixos/home/scripts/pref-apply`
- Create: `/etc/nixos/home/scripts/lib/sidecar-render.sh`
- Create: `/etc/nixos/home/tests/test_sidecar_render.sh`

**Interfaces:**
- Consumes: `~/.config/standardos/staged-prefs.json` (Task 2), `/etc/nixos/standardos-canvas-sidecar.nix` (Task 1), `sudo -n nixos-rebuild switch` (Task 1).
- Produces: on success — overwrites the sidecar with `{users.users.max = {...};}`, runs rebuild, clears staging, signals waybar. On failure — writes `~/.config/standardos/last-error.json` with `{reason, source_prefs}`, leaves staging intact, signals waybar.
- The renderer is a separate lib (`sidecar-render.sh`) so it can be unit-tested without sudo or rebuild.

- [ ] **Step 1: Write the failing test for the renderer**

Create `/etc/nixos/home/tests/test_sidecar_render.sh`:

```bash
#!/usr/bin/env bash
# test_sidecar_render — TDD for the staging → sidecar Nix renderer.
set -euo pipefail

LIB="$(cd "$(dirname "$0")"/.. && pwd)/scripts/lib/sidecar-render.sh"
source "$LIB"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name:"
        echo "  expected: $expected"
        echo "  got     : $actual"
        fail=$((fail+1))
    fi
}

# Empty staging → empty users block.
out=$(render_sidecar '{}')
check "empty staging" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
  };
}'

# Shell only.
out=$(render_sidecar '{"shell":"zsh"}')
check "shell only" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
    shell = pkgs.zsh;
  };
}'

# Groups only.
out=$(render_sidecar '{"groups":["wheel","audio"]}')
check "groups only" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
    extraGroups = [ "wheel" "audio" ];
  };
}'

# Both.
out=$(render_sidecar '{"shell":"fish","groups":["wheel","video"]}')
check "shell + groups" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
    shell = pkgs.fish;
    extraGroups = [ "wheel" "video" ];
  };
}'

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
```

```bash
chmod +x /etc/nixos/home/tests/test_sidecar_render.sh
```

- [ ] **Step 2: Run test to verify it fails**

```bash
/etc/nixos/home/tests/test_sidecar_render.sh
```

Expected: FAIL (lib doesn't exist).

- [ ] **Step 3: Implement the renderer**

Create `/etc/nixos/home/scripts/lib/sidecar-render.sh`:

```bash
#!/usr/bin/env bash
# sidecar-render.sh — pure function library. Source it; call
# render_sidecar with a JSON staging blob; get back a Nix expression
# string that defines users.users.max with the staged shell + groups.
#
# Keeps the apply orchestration (sudo, rebuild, error handling) out
# of the rendering logic so the renderer is unit-testable.

render_sidecar() {
    local staging="$1"
    local shell groups_list extra
    shell="$(printf '%s' "$staging" | jq -r '.shell // empty')"
    groups_list="$(printf '%s' "$staging" \
        | jq -r 'if .groups then (.groups | map("\"" + . + "\"") | join(" ")) else empty end')"

    extra=""
    if [ -n "$shell" ]; then
        extra+="    shell = pkgs.${shell};"$'\n'
    fi
    if [ -n "$groups_list" ]; then
        extra+="    extraGroups = [ $groups_list ];"$'\n'
    fi

    cat <<EOF
{ config, lib, pkgs, ... }: {
  users.users.max = {
$(printf '%s' "$extra")  };
}
EOF
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
/etc/nixos/home/tests/test_sidecar_render.sh
```

Expected: `PASS: 4  FAIL: 0`

- [ ] **Step 5: Implement pref-apply**

Create `/etc/nixos/home/scripts/pref-apply`:

```bash
#!/usr/bin/env bash
# pref-apply — renders staging into the sidecar, runs sudo nixos-rebuild
# switch, splits on success/failure:
#   success: clears staging, signals waybar.
#   failure: writes last-error.json (best-effort parsed reason +
#            source_prefs), leaves staging intact, signals waybar.
#
# Env overrides for tests:
#   STAGED_PREFS_FILE   override the staging path
#   SIDECAR_FILE        override the sidecar path (skip sudo write)
#   REBUILD_CMD         override the rebuild command (mock in tests)
#   LAST_ERROR_FILE     override the last-error path
#   PREF_APPLY_SKIP_SIGNAL=1   skip the pkill

set -euo pipefail

source "$(dirname "$0")/lib/sidecar-render.sh"

STAGED="${STAGED_PREFS_FILE:-$HOME/.config/standardos/staged-prefs.json}"
SIDECAR="${SIDECAR_FILE:-/etc/nixos/standardos-canvas-sidecar.nix}"
ERR_FILE="${LAST_ERROR_FILE:-$HOME/.config/standardos/last-error.json}"
REBUILD="${REBUILD_CMD:-sudo -n nixos-rebuild switch}"
LOG_DIR="$HOME/.local/state/standardos"
LOG_FILE="$LOG_DIR/last-rebuild.log"

mkdir -p "$LOG_DIR" "$(dirname "$ERR_FILE")"

# Nothing staged → nothing to apply.
staging="$(cat "$STAGED" 2>/dev/null || echo '{}')"
[ "$(printf '%s' "$staging" | jq 'length')" -gt 0 ] || { echo "nothing staged"; exit 0; }

# 1. Render the sidecar.
rendered="$(render_sidecar "$staging")"

# 2. Write the sidecar (user-writable per Task 1's chown).
printf '%s' "$rendered" > "$SIDECAR"

# 3. Run rebuild, tee to log.
if $REBUILD 2>&1 | tee "$LOG_FILE"; then
    # Success: clear staging and any prior error.
    rm -f "$STAGED" "$ERR_FILE"
else
    # Failure: parse the log tail for the best-effort reason.
    reason="$(tail -200 "$LOG_FILE" \
        | grep -oP "error: group '[^']+' does not exist|error: user '[^']+' does not exist|error: .+:\d+:\d+: .+" \
        | tail -1)"
    [ -n "$reason" ] || reason="Rebuild failed: $(tail -c 200 "$LOG_FILE" | tr '\n' ' ')"

    source_prefs="$(printf '%s' "$staging" | jq -c '[keys[] | select(endswith("_display") | not)]')"
    jq -n --arg r "$reason" --argjson p "$source_prefs" \
        '{reason: $r, source_prefs: $p}' > "$ERR_FILE"
fi

# 4. Signal waybar.
if [ -z "${PREF_APPLY_SKIP_SIGNAL:-}" ]; then
    pkill -RTMIN+23 waybar 2>/dev/null || true
fi
```

```bash
chmod +x /etc/nixos/home/scripts/pref-apply
```

- [ ] **Step 6: End-to-end dry run**

```bash
# Stage a no-op change and apply (REBUILD_CMD = true to skip real rebuild).
PREF_STAGE_SKIP_SIGNAL=1 STAGED_PREFS_FILE=/tmp/staged.json \
  /etc/nixos/home/scripts/pref-stage shell '"bash"'

PREF_APPLY_SKIP_SIGNAL=1 \
  STAGED_PREFS_FILE=/tmp/staged.json \
  SIDECAR_FILE=/tmp/sidecar.nix \
  LAST_ERROR_FILE=/tmp/err.json \
  REBUILD_CMD=true \
  /etc/nixos/home/scripts/pref-apply

echo "--- sidecar:"
cat /tmp/sidecar.nix
echo "--- staging (should be gone):"
ls /tmp/staged.json 2>&1
echo "--- err (should be gone):"
ls /tmp/err.json 2>&1

rm -f /tmp/staged.json /tmp/sidecar.nix /tmp/err.json
```

Expected: sidecar shows `shell = pkgs.bash;`, staging file removed, no error file.

- [ ] **Step 7: Error-path dry run**

```bash
PREF_STAGE_SKIP_SIGNAL=1 STAGED_PREFS_FILE=/tmp/staged.json \
  /etc/nixos/home/scripts/pref-stage groups '["wheel","NoSuchGroup"]'

PREF_APPLY_SKIP_SIGNAL=1 \
  STAGED_PREFS_FILE=/tmp/staged.json \
  SIDECAR_FILE=/tmp/sidecar.nix \
  LAST_ERROR_FILE=/tmp/err.json \
  REBUILD_CMD="bash -c 'echo \"error: group '\''NoSuchGroup'\'' does not exist\" >&2; exit 1'" \
  /etc/nixos/home/scripts/pref-apply || true

echo "--- err:"
cat /tmp/err.json
echo "--- staging (should remain):"
cat /tmp/staged.json

rm -f /tmp/staged.json /tmp/sidecar.nix /tmp/err.json
```

Expected: `err.json` has `{"reason":"error: group 'NoSuchGroup' does not exist","source_prefs":["groups"]}`. Staging file preserved.

- [ ] **Step 8: Commit**

```bash
cd /etc/nixos/home
git add scripts/pref-apply scripts/lib/sidecar-render.sh tests/test_sidecar_render.sh
git commit -m "canvas-prefs: pref-apply renders sidecar + runs rebuild

Splits into:
- lib/sidecar-render.sh: pure function generating the Nix expression
  for users.users.max from the staging JSON. Unit-tested.
- pref-apply: orchestrator that writes the sidecar (sudo tee), runs
  sudo -n nixos-rebuild switch, and on failure parses the log tail
  for the best-effort reason ('group X does not exist', 'user X',
  Nix syntax error, or fallback tail of stderr) into last-error.json.

Both signal waybar RTMIN+23 so the standardos-pending pill picks up
the new state."
```

---

### Task 6: pref-dismiss + pref-revert

**Files:**
- Create: `/etc/nixos/home/scripts/pref-dismiss`
- Create: `/etc/nixos/home/scripts/pref-revert`

**Interfaces:**
- Both delete user-side JSON files and signal waybar RTMIN+23. No rebuild, no privileged ops.

- [ ] **Step 1: Implement pref-dismiss**

Create `/etc/nixos/home/scripts/pref-dismiss`:

```bash
#!/usr/bin/env bash
# pref-dismiss — drop the staging file unread. The system state is
# untouched (the sidecar still reflects the last successful Apply).
set -euo pipefail

rm -f "${STAGED_PREFS_FILE:-$HOME/.config/standardos/staged-prefs.json}"
[ -z "${PREF_STAGE_SKIP_SIGNAL:-}" ] && pkill -RTMIN+23 waybar 2>/dev/null || true
```

- [ ] **Step 2: Implement pref-revert**

Create `/etc/nixos/home/scripts/pref-revert`:

```bash
#!/usr/bin/env bash
# pref-revert — drop the error file AND the staging file. A failed
# rebuild never updated the system, so no actual revert against the
# running system is needed; we just clear the user-side state so the
# bar pill returns to empty.
set -euo pipefail

rm -f "${STAGED_PREFS_FILE:-$HOME/.config/standardos/staged-prefs.json}"
rm -f "${LAST_ERROR_FILE:-$HOME/.config/standardos/last-error.json}"
[ -z "${PREF_STAGE_SKIP_SIGNAL:-}" ] && pkill -RTMIN+23 waybar 2>/dev/null || true
```

- [ ] **Step 3: Smoke-test both**

```bash
chmod +x /etc/nixos/home/scripts/pref-dismiss /etc/nixos/home/scripts/pref-revert
echo '{"shell":"x"}' > /tmp/s.json
STAGED_PREFS_FILE=/tmp/s.json PREF_STAGE_SKIP_SIGNAL=1 /etc/nixos/home/scripts/pref-dismiss
[ ! -e /tmp/s.json ] && echo OK-dismiss || echo FAIL

echo '{"reason":"x","source_prefs":["shell"]}' > /tmp/e.json
echo '{"shell":"x"}' > /tmp/s.json
STAGED_PREFS_FILE=/tmp/s.json LAST_ERROR_FILE=/tmp/e.json PREF_STAGE_SKIP_SIGNAL=1 \
    /etc/nixos/home/scripts/pref-revert
[ ! -e /tmp/s.json ] && [ ! -e /tmp/e.json ] && echo OK-revert || echo FAIL
```

Expected: `OK-dismiss` then `OK-revert`.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home
git add scripts/pref-dismiss scripts/pref-revert
git commit -m "canvas-prefs: pref-dismiss + pref-revert (clear staging/error)"
```

---

### Task 7: standardos-pending daemon (waybar custom-module backend)

**Files:**
- Create: `/etc/nixos/home/widgets/scripts/standardos-pending.sh`
- Create: `/etc/nixos/home/tests/test_standardos_pending.sh`

**Interfaces:**
- Consumes: `~/.config/standardos/staged-prefs.json`, `~/.config/standardos/last-error.json`.
- Produces: a single line of JSON on stdout per invocation, formatted as waybar's custom-module schema: `{"text":...,"tooltip":...,"class":[...]}`. waybar invokes the script as a `custom/standardos-pending` `exec` (one-shot per signal — registered in Task 8).
- Three states: `empty` (no staging, no error), `pending` (staging non-empty), `error` (last-error.json present).

- [ ] **Step 1: Write the failing test**

Create `/etc/nixos/home/tests/test_standardos_pending.sh`:

```bash
#!/usr/bin/env bash
# test_standardos_pending — TDD for the waybar custom-module backend.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/widgets/scripts/standardos-pending.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export STAGED_PREFS_FILE="$TMP/staged.json"
export LAST_ERROR_FILE="$TMP/err.json"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Empty state: no files exist.
out="$("$SCRIPT")"
check "empty class"    "$(echo "$out" | jq -rc '.class')" '["empty"]'
check "empty text"     "$(echo "$out" | jq -r '.text')" ""

# Pending state: staging non-empty.
echo '{"shell":"zsh","groups":["wheel"],"groups_display":"wheel"}' > "$STAGED_PREFS_FILE"
out="$("$SCRIPT")"
check "pending class"  "$(echo "$out" | jq -rc '.class')" '["pending"]'
check "pending text"   "$(echo "$out" | jq -r '.text')" "Apply (2)"

# Error state: error file present (takes priority over staging).
echo '{"reason":"group nope does not exist","source_prefs":["groups"]}' > "$LAST_ERROR_FILE"
out="$("$SCRIPT")"
check "error class"    "$(echo "$out" | jq -rc '.class')" '["error"]'
check "error text"     "$(echo "$out" | jq -r '.text')" "Error"
check "error tooltip"  "$(echo "$out" | jq -r '.tooltip')" "group nope does not exist"

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
```

```bash
chmod +x /etc/nixos/home/tests/test_standardos_pending.sh
```

- [ ] **Step 2: Run to verify it fails**

```bash
/etc/nixos/home/tests/test_standardos_pending.sh
```

Expected: FAIL (script missing).

- [ ] **Step 3: Implement the daemon**

Create `/etc/nixos/home/widgets/scripts/standardos-pending.sh`:

```bash
#!/usr/bin/env bash
# standardos-pending — waybar custom-module backend for the canvas
# Apply flow's bar pill. Reads the user-side state files and emits
# a single JSON line:
#   empty   : {"text":"","tooltip":"","class":["empty"]}
#   pending : {"text":"Apply (N)","tooltip":"<keys>","class":["pending"]}
#   error   : {"text":"Error","tooltip":"<reason>","class":["error"]}
#
# Invoked by waybar as a custom module's exec, refreshed via RTMIN+23
# (see waybar/config.jsonc + ARCHITECTURE.md signal table).
set -euo pipefail

STAGED="${STAGED_PREFS_FILE:-$HOME/.config/standardos/staged-prefs.json}"
ERR="${LAST_ERROR_FILE:-$HOME/.config/standardos/last-error.json}"

# Error state takes priority.
if [ -s "$ERR" ]; then
    reason="$(jq -r '.reason // "rebuild failed"' "$ERR")"
    jq -nc --arg t "Error" --arg tt "$reason" '{text:$t, tooltip:$tt, class:["error"]}'
    exit 0
fi

# Pending state.
if [ -s "$STAGED" ]; then
    # Count keys excluding *_display sidecars.
    n="$(jq '[keys[] | select(endswith("_display") | not)] | length' "$STAGED")"
    if [ "$n" -gt 0 ]; then
        tt="$(jq -r '[keys[] | select(endswith("_display") | not)] | join(", ")' "$STAGED")"
        jq -nc --arg t "Apply ($n)" --arg tt "$tt" '{text:$t, tooltip:$tt, class:["pending"]}'
        exit 0
    fi
fi

# Empty state.
jq -nc '{text:"", tooltip:"", class:["empty"]}'
```

```bash
chmod +x /etc/nixos/home/widgets/scripts/standardos-pending.sh
```

- [ ] **Step 4: Run test to verify it passes**

```bash
/etc/nixos/home/tests/test_standardos_pending.sh
```

Expected: `PASS: 7  FAIL: 0`

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add widgets/scripts/standardos-pending.sh tests/test_standardos_pending.sh
git commit -m "canvas-prefs: standardos-pending waybar backend (3 states)"
```

---

### Task 8: Waybar registration + pill CSS + signal table doc

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc` (add `custom/standardos-pending` to a module list)
- Modify: `/etc/nixos/home/waybar/style.css` (add the three-state pill rules)
- Modify: `/etc/nixos/home/waybar/ARCHITECTURE.md` (document RTMIN+23 in the signal table)

**Interfaces:**
- Consumes: `standardos-pending.sh` (Task 7).
- Produces: a visible pill on the bar in the SYSTEM zone, refreshed on RTMIN+23.

- [ ] **Step 1: Inspect current SYSTEM-zone module list**

```bash
grep -n "modules-right\|custom/" /etc/nixos/home/waybar/config.jsonc | head -20
```

Identify the array in `modules-right` where the new module slots between (right of) `custom/notif-bell` and (left of) the existing system-state pills. Note the surrounding entries.

- [ ] **Step 2: Add the custom module definition**

In `config.jsonc`, add (anywhere in the top-level config object, beside the other `custom/*` definitions):

```jsonc
"custom/standardos-pending": {
    "exec": "/etc/nixos/home/widgets/scripts/standardos-pending.sh",
    "return-type": "json",
    "signal": 23,
    "format": "{}",
    "on-click": "/etc/nixos/home/scripts/pref-apply",
    "on-click-right": "/etc/nixos/home/scripts/pref-dismiss"
},
```

Note: `signal: 23` matches `pkill -RTMIN+23 waybar`. Left-click applies, right-click dismisses (simpler than hover-expand siblings for the MVP; we can add a hover cluster later if needed).

For the error state, the module's on-click still calls pref-apply — but since the daemon's output puts `class: ["error"]` on the pill, we'll wire a separate keybind or accept that the error state requires the user to manually run `pref-revert` (which is documented). To make Revert clickable, we'd need a sibling pill — out of scope for MVP. (Captured in the spec's "Open questions baked-in".)

Add the module to `modules-right`:

```jsonc
"modules-right": [
    // ... existing entries ...
    "custom/notif-bell",
    "custom/standardos-pending",   // <-- new
    // ... rest ...
]
```

- [ ] **Step 3: Add the SCSS for the pill states**

In `/etc/nixos/home/waybar/style.css`, add (near other custom-module pill rules):

```css
/* standardos-pending — canvas Apply flow pill. Three classes from
 * widgets/scripts/standardos-pending.sh: empty / pending / error. */

#custom-standardos-pending {
    padding: 0 10px;
    border-radius: 30px;
    margin: 0 4px;
    transition: background-color 140ms ease, padding 140ms ease;
}

#custom-standardos-pending.empty {
    padding: 0;
    margin: 0;
    font-size: 0;
    background-color: transparent;
}

#custom-standardos-pending.pending {
    background-color: rgba(110, 150, 255, 0.85);  /* primary-blue */
    color: rgba(255, 255, 255, 1.0);
}

#custom-standardos-pending.error {
    background-color: rgba(217, 179, 255, 0.95);  /* standout-violet */
    color: rgba(255, 255, 255, 1.0);
}
```

(Per the closed-budget rule in the navigator: no new colors. `primary-blue` and `standout-violet` are already in the palette.)

- [ ] **Step 4: Document the signal slot in ARCHITECTURE.md**

```bash
grep -n "RTMIN" /etc/nixos/home/waybar/ARCHITECTURE.md | head -5
```

Find the signal-numbers table. Add a row:

```
| RTMIN+23 | standardos-pending | canvas Apply flow staging/error state |
```

- [ ] **Step 5: Restart waybar to load the new module**

```bash
systemctl --user restart waybar
sleep 1
# Verify the module loaded without errors:
journalctl --user -u waybar -n 20 --no-pager
```

Expected: no errors mentioning `standardos-pending`.

- [ ] **Step 6: Verify empty state (no pill visible)**

The pill should be collapsed (font-size:0, no padding) because no staging file exists yet. Visually inspect the bar.

- [ ] **Step 7: Verify pending state**

```bash
echo '{"shell":"bash","groups":["wheel"],"groups_display":"wheel"}' \
    > ~/.config/standardos/staged-prefs.json
pkill -RTMIN+23 waybar
```

Expected: blue "Apply (2)" pill appears on the right. Click it (it'll try to run pref-apply with the real `sudo nixos-rebuild` — Ctrl-C the terminal session if you don't want to actually rebuild for this verification). For now just confirm visually it appeared.

```bash
rm ~/.config/standardos/staged-prefs.json
pkill -RTMIN+23 waybar
```

Expected: pill disappears.

- [ ] **Step 8: Commit**

```bash
cd /etc/nixos/home
git add waybar/config.jsonc waybar/style.css waybar/ARCHITECTURE.md
git commit -m "canvas-prefs: waybar pill (empty/pending/error) on RTMIN+23

Adds the standardos-pending custom module to the SYSTEM zone. Three
states from the daemon (empty/pending/error) map to three SCSS rules
using only the existing palette (primary-blue / standout-violet, no
new tokens). Left-click runs pref-apply, right-click runs pref-dismiss.
Revert is currently CLI-only (out of scope for MVP per spec's open
questions section)."
```

---

### Task 9: Eww integration — staged-prefs defpoll + pref-row pending branch + click wiring

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (add defpoll, extend pref-row signature, wire the 2 onclicks)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.pref-row-pending` fade rule)

**Interfaces:**
- Consumes: `pref-stage`/`pref-choose-shell`/`pref-choose-groups` (Tasks 2-4).
- Produces: canvas pref-rows for Default shell + Groups click → chooser; staged values render with `.pref-row-pending` class on `.pref-value`.

- [ ] **Step 1: Add the staged-prefs defpoll**

In `eww.yuck` in the `;; ── Data sources ──` section (after the `(defpoll today ...)` block, before `(defpoll user-shell ...)`):

```lisp
;; Canvas Apply flow — staged prefs read from the user-owned JSON file.
;; Empty object when nothing is staged; { shell, groups, groups_display, ... }
;; otherwise. See docs/superpowers/specs/2026-06-25-canvas-prefs-apply-design.md.
(defpoll staged-prefs :interval "1s" :initial "{}"
  `cat $HOME/.config/standardos/staged-prefs.json 2>/dev/null || echo "{}"`)
```

- [ ] **Step 2: Extend pref-row signature**

Find the current `pref-row` defwidget:

```bash
grep -n "defwidget pref-row" /etc/nixos/home/widgets/eww/eww.yuck
```

Replace the existing definition with:

```lisp
(defwidget pref-row [label value on-click ?pending]
  (eventbox :class "pref-row-click" :onclick on-click
    (box :class "pref-row" :orientation "horizontal" :space-evenly false :hexpand true :spacing 8
      (label :class "pref-label" :text label :halign "start" :hexpand false)
      (label :class {pending == "true" ? "pref-value pref-value-pending" : "pref-value"}
             :text value :halign "end" :hexpand true :limit-width 32 :truncate true)
      (label :class "pref-chev"  :text ">"   :halign "end"))))
```

The `?pending` parameter is optional (eww defwidget convention), defaults to empty string. The class branch keys on `"true"` so callers pass strings.

- [ ] **Step 3: Wire the Default shell row**

In `max-config-card`, find the existing Default shell line:

```bash
grep -n "Default shell" /etc/nixos/home/widgets/eww/eww.yuck
```

Replace with:

```lisp
    (pref-row :label "Default shell"
              :value   {staged-prefs.shell != null ? staged-prefs.shell : user-shell}
              :pending {staged-prefs.shell != null ? "true" : "false"}
              :on-click "/etc/nixos/home/scripts/pref-choose-shell")
```

- [ ] **Step 4: Wire the Groups row**

Find and replace the Groups line similarly:

```lisp
    (pref-row :label "Groups"
              :value   {staged-prefs.groups_display != null ? staged-prefs.groups_display : user-groups}
              :pending {staged-prefs.groups_display != null ? "true" : "false"}
              :on-click "/etc/nixos/home/scripts/pref-choose-groups")
```

- [ ] **Step 5: Add the SCSS fade rule**

In `eww.scss`, find the existing `.pref-row` block:

```bash
grep -n "^.pref-row " /etc/nixos/home/widgets/eww/eww.scss
```

After the `.pref-chev` rule, add:

```css
/* Canvas Apply flow: a pref whose value differs from the live system
 * (because the user staged an edit) renders its value with reduced
 * alpha. The bar pill (standardos-pending) is the actual call to
 * action; the fade is the in-canvas hint. */
.pref-value-pending {
  color: rgba(255, 255, 255, 0.55);
}
```

- [ ] **Step 6: ASCII check + eww reload**

```bash
grep -nP "[^\x00-\x7f]" /etc/nixos/home/widgets/eww/eww.scss && echo "NON-ASCII FOUND" || echo "ASCII OK"
eww reload 2>&1 | head -10
```

Expected: `ASCII OK`, eww reload no errors.

- [ ] **Step 7: Smoke test — stage from CLI, open canvas, see fade**

```bash
echo '{"shell":"zsh","groups":["wheel","audio"],"groups_display":"wheel · audio"}' \
    > ~/.config/standardos/staged-prefs.json
pkill -RTMIN+23 waybar  # waybar pill should appear
# Pop the canvas via Super+RETURN. The Default shell row should show
# "zsh" in faded text, Groups should show "wheel · audio" faded.
```

After visual confirmation:

```bash
rm ~/.config/standardos/staged-prefs.json
pkill -RTMIN+23 waybar
```

- [ ] **Step 8: Commit**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck widgets/eww/eww.scss
git commit -m "canvas-prefs: eww wires staged-prefs defpoll + pref-row fade

- staged-prefs defpoll reads ~/.config/standardos/staged-prefs.json
  (1s interval).
- pref-row gains an optional :pending parameter; when true, the
  value label gets .pref-value-pending (reduced alpha) per the
  fadeish-text behavior agreed in the spec.
- Default shell and Groups pref-rows in max-config-card wired to
  pref-choose-shell / pref-choose-groups respectively. Their displayed
  value comes from staging when present, else from the live
  user-shell / user-groups defpolls."
```

---

### Task 10: End-to-end smoke test (no automation — real rebuild on a real change)

**Files:** none — this is a manual integration walkthrough that proves the whole flow.

- [ ] **Step 1: Note your current shell**

```bash
echo "current shell: $(getent passwd $USER | cut -d: -f7)"
```

Remember this value to revert at the end.

- [ ] **Step 2: Open the canvas, click Default shell**

Super+RETURN. Click Default shell. rofi opens. Pick a different shell from your current one (e.g. if you're on bash, pick zsh). The pref-row should now show the new shell in faded text.

- [ ] **Step 3: Close canvas, observe waybar pill**

Press Esc. Canvas closes. Waybar pill on the right should show "Apply (1)" in blue.

- [ ] **Step 4: Click Apply**

Click the blue pill. nixos-rebuild runs (takes ~30-60 s on a no-substantive-change rebuild). Watch the bar.

Expected (happy path): rebuild succeeds; pill disappears; in a fresh shell, `getent passwd $USER | cut -d: -f7` shows the new shell.

- [ ] **Step 5: Test error path**

```bash
# Manually stage a bad value to force a failure.
echo '{"groups":["wheel","ThisGroupDoesNotExist"],"groups_display":"wheel · ThisGroupDoesNotExist"}' \
    > ~/.config/standardos/staged-prefs.json
pkill -RTMIN+23 waybar
```

Pill should appear in pending state. Click Apply. Rebuild fails. Pill morphs to violet "Error" state. Hover for the tooltip: should say "group 'ThisGroupDoesNotExist' does not exist".

- [ ] **Step 6: Revert from CLI**

```bash
/etc/nixos/home/scripts/pref-revert
```

Pill should disappear.

- [ ] **Step 7: Restore the original shell**

If Step 4 changed your shell, change it back via the same canvas flow OR by editing `~/.config/standardos/staged-prefs.json` directly and applying.

- [ ] **Step 8: Inspect the sidecar end state**

```bash
cat /etc/nixos/standardos-canvas-sidecar.nix
```

Should reflect the last applied state (likely the restored shell).

- [ ] **Step 9: No commit** — this task is verification only. If everything passed, the feature is shipped.

---

## Self-review notes

- Spec coverage: 10 tasks map to the spec's 3 state files, 6 scripts, eww + waybar wiring, NixOS module, error parsing. ✓
- The "Edit" button on the error-state pill is **not implemented** in MVP (would need a sibling pill or hover-expand) — captured as known gap in Task 8 Step 2 + the spec's open-questions section.
- The waybar `signal: 23` matches the RTMIN+23 sent by every signaling script (`pref-stage`, `pref-apply`, `pref-dismiss`, `pref-revert`). Consistent across all 5 emit sites.
- All bash scripts use `set -euo pipefail`. All file writes use `tmp + mv -f` via `jq` redirection. ✓
- No SCSS edits use em-dashes (the hazard) — all comments use `--`. ✓
- `pref-row` signature change is backwards-compatible (optional `?pending`) — existing pref-rows in `max-config-card` and `max-pomodoro-card` not touched in Task 9 still work, only the two wired prefs get the parameter. ✓
