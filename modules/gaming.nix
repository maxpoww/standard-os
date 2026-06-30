{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Steam
  # ---------------------------------------------------------------------------
  programs.steam = {
    enable                 = true;
    remotePlay.openFirewall    = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };

  # ---------------------------------------------------------------------------
  # Gamescope — compositing window manager for games
  # ---------------------------------------------------------------------------
  programs.gamescope = {
    enable    = true;
    capSysNice = true;
  };

  # ---------------------------------------------------------------------------
  # Gamemode — on-demand CPU/GPU performance optimizations
  # ---------------------------------------------------------------------------
  programs.gamemode = {
    enable = true;
    settings = {
      general = {
        renice       = 10;
        softrealtime = "auto";
        ioprio       = 0;
      };
      gpu = {
        apply_gpu_optimisations = "accept-responsibility";
        gpu_device              = 0;
      };
      custom = {
        start = "${pkgs.libnotify}/bin/notify-send 'GameMode' 'Performance mode enabled'";
        end   = "${pkgs.libnotify}/bin/notify-send 'GameMode' 'Performance mode disabled'";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Gaming packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # Launchers
    lutris
    heroic
    bottles

    # Performance overlay
    mangohud

    # Proton/Wine dependencies
    winetricks
    wineWowPackages.stagingFull
    protontricks

    # Controllers
    antimicrox

    # Emulators
    retroarch

    # Utilities
    gamescope
    gamemode
    protonup-qt
    steamtinkerlaunch
  ];

  # ---------------------------------------------------------------------------
  # Controllers & input
  # ---------------------------------------------------------------------------
  hardware.steam-hardware.enable = true;

  # Xbox controller support
  hardware.xpadneo.enable = true;

  # PS4/PS5 DualSense support
  services.udev.extraRules = ''
    # DualShock 4
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="05c4", MODE="0660", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="09cc", MODE="0660", TAG+="uaccess"
    # DualSense
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0660", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", MODE="0660", TAG+="uaccess"
  '';

  # Joystick support
  hardware.uinput.enable = true;

  # ---------------------------------------------------------------------------
  # Kernel tweaks for gaming (Bazzite-inspired)
  # ---------------------------------------------------------------------------
  boot.kernel.sysctl = {
    # Reduce swap tendency — keep games in RAM
    "vm.swappiness" = 10;

    # Faster memory reclaim for gaming workloads
    "vm.compaction_proactiveness" = 0;
    "vm.page_lock_unfairness" = 1;

    # Network tweaks for online gaming
    "net.ipv4.tcp_fastopen" = 3;
    "net.core.netdev_max_backlog" = 16384;
    "net.core.somaxconn" = 8192;
    "net.ipv4.tcp_mtu_probing" = 1;

    # Increase max memory map areas (needed by some games)
    "vm.max_map_count" = 2147483642;

    # Split lock performance
    "kernel.split_lock_mitigate" = 0;
  };

  # ---------------------------------------------------------------------------
  # Security — allow unprivileged userfaultfd (needed by some Proton games)
  # ---------------------------------------------------------------------------
  security.pam.loginLimits = [
    { domain = "*"; item = "nofile"; type = "hard"; value = "1048576"; }
    { domain = "*"; item = "memlock"; type = "hard"; value = "unlimited"; }
    { domain = "*"; item = "memlock"; type = "soft"; value = "unlimited"; }
  ];

  # ---------------------------------------------------------------------------
  # Filesystem — enable NTFS support for external game drives
  # ---------------------------------------------------------------------------
  boot.supportedFilesystems = [ "ntfs" ];
}
