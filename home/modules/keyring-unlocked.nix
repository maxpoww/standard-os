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

    # Pipe an empty password to the daemon. The daemon is already running
    # (D-Bus-activated via services.gnome.gnome-keyring.enable). On first run
    # with no keyring file present, the daemon creates 'login.keyring' with
    # empty password on the next secret-store write.
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
