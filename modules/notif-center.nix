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
    gnugrep        # PCRE (grep -P) for detect_otp
    jq
    libcanberra-gtk3   # canberra-gtk-play for P3 sound subsystem
    libnotify      # notify-send for the do_view step 4 fallback
    mako
    procps
    rofi
    sound-theme-freedesktop
    systemd        # systemctl --user kill for SIGUSR1/USR2 wakes
    wl-clipboard   # wl-copy for the OTP click flow
  ];

  binPath = lib.makeBinPath runtimeDeps;

  # Materialize the lib dir into one /nix/store path. The wrapped scripts
  # get NOTIF_LIB_DIR pointing here so they can `source` without depending
  # on the source-tree layout.
  libDir = pkgs.runCommand "notif-libs" {} ''
    mkdir -p $out/lib
    cp ${../scripts/lib/notif-journal.sh}        $out/lib/notif-journal.sh
    cp ${../scripts/lib/notif-rofi-format.sh}    $out/lib/notif-rofi-format.sh
    # notif-menu's libs — added when notif-menu started shipping.
    cp ${../scripts/lib/notif-menu-format.sh}    $out/lib/notif-menu-format.sh
    cp ${../scripts/lib/notif-hypr.sh}           $out/lib/notif-hypr.sh
    cp ${../scripts/lib/notif-os.sh}             $out/lib/notif-os.sh
  '';

  # Wrap an external bash script as a /nix/store binary. PATH is curated
  # so the script never inherits the user's PATH (NixOS hardening + the
  # FHS-assumption hazard from Standard-OS CLAUDE.md).
  mkScript = name: src: pkgs.writeShellScriptBin name ''
    export PATH=${binPath}:$PATH
    export NOTIF_LIB_DIR=${libDir}/lib
    exec ${pkgs.bash}/bin/bash ${src} "$@"
  '';

  # Rust notif-os-daemon: builds the static binary via rustPlatform.
  notifOsDaemonBin = pkgs.rustPlatform.buildRustPackage {
    pname = "notif-os-daemon";
    version = "0.1.0";
    src = ../notif-os-daemon;
    cargoLock.lockFile = ../notif-os-daemon/Cargo.lock;
    # No runtime deps inside the binary; hyprctl is resolved via PATH at runtime.
    meta.description = "Standard-OS native notification daemon (Rust)";
  };

  notifDaemonBin       = mkScript "notif-daemon"        ./../scripts/notif-daemon;
  notifClickBin        = mkScript "notif-click"         ./../scripts/notif-click;
  notifRofiBin         = mkScript "notif-rofi"          ./../scripts/notif-rofi;
  notifMenuBin         = mkScript "notif-menu"          ./../scripts/notif-menu;

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

    silencedApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Apps whose notifications should be dropped entirely — neither
        transient, nor pin, nor journal entry. App names match the D-Bus
        `app_name` field exactly (case-sensitive). Discover names via:
          busctl --user --json=short call \
            org.freedesktop.Notifications /fr/emersion/Mako \
            fr.emersion.Mako ListNotifications \
            | jq '.data[0][]?."app-name".data'
        Example values: "NetworkManager", "spotify", "cups".
      '';
    };

    journalLimit = lib.mkOption {
      type = lib.types.ints.between 50 5000;
      default = 200;
      description = ''
        Maximum number of journal entries kept in
        ~/.local/share/standard-os/notif-history.jsonl. Older entries are
        pruned on every new arrival.
      '';
    };

    transientMs = lib.mkOption {
      type = lib.types.ints.between 1000 30000;
      default = 5000;
      description = ''
        Duration in milliseconds that the bell pill stays expanded as a
        wide "App · Title" pill after a new notification arrives.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      notifDaemonBin
      notifClickBin
      notifRofiBin
      notifMenuBin       # new: rofi notif selector with View action
      notifOsDaemonBin   # Standard-OS native notif daemon (Rust)
    ];

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
      # Managed by /etc/nixos/home/modules/notif-center.nix — do not edit.
      #
      # Popup suppression strategy: per-urgency criteria with invisible=1.
      # OPTIONS owns the visible notification surface (the notif-bell pill
      # in the bar); mako is the D-Bus capture + history + makoctl backbone.
      # Popups MUST NOT render.
      #
      # Why per-urgency criteria and not the simpler knobs:
      #
      # • `invisible=1` at the global (top-of-config) level is documented
      #   as a STYLE OPTION but in mako 1.10 is treated as a per-criteria
      #   field default — popups still rendered with it set globally
      #   (verified 2026-06-12 after notif-daemon came online for the
      #   first time on this generation).
      #
      # • `max-visible=0` crashes mako 1.10 on Wayland surface init —
      #   the layer-shell anchor/position logic ends up emitting
      #   `wl_surface#3: error -1: x == 0 but anchor doesn't have left
      #   and right` and the compositor kills the surface. D-Bus then
      #   re-activates mako on the next notification, mako crashes
      #   again, makoctl can't connect, and notif-daemon goes silent
      #   (it queries via makoctl). Confirmed regression — DO NOT use
      #   this knob on mako 1.10. Re-evaluate if mako > 1.11 ships.
      #
      # • mako(5) suggests `[mode=do-not-disturb] invisible=1` for the
      #   manual DND toggle. That works on demand but not as the
      #   permanent default — you'd need `makoctl mode -a do-not-disturb`
      #   at session start, which is brittle across mako restarts.
      #
      # Mako 1.10 empirically ignores `invisible=1` for popup rendering
      # in BOTH global position AND per-urgency criteria — verified by
      # `notify-send -u {low,normal,high,critical}` with each config
      # variant; all four still produced visible popups (2026-06-12).
      # mako(5) hints `invisible` only governs max-visible cutoff override,
      # not unconditional render suppression — the phrasing "even if it
      # is above the max-visible cutoff" implies a presupposed cutoff.
      #
      # The docs DO offer a clean DND pattern: `[mode=<name>] invisible=1`
      # criteria + `makoctl mode -a <name>` to enter that mode. Notifications
      # arriving while in the active mode match the criteria and are
      # suppressed. The default mode "default" matches all notifications
      # when no mode is active — so the docs-canonical pattern is to wrap
      # the suppression rules in a `[mode=default]` criteria. Verified to
      # actually fire in mako 1.10 (per-urgency criteria did NOT).
      default-timeout=0
      history=1

      [mode=default]
      invisible=1
    '' + lib.concatMapStrings (app: ''

      [app-name=${app}]
      invisible=1
      history=0
    '') cfg.silencedApps;

    # ── notif-os-daemon: the Rust D-Bus owner ────────────────────────────
    # Owns org.freedesktop.Notifications + org.standardos.NotifOS. Must come
    # up before notif-daemon (bash) — bash queries us via busctl. Starting
    # early also wins the bus-name race against mako's D-Bus auto-activation:
    # whichever service grabs the name first keeps it, so as long as we're
    # running by the time the first app calls Notify, mako stays inert.
    systemd.user.services.notif-os-daemon = {
      Unit = {
        Description = "Standard-OS native notification daemon (Rust)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${notifOsDaemonBin}/bin/notif-os-daemon";
        Restart = "always";
        RestartSec = 1;
      };
    };

    # ── notif-daemon: the spine's main loop ──────────────────────────────
    systemd.user.services.notif-daemon = {
      Unit = {
        Description = "OPTIONS notification center daemon — notif-os-daemon → cache → waybar";
        PartOf = [ "graphical-session.target" ];
        # Must wait for the Rust daemon to own the bus name; we query it
        # via org.standardos.NotifOS.ListNotifications.
        After = [ "graphical-session.target" "notif-os-daemon.service" ];
        Requires = [ "notif-os-daemon.service" ];
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
          "NOTIF_TRANSIENT_MS=${toString cfg.transientMs}"
          "NOTIF_JOURNAL_LIMIT=${toString cfg.journalLimit}"
        ];
      };
    };
  };
}
