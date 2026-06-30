# Unlocked Keyring (zero-prompt secret service) — design

**Date:** 2026-05-21
**Status:** Approved for implementation
**Scope:** Home-manager module under `/home/max/focus/modules/` for the custom NixOS distro.

## Problem

With greetd autologin (`services.greetd.settings.default_session.command = "uwsm start hyprland-uwsm.desktop"`, `user = "max"`), no password ever transits PAM at session start. `security.pam.services.{greetd,hyprland,login}.enableGnomeKeyring = true` is therefore a no-op for the autologin path — `pam_gnome_keyring.so` has no secret to forward to the daemon.

Result: `gnome-keyring-daemon` is running (D-Bus-activated by `services.gnome.gnome-keyring.enable`), but its `login.keyring` / `Default_Keyring.keyring` stays locked. Any app that talks to the secret-service over D-Bus (Chrome, Signal, Slack, network-share auth, etc.) triggers the `gcr-prompter` "Unlock Keyring" dialog. Users of the distro must never see this.

## Goal

Zero keyring prompts on a fresh install, with no per-user setup steps, and no regressions to apps that legitimately use the secret service.

## Non-goals

- Encryption-at-rest for in-keyring secrets. Without a user-entered secret at boot, no auto-unlock scheme can provide it. The distro's full-disk encryption (LUKS) is the real protection layer; the keyring is file-permissions only.
- Replacing libsecret. Apps that store credentials via the secret service still work — the keyring just auto-unlocks.
- Migrating saved secrets from the current passworded keyring. This is a clean wipe.

## Threat model (explicit)

In-scope:
- Casual observation, shoulder-surfing, dropped-laptop with FDE engaged.
- Co-running user-space processes reading the keyring file via the file system: this is **not** mitigated. Any process running as the user can read the keyring. Same de-facto posture as a logged-in macOS or Windows session.

Out-of-scope:
- Hostile multi-user environments on the same Linux account.
- Targeted attacker with the unencrypted disk in hand (mitigated by LUKS, not by us).

## Design — `services.keyring.unlocked`

One new home-manager module: `/home/max/focus/modules/keyring-unlocked.nix`, imported from `/etc/nixos/home.nix` via an absolute path (same pattern as the other modules under `/home/max/focus/modules/`).

### Module options

Home-manager module (`/home/max/focus/modules/keyring-unlocked.nix`):

```nix
services.keyring.unlocked = {
  enable        = lib.mkEnableOption "empty-password gnome-keyring auto-unlock";
  resetExisting = lib.mkOption { type = lib.types.bool; default = true; };
};
```

System module (`/etc/nixos/modules/chrome.nix`):

```nix
services.chromeBasicPasswordStore = {
  enable = lib.mkEnableOption "--password-store=basic for google-chrome (skip secret service)";
};
```

- `services.keyring.unlocked.enable` — opt-in; distro default `true` from `home.nix`.
- `services.keyring.unlocked.resetExisting` — one-time wipe of any pre-existing `*.keyring` files (marker-gated so it never re-wipes). Set `false` for hosts that have real secrets to keep — they'll need to manually clear `~/.local/share/keyrings/` before enabling.
- `services.chromeBasicPasswordStore.enable` — opt-in; distro default `true` from `configuration.nix`. Adds `--password-store=basic` to google-chrome via a nixpkgs overlay. Silos Chrome passwords in `~/.config/google-chrome/Default/Login Data` instead of routing through the secret service.

### Components

**1. One-time keyring wipe (home-manager activation, marker-gated)**

`home.activation.keyringWipeOnce` (under `lib.hm.dag.entryAfter [ "writeBoundary" ]`):

```
KEYRING_DIR="$HOME/.local/share/keyrings"
MARKER="$KEYRING_DIR/.empty-password-initialized"
if [ ! -f "$MARKER" ] && [ "$RESET_EXISTING" = "1" ]; then
  mkdir -p "$KEYRING_DIR"
  rm -f "$KEYRING_DIR"/*.keyring "$KEYRING_DIR/user.keystore"
  touch "$MARKER"
fi
```

Runs only when `resetExisting = true` and the marker is absent. Idempotent on subsequent rebuilds.

**2. Empty-password unlock service (systemd user, oneshot)**

`systemd.user.services.gnome-keyring-empty-unlock`:

```
Unit:
  Description = Auto-unlock gnome-keyring with empty password
  After       = graphical-session-pre.target
  Before      = graphical-session.target
  PartOf      = graphical-session.target

Service:
  Type            = oneshot
  RemainAfterExit = true
  ExecStart       = <pkgs.writeShellScript "gnome-keyring-empty-unlock"> …

Install:
  WantedBy = graphical-session.target
```

The script:
1. `mkdir -p ~/.local/share/keyrings`.
2. Write `~/.local/share/keyrings/default` containing the literal `login` (atomic `tmp + mv`) if it's missing or has different content.
3. `printf '' | gnome-keyring-daemon --unlock` — pipes an empty password to the running daemon. The daemon was already started either by D-Bus activation (via `services.gnome.gnome-keyring.enable`) or by `pam_gnome_keyring.so`. On first run with no keyring file present, gnome-keyring creates `login.keyring` on the first secret-store write and that file inherits the empty password set here.

Belt-and-braces: re-running the script on every session start is safe — `--unlock` with the existing empty password is a no-op against an already-unlocked daemon.

**3. Chrome basic password store (system-level overlay)**

New file `/etc/nixos/modules/chrome.nix`:

