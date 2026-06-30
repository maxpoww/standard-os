{ ... }:

# =============================================================================
# modules/empty-dock.nix — Home Manager: Hyprland empty-workspace dock
# Import in home.nix:  imports = [ ./modules/empty-dock.nix ];
#
# Runs waybar-monitor.sh as a systemd user service. The daemon polls
# hyprctl every 2 s and shows/hides a second Waybar instance whenever
# the active Hyprland workspace has no windows.
#
# Scripts:  ~/.config/waybar/offers/empty-dock/
# Log:      ~/.local/share/empty-dock/empty-dock.log
#
# Dependencies (expected to be in PATH via packages.nix):
#   waybar  jq  rofi  hyprctl  bash
# =============================================================================

let
  dockDir = "%h/.config/waybar/offers/empty-dock";
in
{
  systemd.user.services.empty-dock = {
    Unit = {
      Description = "Hyprland empty-workspace dock monitor";
      # Start after UWSM has fully initialised the Hyprland user session
      # (HYPRLAND_INSTANCE_SIGNATURE is already in the user environment by then).
      After  = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      Type       = "simple";
      # %h expands to the user's home directory in systemd unit files.
      ExecStart  = "%h/.config/waybar/offers/empty-dock/waybar-monitor.sh";
      Restart    = "on-failure";
      RestartSec = "3s";
      Environment = [
        "EMPTY_DOCK_POLL=2"
        "EMPTY_DOCK_LOG=%h/.local/share/empty-dock/empty-dock.log"
      ];
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };
}
