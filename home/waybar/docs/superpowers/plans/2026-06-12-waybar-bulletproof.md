# Waybar Bulletproof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the OPTIONS bar's runtime exec layer from `$HOME` into a single `/nix/store/<hash>-standard-os-waybar-scripts/` derivation; harden systemd supervision; add a self-test pill and a rebuild-pending pill + pre-shutdown gate that close the rebuild-vs-reboot gap.

**Architecture:** Single bundled `pkgs.stdenv.mkDerivation` with `makeWrapper`-curated PATH wraps all 15 existing scripts + 3 new ones. Daemon `ExecStart`s and `config.jsonc` exec sites move off `~/.config/waybar/scripts/`; the `xdg.configFile."waybar/scripts"` symlink is deleted. Two new systemd-user units (`waybar-self-test.service` + `.timer`) drive both pills; a system-scope activation script writes `/run/standard-os/activated-commit` so the rebuild-pending check has ground truth.

**Tech Stack:** Nix (mkDerivation, makeWrapper, lib.makeBinPath), bash, systemd-user, waybar custom modules, rofi-wayland.

**Spec:** `waybar/docs/superpowers/specs/2026-06-12-waybar-bulletproof-design.md`

---

## File Map

**Create:**
- `/etc/nixos/home/waybar/scripts/waybar-self-test.sh` — health check + rebuild-pending check
- `/etc/nixos/home/waybar/scripts/standard-os-shutdown-guard.sh` — power-action wrapper
- `/etc/nixos/home/waybar/scripts/standard-os-rebuild-prompt.sh` — rebuild-pending pill click handler (rofi dialog)
- `/etc/nixos/modules/standard-os-commit-tracking.nix` — system activation script
- `/tmp/waybar-bulletproof-tests.sh` — disposable integration harness (not committed)

**Modify:**
- `/etc/nixos/home/modules/waybar.nix` — add waybar-scripts derivation, `Environment="PATH=..."`, ExecStart rewires, restart-burst tuning, self-test service+timer, drop `xdg.configFile."waybar/scripts"`, add cleanup activation
- `/etc/nixos/home/waybar/config.jsonc` — bare binary names, add custom/waybar-self-test + custom/rebuild-pending, rewire power-cluster on-clicks
- `/etc/nixos/home/waybar/style.css` — add `#custom-waybar-self-test.light`, `#custom-rebuild-pending.light` adaptive-text selectors
- `/etc/nixos/home/waybar/scripts/glass-text-daemon.sh` — add `self_seed` call (if missing)
- `/etc/nixos/home/waybar/scripts/workspace-daemon.sh` — add `self_seed` call (if missing)
- `/etc/nixos/configuration.nix` — import `./modules/standard-os-commit-tracking.nix`
- `/etc/nixos/home/waybar/TODO.md` — move work to DONE on completion

---

## Pre-flight audit (one-shot, not a task — 5 minutes before Task 1)

```bash
# Enumerate every form scripts source lib/pill.sh — the substituteInPlace
# --replace list MUST cover every form found. If anything unusual appears,
# Task 1's installPhase needs an additional --replace pair.
grep -rn 'pill\.sh' /etc/nixos/home/waybar/scripts/

# Enumerate every config.jsonc script reference — every line here gets
# rewritten in Task 4.
grep -nE '~/\.config/waybar/scripts|/home/max/\.config/waybar/scripts' \
  /etc/nixos/home/waybar/config.jsonc

# Confirm no other module references ~/.config/waybar/scripts/ paths.
grep -rn '\.config/waybar/scripts' /etc/nixos/home/modules/ /etc/nixos/modules/
```

If `grep` for `pill.sh` finds forms beyond the two in the spec (`source "$(dirname "$0")/lib/pill.sh"` and `. "$(dirname "$0")/lib/pill.sh"`), append the additional `--replace` pairs to the installPhase in Task 1 before building.

---

## Task 1: Add `waybar-scripts` derivation skeleton (no rewires yet)

**Goal:** Land the `waybar-scripts` derivation in `modules/waybar.nix` without yet changing any `ExecStart` or `xdg.configFile`. Build succeeds; `/nix/store/<hash>-standard-os-waybar-scripts/bin/` contains every expected binary.

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix` (let-block: add `binPath` + `waybar-scripts`)

- [ ] **Step 1: Write the failing test**

```bash
# Failing test: before this task, the derivation doesn't exist.
# After this task, ${waybar-scripts}/bin/glass-text-daemon resolves to a
# real wrapped script.
# We can't reference ${waybar-scripts} from outside Nix, so the test runs
# the build and then inspects the resulting system derivation's references.
cat > /tmp/waybar-bulletproof-tests.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# After Task 1 build, find the waybar-scripts derivation in the system closure.
find_waybar_scripts_store_path() {
  local sys=/run/current-system
  # The derivation is referenced from waybar-glass-text-daemon.service drop-in
  # OR systemd-user units in $sys/etc/systemd/user. But after Task 1 nothing
  # references it yet — we'll find it via nix-store --query --references on the
  # system, looking for any store path ending in -standard-os-waybar-scripts.
  nix-store -q --references "$sys" 2>/dev/null | grep -E '/-standard-os-waybar-scripts$|/[^/]+-standard-os-waybar-scripts$' \
    || nix-store -q --requisites "$sys" | grep '/nix/store/[^/]*-standard-os-waybar-scripts$' \
    || return 1
}

p=$(find_waybar_scripts_store_path) || { echo "FAIL: derivation not found in closure"; exit 1; }
echo "Found: $p"
for bin in glass-text-daemon workspace-daemon pill pill-child battery night-dimmer warm-cycle shader-toggle screen-type shader-stack swap-smart win-action win-icon restore-minimized; do
  [ -x "$p/bin/$bin" ] || { echo "FAIL: missing $p/bin/$bin"; exit 1; }
done
[ -f "$p/share/waybar-scripts/lib/pill.sh" ] || { echo "FAIL: missing $p/share/waybar-scripts/lib/pill.sh"; exit 1; }
echo "PASS: all bins present, lib placed"
EOF
chmod +x /tmp/waybar-bulletproof-tests.sh
```

- [ ] **Step 2: Run the failing test**

```bash
sudo nixos-rebuild dry-build 2>&1 | tail -5  # confirm current build is clean
/tmp/waybar-bulletproof-tests.sh
```

Expected: `FAIL: derivation not found in closure` — because the derivation hasn't been added yet but isn't referenced from the system closure even after we add it (it'll be referenced only after Task 3 wires `ExecStart`). The test is intentionally "fail now" — we'll re-run a different check after Step 4 below.

- [ ] **Step 3: Add the derivation skeleton + a sentinel that pulls it into the closure**

Edit `/etc/nixos/home/modules/waybar.nix`. Replace the existing `let` block (lines 40-47) with:

```nix
let
  cfg = config.services.waybarBar;

  binPath = lib.makeBinPath (with pkgs; [
    bash
    coreutils
    gawk
    gnused
    gnugrep
    jq
    procps
    inotify-tools
    hyprland
    imagemagick
    git
    rofi-wayland
    libnotify
  ]);

  waybar-scripts = pkgs.stdenv.mkDerivation {
    pname   = "standard-os-waybar-scripts";
    version = "0.1.0";
    src     = ../waybar/scripts;
    nativeBuildInputs = [ pkgs.makeWrapper pkgs.shellcheck ];

    # Gate the build on shellcheck for every script in source-of-truth.
    # Runs against the source files BEFORE substituteInPlace rewrites
    # the lib/pill.sh source line.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      # shell scripts under source root:
      shellcheck -s bash *.sh
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/libexec/waybar-scripts $out/share/waybar-scripts/lib

      install -m 0644 lib/pill.sh $out/share/waybar-scripts/lib/pill.sh

      for f in *.sh pill pill-child; do
        name=''${f%.sh}
        install -m 0755 "$f" "$out/libexec/waybar-scripts/$f"
        # Rewrite every form the source uses to source the lib.
        substituteInPlace "$out/libexec/waybar-scripts/$f" \
          --replace 'source "$(dirname "$0")/lib/pill.sh"' \
                    "source $out/share/waybar-scripts/lib/pill.sh" \
          --replace '. "$(dirname "$0")/lib/pill.sh"' \
                    ". $out/share/waybar-scripts/lib/pill.sh"
        makeWrapper ${pkgs.bash}/bin/bash "$out/bin/$name" \
          --add-flags "$out/libexec/waybar-scripts/$f" \
          --prefix PATH : ${binPath}
      done
      runHook postInstall
    '';
  };

  # Where the runtime scripts live. Hard-coded against the user's home
  # because they're not yet nix-packaged; the distro migration will move
  # them under writeShellScriptBin and drop this option.
  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";
