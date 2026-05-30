# =============================================================================
# waybar.nix — declarative home-manager management of the waybar bar
#
# Owns ~/.config/waybar/{config.jsonc,style.css}. The source files live next
# to this module under ../waybar/ so they remain easy to read and edit as
# normal JSON/CSS, then are mapped into the user's config via xdg.configFile.
#
# IMPORTANT — out-of-store symlinks. ~/.config/waybar/{config.jsonc,style.css}
# symlink DIRECTLY to /etc/nixos/home/waybar/{config.jsonc,style.css} via
# `mkOutOfStoreSymlink`, NOT to copies in /nix/store. Why: this is a
# development distro; the user iterates on style.css and config.jsonc
# constantly, and the old behavior (Nix copies source into store at build
# time) silently swallowed every edit until the next `sudo nixos-rebuild
# switch`. Restarting waybar alone reloaded the stale store copy and the
# edit looked like a no-op — a real bug, not a theoretical one.
# With out-of-store symlinks: edit the source under /etc/nixos/home/waybar/,
# then `systemctl --user restart waybar.service` (or `pkill -SIGUSR2 waybar`)
# and the change is live. NO rebuild required for CSS or config tweaks.
# A rebuild is still needed when this module itself changes (or any other
# .nix file). The source is git-versioned in /etc/nixos/home/waybar/.git,
# so reproducibility comes from git, not from the store path being content-
# addressed.
#
# Also wires waybar (and its two cache daemons) as systemd.user.services so
# the bar comes back automatically after crashes and after a logout/login.
# This replaces the legacy ~/.config/waybar/launch.sh exec-once chain, which
# silently lost the bar when waybar died early in boot (no Restart= and no
# unit observability — see distro work).
#
# Note: the daemon scripts (~/.config/waybar/scripts/*.sh) are NOT yet
# managed by this module. They remain real files in the user's home for now;
# migrating them to Nix is a separate task tracked in the distro work.
#
# Usage:
#   services.waybarBar.enable = true;
#   services.waybarBar.systemd.enable = true;     # default
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.waybarBar;

  # Where the runtime scripts live. Hard-coded against the user's home
  # because they're not yet nix-packaged; the distro migration will move
  # them under writeShellScriptBin and drop this option.
  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";
in
{
  options.services.waybarBar = {
    enable = lib.mkEnableOption "declarative waybar config (config.jsonc + style.css)";

    configSource = lib.mkOption {
      type = lib.types.path;
      default = ./../waybar/config.jsonc;
      description = "Path of the waybar config.jsonc to install.";
    };

    styleSource = lib.mkOption {
      type = lib.types.path;
      default = ./../waybar/style.css;
      description = "Path of the waybar style.css to install.";
    };

    systemd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run waybar and its two cache daemons (glass-text-daemon,
        workspace-daemon) as systemd --user units bound to
        graphical-session.target. Each unit has Restart=always so a
        crash or signal-kill is recovered without losing the bar.

        When true, the legacy `exec-once = ~/.config/waybar/launch.sh`
        in Hyprland's Autostart.conf must NOT also fire — otherwise two
        waybar instances race. Disable this flag to opt out.
      '';
    };

    waybarPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.waybar;
      description = "Waybar package providing the binary used by the unit.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # waybar itself is already installed system-wide via modules/packages.nix.
      # We only own the per-user config files here.
      #
      # mkOutOfStoreSymlink: ~/.config/waybar/* points directly to the
      # source in /etc/nixos/home/waybar/*, NOT to a /nix/store copy.
      # Iteration is "edit + restart waybar" — no rebuild step.
      # See the module-header "IMPORTANT — out-of-store symlinks" note
      # for the full rationale.
      xdg.configFile."waybar/config.jsonc" = {
        source = config.lib.file.mkOutOfStoreSymlink cfg.configSource;
        force  = true;   # overwrite any existing hand-edited file on first activation
      };

      xdg.configFile."waybar/style.css" = {
        source = config.lib.file.mkOutOfStoreSymlink cfg.styleSource;
        force  = true;
      };
    }

    (lib.mkIf cfg.systemd.enable {
      systemd.user.services.waybar = {
        Unit = {
          Description = "Waybar status bar";
          PartOf = [ "graphical-session.target" ];
          # Order AFTER the cache daemons so /tmp/waybar-cache is already
          # populated when waybar reads it on cold boot. Wants= (not
          # Requires=) keeps the bar visible even if a daemon fails —
          # partial bar > no bar.
          After = [
            "graphical-session.target"
            "waybar-workspace-daemon.service"
            "waybar-glass-text-daemon.service"
          ];
          Wants = [
            "waybar-workspace-daemon.service"
            "waybar-glass-text-daemon.service"
          ];
          # Don't try to start if waybar can't reach a wayland display.
          ConditionEnvironment = "WAYLAND_DISPLAY";
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "simple";
          ExecStart = "${cfg.waybarPackage}/bin/waybar";
          # No ExecStartPre wipe: waybar owns no on-disk state. The
          # previous version cleared /tmp/waybar-cache + /tmp/glass-mode
          # + the glass-text-daemon lock/pid on every restart — but
          # those belong to the sibling daemons, not to waybar. With
          # Restart=always the wipe ran on every crash and emptied the
          # workspace cache out from under the still-running daemon
          # (which only mkdir'd once at startup), permanently breaking
          # the workspaces module until a manual daemon restart.
          # Each daemon now manages its own state in its own ExecStartPre.
          # Restart=always: waybar can die from an unhandled real-time
          # signal (RTMIN+N where N isn't subscribed in config.jsonc) or
          # from compositor IPC hiccups. The user always wants the bar
          # back without manual intervention.
          Restart = "always";
          RestartSec = 1;
        };
      };

      systemd.user.services.waybar-glass-text-daemon = {
        Unit = {
          Description = "Waybar glass-text daemon (background-aware text color)";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "simple";
          # Clear our own stale lock/pid from the previous instance. The
          # daemon also does a PID-alive check internally, but removing
          # the files declaratively before start keeps the lifecycle
          # owned by this unit rather than relying on luck.
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f /tmp/glass-text-daemon.lock /tmp/glass-text-daemon.pid";
          # Pass through PATH so `hyprctl` / `pkill` / friends are reachable.
          ExecStart = "${pkgs.bash}/bin/bash ${scriptsDir}/glass-text-daemon.sh";
          Restart = "always";
          RestartSec = 1;
        };
      };

      systemd.user.services.waybar-workspace-daemon = {
        Unit = {
          Description = "Waybar workspace cache daemon (per-module JSON writer)";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "simple";
          # Guarantee the cache dir exists before the daemon's first
          # write. The daemon also self-heals each iteration, but doing
          # the mkdir here makes the dir present from the very first
          # tick (otherwise modules with interval=2 could read an empty
          # cache for up to 1s after boot).
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /tmp/waybar-cache";
          ExecStart = "${pkgs.bash}/bin/bash ${scriptsDir}/workspace-daemon.sh";
          Restart = "always";
          RestartSec = 1;
        };
      };
    })
  ]);
}
