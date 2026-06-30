{ config, lib, pkgs, ... }:

let cfg = config.services.notifHistoryChannel; in
{
  options.services.notifHistoryChannel.enable =
    lib.mkEnableOption "StandardOS notif-history canvas channel";

  config = lib.mkIf cfg.enable {
    systemd.user.services.notif-history-channel = {
      Unit = {
        Description = "StandardOS notif-history canvas channel";
        After = [ "notif-os-daemon.service" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.jq}/bin:${pkgs.inotify-tools}/bin:${pkgs.coreutils}/bin:${pkgs.procps}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/notif-history-channel.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