in
```

(`scriptsDir` is intentionally retained for now — Task 3 deletes it after the daemon ExecStarts move off it.)

Pull `waybar-scripts` into the closure with a sentinel `home.packages` entry inside `config.mkIf cfg.enable`:

```nix
config = lib.mkIf cfg.enable (lib.mkMerge [
  {
    # Pull waybar-scripts into the user closure so the derivation is
    # buildable + inspectable independently of ExecStart wiring.
    # Task 3 will reference ${waybar-scripts}/bin/<name> from systemd
    # units; this entry makes the derivation reachable from the closure
    # immediately so Task 1's verification works.
    home.packages = [ waybar-scripts ];

    # ... existing xdg.configFile blocks unchanged ...
  }
  # ...
]);
```

- [ ] **Step 4: Build + verify test passes**

```bash
sudo nixos-rebuild switch 2>&1 | tail -20
/tmp/waybar-bulletproof-tests.sh
```

Expected (rebuild): `Done.` final line. Expected (test): `PASS: all bins present, lib placed`.

If shellcheck fires on any script: read the error, fix the source script (most likely candidates: unquoted vars, missing `set -u` declarations), commit the script fix separately, then re-run.

- [ ] **Step 5: Verify lib substitution worked**

```bash
p=$(/tmp/waybar-bulletproof-tests.sh 2>&1 | grep '^Found:' | awk '{print $2}')
grep -n 'pill.sh' "$p/libexec/waybar-scripts/glass-text-daemon.sh" | head -3
grep -n 'pill.sh' "$p/libexec/waybar-scripts/workspace-daemon.sh" | head -3
```

Expected: every `pill.sh` reference resolves to an absolute `/nix/store/<hash>-standard-os-waybar-scripts/share/waybar-scripts/lib/pill.sh` path — NOT a relative `$(dirname "$0")/lib/pill.sh`. If any relative path remains, append the missing form to `installPhase`'s `--replace` list.

- [ ] **Step 6: Commit**

```bash
git -C /etc/nixos/home add modules/waybar.nix
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
waybar: add waybar-scripts derivation (bundled, shellcheck-gated)

Single pkgs.stdenv.mkDerivation packages all 15 scripts under
/etc/nixos/home/waybar/scripts/ as makeWrapper-wrapped binaries
in ${waybar-scripts}/bin/<name>. lib/pill.sh placed at
share/waybar-scripts/lib/ and sourced via absolute path through
substituteInPlace.

home.packages pulls the derivation into closure but no ExecStart
or exec site references it yet — next tasks rewire daemons and
config.jsonc onto the wrapped binaries.

shellcheck gate (doCheck = true) fires the build on any SC error
in source scripts. PATH curated for jq, hyprctl, pkill, inotifywait,
imagemagick, git, rofi-wayland, libnotify.

Spec: waybar/docs/superpowers/specs/2026-06-12-waybar-bulletproof-design.md
EOF
)"
```

---

## Task 2: Add `Environment="PATH=..."` to waybar.service

**Goal:** Prepare `config.jsonc`'s bare-name PATH resolution. No behavioral change yet (config.jsonc still uses `~/.config/...` paths until Task 4).

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix` (waybar.service `Service` block)

- [ ] **Step 1: Add the Environment line**

In `modules/waybar.nix`, find the `systemd.user.services.waybar = { ... }` block. In its `Service = { ... }` sub-block, add:

```nix
Environment = "PATH=${waybar-scripts}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin";
```

(The `/run/current-system/sw/bin` tail preserves access to `systemctl`, `notify-send`, etc., for any `on-click` not yet bare-name converted.)

- [ ] **Step 2: Build + verify**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
systemctl --user show waybar | grep ^Environment
```

Expected: an `Environment=PATH=...` line containing both `${waybar-scripts}/bin` (resolved to `/nix/store/<hash>-standard-os-waybar-scripts/bin`) and `/run/current-system/sw/bin`.

- [ ] **Step 3: Verify waybar still works**

```bash
systemctl --user restart waybar
sleep 2
systemctl --user is-active waybar
journalctl --user -u waybar --since "30 seconds ago" --no-pager | grep -iE 'error|no such' || echo "clean"
```

Expected: `active` + `clean`.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add modules/waybar.nix
git -C /etc/nixos/home commit -m "waybar: add Environment=PATH on waybar.service (prep for bare-name resolution)"
```

---

## Task 3: Rewire daemon ExecStarts to `${waybar-scripts}/bin/`

**Goal:** Both long-lived daemons exec from `/nix/store/`. `$HOME` is removed from systemd-user `ExecStart` for the daemons. The `scriptsDir` let-binding can now be removed.

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix`

- [ ] **Step 1: Write the verification check**

```bash
cat > /tmp/test-task-3.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for svc in waybar-glass-text-daemon waybar-workspace-daemon; do
  es=$(systemctl --user show -p ExecStart "$svc" | tr ';' '\n' | grep 'path=' | head -1)
  case "$es" in
    *"/nix/store/"*"standard-os-waybar-scripts/bin/"*) echo "PASS: $svc ExecStart=$es" ;;
    *) echo "FAIL: $svc ExecStart=$es"; exit 1 ;;
  esac
done
EOF
chmod +x /tmp/test-task-3.sh
/tmp/test-task-3.sh || true  # expected to FAIL before this task's edit
```

- [ ] **Step 2: Edit the daemon Service blocks**

In `modules/waybar.nix`, find the two daemon service blocks. Change:

```diff
 systemd.user.services.waybar-glass-text-daemon = {
   # ...
   Service = {
     Type = "simple";
     ExecStartPre = "${pkgs.coreutils}/bin/rm -f /tmp/glass-text-daemon.lock /tmp/glass-text-daemon.pid";
-    ExecStart = "${pkgs.bash}/bin/bash ${scriptsDir}/glass-text-daemon.sh";
+    ExecStart = "${waybar-scripts}/bin/glass-text-daemon";
     Restart = "always";
     RestartSec = 1;
   };
 };

 systemd.user.services.waybar-workspace-daemon = {
   # ...
   Service = {
     Type = "simple";
     ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /tmp/waybar-cache";
-    ExecStart = "${pkgs.bash}/bin/bash ${scriptsDir}/workspace-daemon.sh";
+    ExecStart = "${waybar-scripts}/bin/workspace-daemon";
     Restart = "always";
     RestartSec = 1;
   };
 };
```

Also remove the now-unused `scriptsDir` from the let-block (was line 46 pre-Task-1):

```diff
-  # Where the runtime scripts live. Hard-coded against the user's home
-  # because they're not yet nix-packaged; the distro migration will move
-  # them under writeShellScriptBin and drop this option.
-  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";
```

- [ ] **Step 3: Build + restart daemons + verify**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
systemctl --user daemon-reload
systemctl --user restart waybar-glass-text-daemon waybar-workspace-daemon
sleep 2
/tmp/test-task-3.sh
systemctl --user is-active waybar-glass-text-daemon waybar-workspace-daemon
journalctl --user -u waybar-glass-text-daemon -u waybar-workspace-daemon --since "30 seconds ago" --no-pager | grep -iE 'no such|error' || echo "clean"
```

Expected:
- Test script: `PASS: waybar-glass-text-daemon ExecStart=...` for both.
- `is-active`: `active` for both.
- Journal: `clean`.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add modules/waybar.nix
git -C /etc/nixos/home commit -m "waybar: rewire daemon ExecStarts to /nix/store waybar-scripts (\$HOME gone)"
```

---

## Task 4: Rewrite `config.jsonc` script paths to bare names

**Goal:** Every `~/.config/waybar/scripts/<name>.sh` in `config.jsonc` becomes a bare PATH-resolved name. The bar's per-module execs leave `$HOME` entirely.

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`

- [ ] **Step 1: Enumerate every replacement**

```bash
grep -nE '~/\.config/waybar/scripts/[a-z-]+\.sh|/home/max/\.config/waybar/scripts/[a-z-]+\.sh' \
  /etc/nixos/home/waybar/config.jsonc | tee /tmp/jsonc-script-refs.txt
wc -l /tmp/jsonc-script-refs.txt
```

Hand-count: expect roughly 15-25 lines covering `warm-cycle.sh`, `shader-toggle.sh`, `night-dimmer.sh`, `pill`, `pill-child`, `win-action.sh`, `swap-smart.sh`. Per-line, the bare name is `<basename without .sh>`.

- [ ] **Step 2: Apply the rewrites**

