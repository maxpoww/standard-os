{ config, lib, pkgs, ... }:

let
  cfg = config.services.brightnessDaemon;
in
{
  options.services.brightnessDaemon.enable =
    lib.mkEnableOption "StandardOS brightness daemon (sysfs poll + RTMIN+21 cache)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.brightness-daemon = {
      Unit = {
        Description = "StandardOS brightness daemon (sysfs poll + RTMIN+21 cache)";
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.brightnessctl}/bin:${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/brightness-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
