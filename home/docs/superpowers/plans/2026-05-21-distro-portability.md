# Distro Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the NixOS config installable on any fresh PC by editing **one line** (the username). Move the user-owned distro source tree from `~/focus/` into `/etc/nixos/home/`, parameterize every `/home/max/` reference via `primaryUser` / `userHome`, and clean up two duplicate config blocks.

**Architecture:** A single `let`-block at the top of `configuration.nix` defines `primaryUser` + `userHome`. Values propagate to system modules via `_module.args` and to home-manager modules via `home-manager.extraSpecialArgs`. After the move, all distro-internal imports become relative paths inside `/etc/nixos/`. Hyprland binds use `~/...` (Hyprland expands at runtime, already used in lines 100–105 of `configuration.nix`); root-level install paths use `${userHome}/...` (shell `install` won't reliably expand `~`).

**Tech Stack:** NixOS 25.11 (channel-based, no flakes), home-manager as a NixOS module, bash for file moves and verification.

**Spec:** `docs/superpowers/specs/2026-05-21-distro-portability-design.md`

---

## File structure (post-move)

| File | Status | Responsibility |
|---|---|---|
| `/etc/nixos/configuration.nix` | **Modify** | Add `let primaryUser/userHome`; `_module.args`; `home-manager.extraSpecialArgs`; rename `users.max` → `users.${primaryUser}`; rewrite 4 hardcoded install paths + 19 hardcoded Hyprland bind paths. |
| `/etc/nixos/home.nix` | **Modify** | Accept `primaryUser, userHome` as function args; rewrite 6 absolute imports to relative `./home/...`; replace `home.username` and `home.homeDirectory` with the variables. |
| `/etc/nixos/modules/users.nix` | **Modify** | Accept `primaryUser` as function arg; rename `users.users.max` → `users.users.${primaryUser}`. |
| `/etc/nixos/modules/nautilus-system.nix` | **Modify** | Remove duplicate `services.gnome.gnome-keyring.enable` and `services.dbus.packages` (canonically in `modules/services.nix`). Keep the PAM-unlock line — it's unique here. |
| `/home/max/focus/modules/keyring-unlocked.nix` (pre-move) | **Modify** | Strengthen header comment with the security model (FDE is real protection). Strengthen `resetExisting` description. |
| `/home/max/focus/modules/hyprland-config.nix` (pre-move) | **Modify** | Update 3 stale comments referencing `/home/max/focus/...`. |
| `/home/max/focus/` → `/etc/nixos/home/` | **Move** | `sudo mv` the entire tree. `chown -R root:root` after the move to match other `/etc/nixos/` content. |
| `/etc/nixos/*.bak`, `/etc/nixos/*.bak-hypr-port` | **Delete (after verification)** | Old snapshots, kept as rollback insurance through `Task 10`, deleted in `Task 11`. |

## Notes for the implementer

- **NixOS module function signature**: `{ config, lib, pkgs, ... }:` is the standard. Adding our own args looks like `{ config, lib, pkgs, primaryUser, userHome, ... }:`. The `...` swallows everything else — the module system passes a lot of args.
- **`_module.args`** is the system-side way to inject `let`-bound values into every imported module. Set it at the top level of `configuration.nix`. System modules then receive those args in their function head.
- **`home-manager.extraSpecialArgs`** is the home-manager equivalent. It propagates to every module imported by home-manager (i.e. anything under `home.nix`'s imports list, recursively).
- **Dynamic attribute names**: Nix supports `users.users.${primaryUser} = { ... };` (string interpolation as attr name). When `primaryUser = "max"`, this expands to `users.users.max = { ... };`.
- **Path interpolation in imports**: `./home/modules/foo.nix` is a path literal (relative to the file containing it). `(distroRoot + "/modules/foo.nix")` is a string that needs path coercion. We use **path literals** everywhere because the tree now lives under `/etc/nixos/` — no string concatenation needed.
- **Parse-check command**: `nix-instantiate --parse <file.nix>` — exits 0 on syntactically valid Nix, prints the parse tree to stdout. Pipe to `>/dev/null` to suppress.
- **Eval-check command**: `sudo nixos-rebuild dry-build` — evaluates the full system config without building. Catches type errors, missing imports, undefined options, missing function args.
- **Apply command**: `sudo nixos-rebuild switch` — applies for real. Only run after dry-build is clean.
- **No git** in `/etc/nixos/` or `/home/max/focus/` on this machine. Skip commit steps.
- **Working directory after move**: Claude Code sessions that need to edit the distro source must `cd /etc/nixos/home` and use `sudo` for writes (the tree is root-owned after the move). The user accepted this trade-off — it's the whole point of moving the tree.
- **Currently running Hyprland session**: Hyprland is reading from `~/.config/hypr/`, which is already-generated Layer 3. Moving the source modules does NOT affect the running session — only the NEXT `nixos-rebuild switch` cares about source location.

---

### Task 1: Pre-move edits to keyring-unlocked.nix and hyprland-config.nix

**Files:**
- Modify: `/home/max/focus/modules/keyring-unlocked.nix`
- Modify: `/home/max/focus/modules/hyprland-config.nix`

These edits happen FIRST, before the move, while the files are still user-owned (no sudo needed).

- [ ] **Step 1: Strengthen the keyring-unlocked.nix header comment**

Replace the existing module header in `/home/max/focus/modules/keyring-unlocked.nix` (lines 1–9, the leading `# ===...` block).

Old:
```nix
# =============================================================================
# keyring-unlocked.nix — empty-password gnome-keyring that auto-unlocks
#
# Solves the "Unlock Keyring" prompt on autologin sessions where no password
# transits PAM at login time. One-time wipe of any existing passworded keyring
# (marker-gated), plus a systemd user oneshot that pipes an empty password
# into gnome-keyring-daemon at every session start.
#
# Designed for the distro: assumes full-disk encryption is the real protection
# layer; the keyring is file-permissions only.
# =============================================================================
```

New:
```nix
# =============================================================================
# keyring-unlocked.nix — empty-password gnome-keyring that auto-unlocks
#
# Solves the "Unlock Keyring" prompt on autologin sessions where no password
# transits PAM at login time. One-time wipe of any existing passworded keyring
# (marker-gated), plus a systemd user oneshot that pipes an empty password
# into gnome-keyring-daemon at every session start.
#
# SECURITY MODEL (important — read before enabling on a non-distro host):
#   * The keyring is protected by FILE PERMISSIONS ONLY (the empty password
#     provides no cryptographic protection — anyone with read access to
#     ~/.local/share/keyrings/login.keyring can decrypt every secret).
#   * The distro that ships this module assumes FULL-DISK ENCRYPTION is
#     enabled at install time. FDE is the real security boundary; this
#     module trades login-prompt friction for that single dependency.
#   * Do NOT enable this on a host without FDE unless the secrets stored in
#     the keyring are themselves disposable.
# =============================================================================
```

- [ ] **Step 2: Strengthen the `resetExisting` option description**

In the same file, find the `resetExisting` option (around line 92). Replace its `description` text.

Old:
```nix
    resetExisting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        One-time wipe of any pre-existing keyring files on first activation
        (marker-gated). Set to false for hosts whose existing keyring already
        holds secrets that must be preserved — those hosts must be migrated
        manually before enabling this module.
      '';
    };
```

New:
```nix
    resetExisting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        One-time wipe of any pre-existing keyring files on first activation
        (marker-gated by ~/.local/share/keyrings/.empty-password-initialized).

        DESTRUCTIVE when retrofitted onto an account with secrets — the wipe
        runs once, then never again, but the FIRST run permanently deletes
        every *.keyring file in the directory. Distro-fresh accounts have no
        prior secrets, so the default `true` is safe for new installs.

        Set to `false` only for hosts whose existing keyring holds secrets
        that must be preserved. Those hosts must be migrated manually (e.g.
        `secret-tool` export → wipe → import) before enabling this module.
      '';
    };
```

- [ ] **Step 3: Update the 3 stale comments in hyprland-config.nix**

In `/home/max/focus/modules/hyprland-config.nix`:

Line 6 — change:
```nix
# /home/max/focus/hypr/modules/; 5 hardware-aware files are rendered by Nix
```
to:
```nix
# /etc/nixos/home/hypr/modules/; 5 hardware-aware files are rendered by Nix
```

Line 10 — change:
```nix
# module under /home/max/focus/hosts/<hostname>.nix.
```
to:
```nix
# module under /etc/nixos/home/hosts/<hostname>.nix.
```

Line 94 — change:
```nix
    # Per-machine overrides live in /home/max/focus/hosts/<hostname>.nix.
```
to:
```nix
    # Per-machine overrides live in /etc/nixos/home/hosts/<hostname>.nix.
```

- [ ] **Step 4: Parse-check both files**

Run:
```bash
nix-instantiate --parse /home/max/focus/modules/keyring-unlocked.nix > /dev/null && echo OK
nix-instantiate --parse /home/max/focus/modules/hyprland-config.nix > /dev/null && echo OK
```
Expected: both print `OK`, no stderr.

---

### Task 2: Backup `/etc/nixos/` roots, then move the tree

**Files:**
- Move: `/home/max/focus/` → `/etc/nixos/home/`
- Create: `/etc/nixos/configuration.nix.bak-distro-portability` (snapshot)
- Create: `/etc/nixos/home.nix.bak-distro-portability` (snapshot)
- Create: `/etc/nixos/modules/users.nix.bak-distro-portability` (snapshot)
- Create: `/etc/nixos/modules/nautilus-system.nix.bak-distro-portability` (snapshot)

- [ ] **Step 1: Snapshot the files we're about to edit**

Run:
```bash
sudo cp -a /etc/nixos/configuration.nix /etc/nixos/configuration.nix.bak-distro-portability
sudo cp -a /etc/nixos/home.nix /etc/nixos/home.nix.bak-distro-portability
sudo cp -a /etc/nixos/modules/users.nix /etc/nixos/modules/users.nix.bak-distro-portability
sudo cp -a /etc/nixos/modules/nautilus-system.nix /etc/nixos/modules/nautilus-system.nix.bak-distro-portability
```
Expected: no output, exit 0.

- [ ] **Step 2: Move the tree**

Run:
```bash
sudo mv /home/max/focus /etc/nixos/home
```
Expected: no output, exit 0. `/home/max/focus` no longer exists; `/etc/nixos/home/` now contains everything.

- [ ] **Step 3: Set root ownership on the moved tree**

Run:
```bash
sudo chown -R root:root /etc/nixos/home
```
Expected: no output, exit 0. End users can no longer modify these files without sudo, matching the intent ("users don't deal with it").

- [ ] **Step 4: Verify the move**

Run:
```bash
[ ! -e /home/max/focus ] && echo "OK: ~/focus removed"
[ -d /etc/nixos/home/modules ] && echo "OK: /etc/nixos/home/modules exists"
ls /etc/nixos/home/ | sort
```
Expected output:
```
OK: ~/focus removed
OK: /etc/nixos/home/modules exists
.claude
distro-todo.md
docs
hosts
hypr
models
modules
scripts
tests
waybar
```

If `/home/max/focus` still exists, the move failed — inspect `mv` output and rerun.

---

### Task 3: Edit configuration.nix — let block, propagation, user attr

**Files:**
- Modify: `/etc/nixos/configuration.nix` (lines 1, 37–43)

- [ ] **Step 1: Add the `let` block at the top + `_module.args` and rename `users.max`**

Replace lines 1–3 (the function header and opening brace).

Old:
```nix
{ config, lib, pkgs, ... }:

{
```

New:
```nix
{ config, lib, pkgs, ... }:

let
  # =========================================================================
  # primaryUser — the ONE knob a fresh-PC distro install edits.
  # The future installer ISO writes this line based on the username the user
  # entered at install time. Every other /home/<user>/... reference in this
  # config derives from it (via _module.args + home-manager.extraSpecialArgs).
  # =========================================================================
  primaryUser = "max";
  userHome    = "/home/${primaryUser}";
in
{
  # Make primaryUser + userHome available to every imported system module
  # (users.nix etc.) without threading them by hand.
  _module.args = { inherit primaryUser userHome; };

```

- [ ] **Step 2: Add `extraSpecialArgs` to the home-manager block and rename `users.max`**

Find the home-manager block (around lines 37–43, after the move/edit from Step 1 — line numbers shift down by ~13 due to the let block). Look for the literal `home-manager = {` line.

Old:
```nix
  home-manager = {
    useGlobalPkgs   = true;   # share nixpkgs with system (avoids double evaluation)
    useUserPackages = true;   # install home.packages into the user profile
    backupFileExtension = "hm-bak";  # back up conflicting files instead of failing

    users.max = import ./home.nix;
  };
```

New:
```nix
  home-manager = {
    useGlobalPkgs   = true;   # share nixpkgs with system (avoids double evaluation)
    useUserPackages = true;   # install home.packages into the user profile
    backupFileExtension = "hm-bak";  # back up conflicting files instead of failing

    # Propagate identity to every home-manager module so they can use
    # primaryUser / userHome in their function head.
    extraSpecialArgs = { inherit primaryUser userHome; };

    users.${primaryUser} = import ./home.nix;
  };
```

- [ ] **Step 3: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/configuration.nix > /dev/null && echo OK
```
Expected: `OK`, no stderr.

---

### Task 4: Edit configuration.nix — replace 4 install paths

**Files:**
- Modify: `/etc/nixos/configuration.nix` (the 3 `system.activationScripts.*` blocks)

The activation scripts contain 4 hardcoded `/home/max/.config/hypr/...` paths. Replace them with `${userHome}/.config/hypr/...` so they derive from the username.

- [ ] **Step 1: Edit `system.activationScripts.hyprBindsConf` install paths**

Find the `text = ''` block inside `system.activationScripts.hyprBindsConf` (around original line 140–145). It contains:
```bash
install -d -m 755 /home/max/.config/hypr/modules
install -m 644 ${bindsConf} /home/max/.config/hypr/modules/Binds.conf
```

Change to:
```bash
install -d -m 755 ${userHome}/.config/hypr/modules
install -m 644 ${bindsConf} ${userHome}/.config/hypr/modules/Binds.conf
```

- [ ] **Step 2: Edit `system.activationScripts.hyprVolumeScript` install paths**

In the same file, find the `text = ''` block inside `hyprVolumeScript` (around original line 177–180):
```bash
install -d -m 755 /home/max/.config/hypr/scripts
install -m 755 ${volumeScript} /home/max/.config/hypr/scripts/volume.sh
```

Change to:
```bash
install -d -m 755 ${userHome}/.config/hypr/scripts
install -m 755 ${volumeScript} ${userHome}/.config/hypr/scripts/volume.sh
```

- [ ] **Step 3: Edit `system.activationScripts.hyprBrightnessScript` install paths**

In the same file, find the `text = ''` block inside `hyprBrightnessScript` (around original line 213–216):
```bash
install -d -m 755 /home/max/.config/hypr/scripts
install -m 755 ${brightnessScript} /home/max/.config/hypr/scripts/brightness.sh
```

Change to:
```bash
install -d -m 755 ${userHome}/.config/hypr/scripts
install -m 755 ${brightnessScript} ${userHome}/.config/hypr/scripts/brightness.sh
```

- [ ] **Step 4: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/configuration.nix > /dev/null && echo OK
```
Expected: `OK`. Also confirm zero hardcoded paths remain:
```bash
grep -c '/home/max/' /etc/nixos/configuration.nix
```
Expected: a non-zero count (the Hyprland binds in `bindsConf` are still hardcoded — those get fixed in Task 5). Make a note of the number; it should drop after Task 5.

---

### Task 5: Edit configuration.nix — Hyprland bind paths

**Files:**
- Modify: `/etc/nixos/configuration.nix` (inside the `bindsConf = pkgs.writeText "Binds.conf" ''` block, lines ~113–136 in the original)

The Hyprland bind block has 19 hardcoded `/home/max/.config/hypr/scripts/N.sh` paths. Replace every `/home/max/` with `~` inside that one block. Hyprland expands `~` at runtime (already used in lines 100–105 for volume/brightness).

- [ ] **Step 1: Replace `/home/max/.config/hypr/scripts/` with `~/.config/hypr/scripts/` in the binds block**

Use the Edit tool with `replace_all` scoped to the file (the only occurrences of that exact string are in the binds block):

`old_string`: `/home/max/.config/hypr/scripts/`
`new_string`: `~/.config/hypr/scripts/`
`replace_all`: `true`

Note: this substitution is safe because after Task 4 the only remaining `/home/max/.config/hypr/scripts/` references in the file are the 19 binds (the install paths in `hyprVolumeScript` and `hyprBrightnessScript` were rewritten to `${userHome}/.config/hypr/scripts/`).

- [ ] **Step 2: Parse-check and verify zero hardcoded `/home/max/` remain**

Run:
```bash
nix-instantiate --parse /etc/nixos/configuration.nix > /dev/null && echo OK
grep -n '/home/max/' /etc/nixos/configuration.nix
```
Expected:
- `OK` printed.
- `grep` finds zero matches (exits with status 1). If matches remain, inspect them — they're things that didn't fit the previous patterns and need manual handling.

---

### Task 6: Edit home.nix — function args, imports, identity

**Files:**
- Modify: `/etc/nixos/home.nix` (entire file)

- [ ] **Step 1: Rewrite the file**

Replace the entire contents of `/etc/nixos/home.nix` with:

```nix
{ pkgs, lib, primaryUser, userHome, ... }:

# =============================================================================
# home.nix — Home Manager root file for the primary user
# Referenced from configuration.nix:  home-manager.users.${primaryUser} = import ./home.nix;
# Receives primaryUser + userHome via home-manager.extraSpecialArgs.
# =============================================================================

{
  imports = [
    ./home-nautilus.nix
    ./home-screen-type.nix
    ./home/modules/hypr-edge-bg.nix
    ./home/modules/voice-dictation.nix
    ./home/modules/waybar.nix
    ./home/modules/hyprland-config.nix
    ./home/modules/keyring-unlocked.nix
    ./home/hosts/STDOS.nix
  ];

  #services.rofi-empty-dock.enable = true;

  home.username      = primaryUser;
  home.homeDirectory = userHome;
  home.stateVersion  = "25.11";

  # Required: let Home Manager manage itself (enables the home-manager CLI)
  programs.home-manager.enable = true;

  services.hyprEdgeBg.enable = true;

  services.voiceDictation = {
    enable      = true;
    cudaSupport = true;          # RTX 4050 — CUDA-accelerated whisper.cpp
  };

  services.waybarBar.enable = true;
  services.keyring.unlocked.enable = true;

  # Clear Antigravity's service worker cache on each rebuild to prevent
  # stale cached scripts (e.g. after extension updates) from causing
  # "Error loading webview: Could not register service worker: InvalidStateError"
  home.activation.clearAntigravitySwCache = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf "$HOME/.config/Antigravity/Service Worker"
  '';
}
```

- [ ] **Step 2: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/home.nix > /dev/null && echo OK
```
Expected: `OK`.

---

### Task 7: Edit modules/users.nix — accept primaryUser

**Files:**
- Modify: `/etc/nixos/modules/users.nix` (entire file)

- [ ] **Step 1: Rewrite the file**

Replace the entire contents of `/etc/nixos/modules/users.nix` with:

```nix
{ config, lib, pkgs, primaryUser, ... }:

{
  # ---------------------------------------------------------------------------
  # User account — name comes from configuration.nix's `primaryUser` let-binding,
  # propagated via _module.args. The future installer sets that one variable.
  # ---------------------------------------------------------------------------
  users.users.${primaryUser} = {
    shell        = pkgs.zsh;
    isNormalUser = true;
    description  = primaryUser;
    extraGroups  = [ "networkmanager" "wheel" "video" "audio" "render" "input" "plugdev" "storage" "disk" "dialout" "lp" "scanner" "adbusers" "libvirtd" ];
    packages     = with pkgs; [];
  };
}
```

(Note: `description = primaryUser` mirrors the previous `description = "max"`. If a future installer wants a separate display name, that's a follow-up — out of scope here.)

- [ ] **Step 2: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/modules/users.nix > /dev/null && echo OK
```
Expected: `OK`.

---

### Task 8: Edit modules/nautilus-system.nix — remove duplicates

**Files:**
- Modify: `/etc/nixos/modules/nautilus-system.nix` (lines 51–60)

- [ ] **Step 1: Remove the duplicate gnome-keyring + dbus.packages lines**

Replace this block (lines 51–60 in the current file):

```nix
  # ---------------------------------------------------------------------------
  # GNOME Keyring — password storage for network shares (SMB, SFTP)
  # ---------------------------------------------------------------------------
  services.gnome.gnome-keyring.enable = true;

  # Unlock the keyring automatically on PAM login
  security.pam.services.login.enableGnomeKeyring = true;

  # Register gcr and gnome-keyring on the system D-Bus so other apps can find them
  services.dbus.packages = with pkgs; [ gcr gnome-keyring ];
```

with this:

```nix
  # ---------------------------------------------------------------------------
  # GNOME Keyring — PAM unlock at TTY/login-manager login
  # (gnome-keyring.enable + dbus.packages are centralised in modules/services.nix;
  # only the PAM-side enable lives here because it's a Nautilus/login-path concern.)
  # ---------------------------------------------------------------------------
  security.pam.services.login.enableGnomeKeyring = true;
```

- [ ] **Step 2: Parse-check**

Run:
```bash
nix-instantiate --parse /etc/nixos/modules/nautilus-system.nix > /dev/null && echo OK
```
Expected: `OK`.

---

### Task 9: Dry-build the full system config

**Files:** none modified.

- [ ] **Step 1: Run dry-build**

Run:
```bash
sudo nixos-rebuild dry-build 2>&1 | tail -40
```
Expected: exits 0; the final lines describe what would be built/copied. No `error:` lines.

If eval fails, common failure modes:
- `error: getting status of '/home/max/focus/...': No such file or directory` → an import wasn't migrated to `./home/...`. Re-check `home.nix` imports.
- `error: function 'anonymous lambda' called without required argument 'primaryUser'` → `_module.args` or `extraSpecialArgs` wasn't wired into `configuration.nix`. Re-check Task 3.
- `error: attribute 'X' missing` → typo in an option name or a stale reference to the old layout.
- `error: cannot coerce a set to a string` → likely a path-vs-string confusion in `home.nix` imports. They should be path literals (`./home/modules/foo.nix`), not strings.

Fix any errors and re-run until clean.

---

### Task 10: Apply, then verify

**Files:** none modified.

- [ ] **Step 1: Apply the configuration**

Run:
```bash
sudo nixos-rebuild switch 2>&1 | tail -60
```
Expected: exits 0; the last few lines include `activation finished`. No traceback.

If the build itself succeeded but activation failed, inspect:
```bash
sudo journalctl -b -u nixos-upgrade --no-pager | tail -50
```

- [ ] **Step 2: Verify the user account is intact**

Run:
```bash
id max
```
Expected: same UID and groups as before (e.g. `uid=1000(max) gid=100(users) groups=100(users),1(wheel),...`).

- [ ] **Step 3: Verify the keyring still auto-unlocks**

Run:
```bash
systemctl --user status gnome-keyring-empty-unlock
```
Expected: `Active: active (exited)` with `status=0/SUCCESS`.

Then run the secret-tool roundtrip:
```bash
echo "portability-test" | secret-tool store --label='portability' service portability key portability
secret-tool lookup service portability key portability
secret-tool clear service portability key portability
```
Expected: middle command prints `portability-test`. **No GUI prompt at any point.**

- [ ] **Step 4: Verify Chrome still has `--password-store=basic`**

Launch Chrome (or check the wrapper):
```bash
head -c 4096 "$(readlink -f "$(which google-chrome-stable)")" | grep -o 'password-store=basic'
```
Expected: prints `password-store=basic`.

- [ ] **Step 5: Verify Hyprland binds still work**

Press `Super+E` — kitty terminal should open. Press `Super+1` through `Super+9` — workspace switches should respond. Press `Super+SPACE` — rofi should open.

If any of these fail, inspect the generated Binds.conf:
```bash
cat ~/.config/hypr/modules/Binds.conf | head -40
```
Confirm the bind lines say `exec, ~/.config/hypr/scripts/...` (tilde expanded at runtime). If they say `exec, /home/max/.config/hypr/scripts/...`, Task 5 didn't take effect — re-check.

- [ ] **Step 6: Confirm Hyprland workspace switch scripts exist**

Run:
```bash
ls ~/.config/hypr/scripts/{1,5,9,10,11,19}.sh 2>&1
```
Expected: each path exists. If any are missing, that's a pre-existing Layer 3 leak (called out in the spec as out-of-scope) — not introduced by this refactor. Note it for a follow-up.

---

### Task 11: Cleanup `.bak` files

**Files:**
- Delete: `/etc/nixos/*.bak`, `/etc/nixos/*.bak-hypr-port`, `/etc/nixos/*.bak-distro-portability` (and any `.bak-distro-portability` files under `modules/`).

Only run this after Task 10 passed end-to-end.

- [ ] **Step 1: List what's about to be deleted**

Run:
```bash
sudo find /etc/nixos -maxdepth 3 -name '*.bak*' -print
```
Expected: a list of the snapshot files plus older `*.bak` and `*.bak-hypr-port` from prior work.

- [ ] **Step 2: Delete them**

Run:
```bash
sudo find /etc/nixos -maxdepth 3 -name '*.bak*' -delete
```
Expected: no output, exit 0.

- [ ] **Step 3: Final sanity**

Run:
```bash
sudo find /etc/nixos -maxdepth 3 -name '*.bak*'
```
Expected: empty output.

---

## Self-review

### Spec coverage

- [x] Move the tree (`/home/max/focus/` → `/etc/nixos/home/`) — Task 2.
- [x] Single-knob `primaryUser` defined in `configuration.nix` — Task 3 Step 1.
- [x] Propagation via `_module.args` (system) — Task 3 Step 1.
- [x] Propagation via `home-manager.extraSpecialArgs` (home-manager) — Task 3 Step 2.
- [x] `users.${primaryUser}` rename in `configuration.nix` and `users.nix` — Tasks 3 Step 2, 7.
- [x] `home.username` / `home.homeDirectory` derived from variables — Task 6.
- [x] Relative `./home/...` imports in `home.nix` — Task 6.
- [x] `${userHome}` rewrite of install paths — Task 4.
- [x] `~/...` rewrite of Hyprland binds — Task 5.
- [x] Duplicate gnome-keyring cleanup — Task 8.
- [x] Keyring module security-model + resetExisting warning — Task 1 Steps 1–2.
- [x] hyprland-config.nix stale-comment fixes — Task 1 Step 3.
- [x] `*.bak` cleanup gated on verification — Task 11 (and rollback note in the spec).
- [x] Eval + apply + functional verification — Tasks 9, 10.

### Placeholder / type-consistency check

- No "TBD" / "TODO" / "implement later" present.
- Variable names `primaryUser` and `userHome` are used identically across all tasks.
- File paths in tasks reflect post-move locations for files inside the moved tree; pre-move locations for files edited before the move (Task 1).
- `_module.args = { inherit primaryUser userHome; };` and `extraSpecialArgs = { inherit primaryUser userHome; };` have matching attribute sets — modules receiving these args use the same names in their function heads.
- The Hyprland substitution (`/home/max/.config/hypr/scripts/` → `~/.config/hypr/scripts/`) is safe because Task 4 first removes the OTHER `/home/max/.config/hypr/scripts/` references from the install blocks, leaving the bind block as the sole remaining matches.