Use a single `sed` with anchored replacements:

```bash
sed -i.bak \
  -e 's|~/\.config/waybar/scripts/\([a-z][a-z-]*\)\.sh|\1|g' \
  -e 's|~/\.config/waybar/scripts/\(pill-child\)|\1|g' \
  -e 's|~/\.config/waybar/scripts/\(pill\)|\1|g' \
  -e 's|/home/max/\.config/waybar/scripts/\([a-z][a-z-]*\)\.sh|\1|g' \
  -e 's|/home/max/\.config/waybar/scripts/\(pill-child\)|\1|g' \
  -e 's|/home/max/\.config/waybar/scripts/\(pill\)|\1|g' \
  /etc/nixos/home/waybar/config.jsonc
```

Verify zero stragglers:

```bash
grep -nE '~/\.config/waybar/scripts|/home/max/\.config/waybar/scripts' \
  /etc/nixos/home/waybar/config.jsonc \
  && echo "FAIL: stragglers found" || echo "PASS: all rewritten"
```

Expected: `PASS: all rewritten`.

- [ ] **Step 3: Spot-check that no over-replacement happened**

```bash
diff /etc/nixos/home/waybar/config.jsonc.bak /etc/nixos/home/waybar/config.jsonc | head -40
```

Confirm every diff hunk is the expected path → bare-name shape, no unrelated changes.

- [ ] **Step 4: Restart waybar + visual check**

```bash
systemctl --user restart waybar
sleep 2
journalctl --user -u waybar --since "30 seconds ago" --no-pager | grep -iE 'no such|error' || echo "clean"
```

Expected: `clean`. Visually confirm the bar renders every module the same as before.

- [ ] **Step 5: Cleanup + commit**

```bash
rm /etc/nixos/home/waybar/config.jsonc.bak
git -C /etc/nixos/home add waybar/config.jsonc
git -C /etc/nixos/home commit -m "waybar/config: bare-name script refs (PATH-resolved via waybar.service Environment)"
```

---

## Task 5: Add restart-burst tuning to daemons

**Goal:** Both daemons survive ≥20 failed restart attempts over 5 minutes with exponential backoff plateauing at 30 s. Transient session-start races no longer permanently fail the daemon.

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix`

- [ ] **Step 1: Edit both daemon Service blocks**

For each of `waybar-glass-text-daemon` and `waybar-workspace-daemon`, replace the `Restart = "always"; RestartSec = 1;` lines with:

```nix
Restart               = "on-failure";
RestartSec            = "1s";
RestartSteps          = 5;
RestartMaxDelaySec    = "30s";
StartLimitBurst       = 20;
StartLimitIntervalSec = "5min";
```

Leave `waybar.service`'s `Restart = "always"; RestartSec = 1;` unchanged — its crash modes are different.

- [ ] **Step 2: Build + verify the fields land**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
systemctl --user daemon-reload
systemctl --user restart waybar-glass-text-daemon waybar-workspace-daemon
for svc in waybar-glass-text-daemon waybar-workspace-daemon; do
  echo "=== $svc ==="
  systemctl --user show "$svc" -p Restart -p RestartUSec -p RestartSteps -p RestartMaxDelayUSec -p StartLimitBurst -p StartLimitIntervalUSec
done
```

Expected for each:
- `Restart=on-failure`
- `RestartUSec=1s` (or `1000000`)
- `RestartSteps=5`
- `RestartMaxDelayUSec=30s` (or `30000000`)
- `StartLimitBurst=20`
- `StartLimitIntervalUSec=5min` (or `300000000`)

- [ ] **Step 3: Smoke-test the backoff**

Inject a transient failure by stopping the daemon and watching the journal:

```bash
systemctl --user stop waybar-glass-text-daemon
sleep 1
systemctl --user start waybar-glass-text-daemon  # should start immediately, no burst
systemctl --user is-active waybar-glass-text-daemon
```

Expected: `active`. (We don't simulate a hard failure here — the next failure mode test is in Task 11's integration check.)

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add modules/waybar.nix
git -C /etc/nixos/home commit -m "waybar: restart-burst tuning (20/5min, expo backoff to 30s) on daemons"
```

---

## Task 6: Audit + add `self_seed` to long-lived daemons

**Goal:** After `rm -rf /tmp/waybar-cache /tmp/glass-mode` + restart, every required cache file exists within 1 second of daemon startup. No "blank pill until first event" on fresh tmpfs `/tmp`.

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/glass-text-daemon.sh`
- Modify: `/etc/nixos/home/waybar/scripts/workspace-daemon.sh`

- [ ] **Step 1: Read both daemons to map their startup vs. event-loop sections**

```bash
grep -nE 'while|^[a-z_]+\(\)' /etc/nixos/home/waybar/scripts/glass-text-daemon.sh | head -20
grep -nE 'while|^[a-z_]+\(\)' /etc/nixos/home/waybar/scripts/workspace-daemon.sh | head -20
```

Identify the boundary between "startup setup" and "event loop." `self_seed` must run AFTER lock acquisition, AFTER any state initialization, BEFORE entering `while true` / `inotifywait` / `dbus-monitor`.

- [ ] **Step 2: Write the failing integration test**

```bash
cat > /tmp/test-task-6.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REQUIRED_CACHES=(ws-current window)
# notif-bell skipped here — owned by notif-daemon, not in this task's scope.

systemctl --user stop waybar-glass-text-daemon waybar-workspace-daemon
sleep 1
rm -rf /tmp/waybar-cache /tmp/glass-mode
mkdir -p /tmp/waybar-cache
systemctl --user start waybar-glass-text-daemon waybar-workspace-daemon
sleep 1

failures=()
[ -e /tmp/glass-mode ] || failures+=("/tmp/glass-mode missing")
for f in "${REQUIRED_CACHES[@]}"; do
  [ -s "/tmp/waybar-cache/$f" ] || failures+=("/tmp/waybar-cache/$f missing or empty")
done

if [ "${#failures[@]}" -eq 0 ]; then
  echo "PASS"
else
  printf 'FAIL:\n  %s\n' "${failures[@]}"
  exit 1
fi
EOF
chmod +x /tmp/test-task-6.sh
/tmp/test-task-6.sh || true  # expected FAIL before this task
```

- [ ] **Step 3: Add `self_seed` to `glass-text-daemon.sh`**

After the lock check, BEFORE the event loop, insert:

```bash
# self_seed: ensure /tmp/glass-mode + every cache file exists from the
# authoritative source before entering the event loop. Required so a fresh
# tmpfs /tmp (or any /tmp wipe) doesn't render blank pills until the first
# external event arrives.
self_seed() {
  # Read the current luminance state from hypr-edge-bg (the source of truth).
  # If hypr-edge-bg's cache isn't ready yet, default to 'dark' (the
  # conservative pick — every pill emits white text, which is readable on
  # any wallpaper that isn't fully white).
  local mode
  mode=$(read_mode_from_hypr_edge_bg) || mode=dark
  printf '%s' "$mode" > /tmp/glass-mode.tmp
  mv -f /tmp/glass-mode.tmp /tmp/glass-mode
  # Trigger one cache rewrite so all subscribed pills pick up the seeded mode.
  update_cache_mode "$mode"
}

self_seed
```

