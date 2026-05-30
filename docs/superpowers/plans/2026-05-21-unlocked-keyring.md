# Unlocked Keyring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate gnome-keyring "Unlock Keyring" prompts on autologin sessions of the distro by shipping an empty-password keyring that auto-unlocks at session start, plus configuring Chrome to use its own basic password store.

**Architecture:** One home-manager module wipes the existing passworded keyring file (once, marker-gated) and registers a systemd user oneshot service that pipes an empty password into `gnome-keyring-daemon --unlock` early in `graphical-session.target`. One system NixOS module overlays `pkgs.google-chrome` with `commandLineArgs = "--password-store=basic"`. Both modules are gated by enable flags and imported from `home.nix` / `configuration.nix`.

**Tech Stack:** NixOS (channel-based, no flakes), Home Manager as a NixOS module, gnome-keyring 48, systemd user services, `nixpkgs.overlays`.

**Spec:** `/home/max/focus/docs/superpowers/specs/2026-05-21-unlocked-keyring-design.md`

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `/home/max/focus/modules/keyring-unlocked.nix` | **Create** | Home-manager module: keyring wipe activation + empty-password systemd user unlock service. Owns `services.keyring.unlocked.{enable,resetExisting}`. |
| `/etc/nixos/modules/chrome.nix` | **Create** | System NixOS module: nixpkgs overlay that overrides `google-chrome` with `commandLineArgs = "--password-store=basic"`. Owns `services.chromeBasicPasswordStore.enable`. |
| `/etc/nixos/home.nix` | **Modify** | Add absolute-path import of `/home/max/focus/modules/keyring-unlocked.nix`; set `services.keyring.unlocked.enable = true;`. |
| `/etc/nixos/configuration.nix` | **Modify** | Add `./modules/chrome.nix` to the imports list; set `services.chromeBasicPasswordStore.enable = true;`. |

No other files are touched. PAM entries in `modules/services.nix` and `modules/nautilus-system.nix` stay as-is (kept as belt-and-braces for the TTY-login path; see spec).

## Notes for the implementer

- Nix module syntax: `{ config, lib, pkgs, ... }: { options = …; config = …; }`. Always declare `options` and `config` separately when using `lib.mkIf`.
- `lib.hm.dag.entryAfter [ "writeBoundary" ]` is the home-manager activation phase that runs after the user profile is symlinked into place — the correct place for file-system mutations.
- `pkgs.writeShellScript "name" '' … ''` produces a `/nix/store/<hash>-name` path that has its interpreter line set; use it as the `ExecStart` value directly.
- `systemd.user.services.<name>` under home-manager auto-installs the unit into `~/.config/systemd/user/`. `Install.WantedBy = [ "graphical-session.target" ]` makes it start when the graphical session starts (uwsm sets that target up).
- Parse-check command: `nix-instantiate --parse <file.nix>` — exits 0 on syntactically valid Nix, prints the parse tree to stdout.
- Eval-check command: `sudo nixos-rebuild dry-build` — evaluates the full system config without building. Catches type errors, missing imports, undefined options.
- Apply command: `sudo nixos-rebuild switch` — applies for real. Only run after dry-build is clean.
- Neither `/etc/nixos/` nor `/home/max/focus/` is a git repo on this machine. Skip commit steps. If the user wants version control, that's a separate follow-up.

---

### Task 1: Create the home-manager keyring-unlocked module

**Files:**
- Create: `/home/max/focus/modules/keyring-unlocked.nix`

- [ ] **Step 1: Write the module file**

Write the complete module:

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
{ config, lib, pkgs, ... }:

let
  cfg = config.services.keyring.unlocked;

  unlockScript = pkgs.writeShellScript "gnome-keyring-empty-unlock" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.gnome-keyring pkgs.coreutils ]}:$PATH

    KEYRING_DIR="$HOME/.local/share/keyrings"
    mkdir -p "$KEYRING_DIR"

    # Ensure the 'default' pointer names the 'login' keyring (atomic tmp + mv).
    if [ ! -f "$KEYRING_DIR/default" ] \
       || [ "$(cat "$KEYRING_DIR/default" 2>/dev/null)" != "login" ]; then
      printf 'login' > "$KEYRING_DIR/default.tmp"
      mv -f "$KEYRING_DIR/default.tmp" "$KEYRING_DIR/default"
    fi

    # Pipe an empty password (a bare newline) to the daemon. The daemon is
    # already running (D-Bus-activated via services.gnome.gnome-keyring.enable).
    # On first run with no keyring file present, the daemon creates
    # 'login.keyring' with empty password on the next secret-store write.
    # NB: inside a Nix ''…'' string, the empty string in shell must be
    # written as "" not '' (which would close the Nix string).
    printf '\n' | gnome-keyring-daemon --unlock 2>/dev/null || true
  '';
