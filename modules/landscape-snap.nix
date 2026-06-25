{ config, lib, pkgs, ... }:

let
  cfg = config.services.landscapeSnap;
in
{
  options.services.landscapeSnap.enable =
    lib.mkEnableOption "StandardOS landscape snapshot daemon (3x3 workspace exposé)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.landscape-snap = {
      Unit = {
        Description = "StandardOS landscape snapshot daemon (3x3 workspace exposé)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.grim}/bin:${pkgs.jq}/bin:${pkgs.socat}/bin:${pkgs.inotify-tools}/bin:${pkgs.hyprland}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/landscape-snap-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