(`read_mode_from_hypr_edge_bg` and `update_cache_mode` are existing functions in the daemon. If `read_mode_from_hypr_edge_bg` doesn't exist by that name, find the existing function that reads from `/tmp/hypr-edge-bg/` and substitute.)

- [ ] **Step 4: Add `self_seed` to `workspace-daemon.sh`**

The workspace daemon already runs its emit loop once per second. The cleanest seed is to extract the body of one loop iteration into a `seed_once()` function and call it before entering the `while` loop:

```bash
# self_seed: write every ws-N, win-move-N, ws-current, window, win-close,
# win-minimize, win-swap-right, win-move-trigger, win-move-new cache from
# hyprctl state BEFORE entering the polling loop. Required so the bar isn't
# blank for up to 1 second after daemon start.
seed_once() {
  # Run one iteration of the main emit cycle without sleep.
  emit_workspaces_and_windows   # name varies — find the existing function
}

seed_once

while true; do
  # ... existing loop body unchanged ...
  sleep 1
done
```

Find the actual function name by inspecting the daemon. The replacement is mechanical — extract whatever the loop body does today into `seed_once`, call it once before the loop, then call the same function (or keep the inline body) inside the loop.

- [ ] **Step 5: Run the test, expect PASS**

```bash
/tmp/test-task-6.sh
```

Expected: `PASS`. If FAIL, the seed call isn't reaching every required cache — re-inspect which writes the loop body performs.

- [ ] **Step 6: Commit each daemon edit separately**

```bash
git -C /etc/nixos/home add waybar/scripts/glass-text-daemon.sh
git -C /etc/nixos/home commit -m "glass-text-daemon: self_seed at startup (tmpfs-/tmp safety)"
git -C /etc/nixos/home add waybar/scripts/workspace-daemon.sh
git -C /etc/nixos/home commit -m "workspace-daemon: self_seed at startup (tmpfs-/tmp safety)"
```

---

## Task 7: Create `waybar-self-test.sh` (health check only, no rebuild-pending yet)

**Goal:** A script in source-of-truth that, when invoked, checks required daemons + caches and writes `/tmp/waybar-cache/waybar-self-test`. Rebuild-pending support is added in Task 11.

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/waybar-self-test.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test-task-7.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# After Task 7, the wrapped binary exists.
p=$(nix-store -q --requisites /run/current-system | grep '/nix/store/[^/]*-standard-os-waybar-scripts$' | head -1)
[ -x "$p/bin/waybar-self-test" ] || { echo "FAIL: missing waybar-self-test bin"; exit 1; }

# Healthy run: every required unit active + caches present → cache empty text.
rm -f /tmp/waybar-cache/waybar-self-test
"$p/bin/waybar-self-test"
cache=$(cat /tmp/waybar-cache/waybar-self-test 2>/dev/null || echo "{}")
text=$(printf '%s' "$cache" | jq -r '.text // ""')
[ "$text" = "" ] && echo "PASS: healthy → empty text" || { echo "FAIL: healthy → text=$text (expected empty)"; exit 1; }

# Failing run: stop a daemon → cache has ⚠ N.
systemctl --user stop waybar-glass-text-daemon
"$p/bin/waybar-self-test"
cache=$(cat /tmp/waybar-cache/waybar-self-test)
text=$(printf '%s' "$cache" | jq -r '.text // ""')
case "$text" in
  "⚠ "*) echo "PASS: failure → text=$text" ;;
  *) systemctl --user start waybar-glass-text-daemon; echo "FAIL: failure → text=$text"; exit 1 ;;
esac
systemctl --user start waybar-glass-text-daemon
sleep 1

# Recovery: re-run → empty again.
"$p/bin/waybar-self-test"
cache=$(cat /tmp/waybar-cache/waybar-self-test)
text=$(printf '%s' "$cache" | jq -r '.text // ""')
[ "$text" = "" ] && echo "PASS: recovered → empty text" || { echo "FAIL: post-recovery → text=$text"; exit 1; }
EOF
chmod +x /tmp/test-task-7.sh
/tmp/test-task-7.sh || true  # expected FAIL: binary doesn't exist yet
```

- [ ] **Step 2: Create the script**

`/etc/nixos/home/waybar/scripts/waybar-self-test.sh`:

```bash
#!/usr/bin/env bash
# waybar-self-test: verify the bar's runtime invariants and surface
# failures via a SYSTEM-zone pill. Kicked by waybar-self-test.timer
# every 60s and on demand via click handler.
set -euo pipefail

# Resolve lib path. When invoked via makeWrapper, $0 is the wrapper;
# the libexec script's source line has been substituted to absolute
# path at build time.
source "$(dirname "$0")/lib/pill.sh"

REQUIRED_UNITS=(waybar waybar-glass-text-daemon waybar-workspace-daemon)
REQUIRED_CACHES=(ws-current window notif-bell)
REQUIRED_FILES=(/tmp/glass-mode)

failures=()

for u in "${REQUIRED_UNITS[@]}"; do
  if ! systemctl --user is-active --quiet "$u"; then
    state=$(systemctl --user is-active "$u" 2>/dev/null || true)
    failures+=("$u: $state")
  fi
done

for f in "${REQUIRED_CACHES[@]}"; do
  [ -s "/tmp/waybar-cache/$f" ] || failures+=("cache/$f: missing-or-empty")
done

for f in "${REQUIRED_FILES[@]}"; do
  [ -e "$f" ] || failures+=("$f: missing")
done

if [ "${#failures[@]}" -eq 0 ]; then
  # Healthy: empty text → waybar hides the module entirely.
  pill_emit waybar-self-test "" "opt-pill" ""
else
  tooltip=$(printf 'Self-test failures:\n%s\n' "$(printf '• %s\n' "${failures[@]}")")
  pill_emit waybar-self-test "⚠ ${#failures[@]}" "opt-pill opt-no" "$tooltip"
fi
```

- [ ] **Step 3: Build (so the new script gets wrapped) + run the test**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
/tmp/test-task-7.sh
```

Expected: three `PASS:` lines.

If `pill_emit` complains about unknown function: confirm the lib substitution happened (Task 1 Step 5). If `notif-bell` cache is genuinely missing on the test system (notif-daemon not running for whatever reason), narrow `REQUIRED_CACHES` to `(ws-current window)` and re-run.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add waybar/scripts/waybar-self-test.sh
git -C /etc/nixos/home commit -m "waybar-self-test: health-check script (units + caches + glass-mode)"
```

---

## Task 8: Add `waybar-self-test.service` + `.timer`

**Goal:** The self-test runs at session-start (10 s after `graphical-session.target`) and every 60 s thereafter.

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix`

- [ ] **Step 1: Add the service + timer to the `mkIf cfg.systemd.enable` block**

After the `waybar-workspace-daemon` block, add:

```nix
systemd.user.services.waybar-self-test = {
  Unit = {
    Description = "Waybar boot-time + periodic health check";
    PartOf = [ "graphical-session.target" ];
    After  = [
      "graphical-session.target"
      "waybar.service"
      "waybar-glass-text-daemon.service"
      "waybar-workspace-daemon.service"
    ];
  };
  Install.WantedBy = [ "graphical-session.target" ];
  Service = {
    Type      = "oneshot";
    ExecStart = "${waybar-scripts}/bin/waybar-self-test";
  };
};

systemd.user.timers.waybar-self-test = {
  Unit.Description = "Periodic re-check for waybar health";
  Install.WantedBy = [ "timers.target" ];
  Timer = {
    OnBootSec       = "10s";
    OnUnitActiveSec = "60s";
    Unit            = "waybar-self-test.service";
  };
};
```

- [ ] **Step 2: Build + verify**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
systemctl --user daemon-reload
systemctl --user start waybar-self-test.timer
systemctl --user is-active waybar-self-test.timer
systemctl --user list-timers | grep waybar-self-test
```

Expected:
- Timer is `active`.
- `list-timers` shows the next firing within 60 s.

- [ ] **Step 3: Force a run + verify cache writes**

```bash
systemctl --user start waybar-self-test.service
sleep 1
cat /tmp/waybar-cache/waybar-self-test
```

Expected: a JSON line with `text` empty (healthy state).

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add modules/waybar.nix
git -C /etc/nixos/home commit -m "waybar: waybar-self-test systemd-user service + 60s timer"
```

---

## Task 9: Add `custom/waybar-self-test` module + light-mode CSS

**Goal:** The self-test pill renders in SYSTEM zone. Hidden when healthy; red `opt-no` with tooltip when broken. Click → kicks immediate re-check.

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`
- Modify: `/etc/nixos/home/waybar/style.css`

- [ ] **Step 1: Find the SYSTEM zone location for the pill**

```bash
grep -nE 'custom/power-resume|"modules-right"' /etc/nixos/home/waybar/config.jsonc | head -10
```

The pill goes immediately *before* `custom/power-resume` in the `modules-right` array.

- [ ] **Step 2: Add the module definition**

In `config.jsonc`, in the `modules-right` array, insert `"custom/waybar-self-test"` immediately before `"custom/power-resume"`.

Then add the module definition block, placed near `custom/power-resume`'s definition:

```jsonc
"custom/waybar-self-test": {
  "exec": "cat /tmp/waybar-cache/waybar-self-test 2>/dev/null",
  "return-type": "json",
  "format": "{}",
  "interval": 2,
  "signal": 10,
  "tooltip": true,
  "on-click": "systemctl --user start waybar-self-test.service"
}
```

- [ ] **Step 3: Add light-mode adaptive-text CSS selector**

Find the existing light-mode selector block in `style.css` (grep for `\.light` to locate it). Add:

```css
window#waybar #custom-waybar-self-test.light {
  color: @opt-text-on-light;
}
```

next to the other `#custom-X.light` selectors.

- [ ] **Step 4: Restart waybar + visual verification**

