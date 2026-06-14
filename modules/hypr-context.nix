# Hypr-context daemon — unified Hyprland-state publisher.
# Source: waybar/scripts/hypr-context-daemon.sh (bundled into the
# `waybar-scripts` derivation in modules/waybar.nix).
# See docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md
{ config, lib, ... }:

let
  cfg = config.services.hyprContext;
in
{
  options.services.hyprContext = {
    enable = lib.mkEnableOption "Unified Hyprland-state publisher (waybar pills + snapshot)";
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.waybar-hypr-context-daemon = {
      Unit = {
        Description = "Hyprland unified context publisher (waybar pills + hypr-context.json)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        StartLimitBurst = 20;
        StartLimitIntervalSec = 300;
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        # Path resolved via waybar-scripts derivation (installed by modules/waybar.nix).
        ExecStart = "/etc/profiles/per-user/${config.home.username}/bin/hypr-context-daemon";
        Restart = "always";
        RestartSec = 1;
      };
    };
  };
}
