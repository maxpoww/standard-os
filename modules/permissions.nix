{ config, lib, pkgs, ... }:

{
  # ===========================================================================
  # permissions.nix — Reduce sudo friction for desktop users
  #
  # Philosophy: users should never need sudo for everyday tasks like mounting
  # USB drives, changing brightness, managing networks, or flashing keyboards.
  # Security is maintained at system boundaries (firewall, fail2ban, disk
  # encryption) — not by making users type passwords for routine operations.
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # 1. Backlight + USB/serial/input udev rules (single declaration)
  # ---------------------------------------------------------------------------
  services.udev.extraRules = ''
    # Backlight — allow video group to control brightness
    ACTION=="add", SUBSYSTEM=="backlight", RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/backlight/%k/brightness"

    # Generic USB devices — accessible to plugdev group
    SUBSYSTEM=="usb", MODE="0664", GROUP="plugdev"

    # Serial ports (Arduino, QMK keyboards, embedded dev)
    SUBSYSTEM=="tty", ATTRS{idVendor}=="*", MODE="0660", GROUP="plugdev", TAG+="uaccess"

    # Input devices (gamepads, custom controllers, tablets)
    KERNEL=="uinput", MODE="0660", GROUP="input", TAG+="uaccess"

    # HID raw devices — keyboards, mice, custom HID (QMK, VIA)
    KERNEL=="hidraw*", MODE="0660", GROUP="plugdev", TAG+="uaccess"
  '';

  programs.light.enable = true;

  # ---------------------------------------------------------------------------
  # 2. Realtime scheduling — needed for audio production, gaming, low-latency
  # ---------------------------------------------------------------------------
  security.rtkit.enable = true;

  # ---------------------------------------------------------------------------
  # 3. Polkit — GUI privilege escalation + mount/network/power without password
  # ---------------------------------------------------------------------------
  security.polkit.enable = true;

  # Polkit agent for Hyprland (no DE provides one automatically)
  systemd.user.services.polkit-agent = {
    description = "Polkit authentication agent";
    wantedBy = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 10;
    };
  };

  environment.systemPackages = [ pkgs.polkit_gnome ];

  # Polkit rules: allow wheel group to do common tasks without password
  security.polkit.extraConfig = ''
    // Allow wheel users to mount/unmount drives without password
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
           action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
           action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
           action.id == "org.freedesktop.udisks2.filesystem-mount-other-seat" ||
           action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
           action.id == "org.freedesktop.udisks2.encrypted-unlock-system" ||
           action.id == "org.freedesktop.udisks2.loop-setup" ||
           action.id == "org.freedesktop.udisks2.loop-delete" ||
           action.id == "org.freedesktop.udisks2.power-off-drive" ||
           action.id == "org.freedesktop.udisks2.eject-media") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });

    // Allow wheel users to manage NetworkManager without password
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });

    // Allow wheel users to control power (reboot, shutdown, suspend)
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.login1.reboot" ||
           action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
           action.id == "org.freedesktop.login1.power-off" ||
           action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
           action.id == "org.freedesktop.login1.suspend" ||
           action.id == "org.freedesktop.login1.hibernate" ||
           action.id == "org.freedesktop.login1.set-wall-message") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });

    // Allow wheel users to manage systemd units (start/stop/restart services)
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.systemd1.manage-units" ||
           action.id == "org.freedesktop.systemd1.manage-unit-files" ||
           action.id == "org.freedesktop.systemd1.reload-daemon") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });

    // Allow wheel users to set the system time/timezone
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.timedate1.set-time" ||
           action.id == "org.freedesktop.timedate1.set-timezone" ||
           action.id == "org.freedesktop.timedate1.set-ntp") &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });

    // Allow wheel users to update firmware via fwupd
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("org.freedesktop.fwupd.") == 0 &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';

  # ---------------------------------------------------------------------------
  # 4. Sudo — passwordless for common safe operations
  # ---------------------------------------------------------------------------
  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands = [
        { command = "/run/current-system/sw/bin/nixos-rebuild"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/nix-collect-garbage"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/nix-env"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/reboot"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/poweroff"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/brightnessctl"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/mount"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/umount"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/ip"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/rfkill"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/dmesg"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/journalctl"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/lsblk"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/fdisk"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  # ---------------------------------------------------------------------------
  # 5. Groups — ensure plugdev and input exist
  # ---------------------------------------------------------------------------
  users.groups.plugdev = {};
  users.groups.input = {};

  # ---------------------------------------------------------------------------
  # 6. Kernel — relax restrictions that commonly block desktop usage
  # ---------------------------------------------------------------------------
  boot.kernel.sysctl = {
    # Allow unprivileged users to use dmesg (useful for debugging)
    "kernel.dmesg_restrict" = 0;

    # Allow unprivileged user namespaces (needed by Flatpak, Electron sandboxing,
    # browsers, Bubblewrap, many modern apps)
    "kernel.unprivileged_userns_clone" = 1;

    # Allow unprivileged BPF (needed by some networking tools)
    "kernel.unprivileged_bpf_disabled" = 0;

    # Relax ptrace scope — allows debugging own processes (strace, gdb)
    "kernel.yama.ptrace_scope" = 0;
  };

  # ---------------------------------------------------------------------------
  # 7. Fuse — allow regular users to mount FUSE filesystems (sshfs, AppImages,
  #    NTFS, MTP, etc.)
  # ---------------------------------------------------------------------------
  programs.fuse.userAllowOther = true;

  # ---------------------------------------------------------------------------
  # 8. ADB — Android device access without sudo
  # ---------------------------------------------------------------------------
  programs.adb.enable = true;

  # ---------------------------------------------------------------------------
  # 9. Flatpak — sandboxed apps without sudo
  # ---------------------------------------------------------------------------
  services.flatpak.enable = true;
}