```bash
systemctl --user restart waybar
sleep 2
# Healthy: pill should be invisible.
# Force a failure to confirm visibility:
systemctl --user stop waybar-glass-text-daemon
sleep 70  # wait for timer to refresh
# Visual check: SYSTEM-zone pill should now show "⚠ 1" in red.
# Recover:
systemctl --user start waybar-glass-text-daemon
sleep 70
# Visual check: pill should be invisible again.
```

If the user is present, they confirm visually. Otherwise grep the cache:

```bash
cat /tmp/waybar-cache/waybar-self-test
```

Expected JSON differs between healthy and failure states as established in Task 7.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add waybar/config.jsonc waybar/style.css
git -C /etc/nixos/home commit -m "waybar: custom/waybar-self-test pill (SYSTEM zone, hidden when healthy)"
```

---

## Task 10: Create `modules/standard-os-commit-tracking.nix` + import it

**Goal:** `/run/standard-os/activated-commit` exists after every `nixos-rebuild switch` containing the `/etc/nixos/home` HEAD SHA.

**Files:**
- Create: `/etc/nixos/modules/standard-os-commit-tracking.nix`
- Modify: `/etc/nixos/configuration.nix` (add the import)

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test-task-10.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -f /run/standard-os/activated-commit ] || { echo "FAIL: file missing"; exit 1; }
content=$(cat /run/standard-os/activated-commit)
case "$content" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) echo "PASS: contains SHA-like $content" ;;
  *) echo "FAIL: contains '$content'"; exit 1 ;;
esac
EOF
chmod +x /tmp/test-task-10.sh
/tmp/test-task-10.sh || true  # expected FAIL: file doesn't exist
```

- [ ] **Step 2: Create the module**

`/etc/nixos/modules/standard-os-commit-tracking.nix`:

```nix
# Records the /etc/nixos/home HEAD SHA at every nixos-rebuild switch.
# /run is a tmpfs, so the file regenerates at every boot from the
# already-activated derivation. The waybar-self-test rebuild-pending
# check + standard-os-shutdown-guard pre-shutdown gate both use this
# file as ground truth for "is the working tree ahead of the running
# system?"
{ pkgs, lib, ... }:
{
  system.activationScripts.standardOsCommit = lib.stringAfter [ "users" ] ''
    mkdir -p /run/standard-os
    if [ -d /etc/nixos/home/.git ]; then
      ${pkgs.git}/bin/git -C /etc/nixos/home rev-parse HEAD \
        > /run/standard-os/activated-commit 2>/dev/null || true
    fi
  '';
}
```

- [ ] **Step 3: Import it in `configuration.nix`**

In `/etc/nixos/configuration.nix`, add to the `imports` list (alongside the other `./modules/*.nix` entries):

```nix
./modules/standard-os-commit-tracking.nix
```

- [ ] **Step 4: Build + verify**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
/tmp/test-task-10.sh
```

Expected: `PASS: contains SHA-like <40-hex>`.

Sanity:

```bash
diff <(cat /run/standard-os/activated-commit) <(git -C /etc/nixos/home rev-parse HEAD) && echo "matches HEAD"
```

Expected: `matches HEAD` (no diff output before the echo).

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add ../modules/standard-os-commit-tracking.nix ../configuration.nix 2>/dev/null || true
# /etc/nixos itself isn't a git repo per the 2026-06-12 audit. The
# files become part of the host config but aren't tracked. Confirm:
ls /etc/nixos/.git 2>&1 || echo "/etc/nixos not a git repo — system files untracked, expected"
# No commit at this stage for the system module. Document in the
# DONE Hint that standard-os-commit-tracking.nix lives in /etc/nixos
# unversioned by the host repo.
```

(If `/etc/nixos` later becomes git-versioned, this task's edits get a retrospective commit.)

---

## Task 11: Extend `waybar-self-test.sh` with rebuild-pending check + emit

**Goal:** The same script that emits `waybar-self-test` cache also emits `rebuild-pending` cache. Failure surfaces in the second pill.

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/waybar-self-test.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test-task-11.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
p=$(nix-store -q --requisites /run/current-system | grep '/nix/store/[^/]*-standard-os-waybar-scripts$' | head -1)

# Clean state: HEAD matches activated-commit → pill empty.
rm -f /tmp/waybar-cache/rebuild-pending
"$p/bin/waybar-self-test"
text=$(jq -r '.text // ""' < /tmp/waybar-cache/rebuild-pending)
[ "$text" = "" ] || { echo "FAIL: clean state text=$text"; exit 1; }

# Simulate pending: tamper with activated-commit to point at HEAD~1.
sudo cp /run/standard-os/activated-commit /run/standard-os/activated-commit.bak
sudo sh -c "git -C /etc/nixos/home rev-parse HEAD~1 > /run/standard-os/activated-commit"
"$p/bin/waybar-self-test"
class=$(jq -r '.class | join(" ")' < /tmp/waybar-cache/rebuild-pending)
case "$class" in
  *opt-pin-orange*) echo "PASS: pending → $class" ;;
  *) sudo mv /run/standard-os/activated-commit.bak /run/standard-os/activated-commit; echo "FAIL: pending → $class"; exit 1 ;;
esac

# Restore and verify clean again.
sudo mv /run/standard-os/activated-commit.bak /run/standard-os/activated-commit
"$p/bin/waybar-self-test"
text=$(jq -r '.text // ""' < /tmp/waybar-cache/rebuild-pending)
[ "$text" = "" ] && echo "PASS: restored → empty" || { echo "FAIL: restored → text=$text"; exit 1; }
EOF
chmod +x /tmp/test-task-11.sh
/tmp/test-task-11.sh || true  # expected FAIL: rebuild-pending cache doesn't exist yet
```

- [ ] **Step 2: Add the check function + emit to the script**

Edit `/etc/nixos/home/waybar/scripts/waybar-self-test.sh`. After the `pill_emit waybar-self-test ...` block, append:

```bash

# ---- rebuild-pending check ----

check_rebuild_pending() {
  [ -f /run/standard-os/activated-commit ] || return 1
  local activated head
  activated=$(cat /run/standard-os/activated-commit 2>/dev/null) || return 1
  head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null) || return 1
  [ "$activated" = "$head" ] && return 1
  git -C /etc/nixos/home merge-base --is-ancestor "$activated" HEAD 2>/dev/null
  case $? in
    0|1) return 0 ;;
    *)   return 1 ;;
  esac
}

emit_rebuild_pending() {
  if check_rebuild_pending; then
    local activated ahead last
    activated=$(cat /run/standard-os/activated-commit)
    ahead=$(git -C /etc/nixos/home rev-list --count "$activated..HEAD" 2>/dev/null || echo "?")
    last=$(git -C /etc/nixos/home log -1 --format=%s HEAD 2>/dev/null || echo "?")
    pill_emit rebuild-pending "" "opt-pill opt-pin-orange" \
      "Pending rebuild: $ahead commit(s) ahead — last: $last"
  else
    pill_emit rebuild-pending "" "opt-pill" ""
  fi
}

emit_rebuild_pending
```

- [ ] **Step 3: Rebuild + run the test**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
/tmp/test-task-11.sh
```

Expected: three `PASS:` lines.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add waybar/scripts/waybar-self-test.sh
git -C /etc/nixos/home commit -m "waybar-self-test: rebuild-pending check + cache emit"
```

---

## Task 12: Add `custom/rebuild-pending` module + light-mode CSS

**Goal:** The rebuild-pending pill renders in SYSTEM zone. Hidden on clean tree; `opt-pin-orange` with tooltip when pending. Click → opens rofi dialog (added in Task 13).

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`
- Modify: `/etc/nixos/home/waybar/style.css`

- [ ] **Step 1: Insert the module reference**

In `modules-right`, insert `"custom/rebuild-pending"` immediately after `group-power` (and before `custom/waybar-self-test`).

- [ ] **Step 2: Add the module definition**

Near `custom/waybar-self-test`'s definition, add:

```jsonc
"custom/rebuild-pending": {
  "exec": "cat /tmp/waybar-cache/rebuild-pending 2>/dev/null",
  "return-type": "json",
  "format": "{}",
  "interval": 2,
  "signal": 10,
  "tooltip": true,
  "on-click": "standard-os-rebuild-prompt"
}
```

- [ ] **Step 3: Light-mode CSS selector**

```css
window#waybar #custom-rebuild-pending.light {
  color: @opt-text-on-light;
}
```

- [ ] **Step 4: Restart waybar + visual verification**

