# =============================================================================
# widgets-canvas.nix — declarative home-manager management of the
# StandardOS widget canvas (the Dashboard surface).
#
# Owns ~/.config/eww/{eww.yuck, eww.scss, palette.css}. The source files
# live under /etc/nixos/home/widgets/ so they remain easy to read and edit,
# mapped into the user's config via xdg.configFile.
#
# IMPORTANT — out-of-store symlinks. ~/.config/eww/* symlink DIRECTLY to
# /etc/nixos/home/widgets/* via `mkOutOfStoreSymlink`, NOT to copies in
# /nix/store. Iteration is "edit + `systemctl --user restart
# standardos-canvas.service`" — no rebuild step. Mirrors the pattern
# established by waybar.nix; see that module's header for the full
# rationale.
#
# Wires `eww daemon --no-daemonize` as a systemd-user service bound to
# graphical-session.target with Restart=always — the daemon must be
# running before the user holds Super+Return, or `eww open dashboard`
# fails silently. The Hyprland keybinds live in
# /etc/nixos/home/hypr/modules/Binds.conf (separate module, see
# hyprland-config.nix).
#
# Usage:
#   services.standardosCanvas.enable = true;
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.standardosCanvas;

  # Source-of-truth directory for the canvas config files. The actual
  # paths are absolute strings (not Nix paths) so `mkOutOfStoreSymlink`
  # symlinks to /etc/nixos/home/widgets/ directly, preserving edit-and-
  # restart iteration.
  widgetsDir = "/etc/nixos/home/widgets";
in
{
  options.services.standardosCanvas = {
    enable = lib.mkEnableOption "StandardOS widget canvas (Dashboard surface)";

    ewwPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.eww;
      description = "Eww package providing the daemon binary.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install eww into the user's profile so the binary is on PATH for
    # the Hyprland keybind exec strings (`eww open dashboard`).
    home.packages = [ cfg.ewwPackage ];

    # Out-of-store symlinks: edits to /etc/nixos/home/widgets/* are live
    # the moment the file is saved. Only a daemon restart picks up
    # eww.yuck / eww.scss changes (eww does not hot-reload on file
    # change in Wave 0). palette.css changes also require a restart.
    xdg.configFile."eww/eww.yuck" = {
      source = config.lib.file.mkOutOfStoreSymlink "${widgetsDir}/eww/eww.yuck";
      force  = true;
    };
    xdg.configFile."eww/eww.scss" = {
      source = config.lib.file.mkOutOfStoreSymlink "${widgetsDir}/eww/eww.scss";
      force  = true;
    };
    xdg.configFile."eww/palette.css" = {
      source = config.lib.file.mkOutOfStoreSymlink "${widgetsDir}/palette.css";
      force  = true;
    };

    systemd.user.services.standardos-canvas = {
      Unit = {
        Description = "StandardOS widget canvas (eww daemon)";
        PartOf = [ "graphical-session.target" ];
        # Order after the session is up so the wayland display socket
        # exists when eww connects.
        After = [ "graphical-session.target" ];
        # Don't try to start without a wayland display.
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Environment = [
          "PATH=${cfg.ewwPackage}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
        ];
        Type = "simple";
        # --no-daemonize keeps eww in the foreground so systemd tracks
        # the actual process (without it, systemd loses the daemon
        # after the launcher forks).
        ExecStart = "${cfg.ewwPackage}/bin/eww daemon --no-daemonize";
        # Restart=always: eww can die from a yuck parse error after a
        # config edit; the user always wants the daemon back without
        # manual intervention. The next config edit + restart fixes the
        # parse error.
        Restart = "always";
        RestartSec = 1;
      };
    };
  };
}
