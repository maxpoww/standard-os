{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # System services
  # ---------------------------------------------------------------------------
  services.dbus.enable    = true;
  services.gvfs.enable    = true;    # GVfs virtual filesystem (Trash, MTP, network mounts)
  services.udisks2.enable = true;   # Block device management (mount/unmount)
  services.openssh.enable = true;
virtualisation.libvirtd.enable = true;
  # Polkit: privilege escalation for mount/unmount operations
  # (also declared in nautilus-system.nix — harmless to set here too)
  security.polkit.enable = true;

  # GNOME Keyring: password storage for network shares (SMB, SFTP)
  services.gnome.gnome-keyring.enable             = true;
  security.pam.services.greetd.enableGnomeKeyring  = true;
  security.pam.services.hyprland.enableGnomeKeyring  = true;
  # Register gcr + gnome-keyring on the D-Bus so apps can find them
  services.dbus.packages = with pkgs; [ gcr gnome-keyring ];

  # udev rules for Android MTP device recognition (android-udev-rules removed in 25.11;
  # systemd built-in uaccess rules now cover Android USB access)
  services.udev.packages = with pkgs; [ libmtp qmk-udev-rules ];

  # ---------------------------------------------------------------------------
  # TAS2781 amplifier — Slim Pro 9i speaker chip
  # Without this the EC power-gates the amp and speakers stay silent
  # If the path differs run: find /sys/bus/i2c/devices -name "*TAS*"
  # ---------------------------------------------------------------------------
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="i2c", KERNEL=="i2c-TIAS2781:00", \
      RUN+="${pkgs.bash}/bin/bash -c 'echo on > /sys/bus/i2c/devices/i2c-TIAS2781:00/power/control'"

    ACTION=="add", SUBSYSTEM=="sound", \
      RUN+="${pkgs.bash}/bin/bash -c 'echo on > /sys$devpath/device/power/control'"
  '';
}