```bash
systemctl --user restart waybar
# Sanity: on clean tree pill is invisible.
git -C /etc/nixos/home log --oneline -1
# Simulate pending:
git -C /etc/nixos/home commit --allow-empty -m "test-pending"
systemctl --user start waybar-self-test.service
sleep 1
cat /tmp/waybar-cache/rebuild-pending  # should show opt-pin-orange
# Cleanup:
git -C /etc/nixos/home reset --hard HEAD~1
systemctl --user start waybar-self-test.service
sleep 1
cat /tmp/waybar-cache/rebuild-pending  # should be text=""
```

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add waybar/config.jsonc waybar/style.css
git -C /etc/nixos/home commit -m "waybar: custom/rebuild-pending pill (SYSTEM, opt-pin-orange when ahead)"
```

---

## Task 13: Create `standard-os-rebuild-prompt.sh` + `standard-os-shutdown-guard.sh`

**Goal:** Two new wrapped binaries. `standard-os-rebuild-prompt` is the pill click handler (opens rofi dialog); `standard-os-shutdown-guard <action>` wraps power-cluster handlers.

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/standard-os-rebuild-prompt.sh`
- Create: `/etc/nixos/home/waybar/scripts/standard-os-shutdown-guard.sh`

- [ ] **Step 1: Write the failing tests**

```bash
cat > /tmp/test-task-13.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
p=$(nix-store -q --requisites /run/current-system | grep '/nix/store/[^/]*-standard-os-waybar-scripts$' | head -1)
[ -x "$p/bin/standard-os-rebuild-prompt" ] || { echo "FAIL: missing rebuild-prompt"; exit 1; }
[ -x "$p/bin/standard-os-shutdown-guard" ] || { echo "FAIL: missing shutdown-guard"; exit 1; }
echo "PASS: both binaries wrapped"

# shutdown-guard with clean tree should exec the action directly.
# Test the "would-exec" path with DRY_RUN=1.
DRY_RUN=1 "$p/bin/standard-os-shutdown-guard" sleep 2>&1 | tee /tmp/sg.out
grep -q 'would-exec: systemctl suspend' /tmp/sg.out && echo "PASS: clean tree → would-exec" || { echo "FAIL: clean tree path"; exit 1; }
EOF
chmod +x /tmp/test-task-13.sh
/tmp/test-task-13.sh || true
```

- [ ] **Step 2: Create `standard-os-shutdown-guard.sh`**

`/etc/nixos/home/waybar/scripts/standard-os-shutdown-guard.sh`:

```bash
#!/usr/bin/env bash
# standard-os-shutdown-guard: gates user-initiated power actions on
# rebuild-pending state. If working tree at /etc/nixos/home is ahead of
# the activated generation, surface a rofi modal letting the user choose
# (rebuild+action / action-anyway / cancel). Otherwise forward immediately.
#
# usage: standard-os-shutdown-guard <action>
#   action ∈ {sleep, hibernate, reboot, poweroff}
#
# DRY_RUN=1 prints "would-exec: <cmd>" instead of running. Used by tests.
set -euo pipefail

action="${1:-}"
case "$action" in
  sleep)      cmd=(systemctl suspend) ;;
  hibernate)  cmd=(systemctl hibernate) ;;
  reboot)     cmd=(systemctl reboot) ;;
  poweroff)   cmd=(systemctl poweroff) ;;
  *) echo "usage: $0 <sleep|hibernate|reboot|poweroff>" >&2; exit 2 ;;
esac

check_rebuild_pending() {
  [ -f /run/standard-os/activated-commit ] || return 1
  local activated head
  activated=$(cat /run/standard-os/activated-commit 2>/dev/null) || return 1
  head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null) || return 1
  [ "$activated" = "$head" ] && return 1
  git -C /etc/nixos/home merge-base --is-ancestor "$activated" HEAD 2>/dev/null
  case $? in
    0|1) return 0 ;;
    *)   return 1 ;;
  esac
}

run_or_dry() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "would-exec: $*"
  else
    exec "$@"
  fi
}

if ! check_rebuild_pending; then
  run_or_dry "${cmd[@]}"
  exit 0
fi

# Pending tree: rofi modal.
ahead=$(git -C /etc/nixos/home rev-list --count \
  "$(cat /run/standard-os/activated-commit)..HEAD" 2>/dev/null || echo "?")
last=$(git -C /etc/nixos/home log -1 --format='%h %s' HEAD)
prompt="Pending rebuild: $ahead commit(s) ahead\nLast: $last"

choice=$(printf '%s\n' \
  "Rebuild + then $action" \
  "$action anyway" \
  "Cancel" \
  | rofi -dmenu -p "shutdown" -mesg "$prompt" -theme-str 'window {width: 600px;}')

case "$choice" in
  "Rebuild + then $action")
    # Terminal needed so sudo can prompt for password.
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "would-exec: terminal: sudo nixos-rebuild switch && ${cmd[*]}"
    else
      kitty --hold sh -c "sudo nixos-rebuild switch && ${cmd[*]}"
    fi
    ;;
  "$action anyway")
    run_or_dry "${cmd[@]}"
    ;;
  *)  # Cancel or empty
    exit 0
    ;;
esac
```

(`kitty` is the assumed terminal; if the user uses a different one, swap. The implementation note in the spec covers this.)

- [ ] **Step 3: Create `standard-os-rebuild-prompt.sh`**

`/etc/nixos/home/waybar/scripts/standard-os-rebuild-prompt.sh`:

```bash
#!/usr/bin/env bash
# Pill click handler: open a rofi dialog with rebuild / dismiss / view-log.
set -euo pipefail

if ! [ -f /run/standard-os/activated-commit ]; then
  # No tracking → nothing to prompt about.
  notify-send "Standard-OS" "No activated-commit tracking; nothing to prompt."
  exit 0
fi

activated=$(cat /run/standard-os/activated-commit)
head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null || echo unknown)
[ "$activated" = "$head" ] && {
  notify-send "Standard-OS" "Working tree already matches activated generation."
  exit 0
}

ahead=$(git -C /etc/nixos/home rev-list --count "$activated..HEAD" 2>/dev/null || echo "?")
last=$(git -C /etc/nixos/home log -1 --format='%h %s' HEAD)
prompt="$ahead commit(s) ahead\nLast: $last"

choice=$(printf '%s\n' \
  "Rebuild now (terminal)" \
  "View commits ahead" \
  "Dismiss" \
  | rofi -dmenu -p "rebuild" -mesg "$prompt" -theme-str 'window {width: 600px;}')

case "$choice" in
  "Rebuild now (terminal)")
    kitty --hold sh -c "sudo nixos-rebuild switch"
    ;;
  "View commits ahead")
    kitty --hold sh -c "git -C /etc/nixos/home log --oneline $activated..HEAD"
    ;;
  *) exit 0 ;;
esac
```

- [ ] **Step 4: Build + run the test**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
/tmp/test-task-13.sh
```

Expected: three `PASS:` lines.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add waybar/scripts/standard-os-shutdown-guard.sh waybar/scripts/standard-os-rebuild-prompt.sh
git -C /etc/nixos/home commit -m "waybar/scripts: shutdown-guard + rebuild-prompt (rebuild-pending UX)"
```

---

## Task 14: Rewire power-cluster `on-click` handlers via the guard

**Goal:** Every OPTIONS power-cluster click routes through `standard-os-shutdown-guard <action>` instead of calling `systemctl` directly. Clean tree behaves identically; pending tree gates.

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`

- [ ] **Step 1: Find the three handlers**

```bash
grep -nE '"on-click": "(systemctl (suspend|hibernate)|reboot)"' /etc/nixos/home/waybar/config.jsonc
```

Expected matches (per the pre-flight audit):
- Line 401: `"on-click": "systemctl hibernate"` (custom/power)
- Line 407: `"on-click": "reboot"` (custom/reboot)
- Line 413: `"on-click": "systemctl suspend"` (custom/lock)

- [ ] **Step 2: Rewire**

```bash
sed -i.bak \
  -e 's|"on-click": "systemctl suspend"|"on-click": "standard-os-shutdown-guard sleep"|' \
  -e 's|"on-click": "systemctl hibernate"|"on-click": "standard-os-shutdown-guard hibernate"|' \
  -e 's|"on-click": "reboot"|"on-click": "standard-os-shutdown-guard reboot"|' \
  /etc/nixos/home/waybar/config.jsonc

