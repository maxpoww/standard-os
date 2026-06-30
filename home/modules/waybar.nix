# =============================================================================
# waybar.nix — declarative home-manager management of the waybar bar
#
# Owns ~/.config/waybar/{config.jsonc,style.css}. The source files live next
# to this module under ../waybar/ so they remain easy to read and edit as
# normal JSON/CSS, then are mapped into the user's config via xdg.configFile.
#
# IMPORTANT — out-of-store symlinks. ~/.config/waybar/{config.jsonc,style.css}
# symlink DIRECTLY to /etc/nixos/home/waybar/{config.jsonc,style.css} via
# `mkOutOfStoreSymlink`, NOT to copies in /nix/store. Why: this is a
# development distro; the user iterates on style.css and config.jsonc
# constantly, and the old behavior (Nix copies source into store at build
# time) silently swallowed every edit until the next `sudo nixos-rebuild
# switch`. Restarting waybar alone reloaded the stale store copy and the
# edit looked like a no-op — a real bug, not a theoretical one.
# With out-of-store symlinks: edit the source under /etc/nixos/home/waybar/,
# then `systemctl --user restart waybar.service` (or `pkill -SIGUSR2 waybar`)
# and the change is live. NO rebuild required for CSS or config tweaks.
# A rebuild is still needed when this module itself changes (or any other
# .nix file). The source is git-versioned in /etc/nixos/home/waybar/.git,
# so reproducibility comes from git, not from the store path being content-
# addressed.
#
# Also wires waybar (and its two cache daemons) as systemd.user.services so
# the bar comes back automatically after crashes and after a logout/login.
# This replaces the legacy ~/.config/waybar/launch.sh exec-once chain, which
# silently lost the bar when waybar died early in boot (no Restart= and no
# unit observability — see distro work).
#
# The daemon scripts are nix-packaged in this module as the
# `waybar-scripts` derivation (let-block below). Source-of-truth lives
# at /etc/nixos/home/waybar/scripts/; the derivation wraps each script
# as a makeWrapper-curated binary under ${waybar-scripts}/bin/<name>
# with lib/pill.sh shared at share/waybar-scripts/lib/. Until the
# bulletproof migration finishes (Tasks 3–15), some ExecStarts and
# config.jsonc exec sites still reference ~/.config/waybar/scripts/
# via mkOutOfStoreSymlink; those rewire onto the wrapped binaries in
# the same migration. See waybar/docs/superpowers/specs/2026-06-12-
# waybar-bulletproof-design.md for the full picture.
#
# Usage:
#   services.waybarBar.enable = true;
#   services.waybarBar.systemd.enable = true;     # default
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.waybarBar;

  binPath = lib.makeBinPath (with pkgs; [
    bash
    coreutils
    gawk
    gnused
    gnugrep
    jq
    procps
    inotify-tools
    hyprland          # hyprctl
    imagemagick       # hypr-bg-daemon luminance sample (waypaper)
    git               # UPDATE scheduler L1 source-ahead check
    rofi              # reboot-prompt modal
    libnotify         # notify-send fallback
    brightnessctl     # night-dimmer, screen-type
    hyprsunset        # warm-cycle, screen-type
    util-linux        # flock (update pipeline lock)
    polkit            # pkexec (nixos-rebuild with elevated priv)
    systemd           # systemd-run (scheduler spawns pipeline detached)
  ]);

  waybar-scripts = pkgs.stdenv.mkDerivation {
    pname   = "standard-os-waybar-scripts";
    version = "0.1.0";
    src     = ../waybar/scripts;
    nativeBuildInputs = [ pkgs.makeWrapper pkgs.shellcheck ];

    # Gate the build on shellcheck for every script in source-of-truth.
    # Runs against the source files BEFORE substituteInPlace rewrites
    # the lib/pill.sh source line.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      # -S error: only ERROR-severity findings fail the build. Existing
      # scripts have legitimate informational/warning findings
      # (SC1090/SC1091 non-const source, SC2154 false-positive jq vars,
      # SC2034 unused INTERVAL). The gate's job is catching new bugs,
      # not enforcing a style pass on the pre-bulletproof corpus.
      # Explicit extensionless names so they don't silently slip through
      # the `*.sh` glob.
      shellcheck -S error -s bash *.sh pill pill-child standard-os-reboot-prompt standard-os-update standard-os-update-pill-ack standard-os-update-scheduler apps-launcher
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/libexec/waybar-scripts $out/share/waybar-scripts/lib

      install -m 0644 lib/pill.sh $out/share/waybar-scripts/lib/pill.sh

      for f in *.sh pill pill-child standard-os-reboot-prompt standard-os-update standard-os-update-pill-ack standard-os-update-scheduler apps-launcher; do
        # name=f when extensionless (pill, pill-child); strip .sh otherwise.
        name=''${f%.sh}
        install -m 0755 "$f" "$out/libexec/waybar-scripts/$f"
        # Every source script uses `. "$SELF_DIR/lib/pill.sh"`. If any
        # future script adopts a different form (e.g. `source "$(dirname
        # "$0")/lib/pill.sh"`), append another --replace pair here.
        substituteInPlace "$out/libexec/waybar-scripts/$f" \
          --replace-quiet '. "$SELF_DIR/lib/pill.sh"' \
                          ". $out/share/waybar-scripts/lib/pill.sh"
        makeWrapper ${pkgs.bash}/bin/bash "$out/bin/$name" \
          --add-flags "$out/libexec/waybar-scripts/$f" \
          --prefix PATH : ${binPath}
      done
      runHook postInstall
    '';
  };

