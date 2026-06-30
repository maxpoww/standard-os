{ config, lib, pkgs, ... }:

let
  cfg = config.services.weatherDaemon;
in
{
  options.services.weatherDaemon = {
    enable = lib.mkEnableOption "StandardOS weather daemon (canvas weather.json)";

    city = lib.mkOption {
      type = lib.types.str;
      default = "Mendoza";
      description = "City passed to wttr.in.";
    };

    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Seconds between fetches.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.weather-daemon = {
      Unit = {
        Description = "StandardOS weather daemon (canvas weather.json)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "STANDARDOS_WEATHER_CITY=${cfg.city}"
          "WEATHER_POLL_INTERVAL=${toString cfg.pollInterval}"
          "PATH=${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.bash}/bin:${pkgs.coreutils}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/weather-daemon.sh";
        Restart = "always";
        RestartSec = "10";
      };
    };
  };
}
