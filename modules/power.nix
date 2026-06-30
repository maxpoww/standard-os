{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Power management
  # ---------------------------------------------------------------------------
  services.thermald.enable              = false;
  services.power-profiles-daemon.enable = false;

  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC    = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT   = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC  = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_HWP_DYN_BOOST_ON_AC       = 1;
      CPU_HWP_DYN_BOOST_ON_BAT      = 0;
      CPU_BOOST_ON_AC               = 0;
      CPU_BOOST_ON_BAT              = 0;
      CPU_MIN_PERF_ON_AC            = 0;
      CPU_MAX_PERF_ON_AC            = 100;
      CPU_MIN_PERF_ON_BAT           = 0;
      CPU_MAX_PERF_ON_BAT           = 50;
      PLATFORM_PROFILE_ON_AC        = "performance";
      PLATFORM_PROFILE_ON_BAT       = "low_power";
      RUNTIME_PM_ON_AC              = "on";
      RUNTIME_PM_ON_BAT             = "on";
      PCIE_ASPM_ON_AC               = "powersave";
      PCIE_ASPM_ON_BAT              = "powersave";
      DISK_APM_LEVEL_ON_AC          = "254";
      DISK_APM_LEVEL_ON_BAT         = "128";
      USB_AUTOSUSPEND               = 1;
      USB_EXCLUDE_BTUSB             = 1;
      USB_EXCLUDE_AUDIO             = 1;
      SATA_LINKPWR_ON_AC            = "max_performance";
      SATA_LINKPWR_ON_BAT           = "med_power_with_dipm";
      # WiFi excluded from "disable on battery not in use" — on every
      # resume TLP races NetworkManager: if NM hasn't re-established the
      # connection when TLP applies, the radio is "not in use" → TLP
      # soft-blocks it via rfkill, surfacing as "no internet after wake"
      # until the user runs `rfkill unblock wifi`. Keeping bluetooth in
      # the list is per user preference (manual toggle habit).
      DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE = "bluetooth";
      DEVICES_TO_ENABLE_ON_AC       = "bluetooth";
      # Persist radio enable/disable across reboots so the rfkill state
      # the user left at shutdown is restored, not overwritten by TLP's
      # default-on policy.
      RESTORE_DEVICE_STATE_ON_STARTUP = 1;
      WIFI_PWR_ON_AC                = "off";
      WIFI_PWR_ON_BAT               = "off";
      START_CHARGE_THRESH_BAT0      = 0;
      STOP_CHARGE_THRESH_BAT0       = 1;

      # Audio power saving — disable completely, TLP was overriding
      # snd_hda_intel power_save=0 set in extraModprobeConfig
      SOUND_POWER_SAVE_ON_AC        = 0;
      SOUND_POWER_SAVE_ON_BAT       = 0;
      SOUND_POWER_SAVE_CONTROLLER   = "N";
    };
  };

  # ---------------------------------------------------------------------------
  # RAPL — thermal ceiling (root cause of original 98°C)
  # ---------------------------------------------------------------------------
  systemd.services.rapl-limits = {
    description   = "Intel RAPL power limits — Slim Pro 9i";
    wantedBy      = [ "multi-user.target" ];
    after         = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      RAPL=/sys/class/powercap/intel-rapl/intel-rapl:0
      [ -d "$RAPL" ] || { echo "RAPL sysfs not found"; exit 0; }
      echo 55000000 > $RAPL/constraint_0_power_limit_uw
      echo 80000000 > $RAPL/constraint_1_power_limit_uw
      echo 28000000 > $RAPL/constraint_0_time_window_us
      echo "RAPL: PL1=55W PL2=80W window=28s"
    '';
  };

  # ---------------------------------------------------------------------------
  # Fan control — auto-discovers hwmon, exits if EC doesn't expose PWM
  # ---------------------------------------------------------------------------
  systemd.services.fan-control = {
    description = "Dynamic fan curve — Slim Pro 9i";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "multi-user.target" ];
    path        = with pkgs; [ bash coreutils ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "always";
      RestartSec = "5s";
    };
    script = ''
      TEMP_FILE=""
      for d in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$d/name" 2>/dev/null)" = "coretemp" ] && TEMP_FILE="$d/temp1_input" && break
      done

      PWM_FILE=""
      for d in /sys/class/hwmon/hwmon*; do
        [ -w "$d/pwm1" ] && PWM_FILE="$d/pwm1" && break
      done

      if [ -z "$TEMP_FILE" ] || [ -z "$PWM_FILE" ]; then
        echo "No controllable fan via hwmon — firmware retains control"
        exit 0
      fi

      echo 1 > "$(dirname "$PWM_FILE")/pwm1_enable"

      while true; do
        T=$(( $(cat "$TEMP_FILE" 2>/dev/null || echo 50000) / 1000 ))

        if   [ "$T" -le 50 ]; then PWM=0
        elif [ "$T" -le 65 ]; then PWM=$(( (T - 50) * 8 ))
        elif [ "$T" -le 78 ]; then PWM=$(( 120 + (T - 65) * 10 ))
        elif [ "$T" -le 88 ]; then PWM=$(( 250 + (T - 78) * 5 ))
        else PWM=255
        fi

        [ "$PWM" -gt 255 ] && PWM=255
        [ "$PWM" -lt 0   ] && PWM=0
        echo "$PWM" > "$PWM_FILE"
        sleep 2
      done
    '';
  };

  powerManagement = {
    enable          = true;
    cpuFreqGovernor = lib.mkDefault "powersave";
  };
}
