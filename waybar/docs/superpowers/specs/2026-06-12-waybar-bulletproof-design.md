# Waybar bulletproof: end the $HOME runtime dep + close the rebuild-vs-reboot gap

**Date:** 2026-06-12
**Status:** Approved (pending user review of this written doc).
**Triggered by:** 2026-06-12 incident — post-reboot blank bar caused by commit `a8d720a` (scripts/ → HM symlink) shipping without a `nixos-rebuild switch` before the user rebooted to validate the 2026-06-11 sleep/hibernate kernel-param changes. The activated HM at boot was the pre-migration generation; `~/.config/waybar/scripts/` was never materialized; every script-driven module + both HM-managed daemons failed.
**Scope:** Three layered hardenings of the OPTIONS bar — (a) the runtime exec path leaves `$HOME` entirely, (b) the bar surfaces its own health, (c) the rebuild-vs-reboot gap closes.

---

## Purpose

The 2026-06-12 incident was not unlucky timing. The bar's *runtime architecture* makes it fragile by design: `modules/waybar.nix`'s `scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts"` ties every daemon and every per-module `exec` to a path under `$HOME`. Any missed activation, partial HM run, `rm -rf ~/.config`, or fresh-install-before-user-activation breaks the entire interactive layer.

This spec moves the bar's runtime path into `/nix/store/` (where every other system binary lives), tunes the supervisory layer so transient races at session-start don't permanently fail a daemon, and adds two new persistent surfaces — a self-test pill and a rebuild-pending pill — so failures the user *would have missed* become visible. A pre-shutdown gate intercepts the "commit, then reboot to test the OTHER thing, find the bar broken" pattern at the moment it happens.

The non-negotiables from the standard-os skill — OPTIONS as the shell, closed budget, parents-naturally-uncolored, input-acknowledged/context-silent, same-option-same-look — are preserved end-to-end.

---

## Architecture overview

```
Before (the 2026-06-12 incident shape):

  ~/.config/waybar/scripts/         (HM out-of-store symlink; load-bearing)
   ├── glass-text-daemon.sh         (systemd ExecStart targets this)
   ├── workspace-daemon.sh          (systemd ExecStart targets this)
   ├── lib/pill.sh                  (every script sources this relatively)
   └── …13 other scripts…           (config.jsonc execs from ~/...)

  Failure mode: any break in the symlink chain or missed activation
                empties the entire interactive layer of the bar.

After:

  /nix/store/<hash>-standard-os-waybar-scripts/
   ├── bin/glass-text-daemon         (makeWrapper → bash + curated PATH)
   ├── bin/workspace-daemon
   ├── bin/waybar-self-test
   ├── bin/standard-os-shutdown-guard
   ├── bin/standard-os-rebuild-prompt
   ├── bin/pill, pill-child
   ├── bin/battery, night-dimmer, …
   └── share/waybar-scripts/lib/pill.sh

  ~/.config/waybar/scripts          (DELETED)

  systemd ExecStart                  → ${waybar-scripts}/bin/<name>
  waybar.service Environment=PATH=   = ${waybar-scripts}/bin:…
  config.jsonc exec                  = bare names (PATH-resolved)
```

The bar stops caring about `$HOME` for its runtime path. Source-of-truth lives in `/etc/nixos/home/waybar/scripts/` (git-versioned) and is materialized into `/nix/store/` at every rebuild — same shape as every other Nix module.

Two new long-lived surfaces join the SYSTEM zone:

- `custom/waybar-self-test` — hidden at rest; appears red when any required daemon is down or any required cache is missing.
- `custom/rebuild-pending` — hidden at rest; appears `opt-pin-orange` whenever the working tree at `/etc/nixos/home` has commits ahead of `/run/standard-os/activated-commit`.

A new system-level integration intercepts the power-off path:

- `standard-os-shutdown-guard` — wrapped binary; OPTIONS power-cluster `on-click` handlers (and the SUPER+ESC power menu) route through it. On a clean tree it forwards the action immediately; on a pending tree it shows a rofi modal letting the user choose [Rebuild + then `<action>`] / [`<action>` anyway] / [Cancel].

---

## Components

### 1. The `waybar-scripts` derivation

