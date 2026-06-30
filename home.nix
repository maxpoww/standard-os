{ pkgs, lib, primaryUser, userHome, ... }:

# =============================================================================
# home.nix — Home Manager root file for the primary user
# Referenced from configuration.nix:  home-manager.users.${primaryUser} = import ./home.nix;
# Receives primaryUser + userHome via home-manager.extraSpecialArgs.
# =============================================================================

{
  imports = [
    ./home-nautilus.nix
    ./home-screen-type.nix
    ./home-xdg.nix
    ./home/modules/hypr-context.nix
    ./home/modules/hypr-bg.nix
    ./home/modules/voice-dictation.nix
    ./home/modules/waybar.nix
    ./home/modules/rofi.nix
    ./home/modules/hyprland-config.nix
    ./home/modules/keyring-unlocked.nix
    ./home/modules/standard-os-resume-user.nix
    ./home/modules/standard-os-update-scheduler.nix
    ./home/modules/notif-center.nix
    ./home/modules/widgets-canvas.nix
    ./home/modules/weather-daemon.nix
    ./home/modules/system-daemon.nix
    ./home/modules/notif-history-channel.nix
    ./home/modules/pomodoro-daemon.nix
    ./home/modules/cal-source-daemon.nix
    ./home/modules/brightness-daemon.nix
    ./home/modules/mpris-publisher.nix
    ./home/modules/landscape-snap.nix
    ./home/hosts/STDOS.nix
  ];

  #services.rofi-empty-dock.enable = true;

  home.username      = primaryUser;
  home.homeDirectory = userHome;
  home.stateVersion  = "25.11";

  # Required: let Home Manager manage itself (enables the home-manager CLI)
  programs.home-manager.enable = true;

  services.hyprContext.enable = true;
  services.hyprBg.enable = true;

  services.voiceDictation = {
    enable      = true;
    cudaSupport = true;          # RTX 4050 — CUDA-accelerated whisper.cpp
  };

  services.waybarBar.enable = true;
  services.keyring.unlocked.enable = true;
  services.notifCenter.enable = true;
  services.standardosCanvas.enable = true;
  services.weatherDaemon.enable = true;
  services.weatherDaemon.city = "Mendoza";
  services.systemDaemon.enable = true;
  services.notifHistoryChannel.enable = true;
  services.pomodoroDaemon.enable = true;
  services.calSourceDaemon.enable = true;
  services.brightnessDaemon.enable = true;
  services.mprisPublisher.enable = true;
  services.landscapeSnap.enable = true;

  # Clear Antigravity's service worker cache on each rebuild to prevent
  # stale cached scripts (e.g. after extension updates) from causing
  # "Error loading webview: Could not register service worker: InvalidStateError"
  home.activation.clearAntigravitySwCache = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf "$HOME/.config/Antigravity/Service Worker"
  '';
}
