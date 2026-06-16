# =============================================================================
# rofi.nix — declares the OPTIONS-coherent rofi theme files.
#
# The source .rasi files live next to waybar/style.css at
# /etc/nixos/home/rofi/ so they remain easy to iterate on. They symlink
# directly into the user's ~/.config/rofi/ via mkOutOfStoreSymlink — same
# pattern as waybar.nix — so edits to the .rasi files are live after a
# `rofi` restart, without a nixos-rebuild.
#
# config.rasi defaults to the dark theme for invocations that don't pass
# -theme explicitly (e.g. Hyprland's $mod+SPACE before its launcher gets
# the rofi-anchor.sh treatment).
#
# IMPORTANT — this module only manages the four .rasi files listed in
# xdg.configFile below. The pre-existing ~/.config/rofi/ directory has its
# own git repo with window-switcher.sh, window-helper.sh, offers/, etc.
# Those files are untouched by home-manager; this module does not claim
# ownership of the entire ~/.config/rofi/ directory.
# =============================================================================
{ config, pkgs, lib, ... }:

let
  # String (not a Nix path literal) so Nix does NOT copy the directory
  # into /nix/store. mkOutOfStoreSymlink requires a string argument that
  # points directly at the on-disk location — using a path literal causes
  # the source tree to be imported into the store, defeating the purpose.
  rofiSrc = "/etc/nixos/home/rofi";
in
{
  home.packages = [ pkgs.rofi ];

  # The three theme files. ~/.config/rofi/config.rasi defaults to the
  # dark theme for invocations that don't pass -theme (e.g. Hyprland's
  # $mod+SPACE before its launcher gets the rofi-anchor.sh treatment).
  xdg.configFile = {
    "rofi/options-base.rasi".source  = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-base.rasi";
    "rofi/options-light.rasi".source = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-light.rasi";
    "rofi/options-dark.rasi".source  = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-dark.rasi";
    "rofi/config.rasi".source        = config.lib.file.mkOutOfStoreSymlink "${rofiSrc}/options-dark.rasi";
  };
}
