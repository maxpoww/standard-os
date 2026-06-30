{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Hyprland
  # ---------------------------------------------------------------------------
  programs.hyprland = {
    enable          = true;
    withUWSM        = true;
    xwayland.enable = true;
  };

  programs.zsh = {
    enable                 = true;
    enableCompletion       = true;
    autosuggestions.enable = true;
  };

  # ---------------------------------------------------------------------------
  # Display manager
  # ---------------------------------------------------------------------------
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "uwsm start hyprland-uwsm.desktop";
        user    = "max";
      };
    };
  };

  systemd.services.greetd.serviceConfig = {
    StandardInput  = "tty";
    StandardOutput = "null";
    StandardError  = "null";
  };

  # ---------------------------------------------------------------------------
  # XDG portals
  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # BUG 6 FIX: XDG portal — explicit interface routing
  # ---------------------------------------------------------------------------
  # When both XDPH and XDPG are installed, the wildcard default causes apps to
  # attempt XDPH for FileChooser (which XDPH doesn't implement), timing out
  # after ~30 seconds before falling back to XDPG.
  # Fix: route each interface explicitly. FileChooser → gtk only.
  # NOTE: Do NOT add xdg-desktop-portal-hyprland to extraPortals here.
  #       programs.hyprland.enable already adds it; adding it twice causes
  #       duplicate service registrations and portal conflicts.
  xdg.portal = {
    enable       = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.hyprland = {
      default                                       = [ "hyprland" "gtk" ];
      "org.freedesktop.impl.portal.FileChooser"    = [ "gtk" ];
      "org.freedesktop.impl.portal.AppChooser"     = [ "gtk" ];
      "org.freedesktop.impl.portal.Screenshot"     = [ "hyprland" ];
      "org.freedesktop.impl.portal.ScreenCast"     = [ "hyprland" ];
      "org.freedesktop.impl.portal.GlobalShortcuts" = [ "hyprland" ];
      "org.freedesktop.impl.portal.Inhibit"        = [ "hyprland" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Fonts — the bar (OPTIONS) depends on this set:
  #   meslo-lgs-nf  → "MesloLGS NF" (primary on the bar — bundles alphanumerics
  #                   AND Nerd Font icon glyphs in one font, keeping metrics
  #                   consistent between text pills and icon pills).
  #   font-awesome  → "Font Awesome 7 Free" (explicit fallback for FA codepoints
  #                   that may not be in older Nerd Font builds).
  #   nerd-fonts.symbols-only
  #                 → "Symbols Nerd Font Mono" (belt-and-braces fallback for
  #                   niche private-use codepoints — Material, Codicons, etc.).
  # The bar's CSS `font-family` lists these by their CANONICAL font names (the
  # name embedded in the font file, queryable via `fc-match "<name>"`) NOT the
  # nixpkgs package names — `font-awesome` as a CSS family does not resolve.
  # See waybar/CLAUDE.md "Known hazards" for the trap.
  # meslo-lg is the plain (non-NF) Meslo, kept for general system use.
  fonts.packages = with pkgs; [
    meslo-lg
    meslo-lgs-nf
    font-awesome
    nerd-fonts.symbols-only
  ];
}
