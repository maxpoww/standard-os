{ config, lib, pkgs, ... }:

let
  cfg = config.services.calSourceDaemon;
in
{
  options.services.calSourceDaemon = {
    enable = lib.mkEnableOption "StandardOS calendar source daemon (ICS → agenda)";
    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds between ICS re-reads.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.cal-source-daemon = {
      Unit = {
        Description = "StandardOS calendar source (ICS → agenda.json)";
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "CAL_POLL_INTERVAL=${toString cfg.pollInterval}"
          "PATH=${pkgs.jq}/bin:${pkgs.gawk}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/cal-source-daemon.sh";
        Restart = "always";
        RestartSec = "10";
      };
    };
  };
}
