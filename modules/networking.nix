{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Network
  # ---------------------------------------------------------------------------
  networking.hostName              = "STDOS";
  services.openssh.enable = true;
networking.networkmanager.enable = true;
  services.fail2ban.enable         = true;

  networking.firewall = {
    enable = true;
    allowedTCPPortRanges = [
      { from = 1714; to = 1764; }
    ];
    allowedUDPPortRanges = [
      { from = 1714; to = 1764; }
    ];
    allowedTCPPorts = [ 22 80 443 53 ];
    allowedUDPPorts = [ 53 ];
    trustedInterfaces = [ "virbr0" ];
  };
}
