{ config, lib, pkgs, ... }:

let
  cfg = config.services.pomodoroDaemon;
in
{
  options.services.pomodoroDaemon.enable =
    lib.mkEnableOption "StandardOS pomodoro daemon (FIFO + state cache)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.pomodoro-daemon = {
      Unit = {
        Description = "StandardOS pomodoro daemon (FIFO + state cache)";
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/pomodoro-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };

    # Expose pomodoroctl as ~/.local/bin/pomodoroctl so it is on the
    # user's PATH alongside other manually-added tools (e.g. claude-app).
    home.file.".local/bin/pomodoroctl" = {
      source = /etc/nixos/home/scripts/pomodoroctl;
      executable = true;
    };
  };
}
