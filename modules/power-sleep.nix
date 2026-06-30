{ config, lib, pkgs, ... }:

let
  cfg = config.standardOs.power.sleep;

  swapEntry = lib.head (config.swapDevices or []);

  # Resolve UUID from a /dev/disk/by-uuid/<uuid> device path. Hard-errors
  # if the device is a swapfile — that requires resume_offset and is
  # explicitly out of scope for v1.
  resolveSwapUUID = entry:
    let
      dev    = entry.device;
      prefix = "/dev/disk/by-uuid/";
    in
      if lib.hasPrefix prefix dev
      then lib.removePrefix prefix dev
      else throw ''
        standardOs.power.sleep: swap entry "${dev}" is not addressed by UUID.
        Hibernation requires a swap PARTITION addressed via /dev/disk/by-uuid/.
        Swapfile hibernate (with resume_offset) is out of scope for v1.
      '';

  swapUUID =
    if cfg.resumeDevice != null then cfg.resumeDevice
    else if (config.swapDevices or []) != [] then resolveSwapUUID swapEntry
    else null;

in
{
  options.standardOs.power.sleep = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Standard-OS suspend & hibernate system. Default on so every
        Standard-OS machine behaves identically.
      '';
    };

    resumeDevice = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      example     = "0947464b-4726-4cce-beff-2af1b1f5089b";
      description = ''
        UUID of the resume device (swap partition). If null, derived
        from the first entry in config.swapDevices.
      '';
    };

    criticalBatteryPercent = lib.mkOption {
      type        = lib.types.int;
      default     = 5;
      description = ''
        Battery percentage at which UPower auto-hibernates. Acts as a
        safety net during Sleep so the laptop never wakes to a dead
        battery with lost state.
      '';
    };

    displayRestoreTimeoutSec = lib.mkOption {
      type        = lib.types.int;
      default     = 5;
      description = ''
        Maximum seconds the post-resume display-restore loop will
        keep polling hyprctl before giving up. If the compositor
        never comes back within this window, the loop exits and the
        user sees whatever i915 / NVIDIA chose to put on the panel
        — better than blocking forever. Set to 0 to disable the
        blackout choreography entirely (presleep DPMS off + post-
        resume DPMS on).

        No-op on non-Hyprland systems: the loop body never executes
        when no /run/user/*/hypr/* socket is present.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (config.swapDevices or []) != [];
        message   = ''
          standardOs.power.sleep is enabled but no swap device is configured.
          Hibernation needs a swap partition >= total RAM. Add a swap device
          (see modules/disko-layout.nix for the canonical install-time scheme)
          or disable with standardOs.power.sleep.enable = false.
        '';
      }
      {
        assertion = swapUUID != null;
        message   = ''
          standardOs.power.sleep: could not derive a resume UUID. Either set
          standardOs.power.sleep.resumeDevice explicitly or configure
          swapDevices with a /dev/disk/by-uuid/<uuid> entry.
        '';
      }
    ];

    # ── Kernel resume ──────────────────────────────────────────────────
    boot.resumeDevice = "/dev/disk/by-uuid/${swapUUID}";
    boot.kernelParams = lib.mkMerge [
      [
        "resume=UUID=${swapUUID}"

        # i915 display stability across suspend/resume + lid-open. The
        # Alder Lake-P Type-C PHY (adlp_tc_phy_connect) times out re-
        # establishing the DP-alt link when Panel Self-Refresh re-probes
        # on every screen-on transition — observed on Lenovo Slim Pro 9i
        # (83C0) and other ADL-P laptops with USB-C DisplayPort. The
        # WARN escalates to a hard display freeze on a fraction of lid-
        # open events. Disabling PSR + FBC eliminates the trigger.
        #
        # Hardware-agnostic: these are i915 module params; the kernel
        # silently ignores them on AMD GPUs and on newer Intel iGPUs
        # using the `xe` driver. Cost on i915 systems is ~0.5–1 W extra
        # idle iGPU draw on battery — worth it for resume stability.
        "i915.enable_psr=0"
        "i915.enable_fbc=0"
      ]

      # ── NVIDIA VRAM-save mode override (must come LAST) ────────────
      # nixpkgs's hardware.nvidia.powerManagement.enable=true silently
      # appends "nvidia.NVreg_PreserveVideoMemoryAllocations=1" to
      # boot.kernelParams via its own module-internal logic. That
      # mode-1 uses a sysfs trigger to save VRAM, which briefly re-
      # activates the display during the save handoff — the visible
      # "comes back, off again" flash on the way down.
      #
      # Mode 2 saves VRAM into the kernel suspend image instead and
      # never touches the display. Slightly larger suspend image and
      # ~50 ms extra suspend/resume time; visually silent.
      #
      # The kernel takes the LAST occurrence of a module param when
      # the cmdline lists it twice. lib.mkAfter is the Nix lever that
      # appends this list to the END of every contribution to
      # boot.kernelParams — guaranteeing this =2 lands after the
      # nixpkgs-injected =1 and therefore wins. No-op on non-NVIDIA
      # hosts (kernel ignores params for unloaded modules).
      (lib.mkAfter [
        "nvidia.NVreg_PreserveVideoMemoryAllocations=2"
      ])
    ];

    # disk=shutdown enters hibernation faster than platform mode and is
    # identical from the user's perspective. /run/standard-os/ is scratch
    # for the last-sleep timestamp consumed by the post-resume service.
    #
    # Note: /sys/power/image_compression is NOT exposed by the NixOS
    # default kernel (no CONFIG_HIBERNATION_COMP_LZ4 / similar). Kernel
    # default compression is used. A kernel rebuild with that option
    # would gain ~20-30% faster image I/O; out of scope for v1.
    systemd.tmpfiles.rules = [
      "w- /sys/power/disk  - - - - shutdown"
      "d  /run/standard-os 0775 root users -"
    ];

    # ── NVIDIA suspend/hibernate/resume services ───────────────────────
    # No-op on non-NVIDIA hosts. Enables nvidia-suspend.service,
    # nvidia-resume.service, nvidia-hibernate.service which preserve VRAM
    # allocations across the sleep cycle. Requires
    # NVreg_PreserveVideoMemoryAllocations=1 (already in boot.nix).
    hardware.nvidia.powerManagement = lib.mkIf
      (config.hardware.nvidia.modesetting.enable or false)
      {
        enable      = true;
        finegrained = false;
      };

    # ── Sysctl tuning ─────────────────────────────────────────────────
    boot.kernel.sysctl = {
      "vm.swappiness" = lib.mkDefault 10;
    };

    # ── logind ────────────────────────────────────────────────────────
    # Lid close: do nothing on all power states. Power button: kernel
    # default poweroff (explicit). Per user decision 2026-06-05.
    # NixOS 25.11 moved these to services.logind.settings.Login.*.
    services.logind.settings.Login = {
      HandleLidSwitch              = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked        = "ignore";
      HandlePowerKey               = "poweroff";
      HandlePowerKeyLongPress      = "poweroff";
    };

    # ── UPower critical-battery → Hibernate ──────────────────────────
    # Single safety net: if battery falls to criticalBatteryPercent
    # during Sleep, UPower fires Hibernate to preserve state.
    services.upower = {
      enable               = true;
      criticalPowerAction  = "Hibernate";
      percentageLow        = 15;
      percentageCritical   = 5;
      percentageAction     = cfg.criticalBatteryPercent;
    };

    # ── Pre-sleep service ─────────────────────────────────────────────
    # Flushes dirty pages so the suspended / hibernated image is
    # filesystem-consistent. Records a timestamp the post-resume service
    # uses to compute wall-clock asleep duration for the failure pill
    # tooltip. Also blacks out the display via Hyprland DPMS before the
    # kernel suspend kicks in, masking the multi-subsystem visual mess
    # (compositor freeze, i915 panel-off, NVIDIA VRAM-save handoff).
    #
    # Why system-scope: user-scope `sleep.target` does not exist on
    # this NixOS+systemd setup — `systemctl --user list-unit-files`
    # has no `sleep.target` / `suspend.target` units, so a HM-installed
    # user service with WantedBy=sleep.target is a dead letter. The
    # display blackout has to live here, in a real system-scope sleep
    # hook, with a root→user bridge to invoke hyprctl.
    systemd.services.standard-os-presleep = {
      description = "Standard-OS pre-sleep flush + display blackout + timestamp";
      before      = [ "sleep.target" ];
      wantedBy    = [ "sleep.target" ];
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = false;
      };
      # gawk is REQUIRED — earlier version had only coreutils+bluez,
      # so the bt snapshot's `awk '{print $2}'` failed silently
      # ("awk: command not found"), writing an empty bt-presleep file
      # on every suspend. The `|| :` in the script swallowed the error.
      # Result: post-resume bluetooth reconnect logic had no input and
      # silently no-op'd. Fixed 2026-06-11.
      #
      # hyprland is for hyprctl. util-linux is for runuser (root→user
      # bridge so we can invoke hyprctl in the user's session).
      path = with pkgs; [ coreutils bluez gawk hyprland util-linux ];
      script = ''
        sync
        date -Iseconds > /run/standard-os/last-sleep

        # Snapshot currently-connected Bluetooth devices so post-resume
        # can check that those SPECIFIC devices come back, not "all
        # trusted devices must be connected" (which would false-positive
        # on paired-but-not-active headphones).
        bluetoothctl devices Connected 2>/dev/null \
          | awk '{print $2}' > /run/standard-os/bt-connected-presleep \
          || : > /run/standard-os/bt-connected-presleep

        # ── Display blackout via Hyprland DPMS ─────────────────────
        # Find any active Hyprland session on this machine. The socket
        # path is /run/user/<uid>/hypr/<instance>/.socket.sock — the
        # uid identifies which user to bridge to, the instance is the
        # value of HYPRLAND_INSTANCE_SIGNATURE hyprctl needs in env.
        #
        # Hardware-agnostic: if no Hyprland session is found (non-
        # Hyprland Wayland compositor, X session, headless box), the
        # for-loop body never executes — sleep proceeds normally
        # without the blackout polish.
        for sock in /run/user/*/hypr/*/.socket.sock; do
          [ -e "$sock" ] || continue
          uid=$(stat -c %u "$sock" 2>/dev/null) || continue
          user=$(id -nu "$uid" 2>/dev/null) || continue
          instance=$(basename "$(dirname "$sock")")
          [ -n "$user" ] && [ -n "$instance" ] || continue
          runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            HYPRLAND_INSTANCE_SIGNATURE="$instance" \
            hyprctl dispatch dpms off >/dev/null 2>&1 || true
        done

        # Brief settle so the panel-off transition completes BEFORE
        # the kernel begins the suspend sequence. Without this the
        # kernel can begin suspending while the DPMS-off frame is
        # mid-render — the panel may flash live content one last
        # time before going dark.
        sleep 0.2
      '';
    };

    # ── Post-resume system-scope health-check ────────────────────────
    # Two-pass structure: probe at +1s, remediate, probe again at +3s,
    # surface anything still broken via /tmp/waybar-cache/power-resume.
    # System scope: NetworkManager, NVIDIA, time, Bluetooth.
    # User scope (in home/modules/standard-os-resume-user.nix): pipewire,
    # hyprland, OPTIONS daemons.
    systemd.services.standard-os-resume = {
      description = "Standard-OS post-resume health-check (system scope)";
      after       = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      wantedBy    = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = false;
      };
      # util-linux provides rfkill — the system-level radio gate that
      # NetworkManager and bluetoothctl sit on top of. Defense-in-depth
      # probe/remediate must reach the lower layer to see / clear soft-
      # blocks regardless of which userland tool (TLP, blueman, NM)
      # introduced them. hyprland (hyprctl) + util-linux (runuser) are
      # for the display-restore bridge — paired with the DPMS off in
      # the presleep service to mask the suspend/resume choreography.
      path = with pkgs; [
        coreutils networkmanager systemd bluez util-linux gawk procps bash
        hyprland findutils
      ];
      script = ''
        set -u

        # Failures are silent — logged to journalctl -u standard-os-resume
        # (no waybar pill since 2026-06-17). User chose silent: log only
        # over a visible error pill on OPTIONS.

        # ── Display restore (must happen FIRST, before slow probes) ──
        # The presleep service called `hyprctl dispatch dpms off` to
        # black out the panel before suspend. On resume, Hyprland and
        # i915 may not preserve that dpms state — but if they DO, the
        # panel stays dark until we explicitly restore it. We poll
        # hyprctl up to fallbackTimeoutSec at 1-second cadence (each
        # attempt has its own 1s wall-clock cap so a hung hyprctl
        # cannot extend the total wait) and dpms on at the first
        # successful contact. Compositor has had a few hundred ms by
        # then to render fresh frames, so the panel comes back with
        # live content — not a stale framebuffer flash.
        #
        # Hardware-agnostic: if no Hyprland session is found, the
        # for-loop body never executes and the script proceeds to
        # probes. Net effect for non-Hyprland systems: zero behavior
        # change vs the pre-blackout-choreography state.
        restore_display() {
          local sock uid user instance attempted=0
          for i in $(seq 1 ${toString cfg.displayRestoreTimeoutSec}); do
            for sock in /run/user/*/hypr/*/.socket.sock; do
              [ -e "$sock" ] || continue
              uid=$(stat -c %u "$sock" 2>/dev/null) || continue
              user=$(id -nu "$uid" 2>/dev/null) || continue
              instance=$(basename "$(dirname "$sock")")
              [ -n "$user" ] && [ -n "$instance" ] || continue
              attempted=1
              if timeout 1 runuser -u "$user" -- env \
                  XDG_RUNTIME_DIR="/run/user/$uid" \
                  HYPRLAND_INSTANCE_SIGNATURE="$instance" \
                  hyprctl dispatch dpms on >/dev/null 2>&1; then
                return 0
              fi
            done
            # No Hyprland session detected at all — not running here.
            # No point spinning the loop; exit so probes can run.
            [ "$attempted" -eq 0 ] && return 0
            sleep 1
          done
          # Timed out after $displayRestoreTimeoutSec seconds. Compositor is
          # genuinely broken; no path from system scope to force DRM dpms
          # on without it. Return so probes run anyway — the user will
          # see the failure pill (or recover via SSH/TTY/reboot).
          return 1
        }
        # Fire-and-forget the display restore in parallel with the
        # health probes so a slow compositor doesn't delay net/bt
        # remediation. The restore loop is bounded by its own timeout.
        restore_display &
        DISPLAY_RESTORE_PID=$!

        # ── Probes (return 0 healthy, 1 broken) ──

        probe_net() {
          # Two-layer check: rfkill state (lower layer — the radio
          # itself) AND NetworkManager state (upper layer — IP). If
          # wifi is soft-blocked at the rfkill layer, NM has no path
          # to recover, so report broken regardless of NM's opinion.
          if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
            return 1
          fi
          local s
          s="$(nmcli -t -f STATE g 2>/dev/null || echo unknown)"
          case "$s" in
            connected|connected*) return 0 ;;
            *) return 1 ;;
          esac
        }
        remediate_net() {
          # Explicit rfkill unblock BEFORE NM commands. On resume, TLP
          # (or any other rfkill consumer) can race and soft-block the
          # WLAN radio while NM is still re-establishing the link;
          # `nmcli radio wifi on` only flips NM's view and does NOT
          # always clear an underlying rfkill block in time. Bluetooth
          # is excluded from the unblock — user prefers to keep manual
          # control of BT state across resume (see power.nix TLP
          # DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE comment).
          rfkill unblock wifi >/dev/null 2>&1 || true
          nmcli networking on >/dev/null 2>&1 || true
          nmcli radio wifi on >/dev/null 2>&1 || true
        }

        probe_nvidia() {
          command -v nvidia-smi >/dev/null 2>&1 || return 0
          nvidia-smi -L 2>/dev/null | grep -q '^GPU' && return 0 || return 1
        }

        probe_time() {
          [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]
        }
        remediate_time() {
          systemctl restart systemd-timesyncd 2>/dev/null || true
        }

        probe_bluetooth() {
          # bluetoothd must be running for any meaningful check.
          systemctl is-active bluetooth >/dev/null 2>&1 || return 1
          # If nothing was connected pre-sleep, there is nothing to verify.
          local presleep=/run/standard-os/bt-connected-presleep
          [ -s "$presleep" ] || return 0
          # Every MAC connected pre-sleep must be connected now.
          local mac connected_now
          connected_now=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}')
          while read -r mac; do
            [ -z "$mac" ] && continue
            printf '%s\n' "$connected_now" | grep -qFx "$mac" || return 1
          done < "$presleep"
          return 0
        }
        remediate_bluetooth() {
          local presleep=/run/standard-os/bt-connected-presleep
          [ -s "$presleep" ] || return 0
          bluetoothctl power on >/dev/null 2>&1 || true
          # Reconnect only devices that WERE connected pre-sleep.
          local mac connected_now
          connected_now=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}')
          while read -r mac; do
            [ -z "$mac" ] && continue
            printf '%s\n' "$connected_now" | grep -qFx "$mac" && continue
            bluetoothctl connect "$mac" >/dev/null 2>&1 || true
          done < "$presleep"
        }

        # ── Two-pass run ──

        run_pass() {
          local failures=()
          probe_net       || failures+=("net")
          probe_nvidia    || failures+=("gpu")
          probe_time      || failures+=("time")
          probe_bluetooth || failures+=("bt")
          # Guard: quoted empty-array expansion + printf '%s\n' emits a
          # phantom empty line that mapfile then records as one element.
          if [ "''${#failures[@]}" -gt 0 ]; then
            printf '%s\n' "''${failures[@]}"
          fi
        }

        remediate_all() {
          local f
          for f in "$@"; do
            case "$f" in
              net)  remediate_net ;;
              time) remediate_time ;;
              bt)   remediate_bluetooth ;;
              gpu)  : ;;
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

        joined=$(IFS=', '; echo "''${pass2[*]}")
        printf 'standard-os-resume: pass2 failures: %s\n' "$joined" >&2
        exit 0
      '';
    };
  };
}