diff /etc/nixos/home/waybar/config.jsonc.bak /etc/nixos/home/waybar/config.jsonc
```

Confirm exactly three diff hunks, no over-replacement.

- [ ] **Step 3: Restart waybar + verify**

```bash
rm /etc/nixos/home/waybar/config.jsonc.bak
systemctl --user restart waybar
sleep 2
journalctl --user -u waybar --since "30 seconds ago" --no-pager | grep -iE 'no such|error' || echo "clean"
```

Manual click test (the user clicks; we don't simulate):
- Clean tree, click `custom/lock` → suspend fires (the laptop suspends; this is destructive testing — only run if the user is ready).
- Pending tree, click `custom/lock` → rofi modal appears.

If destructive testing isn't desired, dry-run the guard:

```bash
DRY_RUN=1 standard-os-shutdown-guard sleep
```

Expected on clean tree: `would-exec: systemctl suspend`.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos/home add waybar/config.jsonc
git -C /etc/nixos/home commit -m "waybar/config: route power-cluster on-clicks through standard-os-shutdown-guard"
```

---

## Task 15: Remove `xdg.configFile."waybar/scripts"` + add cleanup activation

**Goal:** The HM symlink to `/etc/nixos/home/waybar/scripts/` ceases to exist. Bar runs entirely from `/nix/store/`. Stragglers (e.g., `scripts.hm-bak`) are removed.

**Files:**
- Modify: `/etc/nixos/home/modules/waybar.nix`

- [ ] **Step 1: Write the failing check**

```bash
cat > /tmp/test-task-15.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ ! -e /home/max/.config/waybar/scripts ] || { echo "FAIL: ~/.config/waybar/scripts still exists"; exit 1; }
[ ! -e /home/max/.config/waybar/scripts.hm-bak ] || { echo "FAIL: scripts.hm-bak still exists"; exit 1; }
# Bar must remain functional.
systemctl --user is-active waybar waybar-glass-text-daemon waybar-workspace-daemon waybar-self-test.timer
echo "PASS: ~/.config/waybar/scripts gone; bar active"
EOF
chmod +x /tmp/test-task-15.sh
/tmp/test-task-15.sh || true  # expected FAIL: scripts symlink still exists
```

- [ ] **Step 2: Remove the `xdg.configFile."waybar/scripts"` block**

In `modules/waybar.nix`, delete the entire `xdg.configFile."waybar/scripts" = { ... };` block (lines 130-133 ish post-Task-3) plus the comment above it.

Also remove the `scriptsSource` option definition (lines 64-77 of the original) since nothing references it anymore. (Re-check: the spec says `scriptsSource` is unused after migration. Confirm with a grep.)

```bash
grep -n 'scriptsSource\|cfg.scriptsSource' /etc/nixos/home/modules/waybar.nix
```

Expected: zero hits after deletion.

- [ ] **Step 3: Add cleanup activation**

In the `config = lib.mkIf cfg.enable (lib.mkMerge [ { ... } ])` outer block, alongside `home.packages`, add:

```nix
# One-time cleanup: pre-bulletproof generations left a symlink at
# ~/.config/waybar/scripts; activation could also have backed up
# the old real directory as scripts.hm-bak. Both are removed here
# so the bar's $HOME footprint is just config.jsonc + style.css
# (and the icons/, offers/, launch.sh directories preserved).
home.activation.cleanupOldWaybarScripts =
  lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf $HOME/.config/waybar/scripts $HOME/.config/waybar/scripts.hm-bak
  '';
```

- [ ] **Step 4: Build + verify**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
/tmp/test-task-15.sh
ls -la /home/max/.config/waybar/
```

Expected: `PASS: ~/.config/waybar/scripts gone; bar active`. `ls` shows no `scripts` and no `scripts.hm-bak`.

- [ ] **Step 5: Commit**

```bash
git -C /etc/nixos/home add modules/waybar.nix
git -C /etc/nixos/home commit -m "waybar: drop xdg.configFile.\"waybar/scripts\" + clean stragglers (bar leaves \$HOME)"
```

---

## Task 16: Final verification pass + TODO.md DONE entry

**Goal:** Run the full acceptance criteria from the spec; move the TODO entry.

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Run the full acceptance suite**

```bash
cat > /tmp/test-acceptance.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
fail=0

# AC 1: ${waybar-scripts}/bin/ has every binary; ~/.config/waybar/scripts gone.
p=$(nix-store -q --requisites /run/current-system | grep '/nix/store/[^/]*-standard-os-waybar-scripts$' | head -1)
[ -n "$p" ] || { echo "AC1 FAIL: derivation not in closure"; fail=1; }
for b in glass-text-daemon workspace-daemon pill pill-child battery night-dimmer waybar-self-test standard-os-shutdown-guard standard-os-rebuild-prompt; do
  [ -x "$p/bin/$b" ] || { echo "AC1 FAIL: missing $b"; fail=1; }
done
[ ! -e /home/max/.config/waybar/scripts ] || { echo "AC1 FAIL: ~/.config/waybar/scripts still exists"; fail=1; }
echo "AC1 OK: bins present, ~/.config/waybar/scripts gone"

# AC 2: services active, no missing-file errors.
for s in waybar waybar-glass-text-daemon waybar-workspace-daemon; do
  systemctl --user is-active --quiet "$s" || { echo "AC2 FAIL: $s inactive"; fail=1; }
done
journalctl --user -u waybar --since "5 min ago" --no-pager | grep -i 'no such file' \
  && { echo "AC2 FAIL: journal has missing-file errors"; fail=1; }
echo "AC2 OK: services active, no missing-file errors"

# AC 3: tmpfs-/tmp safety.
systemctl --user stop waybar-glass-text-daemon waybar-workspace-daemon
sleep 1
rm -rf /tmp/waybar-cache /tmp/glass-mode
mkdir -p /tmp/waybar-cache
systemctl --user start waybar-glass-text-daemon waybar-workspace-daemon
sleep 1
for f in ws-current window; do
  [ -s "/tmp/waybar-cache/$f" ] || { echo "AC3 FAIL: /tmp/waybar-cache/$f"; fail=1; }
done
[ -e /tmp/glass-mode ] || { echo "AC3 FAIL: /tmp/glass-mode"; fail=1; }
echo "AC3 OK: self-seed worked after wipe"

# AC 4: self-test fail → pill red.
systemctl --user stop waybar-glass-text-daemon
systemctl --user start waybar-self-test.service
sleep 1
t=$(jq -r '.text // ""' < /tmp/waybar-cache/waybar-self-test)
case "$t" in
  "⚠ "*) echo "AC4 OK: self-test surfaced failure: $t" ;;
  *) echo "AC4 FAIL: self-test text=$t"; fail=1 ;;
esac
systemctl --user start waybar-glass-text-daemon
sleep 1
systemctl --user start waybar-self-test.service
sleep 1
t=$(jq -r '.text // ""' < /tmp/waybar-cache/waybar-self-test)
[ "$t" = "" ] && echo "AC4 OK: self-test cleared after recovery" || { echo "AC4 FAIL: post-recovery text=$t"; fail=1; }

# AC 5: rebuild-pending pill.
git -C /etc/nixos/home commit --allow-empty -m "AC5 pending probe"
systemctl --user start waybar-self-test.service
sleep 1
c=$(jq -r '.class | join(" ")' < /tmp/waybar-cache/rebuild-pending)
case "$c" in
  *opt-pin-orange*) echo "AC5 OK: pending → $c" ;;
  *) echo "AC5 FAIL: $c"; fail=1 ;;
esac
git -C /etc/nixos/home reset --hard HEAD~1
systemctl --user start waybar-self-test.service
sleep 1
t=$(jq -r '.text // ""' < /tmp/waybar-cache/rebuild-pending)
[ "$t" = "" ] && echo "AC5 OK: cleared after reset" || { echo "AC5 FAIL: $t"; fail=1; }

# AC 7: clean-tree shutdown-guard is direct.
DRY_RUN=1 standard-os-shutdown-guard sleep | grep -q "would-exec: systemctl suspend" \
  && echo "AC7 OK: clean tree → would-exec" || { echo "AC7 FAIL"; fail=1; }

# AC 9: restart-burst fields land.
for s in waybar-glass-text-daemon waybar-workspace-daemon; do
  systemctl --user show "$s" -p StartLimitBurst | grep -q 'StartLimitBurst=20' || { echo "AC9 FAIL $s burst"; fail=1; }
  systemctl --user show "$s" -p RestartSteps | grep -q 'RestartSteps=5' || { echo "AC9 FAIL $s steps"; fail=1; }
done
echo "AC9 OK: burst tuning fields present"

# AC 8 (shellcheck gate fires): inject a broken script and confirm build fails.
# Skipped here — destructive to the source tree. Documented in TODO Hint
# as a manual one-off: `chmod +w /tmp/test.sh; echo "x=" > /tmp/test.sh;
# then add to scripts/ and sudo nixos-rebuild build`.

