# User-systemd timer that fires the UPDATE scheduler every 5 minutes.
# The scheduler itself (waybar-scripts/bin/standard-os-update-scheduler)
# decides whether to run the pipeline based on detection + idle gates.
# Type=oneshot — the scheduler exits quickly; the pipeline runs detached
# via systemd-run --user --scope.
#
# PATH: home-manager-as-NixOS-module installs user packages into
# /etc/profiles/per-user/<username>/bin. Systemd-user services don't
# inherit that path by default, so we set it explicitly. The bare-name
# `standard-os-update-scheduler` ExecStart then resolves via PATH lookup,
# matching the same pattern waybar.service uses.
{ config, ... }:
{
  systemd.user.services.standard-os-update-scheduler = {
    Unit = {
      Description = "Standard-OS UPDATE scheduler (detection + idle gating)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "oneshot"
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      ExecStart = "/etc/profiles/per-user/${config.home.username}/bin/standard-os-update-scheduler";
    };
  };

  systemd.user.timers.standard-os-update-scheduler = {
    Unit.Description = "Periodic trigger for the UPDATE scheduler";
    Install.WantedBy = [ "timers.target" ];
    Timer = {
      OnBootSec       = "5min";
      OnUnitActiveSec = "5min";
      Unit            = "standard-os-update-scheduler.service";
    };
  };
}
