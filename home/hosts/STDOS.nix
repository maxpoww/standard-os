# =============================================================================
# STDOS.nix — per-host overrides for max's laptop (RTX 4050 + dual monitor)
#
# Imported from /etc/nixos/home.nix alongside services.hyprlandConfig itself.
# Sets the values that differ from the distro defaults — monitors, device
# blacklist, and host-specific exec-once entries.
# =============================================================================
{ ... }:

{
  services.hyprlandConfig = {
    enable = true;

    monitors = [
      { name = "eDP-1";    resolution = "3200x2000@165"; position = "0x0";     scale = 2;
        workspaces = [ 1 2 3 4 5 6 7 8 9 ]; }
      { name = "HDMI-A-1"; resolution = "1280x1024@75";  position = "0x-3000"; scale = 1;
        workspaces = [ 11 12 13 14 15 16 17 18 19 ]; }
    ];

    # Built-in Goodix fingerprint reader — never used, sometimes spurious wakes.
    disableDevices = [ "gdix0001:00-27c6:0123" ];

    # No NVIDIA env vars — leave the proprietary driver's defaults alone.
    nvidia.enable = false;

    # Host-specific startup commands. screen-type.sh restore was previously
    # declared (silently inactive) in home-screen-type.nix.
    extraExecOnce = [
      "$HOME/.config/waybar/scripts/screen-type.sh restore"
      "$HOME/bar.sh"
    ];
  };
}
