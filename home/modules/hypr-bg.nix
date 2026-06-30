# Hypr-bg daemon — single-rule background painter, owns /tmp/glass-mode.
# Source: waybar/scripts/hypr-bg-daemon.sh (bundled into waybar-scripts).
# See docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
{ config, lib, ... }:

let
  cfg = config.services.hyprBg;
in
{
  options.services.hyprBg = {
    enable = lib.mkEnableOption "Hyprland single-rule background painter";

    sampleHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Pixels of vertical strip sampled from the window's top edge.";
    };

    sampleWidthMax = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Max pixels of window width to sample (centered).";
    };

    distanceThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Squared-RGB difference below which color updates are skipped.";
    };

    cacheSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = "Max retained solid-color PNGs in /tmp/hypr-edge-bg.";
    };

    waypaperConfigPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/waypaper/config.ini";
      description = "Path to waypaper config; watched for wallpaper changes.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.waybar-hypr-bg-daemon = {
      Unit = {
        Description = "Hyprland single-rule background painter + glass-mode owner";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" "waybar-hypr-context-daemon.service" "hyprpaper.service" ];
        Requires = [ "waybar-hypr-context-daemon.service" ];
        StartLimitBurst = 20;
        StartLimitIntervalSec = 300;
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "/etc/profiles/per-user/${config.home.username}/bin/hypr-bg-daemon";
        Restart = "always";
        RestartSec = 1;
        Environment = [
          "HYPR_BG_SAMPLE_H=${toString cfg.sampleHeight}"
          "HYPR_BG_SAMPLE_W_MAX=${toString cfg.sampleWidthMax}"
          "HYPR_BG_DIST_THRESHOLD=${toString cfg.distanceThreshold}"
          "HYPR_BG_CACHE_SIZE=${toString cfg.cacheSize}"
          "WAYPAPER_CFG=${cfg.waypaperConfigPath}"
        ];
      };
    };
  };
}
