{ config, lib, pkgs, ... }:

let
  cfg = config.services.hyprEdgeBg;

  runtimeDeps = with pkgs; [
    bash
    coreutils
    findutils
    gawk
    glib # gsettings
    gnused
    grim
    hyprland # hyprctl
    hyprpaper
    imagemagick
    inotify-tools
    jq
    socat
  ];

  binPath = lib.makeBinPath runtimeDeps;

  colorsLib = pkgs.runCommand "hypr-edge-bg-colors" { } ''
    mkdir -p $out/lib
    cp ${./../scripts/lib/colors.sh} $out/lib/colors.sh
  '';

  mkScript = name: src: pkgs.writeShellScriptBin name ''
    export PATH=${binPath}:$PATH
    export HYPR_EDGE_BG_LIB=${colorsLib}/lib
    exec ${pkgs.bash}/bin/bash ${src} "$@"
  '';

  hyprActivitiesBin = mkScript "hypr-activities" ./../scripts/hypr-activities;
  hyprEdgeBgBin = mkScript "hypr-edge-bg" ./../scripts/hypr-edge-bg;
  hyprDiveBin = mkScript "hypr-dive" ./../scripts/hypr-dive;

in
{
  options.services.hyprEdgeBg = {
    enable = lib.mkEnableOption "Hyprland dive-aware background daemon";

    defaultColor = lib.mkOption {
      type = lib.types.str;
      default = "323246";
      description = "Solid hex (no #) used as the dive-on default background.";
    };

    sampleHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Pixels of vertical strip sampled from the window's top edge.";
    };

    sampleWidthMax = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Max pixels of window width to sample (centered). Narrower = faster.";
    };

    mismatchShiftPct = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 40;
      description = "Luminance shift (% of current luma) when deriving mismatch.";
    };

    mismatchClampMin = lib.mkOption {
      type = lib.types.ints.between 0 255;
      default = 30;
      description = "Lower clamp for mismatch luminance (avoids pure black).";
    };

    mismatchClampMax = lib.mkOption {
      type = lib.types.ints.between 0 255;
      default = 225;
      description = "Upper clamp for mismatch luminance (avoids pure white).";
    };

    distanceThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Squared-RGB difference below which color updates are skipped.";
    };

    pollIntervalSec = lib.mkOption {
      type = lib.types.str;
      default = "0.1";
      description = ''
        Poll cadence (seconds, fractional ok) used while in a color-following
        mode (match/mismatch/mixed). Lower = smoother color tracking, higher
        CPU. apply_color short-circuits hyprpaper traffic when the sampled
        color is stable, so steady-state cost is just grim+magick per tick.
      '';
    };

    cacheSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = "Max retained solid-color PNGs in /tmp/hypr-edge-bg.";
    };

    waypaperConfigPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/waypaper/config.ini";
      description = "Path to the waypaper config to watch for silent dive-off.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ hyprActivitiesBin hyprEdgeBgBin hyprDiveBin ];

    systemd.user.services.hypr-activities = {
      Unit = {
        Description = "Hyprland workspace activity publisher";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${hyprActivitiesBin}/bin/hypr-activities";
        # Restart=always: a clean exit (socat client closing, FIFO ENOENT
        # under cleanup race) is still wrong — we want the publisher up.
        Restart = "always";
        RestartSec = 1;
        Environment = [
          "HYPR_ACTIVITIES_WAYPAPER_CFG=${cfg.waypaperConfigPath}"
        ];
      };
    };

    systemd.user.services.hypr-edge-bg = {
      Unit = {
        Description = "Hyprland dive-aware background driver";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" "hypr-activities.service" "hyprpaper.service" ];
        Requires = [ "hypr-activities.service" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${hyprEdgeBgBin}/bin/hypr-edge-bg";
        # Restart=always: when the activities socket closes (publisher restart,
        # logout race), the read loop EOFs and the script exits 0. We still want
        # the consumer up, so let systemd respawn it and reconnect.
        Restart = "always";
        RestartSec = 1;
        Environment = [
          "HYPR_EDGE_BG_DEFAULT=${cfg.defaultColor}"
          "HYPR_EDGE_BG_SAMPLE_H=${toString cfg.sampleHeight}"
          "HYPR_EDGE_BG_SAMPLE_W_MAX=${toString cfg.sampleWidthMax}"
          "HYPR_EDGE_BG_SHIFT_PCT=${toString cfg.mismatchShiftPct}"
          "HYPR_EDGE_BG_CLAMP_LO=${toString cfg.mismatchClampMin}"
          "HYPR_EDGE_BG_CLAMP_HI=${toString cfg.mismatchClampMax}"
          "HYPR_EDGE_BG_DIST_THRESHOLD=${toString cfg.distanceThreshold}"
          "HYPR_EDGE_BG_POLL_INTERVAL=${cfg.pollIntervalSec}"
          "HYPR_EDGE_BG_CACHE_SIZE=${toString cfg.cacheSize}"
        ];
      };
    };
  };
}
