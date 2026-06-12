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
    imagemagick       # glass-text-daemon luminance sample
    git               # rebuild-pending check + shutdown-guard
    rofi              # shutdown-guard + rebuild-prompt modals
    libnotify         # notify-send fallback
    brightnessctl     # night-dimmer, screen-type
    hyprsunset        # warm-cycle, screen-type
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
      # Explicit `pill pill-child` so the no-extension launchers don't
      # silently slip through the `*.sh` glob.
      shellcheck -S error -s bash *.sh pill pill-child
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/libexec/waybar-scripts $out/share/waybar-scripts/lib

      install -m 0644 lib/pill.sh $out/share/waybar-scripts/lib/pill.sh

      for f in *.sh pill pill-child; do
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

    scriptsSource = lib.mkOption {
      type = lib.types.path;
      default = ./../waybar/scripts;
      description = ''
        Path of the waybar scripts directory to install at
        ~/.config/waybar/scripts. Contains glass-text-daemon.sh,
        workspace-daemon.sh, lib/pill.sh, the static pill/pill-child
        wrappers, and every per-module script (battery, screen-type,
        warm-cycle, shader-*, night-dimmer, win-action, win-icon, ...).
        Mirrored into the user's config as a single out-of-store
        symlink so edits in the repo are live without a rebuild and
        a fresh distro install has every script materialised.
      '';
    };

    systemd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run waybar and its two cache daemons (glass-text-daemon,
        workspace-daemon) as systemd --user units bound to
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

      # ~/.config/waybar/scripts is a single out-of-store symlink to the
      # repo's tracked scripts directory. Same iteration model as
      # config.jsonc / style.css — edit + restart waybar (or the owning
      # daemon for a script-only change). Without this symlink, every
      # waybar daemon and per-module script (1,400+ lines of bash that
      # drives the entire bar UX) lives only in $HOME and disappears on
      # a fresh distro install. Closed 2026-06-12 after the b/w switcher
      # audit found that glass-text-daemon.sh's RTMIN+11/+12 fanout and
      # lib/pill.sh's Layer 2A theme-re-read fix were both un-versioned.
      xdg.configFile."waybar/scripts" = {
        source = config.lib.file.mkOutOfStoreSymlink cfg.scriptsSource;
        force  = true;
      };
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
            "waybar-workspace-daemon.service"
            "waybar-glass-text-daemon.service"
          ];
          Wants = [
            "waybar-workspace-daemon.service"
            "waybar-glass-text-daemon.service"
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
            "PATH=${waybar-scripts}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
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

      systemd.user.services.waybar-glass-text-daemon = {
        Unit = {
          Description = "Waybar glass-text daemon (background-aware text color)";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
          # StartLimit* belong in [Unit], not [Service] — systemd silently
          # ignores them in [Service] (StartLimitIntervalSec reverts to the
          # 10s default). Tuning lets the daemon survive 20 restart
          # attempts over 5 minutes before tripping the burst limit.
          StartLimitBurst       = 20;
          StartLimitIntervalSec = "5min";
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "simple";
          # Clear our own stale lock/pid from the previous instance. The
          # daemon also does a PID-alive check internally, but removing
          # the files declaratively before start keeps the lifecycle
          # owned by this unit rather than relying on luck.
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f /tmp/glass-text-daemon.lock /tmp/glass-text-daemon.pid";
          ExecStart = "${waybar-scripts}/bin/glass-text-daemon";
          # Restart=on-failure (not always): graceful exits during shutdown
          # don't trigger restart cycles. Expo backoff plateaus at 30s.
          Restart            = "on-failure";
          RestartSec         = "1s";
          RestartSteps       = 5;
          RestartMaxDelaySec = "30s";
        };
      };

      systemd.user.services.waybar-workspace-daemon = {
        Unit = {
          Description = "Waybar workspace cache daemon (per-module JSON writer)";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
          # StartLimit* in [Unit] — see glass-text-daemon above for why.
          StartLimitBurst       = 20;
          StartLimitIntervalSec = "5min";
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "simple";
          # Guarantee the cache dir exists before the daemon's first
          # write. The daemon also self-heals each iteration, but doing
          # the mkdir here makes the dir present from the very first
          # tick (otherwise modules with interval=2 could read an empty
          # cache for up to 1s after boot).
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /tmp/waybar-cache";
          ExecStart = "${waybar-scripts}/bin/workspace-daemon";
          Restart            = "on-failure";
          RestartSec         = "1s";
          RestartSteps       = 5;
          RestartMaxDelaySec = "30s";
        };
      };
    })
  ]);
}
