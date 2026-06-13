# User-systemd timer that fires the UPDATE scheduler every 5 minutes,
# AND a post-commit git hook at /etc/nixos/home/.git/hooks/post-commit
# that fires it immediately on every commit. Together they guarantee
# the rebuild lands ASAP: the hook handles the normal interactive flow,
# the timer is a safety net for commits that bypass the hook (rebase,
# checkout-as-commit, out-of-band ref moves).
#
# The scheduler script (waybar-scripts/bin/standard-os-update-scheduler)
# does detection + lock-file check + dispatch. No idle gating — see the
# script's header for the rationale.
#
# PATH: home-manager-as-NixOS-module installs user packages into
# /etc/profiles/per-user/<username>/bin. Systemd-user services don't
# inherit that path by default, so we set it explicitly. The bare-name
# `standard-os-update-scheduler` ExecStart then resolves via PATH lookup,
# matching the same pattern waybar.service uses.
{ config, lib, pkgs, ... }:
let
  # Hook content lives in /nix/store and gets `install`-copied into the
  # repo's .git/hooks on every activation. Content changes here propagate
  # via nixos-rebuild without needing a manual hook reinstall.
  postCommitHook = pkgs.writeShellScript "standard-os-post-commit" ''
    # Auto-installed by modules/standard-os-update-scheduler.nix.
    # Triggers the UPDATE scheduler immediately so the new HEAD lands in
    # current-system without waiting for the 5-min timer. The scheduler
    # detaches the pipeline via systemd-run, so this exits in ms and
    # never blocks `git commit`.
    exec /etc/profiles/per-user/${config.home.username}/bin/standard-os-update-scheduler
  '';
in
{
  systemd.user.services.standard-os-update-scheduler = {
    Unit = {
      Description = "Standard-OS UPDATE scheduler (detection + dispatch)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      ExecStart = "/etc/profiles/per-user/${config.home.username}/bin/standard-os-update-scheduler";
    };
  };

  systemd.user.timers.standard-os-update-scheduler = {
    Unit.Description = "Periodic safety-net trigger for the UPDATE scheduler";
    Install.WantedBy = [ "timers.target" ];
    Timer = {
      OnBootSec       = "5min";
      OnUnitActiveSec = "5min";
      Unit            = "standard-os-update-scheduler.service";
    };
  };

  # Install the post-commit hook directly into the repo's .git/hooks. The
  # repo at /etc/nixos/home is owned by ${config.home.username}, so this
  # activation (which runs as the same user) can write the file. Overwrites
  # on every activation so stale content gets refreshed.
  home.activation.installStandardOSPostCommitHook =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -d /etc/nixos/home/.git/hooks ]; then
        $DRY_RUN_CMD install -m 0755 ${postCommitHook} /etc/nixos/home/.git/hooks/post-commit
      fi
    '';
}