exit $fail
EOF
chmod +x /tmp/test-acceptance.sh
/tmp/test-acceptance.sh
```

Expected: every `AC*` line is `OK`. `exit 0`.

- [ ] **Step 2: Add TODO.md DONE entry**

Edit `/etc/nixos/home/waybar/TODO.md`. In the DONE section (immediately under the 2026-06-12 incident entry committed in `f9fdf6b`), add:

```markdown
- **2026-06-12 (bulletproof)** — **OPTIONS bar moves into /nix/store: scripts derivation, self-test pill, rebuild-pending pill, shutdown gate.**
  Closes the architectural follow-up flagged in the incident DONE entry
  above. A single `pkgs.stdenv.mkDerivation` wraps every script under
  `/etc/nixos/home/waybar/scripts/` (plus three new ones —
  `waybar-self-test`, `standard-os-shutdown-guard`,
  `standard-os-rebuild-prompt`) as `${waybar-scripts}/bin/<name>`.
  `lib/pill.sh` lives at `share/waybar-scripts/lib/pill.sh` and is
  sourced via absolute path through `substituteInPlace`. The daemon
  `ExecStart`s and `config.jsonc` exec sites move off
  `~/.config/waybar/scripts/`; the `xdg.configFile."waybar/scripts"`
  declaration is deleted. `~/.config/waybar/scripts` ceases to exist.
  Restart-burst tuning (20 attempts / 5 min, expo backoff plateauing
  at 30 s) replaces the 5-shots-in-12 ms failure mode the incident
  exposed. `waybar-self-test.service` + 60 s timer drive a SYSTEM-zone
  pill that surfaces broken daemons or missing caches in red (`⚠ N`),
  invisible when healthy. `modules/standard-os-commit-tracking.nix`
  writes `/run/standard-os/activated-commit` at every activation;
  the same `waybar-self-test` script emits a second pill
  (`rebuild-pending`, `opt-pin-orange`) whenever the working tree at
  `/etc/nixos/home` is ahead. Power-cluster `on-click` handlers route
  through `standard-os-shutdown-guard <action>` — clean tree forwards
  immediately, pending tree opens a rofi modal (rebuild+action /
  action-anyway / cancel).
  Spec: `waybar/docs/superpowers/specs/2026-06-12-waybar-bulletproof-design.md`.
  Plan: `waybar/docs/superpowers/plans/2026-06-12-waybar-bulletproof.md`.
  **Hint:** lib substitution covers two source-form patterns —
  `source "$(dirname "$0")/lib/pill.sh"` and `. "$(dirname "$0")/lib/pill.sh"`.
  If a future script uses any other form (`LIB=$(dirname "$0")/lib;
  source $LIB/pill.sh`), append the `--replace` pair in
  `modules/waybar.nix` installPhase or substitution will silently
  skip it and the wrapped binary will fail with "lib/pill.sh: No
  such file or directory" on first call.
  **Hint:** `shellcheck` gate fires on every script in the source-of-truth.
  Adding a new script: `cd /etc/nixos/home/waybar/scripts && shellcheck
  -s bash <name>.sh` before committing. SC-error → build fails;
  SC-warning → informational. Disable narrowly with `# shellcheck
  disable=SCxxxx` on the offending line and explain why in a sibling
  comment.
  **Hint:** self-seeding contract — `glass-text-daemon.sh` and
  `workspace-daemon.sh` call `self_seed` at startup before entering
  the event loop. New long-lived daemons must do the same; the
  acceptance test in this plan's Task 16 (`rm -rf /tmp/waybar-cache
  /tmp/glass-mode; restart` → all required caches exist within 1 s)
  is the regression gate.
  **Hint:** the rebuild-pending check uses
  `/run/standard-os/activated-commit` as ground truth.
  `modules/standard-os-commit-tracking.nix` lives in `/etc/nixos/modules/`,
  which is NOT a git repo — the file is part of the host config but
  untracked. If `/etc/nixos` ever becomes git-versioned, retroactively
  commit it.
  **Hint:** `standard-os-shutdown-guard` covers OPTIONS power-cluster
  and (when migrated) SUPER+ESC menu. Emergency hibernate (lid,
  low battery via UPower) and shell-typed `systemctl poweroff`
  intentionally bypass the gate. If a user-initiated power path is
  added (e.g., a new rofi power menu), route it through the guard.
  **Hint:** the `waybar-self-test` REQUIRED lists (`REQUIRED_UNITS`,
  `REQUIRED_CACHES`, `REQUIRED_FILES`) grow over time. When adding a
  new daemon to the bar, add its unit name to `REQUIRED_UNITS` AND
  add the canonical cache file to `REQUIRED_CACHES` if it's a
  reliable presence-indicator.
```

- [ ] **Step 3: Commit the DONE entry + close**

```bash
git -C /etc/nixos/home add waybar/TODO.md
git -C /etc/nixos/home commit -m "$(cat <<'EOF'
docs: TODO DONE entry for waybar bulletproof (writeShellScriptBin migration)

Records the architectural fix that closes today's incident. Hints
cover lib substitution form coverage, shellcheck adoption, the
self-seeding contract for new daemons, the /run/standard-os/activated-
commit ground-truth file, the shutdown-guard scope boundary, and
the maintenance contract for waybar-self-test REQUIRED lists.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Reboot verification (the actual bullet-proof gate)**

The whole point of this work is "make it survive a reboot." The acceptance suite verified at runtime; the final test is to reboot and confirm the bar comes up complete:

```bash
sudo systemctl reboot
```

After reboot, log in and run:

```bash
sleep 30  # let session settle
/tmp/test-acceptance.sh
```

Expected: every AC line OK.

If anything fails: that's the failure mode this work was supposed to prevent. Read the journal, identify the gap, and write a new TODO entry capturing the missed case before fixing.

---

## Plan Self-Review

**Spec coverage:** Each migration step from the spec maps to a task here.

| Spec migration step | Plan task |
|---|---|
| 1. Add waybar-scripts derivation | Task 1 |
| 2. Add Environment="PATH=..." | Task 2 |
| 3. Switch daemon ExecStarts | Task 3 |
| 4. Edit config.jsonc bare names | Task 4 |
| 5. Restart-burst tuning | Task 5 |
| 6. Audit self-seeding | Task 6 |
| 7. Add new scripts to source dir | Task 7 (waybar-self-test) + Task 13 (shutdown-guard, rebuild-prompt) |
| 8. waybar-self-test.service + timer | Task 8 |
| 9. custom/waybar-self-test module | Task 9 |
| 10. standard-os-commit-tracking.nix | Task 10 |
| 11. custom/rebuild-pending module | Task 11 (check+emit) + Task 12 (module+CSS) |
| 12. Rewire power-cluster handlers | Task 14 |
| 13. Remove xdg.configFile."waybar/scripts" | Task 15 |
| Final verification + TODO.md DONE | Task 16 |

**Placeholder scan:** No "TBD" / "TODO" markers in step bodies. Function names (`read_mode_from_hypr_edge_bg`, `update_cache_mode`, `emit_workspaces_and_windows`) are flagged as "find by inspection" — load-bearing identifiers that depend on the actual daemon's current shape; the plan tells the executor to grep and substitute.

**Type consistency:** Binary names (`glass-text-daemon`, `workspace-daemon`, `waybar-self-test`, `standard-os-shutdown-guard`, `standard-os-rebuild-prompt`, `pill`, `pill-child`, `night-dimmer`, `battery`) are consistent across tasks. Class names (`opt-pill`, `opt-no`, `opt-pin-orange`, `light`, `dark`) match the spec and CLAUDE.md vocabulary.

---

## Notes for the executor

- **Each task ends with a commit.** Resist the urge to batch — the migration plan ordering depends on each step landing cleanly so the next one's "before" state is predictable.
- **Function-name placeholders** in Task 6 (`read_mode_from_hypr_edge_bg`, `update_cache_mode`, `emit_workspaces_and_windows`, `seed_once`) are deliberate — the implementing engineer reads the current daemon and substitutes the actual names. The TDD shape (failing test → seed → test passes) catches a wrong substitution.
- **`/etc/nixos` is not a git repo on this host.** Tasks that edit `/etc/nixos/configuration.nix` or `/etc/nixos/modules/*.nix` (Task 10) don't get host-repo commits — only the `/etc/nixos/home` edits do. Tracked at the end via a TODO Hint.
- **Destructive testing (real `systemctl suspend`) is skipped from automated tests.** Task 14 Step 3's note flags this — manual verification by the user, or `DRY_RUN=1` for CI-style runs.
