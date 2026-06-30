{ config, lib, pkgs, ... }:

let
  cfg = config.services.systemDaemon;
in
{
  options.services.systemDaemon = {
    enable = lib.mkEnableOption "StandardOS system daemon (RTMIN+18; sys-* caches)";
    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Seconds between poll iterations.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.system-daemon = {
      Unit.Description = "StandardOS system daemon (CPU/GPU/mem/battery/temp)";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "SYSTEM_POLL_INTERVAL=${toString cfg.pollInterval}"
          "PATH=${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.gawk}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/system-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