in
{
  options.services.keyring.unlocked = {
    enable = lib.mkEnableOption "empty-password gnome-keyring auto-unlock";

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
  };

  config = lib.mkIf cfg.enable {
    # One-time wipe of any pre-existing passworded keyring.
    # Marker file in the same directory ensures we never re-wipe.
    home.activation.keyringWipeOnce =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        KEYRING_DIR="$HOME/.local/share/keyrings"
        MARKER="$KEYRING_DIR/.empty-password-initialized"
        if [ ! -f "$MARKER" ] && ${lib.boolToString cfg.resetExisting}; then
          run mkdir -p "$KEYRING_DIR"
          run find "$KEYRING_DIR" -maxdepth 1 -name '*.keyring' -delete
          run touch "$MARKER"
        fi
      '';

    systemd.user.services.gnome-keyring-empty-unlock = {
      Unit = {
        Description = "Auto-unlock gnome-keyring with empty password";
        After       = [ "graphical-session-pre.target" ];
        Before      = [ "graphical-session.target" ];
        PartOf      = [ "graphical-session.target" ];
      };
      Service = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart       = "${unlockScript}";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
```

- [ ] **Step 2: Parse-check the module**

Run: `nix-instantiate --parse /home/max/focus/modules/keyring-unlocked.nix > /dev/null`
Expected: exit 0, no stderr output.

If it fails, the stderr will point at the offending line/column. Fix and re-run until clean.

---

### Task 2: Create the system Chrome overlay module

**Files:**
- Create: `/etc/nixos/modules/chrome.nix`

- [ ] **Step 1: Write the module file**

Write the complete module:

```nix
# =============================================================================
# chrome.nix — google-chrome with --password-store=basic
#
# Silos Chrome saved passwords inside Chrome's own profile (basic obfuscation)
# instead of routing through the libsecret/gnome-keyring secret service.
# Pairs with the home-manager keyring-unlocked module: a libsecret app compro-
# mise can't reach Chrome's password bucket because Chrome no longer uses it.
#
# Requires google-chrome to expose 'commandLineArgs' as an override argument
# (it does, in nixpkgs 25.11). If a future bump removes it, this overlay fails
# loudly at eval time.
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.chromeBasicPasswordStore;
in
{
  options.services.chromeBasicPasswordStore.enable =
    lib.mkEnableOption "google-chrome --password-store=basic override";

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      (final: prev: {
        google-chrome = prev.google-chrome.override {
          commandLineArgs = "--password-store=basic";
        };
      })
    ];
  };
}
```

- [ ] **Step 2: Parse-check the module**

Run: `nix-instantiate --parse /etc/nixos/modules/chrome.nix > /dev/null`
Expected: exit 0, no stderr output.

---

### Task 3: Wire imports and enable flags

**Files:**
- Modify: `/etc/nixos/home.nix` (lines 9–17 — the `imports` list)
- Modify: `/etc/nixos/configuration.nix` (lines 4–29 — the `imports` list)

- [ ] **Step 1: Add the home-manager module import to home.nix**

Add `/home/max/focus/modules/keyring-unlocked.nix` to the imports list and enable it.

Read `/etc/nixos/home.nix` to confirm the current `imports = [ … ];` and `services.*` block locations, then edit.

Replace this:

```nix
  imports = [
    ./home-nautilus.nix
    ./home-screen-type.nix
    /home/max/focus/modules/hypr-edge-bg.nix
    /home/max/focus/modules/voice-dictation.nix
    /home/max/focus/modules/waybar.nix
    /home/max/focus/modules/hyprland-config.nix
    /home/max/focus/hosts/STDOS.nix
  ];
```

With this:

```nix
  imports = [
    ./home-nautilus.nix
    ./home-screen-type.nix
    /home/max/focus/modules/hypr-edge-bg.nix
    /home/max/focus/modules/voice-dictation.nix
    /home/max/focus/modules/waybar.nix
    /home/max/focus/modules/hyprland-config.nix
    /home/max/focus/modules/keyring-unlocked.nix
    /home/max/focus/hosts/STDOS.nix
  ];
```

Then, after the existing `services.waybarBar.enable = true;` line, add:

```nix
  services.keyring.unlocked.enable = true;
```

- [ ] **Step 2: Add the system module import to configuration.nix**

Replace this:

```nix
  imports = [
    ./hardware-configuration.nix
    ./modules/boot.nix
    ./modules/nvidia.nix
    ./modules/networking.nix
    ./modules/locale.nix
    ./modules/users.nix
    ./modules/desktop.nix
    ./modules/audio.nix
    ./modules/bluetooth.nix
    ./modules/power.nix
    ./modules/services.nix
    ./modules/packages.nix

    # Gaming — Bazzite-inspired gaming stack
    ./modules/gaming.nix

    # Nautilus file manager — system-level config
    ./modules/nautilus-system.nix

    # Permissions (backlight, udev rules, etc.)
    ./modules/permissions.nix

    # Home Manager as a NixOS module (channels, not flakes)
    <home-manager/nixos>
  ];
```

With this:

```nix
  imports = [
    ./hardware-configuration.nix
    ./modules/boot.nix
    ./modules/nvidia.nix
    ./modules/networking.nix
    ./modules/locale.nix
    ./modules/users.nix
    ./modules/desktop.nix
    ./modules/audio.nix
    ./modules/bluetooth.nix
    ./modules/power.nix
    ./modules/services.nix
    ./modules/packages.nix

    # Gaming — Bazzite-inspired gaming stack
    ./modules/gaming.nix

    # Nautilus file manager — system-level config
    ./modules/nautilus-system.nix

    # Permissions (backlight, udev rules, etc.)
    ./modules/permissions.nix

    # Chrome — google-chrome with --password-store=basic
    ./modules/chrome.nix

    # Home Manager as a NixOS module (channels, not flakes)
    <home-manager/nixos>
  ];
```

Then, after the `home-manager = { … };` block closes (around line 40), and before `system.stateVersion = "25.11";`, add:

```nix
  services.chromeBasicPasswordStore.enable = true;
```

- [ ] **Step 3: Dry-build the full configuration**

Run: `sudo nixos-rebuild dry-build 2>&1 | tail -40`
Expected: exit 0; final lines say `would copy these paths to the store` or similar; no `error:` lines.

If eval fails, fix the offending file and re-run. Common errors:
- `error: attribute 'X' missing` — typo in option name or missing import.
- `error: undefined variable 'cfg'` — module-internal `let` block dropped.
- `error: The option 'X' does not exist` — missing `options` declaration.

---

### Task 4: Apply and verify

This task does the actual rebuild, then walks through the verification checklist from the spec.

- [ ] **Step 1: Stash a backup of the current keyring (one-time safety net)**

Run:
```bash
cp -a ~/.local/share/keyrings ~/.local/share/keyrings.pre-unlock-bak-$(date +%Y%m%d-%H%M%S)
```
Expected: backup directory created. This lets the user recover if they change their mind. They can delete it later.

- [ ] **Step 2: Apply the configuration**

Run: `sudo nixos-rebuild switch 2>&1 | tail -60`
Expected: exit 0; final line `activation finished` (or similar). No tracebacks.

If the build fails on the `google-chrome` overlay (nixpkgs API drift), the error will mention `commandLineArgs` — see Task 2 step 1 troubleshooting comment.

- [ ] **Step 3: Verify the wipe + marker**

Run:
```bash
ls -la ~/.local/share/keyrings/
```
Expected output includes:
- `.empty-password-initialized` (marker file, 0 bytes)
- `default` (file, contains `login`)
- No `Default_Keyring.keyring` (wiped)
- No `user.keystore` (wiped)

Then run: `cat ~/.local/share/keyrings/default`
Expected output: `login` (no newline).

- [ ] **Step 4: Reboot, then verify the systemd user service**

Run: `sudo reboot`

After autologin completes, open a terminal and run:
```bash
systemctl --user status gnome-keyring-empty-unlock
```
Expected: `Active: active (exited)` with `Process: … (code=exited, status=0/SUCCESS)`.

If it failed: `journalctl --user -u gnome-keyring-empty-unlock --no-pager` shows why.

- [ ] **Step 5: Verify the keyring file was created and is unlocked**

Run:
```bash
ls -la ~/.local/share/keyrings/
lsof -p "$(pgrep -f 'gnome-keyring-daemon --start')" 2>/dev/null | grep keyrings
```
Expected:
- `login.keyring` now exists (the daemon creates it on first secret operation; if not yet present, that's fine — it'll appear on first write).
- `lsof` shows the daemon has the keyrings directory open.

- [ ] **Step 6: Functional secret-service test**

Run:
```bash
secret-tool store --label='unlock-test' service unlock-test key unlock-test
# No prompt should appear. Type any value at the (silent) stdin prompt and hit enter.
echo "hello-world" | secret-tool store --label='unlock-test' service unlock-test key unlock-test
secret-tool lookup service unlock-test key unlock-test
```
Expected: the second command exits silently; the third prints `hello-world` to stdout. **No GUI prompt at any point.**

Clean up: `secret-tool clear service unlock-test key unlock-test`

- [ ] **Step 7: Verify Chrome cmdline**

Run: `pgrep -af '^/nix/store/.*google-chrome|chrome '` (after launching Chrome at least once)
Expected: at least one process line contains `--password-store=basic`.

Alternative if Chrome isn't running: `ls -l "$(which google-chrome-stable)"`, then `head -c 4096 "$(readlink -f "$(which google-chrome-stable)")"` and confirm `--password-store=basic` appears in the wrapper script.

- [ ] **Step 8: Launch Chrome, sign in to a site, confirm no keyring prompt**

Launch Chrome. Open YouTube (the original repro). Confirm no "Unlock Keyring" dialog appears at any point.

If a prompt still appears: the systemd user service didn't unlock the keyring before Chrome started. Check `journalctl --user -u gnome-keyring-empty-unlock` and `systemctl --user list-units --type=service --state=running` for ordering issues.

- [ ] **Step 9: Persistence smoke test**

Run:
```bash
echo "persist-test-value" | secret-tool store --label='persist' service persist key persist
sudo nixos-rebuild switch 2>&1 | tail -5
secret-tool lookup service persist key persist
```
Expected: the final lookup still prints `persist-test-value`. This confirms the marker file is doing its job — the rebuild did not re-wipe the keyring.

Clean up: `secret-tool clear service persist key persist`

---

## Self-review (post-write)

### Spec coverage

- [x] Module options `services.keyring.unlocked.{enable,resetExisting}` — Task 1.
- [x] Module options `services.chromeBasicPasswordStore.enable` — Task 2.
- [x] One-time wipe gated by `.empty-password-initialized` marker — Task 1 Step 1, Task 4 Step 3.
- [x] Systemd user oneshot piping empty password to `gnome-keyring-daemon --unlock` — Task 1 Step 1.
- [x] `~/.local/share/keyrings/default` set to `login` atomically — Task 1 Step 1.
- [x] `nixpkgs.overlays` overriding `google-chrome.commandLineArgs` — Task 2 Step 1.
- [x] Wiring from `home.nix` and `configuration.nix` — Task 3.
- [x] Verification of marker, default pointer, service status, secret-service roundtrip, Chrome cmdline — Task 4 Steps 3–8.
- [x] Rebuild idempotency test (the central concern from the user) — Task 4 Step 9.

### Placeholder / type-consistency check

- No "TBD", "TODO", "implement later" present.
- Option names match across tasks: `services.keyring.unlocked.enable`, `services.keyring.unlocked.resetExisting`, `services.chromeBasicPasswordStore.enable`.
- File paths match across tasks.
- One asymmetry: Task 1's options block uses `services.keyring.unlocked = { … };` (nested attrset); the enable call in Task 3 uses `services.keyring.unlocked.enable = true;` (dotted path). Both are valid Nix and refer to the same option. Intentional.