in
{
  options.services.waybarBar = {
    enable = lib.mkEnableOption "declarative waybar config (config.jsonc + style.css)";

    configSource = lib.mkOption {
      type = lib.types.path;
      default = ./../waybar/config.jsonc;
      description = "Path of the waybar config.jsonc to install.";
    };

    styleSource = lib.mkOption {
      type = lib.types.path;
      default = ./../waybar/style.css;
      description = "Path of the waybar style.css to install.";
    };

    systemd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run waybar and its unified Hyprland-context cache daemon
        (hypr-context-daemon, in a sibling module) as systemd --user units bound to
        graphical-session.target. Each unit has Restart=always so a
        crash or signal-kill is recovered without losing the bar.

        When true, the legacy `exec-once = ~/.config/waybar/launch.sh`
        in Hyprland's Autostart.conf must NOT also fire — otherwise two
        waybar instances race. Disable this flag to opt out.
      '';
    };

    waybarPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.waybar;
      description = "Waybar package providing the binary used by the unit.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Pull waybar-scripts into the system closure so the store path is
      # reachable for inspection and pre-rewire verification. No ExecStart
      # or exec site references it yet — Tasks 3–4 rewire onto the wrapped
      # binaries once the derivation is confirmed to build correctly.
      home.packages = [ waybar-scripts ];

      # waybar itself is already installed system-wide via modules/packages.nix.
      # We only own the per-user config files here.
      #
      # mkOutOfStoreSymlink: ~/.config/waybar/* points directly to the
      # source in /etc/nixos/home/waybar/*, NOT to a /nix/store copy.
      # Iteration is "edit + restart waybar" — no rebuild step.
      # See the module-header "IMPORTANT — out-of-store symlinks" note
      # for the full rationale.
      xdg.configFile."waybar/config.jsonc" = {
        source = config.lib.file.mkOutOfStoreSymlink cfg.configSource;
        force  = true;   # overwrite any existing hand-edited file on first activation
      };

      xdg.configFile."waybar/style.css" = {
        source = config.lib.file.mkOutOfStoreSymlink cfg.styleSource;
        force  = true;
      };

      # One-time cleanup: pre-bulletproof generations left a symlink at
      # ~/.config/waybar/scripts; activation could also have backed up the
      # old real directory as scripts.hm-bak. Both are removed here so the
      # bar's $HOME footprint shrinks to config.jsonc + style.css (and the
      # icons/, offers/, launch.sh, .git that the user manages outside
      # this module).
      home.activation.cleanupOldWaybarScripts =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          rm -rf $HOME/.config/waybar/scripts $HOME/.config/waybar/scripts.hm-bak
        '';
    }

    (lib.mkIf cfg.systemd.enable {
      systemd.user.services.waybar = {
        Unit = {
          Description = "Waybar status bar";
          PartOf = [ "graphical-session.target" ];
          # Order AFTER the cache daemons so /tmp/waybar-cache is already
          # populated when waybar reads it on cold boot. Wants= (not
          # Requires=) keeps the bar visible even if a daemon fails —
          # partial bar > no bar.
          After = [
            "graphical-session.target"
            "waybar-hypr-context-daemon.service"
          ];
          Wants = [
            "waybar-hypr-context-daemon.service"
          ];
          # Don't try to start if waybar can't reach a wayland display.
          ConditionEnvironment = "WAYLAND_DISPLAY";
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          # WAYBAR_SCRIPTS_LIB lets per-module exec strings that need to
          # source lib/pill.sh (e.g. the clock pill, which calls pill_emit
          # + pill_theme as shell functions, not binaries) reach it via
          # `. $WAYBAR_SCRIPTS_LIB/pill.sh` instead of a $HOME path.
          Environment = [
            # /etc/profiles/per-user/max/bin is the home-manager user-profile
            # directory. Required so binaries declared in sibling HM modules
            # (e.g. voice-dictation.nix's dictate-waybar) remain reachable
            # from waybar's exec strings — previously inherited from the
            # systemctl --user PATH, lost the moment we curated Environment=.
            "PATH=${waybar-scripts}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:/etc/profiles/per-user/max/bin:/run/current-system/sw/bin"
            "WAYBAR_SCRIPTS_LIB=${waybar-scripts}/share/waybar-scripts/lib"
          ];
          Type = "simple";
          ExecStart = "${cfg.waybarPackage}/bin/waybar";
          # No ExecStartPre wipe: waybar owns no on-disk state. The
          # previous version cleared /tmp/waybar-cache + /tmp/glass-mode
          # + the glass-text-daemon lock/pid on every restart — but
          # those belong to the sibling daemons, not to waybar. With
          # Restart=always the wipe ran on every crash and emptied the
          # workspace cache out from under the still-running daemon
          # (which only mkdir'd once at startup), permanently breaking
          # the workspaces module until a manual daemon restart.
          # Each daemon now manages its own state in its own ExecStartPre.
          # Restart=always: waybar can die from an unhandled real-time
          # signal (RTMIN+N where N isn't subscribed in config.jsonc) or
          # from compositor IPC hiccups. The user always wants the bar
          # back without manual intervention.
          Restart = "always";
          RestartSec = 1;
        };
      };

      systemd.user.services.waybar-self-test = {
        Unit = {
          Description = "Waybar boot-time + periodic health check";
          PartOf = [ "graphical-session.target" ];
          After = [
            "graphical-session.target"
            "waybar.service"
            "waybar-hypr-context-daemon.service"
          ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "oneshot";
          ExecStart = "${waybar-scripts}/bin/waybar-self-test";
        };
      };

      systemd.user.timers.waybar-self-test = {
        Unit.Description = "Periodic re-check for waybar health";
        Install.WantedBy = [ "timers.target" ];
        Timer = {
          OnBootSec       = "10s";
          OnUnitActiveSec = "60s";
          Unit            = "waybar-self-test.service";
        };
      };
    })
  ]);
}
