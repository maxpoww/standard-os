{ config, lib, pkgs, ... }:

let
  cfg = config.services.mprisPublisher;
in
{
  options.services.mprisPublisher.enable =
    lib.mkEnableOption "StandardOS mpris-publisher (owns /tmp/waybar-cache/mpris-* and /tmp/mpris/current)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.mpris-publisher = {
      Unit.Description = "StandardOS mpris-publisher (mpris-* pill caches + mpris-snapshot.json composite)";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.playerctl}/bin:${pkgs.jq}/bin:${pkgs.dbus}/bin:${pkgs.inotify-tools}/bin:${pkgs.pipewire}/bin:${pkgs.wireplumber}/bin:${pkgs.curl}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.gawk}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /home/max/mpris-waybar/scripts/mpris-publisher";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
