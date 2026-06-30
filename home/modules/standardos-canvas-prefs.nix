# standardos-canvas-prefs — wires the canvas's Apply flow into the
# system config. Imports the sidecar (which the canvas overwrites on
# each Apply) and grants passwordless sudo for nixos-rebuild so the
# user-side canvas can trigger system rebuilds.
#
# Spec: docs/superpowers/specs/2026-06-25-canvas-prefs-apply-design.md
{ config, lib, pkgs, ... }: {
  imports = [ /etc/nixos/standardos-canvas-sidecar.nix ];

  security.sudo.extraRules = [{
    users = [ "max" ];
    commands = [{
      command = "/run/current-system/sw/bin/nixos-rebuild";
      options = [ "NOPASSWD" ];
    }];
  }];
}
