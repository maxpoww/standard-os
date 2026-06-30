{ config, lib, pkgs, primaryUser, ... }:

{
  # ---------------------------------------------------------------------------
  # User account — name comes from configuration.nix's `primaryUser` let-binding,
  # propagated via _module.args. The future installer sets that one variable.
  # ---------------------------------------------------------------------------
  users.users.${primaryUser} = {
    shell        = pkgs.zsh;
    isNormalUser = true;
    description  = primaryUser;
    extraGroups  = [ "networkmanager" "wheel" "video" "audio" "render" "input" "plugdev" "storage" "disk" "dialout" "lp" "scanner" "adbusers" "libvirtd" ];
    packages     = with pkgs; [];
  };
}