A single `pkgs.stdenv.mkDerivation` in `modules/waybar.nix` bundles every script under `/etc/nixos/home/waybar/scripts/` plus the new scripts introduced by this spec (`waybar-self-test`, `standard-os-shutdown-guard`, `standard-os-rebuild-prompt`).

```nix
let
  binPath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnused
    pkgs.gnugrep
    pkgs.jq
    pkgs.procps
    pkgs.inotify-tools
    pkgs.hyprland
    pkgs.imagemagick
    pkgs.git           # rebuild-pending + shutdown-guard need it
    pkgs.rofi-wayland  # shutdown-guard modal
    pkgs.libnotify     # optional notif fallback
  ];

  waybar-scripts = pkgs.stdenv.mkDerivation {
    pname   = "standard-os-waybar-scripts";
    version = "0.1.0";
    src     = ../waybar/scripts;
    nativeBuildInputs = [ pkgs.makeWrapper pkgs.shellcheck ];

    # shellcheck gate: fail the build on any SC error in our scripts.
    checkPhase = ''
      runHook preCheck
      shellcheck -x -s bash *.sh
      runHook postCheck
    '';
    doCheck = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/libexec/waybar-scripts \
               $out/share/waybar-scripts/lib

      install -m 0644 lib/pill.sh \
        $out/share/waybar-scripts/lib/pill.sh

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
in
…
```

Key shapes:

