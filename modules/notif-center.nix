# =============================================================================
# notif-center.nix — OPTIONS notification center, SPINE only.
#
# A home-manager module wiring three things:
#   1. mako with popups OFF + history ON (the dbus daemon + persistence layer).
#   2. notif-daemon as a systemd.user.service — subscribes to dbus events,
#      computes pill state from makoctl, writes /tmp/waybar-cache/notif,
#      signals RTMIN+12 to waybar.
#   3. notif-click as a writeShellScriptBin — waybar custom/notif on-click
#      dispatcher (transient → makoctl invoke <latest>, rest → dismiss-all).
#
# OPTIONS owns 100% of the visible surface — mako never paints. The pill in
# SYSTEM zone is the entire notification UX in the foundation spec.
#
# Spec:   /etc/nixos/home/waybar/docs/superpowers/specs/
#         2026-06-06-notification-center-spine-design.md
#
# Usage:
#   services.notifCenter.enable = true;
#
# Toggle off: set enable = false and rebuild. mako stays running because
# home-manager's services.mako module is enabled UNDER this flag — disabling
# notifCenter also disables mako. If you want mako alive without our spine,
# enable services.mako directly elsewhere and set notifCenter.enable = false.
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.notifCenter;

  # Runtime dependencies for the daemon + click script.
  # dbus brings `dbus-monitor`; mako brings `makoctl`; jq parses mako's
  # list JSON; procps brings `pkill`; coreutils brings everything else.
  runtimeDeps = with pkgs; [
    bash
    coreutils
    dbus
    jq
    mako
    procps
  ];

  binPath = lib.makeBinPath runtimeDeps;

  # Wrap an external bash script as a /nix/store binary. PATH is curated
  # so the script never inherits the user's PATH (NixOS hardening + the
  # FHS-assumption hazard from Standard-OS CLAUDE.md).
  mkScript = name: src: pkgs.writeShellScriptBin name ''
    export PATH=${binPath}:$PATH
    exec ${pkgs.bash}/bin/bash ${src} "$@"
  '';

  notifDaemonBin = mkScript "notif-daemon" ./../scripts/notif-daemon;
  notifClickBin  = mkScript "notif-click"  ./../scripts/notif-click;

in {
  options.services.notifCenter = {
    enable = lib.mkEnableOption "OPTIONS notification center spine";

    waybarSignal = lib.mkOption {
      type = lib.types.ints.between 10 30;
      default = 12;
      description = ''
        RTMIN+N waybar signal that wakes the custom/notif pill. Must match
        the `signal` field on the custom/notif module in waybar/config.jsonc
        AND the registry table in waybar/ARCHITECTURE.md. The default (12)
        was marked FREE in the registry at spec time.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ notifDaemonBin notifClickBin ];

    # ── mako: capture / history / DND backbone — popups OFF ──────────────
    # mako ships a D-Bus auto-activation service (fr.emersion.mako.service)
    # that starts it on demand whenever anything calls into the
    # org.freedesktop.Notifications bus name. This is the dominant launch
    # path on Hyprland and it conflicts with `services.mako.enable = true`
    # (home-manager's systemd unit can't acquire the bus name when D-Bus
    # already activated mako via the .service file in /usr/share/dbus-1/).
    #
    # Solution: install the config file directly with xdg.configFile and
    # skip the systemd unit entirely. mako auto-starts when needed; reads
    # this config every time it (re)starts. To force a re-read after
    # editing this config: `pkill .mako-wrapped` — D-Bus activation
    # respawns mako with the new config on the next notification.
    xdg.configFile."mako/config".text = ''
      # Managed by /etc/nixos/home/modules/notif-center.nix — do not edit
      # directly. OPTIONS owns the visible surface; mako handles capture
      # + history + DND state only.

      # invisible = 1 → notifications are STORED in history but NEVER
      # painted as popups. This is the right knob; max-visible=0 silently
      # drops notifications entirely (mako 1.10 behavior, verified by
      # busctl ListNotifications returning empty until we switched to this).
      invisible=1

      # default-timeout = 0 → notifications sit in history until
      # explicitly dismissed (by the user via notif pill rest-face click,
      # or per-notification by future drawer actions).
      default-timeout=0

      # Keep history enabled — busctl Mako.ListNotifications is the
      # daemon's authoritative source for unread/critical counts.
      history=1
    '';

    # ── notif-daemon: the spine's main loop ──────────────────────────────
    systemd.user.services.notif-daemon = {
      Unit = {
        Description = "OPTIONS notification center daemon — mako → cache → waybar";
        PartOf = [ "graphical-session.target" ];
        # mako is D-Bus-activated, not systemd-managed (see comment above)
        # — so we don't list it in After. The daemon's query_mako_state
        # handles the case where mako isn't running yet (empty list).
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${notifDaemonBin}/bin/notif-daemon";
        # Restart=always: dbus-monitor can EOF when dbus restarts. The
        # daemon's read loop breaks cleanly; systemd respawns us.
        Restart = "always";
        RestartSec = 1;
        Environment = [
          "NOTIF_SIGNAL=${toString cfg.waybarSignal}"
        ];
      };
    };
  };
}
