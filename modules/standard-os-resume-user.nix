{ config, lib, pkgs, ... }:

let
  cfg = config.standardOs.power.sleepUser;
in
{
  options.standardOs.power.sleepUser = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Standard-OS post-resume USER-scope health-check. Pairs with the
        system-scope service in /etc/nixos/modules/power-sleep.nix.
        User scope handles pipewire, hyprland, OPTIONS daemons. System
        scope handles NetworkManager, NVIDIA, time sync, Bluetooth.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.standard-os-resume-user = {
      Unit = {
        Description = "Standard-OS post-resume health-check (user scope)";
        After       = [
          "suspend.target"
          "hibernate.target"
          "hybrid-sleep.target"
          "suspend-then-hibernate.target"
        ];
      };
      Install.WantedBy = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      Service = {
        Type      = "oneshot";
        ExecStart = let
          script = pkgs.writeShellScript "standard-os-resume-user" ''
            set -u
            CACHE=/tmp/waybar-cache/power-resume
            mkdir -p /tmp/waybar-cache

            write_pill() {
              local text="$1" tooltip="$2"
              local theme
              theme=$(cat /tmp/glass-mode 2>/dev/null) || theme=dark
              case "$theme" in light|dark) ;; *) theme=dark ;; esac
              local classes
              classes=$(printf '["opt-pill","opt-flash","opt-no","%s"]' "$theme")
              local json="{\"text\":\"$text\",\"class\":$classes,\"tooltip\":\"$tooltip\"}"
              printf '%s' "$json" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
              ${pkgs.procps}/bin/pkill -RTMIN+10 waybar 2>/dev/null || true
            }

            # ── User-scope probes ──

            probe_pipewire() {
              local s
              for s in pipewire pipewire-pulse wireplumber; do
                ${pkgs.systemd}/bin/systemctl --user is-active "$s" >/dev/null 2>&1 || return 1
              done
              return 0
            }
            remediate_pipewire() {
              ${pkgs.systemd}/bin/systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1 || true
            }

            probe_hyprland() {
              command -v hyprctl >/dev/null 2>&1 || return 0
              local out
              out=$(hyprctl -j monitors 2>/dev/null) || return 1
              [ "$out" != "[]" ] && [ -n "$out" ]
            }

            probe_options_daemons() {
              local d
              for d in hypr-context-daemon.sh hypr-bg-daemon.sh; do
                ${pkgs.procps}/bin/pgrep -f "$d" >/dev/null 2>&1 || return 1
              done
              return 0
            }
            remediate_options_daemons() {
              ${pkgs.procps}/bin/pkill -RTMIN+10 waybar >/dev/null 2>&1 || true
            }

            run_pass() {
              local failures=()
              probe_pipewire        || failures+=("pipewire")
              probe_hyprland        || failures+=("wm")
              probe_options_daemons || failures+=("bar")
              if [ "''${#failures[@]}" -gt 0 ]; then
                printf '%s\n' "''${failures[@]}"
              fi
            }

            remediate_all() {
              local f
              for f in "$@"; do
                case "$f" in
                  pipewire) remediate_pipewire ;;
                  bar)      remediate_options_daemons ;;
                  wm)       : ;;
                esac
              done
            }

            sleep 1
            mapfile -t pass1 < <(run_pass)
            [ "''${#pass1[@]}" -gt 0 ] && remediate_all "''${pass1[@]}"

            sleep 2
            mapfile -t pass2 < <(run_pass)

            if [ "''${#pass2[@]}" -eq 0 ]; then
              exit 0
            fi

            # Don't stomp a system-scope failure pill if one already exists.
            if [ -s "$CACHE" ] && ! grep -q '"text":""' "$CACHE" 2>/dev/null; then
              exit 0
            fi

            n="''${#pass2[@]}"
            if [ "$n" -eq 1 ]; then
              text="Resume: ''${pass2[0]}"
            else
              text="Resume: $n issues"
            fi
            joined=$(IFS=', '; echo "''${pass2[*]}")
            tooltip="User-scope. Failed: ''${joined}. Click to retry."
            write_pill "$text" "$tooltip"
          '';
        in "${script}";
      };
    };
  };
}
