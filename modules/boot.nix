{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Bootloader
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Cap kept generations so /boot (1 GB EFI) can't fill again. Without
  # this, every `nixos-rebuild switch` adds a kernel+initrd to /boot;
  # once full, bootctl install silently fails to land the new entry and
  # the loader keeps booting the last-installed gen — the 2026-06-13
  # "modules disappear after reboot, return after rebuild" incident.
  boot.loader.systemd-boot.configurationLimit = 10;

  # ---------------------------------------------------------------------------
  # Silent boot
  # ---------------------------------------------------------------------------
  boot.consoleLogLevel        = 0;
  boot.initrd.verbose         = false;
  boot.initrd.systemd.enable  = true;

  boot.kernel.sysctl = {
    "kernel.printk" = "0 0 0 0";
  };

  # ---------------------------------------------------------------------------
  # Kernel parameters
  # ---------------------------------------------------------------------------
  boot.kernelParams = [
    # Silent boot
    "quiet"
    "loglevel=0"
    "rd.systemd.show_status=false"
    "rd.systemd.log_level=0"
    "systemd.show_status=false"
    "systemd.log_level=0"
    "rd.udev.log_level=0"
    "udev.log_level=0"
    "vt.global_cursor_default=0"
    "vt.default_red=0"
    "vt.default_green=0"
    "vt.default_blue=0"
    "fbcon=map:1"
    "splash"

    # NVIDIA
    "nvidia-drm.modeset=1"
    # NVreg_PreserveVideoMemoryAllocations is NOT declared here. It is
    # set to =2 in power-sleep.nix via lib.mkAfter so it lands LAST on
    # the cmdline and overrides the =1 that nixpkgs's
    # hardware.nvidia.powerManagement.enable auto-appends. Mode 2 saves
    # VRAM into the kernel suspend image (no display interaction) vs
    # mode 1's sysfs trigger (briefly flashes the panel during save).
    # 0x01 (D3 hot — PCIe link kept up) instead of 0x02 (D3 cold) to
    # reduce screen-flash count on sleep/resume cycles. Costs ~0.5–1W
    # more idle drain; eliminates 1–2 display transitions per resume.
    # Per user decision 2026-06-05 (Standard-OS sleep-system work).
    "nvidia.NVreg_DynamicPowerManagement=0x01"
    "nvidia.NVreg_RegistryDwords=EnableBrightnessControl=1"

    # System
    "ibt=off"
    "pcie_aspm=force"
    "nmi_watchdog=0"
    "transparent_hugepage=madvise"
    "iommu=pt"
  ];

  # Audio: prevent power gating on HDA controller + TAS2781 amplifier
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=0 power_save_controller=N
  '';

  boot.kernelModules = [
    "coretemp" "nct6775" "ec_sys"
    # FUSE: required for gvfsd-fuse to mount gvfs paths (trash://, mtp://) into POSIX namespace
    "fuse"
    # NLS modules: correct filename encoding for VFAT/NTFS volumes (UTF-8 and CP437/OEM)
    "nls_utf8"
    "nls_cp437"
  ];

  # ---------------------------------------------------------------------------
  # BUG 7 FIX: Filesystem support — attrset form required on NixOS ≥ 24.05
  # ---------------------------------------------------------------------------
  # On NixOS < 24.05, boot.supportedFilesystems was a list of strings.
  # From 24.05+ it is an attrset mapping filesystem names to booleans.
  # Using the old list form causes a type error during nixos-rebuild.
  boot.supportedFilesystems = {
    ntfs  = true;   # NTFS: Windows partitions, external drives
    exfat = true;   # exFAT: SD cards, modern USB drives
    vfat  = true;   # FAT32: legacy USB drives, embedded devices
    btrfs = true;   # Btrfs: copy-on-write Linux filesystem
    xfs   = true;   # XFS: high-performance Linux filesystem
    f2fs  = true;   # F2FS: flash-optimized filesystem
    # zfs = true;   # ZFS: uncomment if needed
  };
}