```nix
{ config, lib, pkgs, ... }:
let cfg = config.services.chromeBasicPasswordStore; in {
  options.services.chromeBasicPasswordStore.enable =
    lib.mkEnableOption "--password-store=basic for google-chrome";

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

`google-chrome` in nixpkgs accepts `commandLineArgs` via its wrapper. The override is global — every consumer of `pkgs.google-chrome` gets the flag. Result: Chrome stops calling the secret service for password storage entirely.

### Module split (system vs home-manager)

The keyring auto-unlock is per-user state → home-manager.
The Chrome overlay is a nixpkgs override that affects the system closure → NixOS system module.

Therefore the work lands in **two** files:

| File | Layer | Purpose |
|---|---|---|
| `/home/max/focus/modules/keyring-unlocked.nix` | home-manager | wipe + systemd user service |
| `/etc/nixos/modules/chrome.nix` | system | google-chrome overlay |

Both have independent enable flags. The home.nix and configuration.nix imports turn them both on. Users of the distro can disable either independently.

### Removed / unchanged

- `security.pam.services.greetd.enableGnomeKeyring`, `…hyprland.enableGnomeKeyring`, `…login.enableGnomeKeyring` (in `modules/services.nix` and `modules/nautilus-system.nix`) — **kept as-is**. They are dormant under autologin (no password to forward) but harmless, and they still do useful work for the TTY-login path (someone logging in via virtual console with their account password). Leaving them avoids a regression for non-autologin paths.
- Duplicate `services.gnome.gnome-keyring.enable = true` lives in both `services.nix` and `nautilus-system.nix`. Out of scope for this spec — flag for a future tidy-up but don't touch here.

### Distro packaging

- `/etc/nixos/home.nix`: add `/home/max/focus/modules/keyring-unlocked.nix` to the imports list; set `services.keyring.unlocked.enable = true`.
- `/etc/nixos/configuration.nix`: add `./modules/chrome.nix` to the imports list; the module itself reads its own enable flag with a default of `true`.

## Verification (post-install)

1. `nixos-rebuild switch` succeeds.
2. After reboot:
   - `~/.local/share/keyrings/.empty-password-initialized` exists.
   - `~/.local/share/keyrings/default` contains `login`.
   - `~/.local/share/keyrings/login.keyring` exists and is the file the daemon is using (`lsof -p $(pgrep -f 'gnome-keyring-daemon')` shows it).
   - `systemctl --user status gnome-keyring-empty-unlock` is `active (exited)`.
3. Open Chrome → no prompt. Run `secret-tool store --label=test foo bar` then `secret-tool lookup foo bar` → roundtrips without a prompt.
4. `ps -ef | grep chrome` shows `--password-store=basic` in the cmdline.

## Rebuild behavior (idempotency)

The most important property for a distro module: subsequent `nixos-rebuild switch` runs must not destroy user state.

| Action | First rebuild after enabling | Every later rebuild |
|---|---|---|
| Keyring wipe (home activation) | runs, drops marker file | marker present → no-op |
| Empty-password unlock (systemd user oneshot) | unlocks (and creates) empty-password keyring | unlocks already-empty keyring → no-op |
| Chrome overlay | flag applied on next launch | unchanged |
| Saved secrets stored *after* first rebuild | n/a | persist untouched |

Concretely: anything a user stores in the keyring *after* the first rebuild — via `secret-tool`, GNOME Online Accounts, Signal pinning, Nautilus saving SMB creds, etc. — survives every future rebuild.

The `.empty-password-initialized` marker file is the contract. Removing it manually is the only way to trigger a re-wipe.

## Migration impact (one-time, max's machine only)

For fresh installs of the distro, this section does not apply.

For the existing host:
- **Keyring file is wiped** on first rebuild. Saved entries in `Default_Keyring.keyring` (SMB shares, etc.) are lost. Acceptable; explicit user decision.
- **Chrome saved passwords become unreadable** on first launch after the rebuild. Entries remain in `~/.config/google-chrome/Default/Login Data` but the password column is encrypted with a key the new `--password-store=basic` Chrome cannot derive. Re-save passwords on next sign-in to each site. Reverting `services.chromeBasicPasswordStore.enable = false` and rebuilding restores access.

## Risks

- **`google-chrome` override surface area.** If a future nixpkgs bump renames or drops the `commandLineArgs` arg, the overlay fails the eval. Mitigation: keep the override block tiny; failure is loud (eval error during rebuild) and easy to fix.
- **`pam_gnome_keyring.so` on TTY login** with a non-empty account password attempts to unlock the (empty-password) keyring with the wrong password → fails silently. The systemd user service then unlocks it. End state is correct; only effect is a wasted PAM hook. Acceptable.
- **First-run race.** If an app talks to the secret service in the brief window between greetd handing off to Hyprland and `gnome-keyring-empty-unlock.service` running, it may see a locked keyring. Mitigated by `Before = graphical-session.target` — the unlock fires before any app started under `graphical-session.target` (which is where uwsm puts user services). Apps Chrome launches from a desktop file would be after the target.

## Out of scope (deliberately deferred)

- Removing the `enableGnomeKeyring` PAM entries.
- Consolidating the duplicate `services.gnome.gnome-keyring.enable` declarations.
- Per-app handling for non-Chrome/non-Chromium browsers (Firefox doesn't use the secret service by default — no action needed; other Chromium forks would need the same override pattern but the distro defaults to Chrome).
- Importing existing secrets from the wiped keyring.