- `bin/<name>` — `makeWrapper` entrypoints. `.sh` suffix stripped from script-named binaries so the wrapped names match the existing `dictate-waybar` convention. `pill` and `pill-child` keep their literal names.
- `libexec/waybar-scripts/` — rewritten scripts after `substituteInPlace`.
- `share/waybar-scripts/lib/pill.sh` — one copy, sourced by absolute path from every wrapped script.
- One shared `binPath` (union of every script's needs). Per-script PATH curation is finer-grained but adds 15× boilerplate without measurable closure-size benefit (most of these tools are already in the waybar closure).
- `shellcheck` enforced via `checkPhase` — any `SC*` error in any script fails the build.

Source-of-truth lives at `/etc/nixos/home/waybar/scripts/`. The `xdg.configFile."waybar/scripts"` declaration from commit `a8d720a` is **removed**; `~/.config/waybar/scripts` ceases to exist after activation. A one-time `home.activation` step cleans up stragglers:

```nix
home.activation.cleanupOldWaybarScripts =
  lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf $HOME/.config/waybar/scripts $HOME/.config/waybar/scripts.hm-bak
  '';
```

### 2. `config.jsonc` path resolution via `PATH`

`config.jsonc` stays `mkOutOfStoreSymlink`'d (live edits, no rebuild for module ordering / class tweaks / tooltip text). Script resolution moves to bare names resolved via the bar's `Environment="PATH=…"`:

```nix
systemd.user.services.waybar.Service = {
  Environment = "PATH=${waybar-scripts}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin";
  # … rest unchanged
};
```

Every `~/.config/waybar/scripts/<name>.sh` reference in `config.jsonc` becomes a bare binary name:

```diff
- "exec": "~/.config/waybar/scripts/night-dimmer.sh exec",
+ "exec": "night-dimmer exec",

- "exec": "~/.config/waybar/scripts/pill '' opt-plus",
+ "exec": "pill '' opt-plus",

- "exec": "~/.config/waybar/scripts/pill-child '󰍁' opt-yes",
+ "exec": "pill-child '󰍁' opt-yes",
```

`cat`, `jq`, `dictate-waybar`, and other existing PATH-resolved sites stay unchanged. Click handlers follow the same pattern.

Why not `pkgs.replaceVars` into the store? Loses live iteration on `config.jsonc` (module reordering, class tweaks, tooltip edits) — these get edited far more often than scripts. The PATH path is the cheapest preservation of that workflow once the wrapper is wired correctly. The "pure store" choice the user made was scoped to *scripts* (the runtime exec layer), not static text config.

Daemon `ExecStart` stays absolute (`${waybar-scripts}/bin/<name>`), not PATH-relative — systemd-user units have a minimal default PATH; `ExecStart` resolution should not depend on it.

### 3. systemd unit hardening + self-seeding contract

**ExecStart rewires:**

```nix
systemd.user.services.waybar-glass-text-daemon.Service = {
  ExecStartPre = "${pkgs.coreutils}/bin/rm -f /tmp/glass-text-daemon.lock /tmp/glass-text-daemon.pid";
  ExecStart    = "${waybar-scripts}/bin/glass-text-daemon";
  Restart              = "on-failure";
  RestartSec           = "1s";
  RestartSteps         = 5;
  RestartMaxDelaySec   = "30s";
  StartLimitBurst      = 20;
  StartLimitIntervalSec = "5min";
};

systemd.user.services.waybar-workspace-daemon.Service = {
  ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /tmp/waybar-cache";
  ExecStart    = "${waybar-scripts}/bin/workspace-daemon";
  # same restart fields
};
```

`Restart=always` → `Restart=on-failure` — graceful stops (e.g., during shutdown) shouldn't trigger restart cycles. The five-step backoff plateaus at 30 s; the 20-attempt burst over 5 minutes covers transient races at session-start (compositor not yet ready, wayland-socket race, etc.) without permanently failing on persistent bugs.

`waybar.service` stays `Restart=always` — its crash modes (unhandled RTMIN+N, IPC hiccups) are different and benefit from immediate restart.

**Self-seeding contract for long-lived daemons:**

Every long-lived daemon writes its initial cache atomically *before* entering its event loop. This is invisible on this host (`/tmp` is non-tmpfs and pre-reboot cache survives), but a fresh distro install onto a tmpfs `/tmp` exposes the contract violation as blank pills until the first external event arrives.

```bash
# At top of each daemon, AFTER lock check, BEFORE event loop:
self_seed() {
  # 1. Compute current state from authoritative source
  #    (glass-text: hypr-edge-bg luminance file; workspace: hyprctl)
  # 2. Atomically write every cache file this daemon owns (pill_emit handles this)
  # 3. Signal waybar (pkill -RTMIN+N) so it picks up the seed
}
self_seed
# now enter event loop
```

The interval-`exec` modules (`battery`, `night-dimmer`, `pill`, `pill-child`, `warm-cycle`, `shader-toggle`) already self-contain because waybar exec's them on every tick.

The implementation plan adds a test that, after `rm -rf /tmp/waybar-cache /tmp/glass-mode` + restart of both daemons + waybar, asserts every expected cache file exists within 1 s.

### 4. `waybar-self-test` service + pill

A new systemd-user oneshot (kicked at session-start and every 60 s by a timer) verifies the bar's runtime invariants and writes `/tmp/waybar-cache/waybar-self-test`.

```nix
systemd.user.services.waybar-self-test = {
  Unit = {
    Description = "Waybar boot-time + periodic health check";
    PartOf = [ "graphical-session.target" ];
    After  = [
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
  Timer = {
    OnBootSec       = "10s";
    OnUnitActiveSec = "60s";
    Unit            = "waybar-self-test.service";
  };
  Install.WantedBy = [ "timers.target" ];
};
```

Script shape:

```bash
#!/usr/bin/env bash
# Required units and required cache files. Edit-this-list-when-adding-modules.
REQUIRED_UNITS=(waybar waybar-glass-text-daemon waybar-workspace-daemon)
REQUIRED_CACHES=(ws-current window notif-bell)
REQUIRED_FILES=(/tmp/glass-mode)

failures=()
for u in "${REQUIRED_UNITS[@]}"; do
  systemctl --user is-active --quiet "$u" \
    || failures+=("$u: $(systemctl --user is-active "$u")")
done
for f in "${REQUIRED_CACHES[@]}"; do
  [ -s "/tmp/waybar-cache/$f" ] || failures+=("cache/$f: missing-or-empty")
done
for f in "${REQUIRED_FILES[@]}"; do
  [ -e "$f" ] || failures+=("$f: missing")
done

# Rebuild-pending is folded in here too — same timer, separate cache file.
emit_rebuild_pending_cache  # writes /tmp/waybar-cache/rebuild-pending

if [ "${#failures[@]}" -eq 0 ]; then
  pill_emit waybar-self-test '' opt-pill ''
else
  tooltip=$(printf 'Self-test failures:\n• %s\n' "${failures[@]}")
  pill_emit waybar-self-test "⚠ ${#failures[@]}" "opt-pill opt-no" "$tooltip"
fi
```

`pill_emit` (from `lib/pill.sh`) handles JSON array `class`, theme re-read, atomic write, and dedup.

**OPTIONS surface:**

- **Zone:** SYSTEM, immediately left of `custom/power-resume`. The cluster reads as "current-state | rebuild-pending | post-resume health | clock."
- **Rest (healthy):** empty `text` → waybar hides the module entirely (the documented `"text":""` hazard, leaned on deliberately).
- **Failure:** red `opt-no` pill with `⚠ N` glyph + count; tooltip lists each failure on its own line.
- **Class composition:** `opt-pill` + theme (`light`/`dark` via `pill_emit`'s fresh read) + `opt-no` only when failed.
- **Motion:** none. Rule 4 — system-driven context shifts are silent; the pill appears without `opt-flash`.
- **Click:** `systemctl --user start waybar-self-test.service` — kicks an immediate re-check.

```jsonc
"custom/waybar-self-test": {
  "exec": "cat /tmp/waybar-cache/waybar-self-test 2>/dev/null",
  "return-type": "json", "format": "{}",
  "interval": 2, "signal": 10, "tooltip": true,
  "on-click": "systemctl --user start waybar-self-test.service"
}
```

CSS needs no new tokens — composes from existing `.opt-pill`, `.opt-no`, `.light`/`.dark` rules. The standard light-mode adaptive-text selector for `#custom-waybar-self-test label` is added to `style.css` per the documented hazard.

### 5. Rebuild-pending pill + `standard-os-shutdown-guard`

**Ground truth — `/run/standard-os/activated-commit`:**

A new system-scope activation script writes the current `/etc/nixos/home` HEAD SHA at every `nixos-rebuild switch`:

```nix
# new file: /etc/nixos/modules/standard-os-commit-tracking.nix (system scope)
{ pkgs, lib, ... }: {
  system.activationScripts.standardOsCommit = lib.stringAfter [ "users" ] ''
    mkdir -p /run/standard-os
    if [ -d /etc/nixos/home/.git ]; then
      ${pkgs.git}/bin/git -C /etc/nixos/home rev-parse HEAD \
        > /run/standard-os/activated-commit
    fi
  '';
}
```

`/run` is a tmpfs and re-runs the activation script at every boot, so the file is always either:

- present — rebuild ran at this generation's build, AND
- absent — no commit-tracked `/etc/nixos/home` (fresh install before first commit; gate fails open).

**Check logic — folded into `waybar-self-test`:**

```bash
check_rebuild_pending() {
  [ -f /run/standard-os/activated-commit ] || return 1
  local activated head
  activated=$(cat /run/standard-os/activated-commit) || return 1
  head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null) || return 1
  [ "$activated" = "$head" ] && return 1   # up to date

  git -C /etc/nixos/home merge-base --is-ancestor "$activated" HEAD 2>/dev/null
  case $? in
    0|1) return 0 ;;   # ahead OR exotic divergence → pending
    *)   return 1 ;;   # bad SHA or other failure → fail open
  esac
}

emit_rebuild_pending_cache() {
  if check_rebuild_pending; then
    activated=$(cat /run/standard-os/activated-commit)
    ahead=$(git -C /etc/nixos/home rev-list --count "$activated..HEAD" 2>/dev/null \
            || echo "?")
    last_subj=$(git -C /etc/nixos/home log -1 --format=%s HEAD)
    pill_emit rebuild-pending "" "opt-pill opt-pin-orange" \
      "Pending rebuild: $ahead commit(s) ahead — last: $last_subj"
  else
    pill_emit rebuild-pending "" "opt-pill"
  fi
}
```

**OPTIONS surface:**

- **Zone:** SYSTEM, between `group-power` and `custom/power-resume`.
- **Glyph:** Material `nf-md-source_branch_sync` () with FA `f021` () as a fallback if the Material glyph is missing on a given system.
- **Rest (clean tree):** empty `text` → module hidden.
- **Rest (pending):** `opt-pin-orange` — solid orange, no motion. Pin = persistent state until cleared (here, until rebuild lands).
- **Tooltip:** `Pending rebuild: N commit(s) ahead — last: <subj>`.
- **Click:** opens a rofi dialog via `standard-os-rebuild-prompt` — three choices: rebuild now, dismiss-only (close dialog), open last commit in editor.

```jsonc
"custom/rebuild-pending": {
  "exec": "cat /tmp/waybar-cache/rebuild-pending 2>/dev/null",
  "return-type": "json", "format": "{}",
  "interval": 2, "signal": 10, "tooltip": true,
  "on-click": "standard-os-rebuild-prompt"
}
```

**Pre-shutdown gate — `standard-os-shutdown-guard`:**

The OPTIONS power-cluster currently calls `systemctl --user`/`sudo` directly from `on-click` handlers. The migration rewires every power-cluster click through a single wrapped guard:

```jsonc
// before:
"on-click": "systemctl suspend"
"on-click": "systemctl hibernate"

// after:
"on-click": "standard-os-shutdown-guard sleep"
"on-click": "standard-os-shutdown-guard hibernate"
"on-click": "standard-os-shutdown-guard reboot"
"on-click": "standard-os-shutdown-guard poweroff"
```

Hyprland's SUPER+ESC power menu, if it calls `systemctl` directly, follows the same migration.

The guard's logic:

1. `check_rebuild_pending` (same function used by the pill).
2. **Clean tree** → `exec` the requested action directly. No friction.
3. **Pending tree** → show a rofi modal:
   ```
   Pending rebuild: 3 commits ahead
   Last: a8d720a waybar: track scripts/ in repo + HM symlink
   ──────────────────────────────────────────────────────
    1  Rebuild + then <action>
    2  <action> anyway
    3  Cancel
   ```
4. Choice 1 → spawn a terminal running `sudo nixos-rebuild switch && systemctl <action>` (terminal needed so sudo can prompt).
5. Choice 2 → `exec` the action immediately.
6. Choice 3 → no-op.

**Scope boundary — what the gate does NOT cover:**

- Emergency hibernate (low battery, lid close → logind triggers). These are time-sensitive; silent intervention is correct.
- `systemctl poweroff` typed in a shell — expert escape hatch, intentionally exempt.

---

## Migration plan (the order that doesn't break the bar mid-way)

The migration must not produce an intermediate state where the bar is broken. Order:

1. **Add `waybar-scripts` derivation to `modules/waybar.nix`** without changing any existing `ExecStart` or `xdg.configFile` yet. Build, verify the derivation exists at `${waybar-scripts}/bin/`, run shellcheck gate.
2. **Add `waybar.service Environment="PATH=${waybar-scripts}/bin:..."`** — preparation for `config.jsonc`'s bare-name resolution. No behavioral change until config.jsonc edits.
3. **Switch systemd `ExecStart`s** of both daemons to `${waybar-scripts}/bin/<name>`. Rebuild + restart daemons. Verify they come up.
4. **Edit `config.jsonc`** in-place — replace every `~/.config/waybar/scripts/<name>.sh` with the bare binary name. Restart waybar. Verify every module renders.
5. **Add restart-burst tuning** to both daemon `Service` blocks. Rebuild. Verify the new fields land in `systemctl --user show waybar-*-daemon | grep Limit`.
6. **Audit self-seeding** in `glass-text-daemon.sh` and `workspace-daemon.sh`. Add `self_seed` calls if missing. Test with `rm -rf /tmp/waybar-cache /tmp/glass-mode` + restart.
7. **Add the new scripts to the source dir:** `waybar-self-test.sh`, `standard-os-shutdown-guard.sh`, `standard-os-rebuild-prompt.sh`. Rebuild — they materialize as `${waybar-scripts}/bin/<name>`.
8. **Add `waybar-self-test.service` + `.timer`** to `modules/waybar.nix`. Rebuild. Verify oneshot fires + cache emits.
9. **Add `custom/waybar-self-test` module** to `config.jsonc` (SYSTEM zone). Add light-mode CSS selector. Restart waybar. Visual check.
10. **Add `modules/standard-os-commit-tracking.nix`** to the system config. Rebuild. Verify `/run/standard-os/activated-commit` exists.
11. **Add `custom/rebuild-pending` module** to `config.jsonc`. Add light-mode CSS selector. Restart waybar. Test by `git commit --allow-empty` and confirm pill appears within 60 s.
12. **Rewire power-cluster `on-click` handlers** in `config.jsonc` to `standard-os-shutdown-guard <action>`. Restart waybar. Test on a clean tree (action runs immediately), test on a pending tree (modal appears).
13. **Remove `xdg.configFile."waybar/scripts"` declaration** from `modules/waybar.nix`. Add `home.activation.cleanupOldWaybarScripts`. Rebuild. Verify `~/.config/waybar/scripts` is gone post-activation.

Each step is independently testable; if a step fails the previous state is reachable by reverting just that step.

---

## Testing strategy

**Build-time:**

- `shellcheck` gate in `waybar-scripts` derivation `checkPhase`. Any SC* error fails the build.
- `nixos-rebuild switch` succeeds.
- `${waybar-scripts}/bin/` contains every expected binary.
- `${waybar-scripts}/share/waybar-scripts/lib/pill.sh` exists.

**Runtime — fresh boot simulation:**

- `rm -rf /tmp/waybar-cache /tmp/glass-mode` + `systemctl --user restart waybar waybar-glass-text-daemon waybar-workspace-daemon` → within 1 s, every `REQUIRED_CACHES` file exists and is non-empty; `/tmp/glass-mode` exists.
- `pgrep -f workspace-daemon` and `pgrep -f glass-text-daemon` both return PIDs that match the `${waybar-scripts}/bin/<name>` invocation in `systemctl --user status`.
- `waybar.service` journal has zero `No such file or directory` errors.

**Restart-burst:**

- Inject a deliberate failure (`chmod 000 ${waybar-scripts}/bin/glass-text-daemon` — well, `chmod 000` doesn't work on store paths, so: rewrite `ExecStart` to a nonexistent path temporarily). Verify backoff applies (RestartSec doubles each attempt, plateaus at 30 s). Verify the unit doesn't hit StartLimit within 5 minutes of failures-at-30-s-cadence.

**Self-test:**

- Healthy state: `cat /tmp/waybar-cache/waybar-self-test` has `text:""` → pill invisible.
- Kill one daemon: `systemctl --user stop waybar-glass-text-daemon`. Within 60 s the cache flips to `text:"⚠ 1"` + `opt-no`; tooltip lists `waybar-glass-text-daemon`. Click the pill: it kicks an immediate re-check. Manually `systemctl --user start waybar-glass-text-daemon` then click pill → within 1 s pill goes invisible.
- Kill notif-bell cache: `rm /tmp/waybar-cache/notif-bell`. Pill flips to failure within 60 s.

**Rebuild-pending:**

- `git -C /etc/nixos/home commit --allow-empty -m "test"` → within 60 s, `cat /tmp/waybar-cache/rebuild-pending` shows `opt-pin-orange` + tooltip with the commit subject.
- `sudo nixos-rebuild switch` → `/run/standard-os/activated-commit` updates → within 60 s pill collapses to invisible.
- `git reset --hard HEAD~1` (bring tree back) → pill clears (both SHAs match).
- `git commit --amend` (divergence, not strict ahead) → pill stays orange (the fail-open case treats divergence as pending).

**Shutdown gate:**

- Clean tree + click `custom/lock` (sleep) → immediate suspend.
- Pending tree + click `custom/lock` → rofi modal appears. Test all three branches.
- Choice 3 (Cancel) → no action, no spurious cache state.

**Migration safety:**

- After step 13 (`xdg.configFile."waybar/scripts"` removed + activation cleanup), `ls ~/.config/waybar/` shows only `config.jsonc`, `style.css`, `icons/`, `offers/`, `.gitignore`, `.git`, `launch.sh` — no `scripts`, no `scripts.hm-bak`.

---

## Hazards

- **`substituteInPlace` only rewrites enumerated forms.** If any script uses an unrecognized form to source the lib, the original path remains. Pre-flight audit: `grep -rn 'pill.sh' /etc/nixos/home/waybar/scripts/` lists every callsite; the `--replace` list must cover every form found.
- **`shellcheck` gate may surface latent issues.** Several scripts predate the gate. The implementation plan budgets a fix-up pass for any SC errors uncovered. SC warnings (not errors) stay informational.
- **PATH-resolved bare names in `config.jsonc` are slightly less explicit** about where binaries come from. A reader has to know "those are wrapped from `${waybar-scripts}/bin`". A header comment in `config.jsonc` explains the convention.
- **Self-test 60 s timer = up to 60 s detection lag.** Acceptable. Rule 4 — system-driven context shifts are silent and don't need millisecond reaction. Click forces immediate re-check.
- **Self-test `REQUIRED_CACHES` is a spot-check, not exhaustive.** Auditing all 30+ caches every 60 s creates noise (workspace caches legitimately delete/replace during workspace churn). The list covers files whose absence reliably indicates a broken daemon.
- **`waybar-self-test.service` could itself fail.** Add `OnFailure=` so the meta-failure is journaled. A broken self-test means no pill — but `journalctl --user -u waybar-self-test` reveals it.
- **`git rev-parse HEAD` on a missing/empty repo prints to stderr.** Suppressed via `2>/dev/null`; the check returns nonzero → pill stays hidden (fail open).
- **Rebuild-pending gate scopes to user-initiated power-off paths only.** Emergency hibernate (lid, low battery) bypasses by design. `systemctl poweroff` typed in a shell bypasses too.
- **Restart-burst tuning numbers are conservative.** If a script has a hard bug that fails fast, 20 attempts at exponential backoff over 5 min still consume noticeable CPU. Mitigated by `Restart=on-failure` (graceful exits stop the loop) and the self-test pill surfacing the persistent failure.
- **The two long-lived daemons must self-seed.** Without the contract, a fresh tmpfs `/tmp` install shows blank pills on first boot. The audit in step 6 is the safety net; the test in "Testing strategy — Runtime — fresh boot simulation" enforces it.

---

## Deferred / out of scope

- **Per-script PATH curation.** Single shared `binPath` is fine for v1.
- **`config.jsonc` Nix templating.** Stays plain JSONC + `mkOutOfStoreSymlink`. Bare-name PATH resolution gives the same robustness without sacrificing iteration.
- **Composite-module pattern using inotify on `/tmp/waybar-cache/`.** Mentioned in TODO NEXT; not part of this spec.
- **System-wide `nixos-rebuild` automation** (e.g., cron-triggered auto-rebuild). Out of scope — this spec only surfaces the pending state and gates power-off.
- **PrepareForShutdown D-Bus interception** to catch every shutdown path including emergency ones. Conscious scope cut — the gate covers user-initiated paths only.
- **Workspace-daemon migration to Nix** (NEXT entry). This spec's `waybar-scripts` derivation IS that migration; the NEXT entry retires.

---

## Acceptance criteria

1. After `nixos-rebuild switch`, `${waybar-scripts}/bin/` contains every script wrapped as a binary; `~/.config/waybar/scripts` does NOT exist.
2. `waybar.service`, `waybar-glass-text-daemon.service`, `waybar-workspace-daemon.service` are all `active` after fresh boot; zero `No such file or directory` errors in waybar journal.
3. `rm -rf /tmp/waybar-cache /tmp/glass-mode` + restart of waybar + both daemons → every `REQUIRED_CACHES` file is present and non-empty within 1 s.
4. Killing `waybar-glass-text-daemon.service` → within 60 s `custom/waybar-self-test` pill appears red with `⚠ 1` and tooltip listing the dead daemon. Click → re-checks; restart daemon manually + click → pill collapses.
5. `git commit --allow-empty` in `/etc/nixos/home` → within 60 s `custom/rebuild-pending` pill appears `opt-pin-orange` with tooltip showing 1 commit ahead and the commit subject. `sudo nixos-rebuild switch` → within 60 s pill collapses.
6. With a pending tree, click `custom/lock` (sleep) → rofi modal appears. Choosing "Cancel" → no action, no spurious state.
7. With a clean tree, click `custom/lock` → immediate suspend (no modal).
8. The `shellcheck` gate fires on a deliberately broken script — `nixos-rebuild switch` fails with a clear shellcheck message.
9. `systemctl --user show waybar-glass-text-daemon` reports `StartLimitBurst=20`, `StartLimitIntervalUSec=5min`, `RestartMaxDelayUSec=30s`, `RestartSteps=5`.
10. TODO.md entry moved to DONE with the standard Hint lines (lib substitution forms, shellcheck adoption, self-seeding test recipe).
