{ config, lib, pkgs, ... }:

let
  cfg = config.standardOs.disk.layout;

  # Disko pinned to a tagged release. Reproducible without flakes.
  # Update the URL + sha256 together when bumping versions.
  # Placeholder sha256 here; replaced with real value before import
  # in /etc/nixos/configuration.nix (see plan T14).
  disko = builtins.fetchTarball {
    url    = "https://github.com/nix-community/disko/archive/refs/tags/v1.12.0.tar.gz";
    sha256 = "0wbx518d2x54yn4xh98cgm65wvj0gpy6nia6ra7ns4j63hx14fkq";
  };
in
{
  # Import disko unconditionally — referencing config.standardOs in
  # imports causes infinite recursion. Disko is no-op until
  # disko.devices is populated, which only happens under mkIf below.
  imports = [ "${disko}/module.nix" ];

  options.standardOs.disk.layout = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = ''
        DESTRUCTIVE. Apply the canonical Standard-OS partition scheme.
        For installer flows only (disko-install, nixos-anywhere). Refuses
        to apply on a running system unless iAmInstallingAFreshSystem is
        also set to true.
      '';
    };

    iAmInstallingAFreshSystem = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = "Safety acknowledgment that the target disk will be wiped.";
    };

    disk = lib.mkOption {
      type        = lib.types.str;
      default     = "/dev/nvme0n1";
      description = "Target disk device path.";
    };

    swapExtraGiB = lib.mkOption {
      type        = lib.types.int;
      default     = 2;
      description = "Swap size = (total RAM) + this many GiB. Hibernate-image headroom.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.iAmInstallingAFreshSystem;
      message   = ''
        standardOs.disk.layout.enable is true but iAmInstallingAFreshSystem
        is false. This module rewrites partition tables. To proceed, set
        standardOs.disk.layout.iAmInstallingAFreshSystem = true.
      '';
    }];

    # Canonical layout: ESP (1G vfat) + swap (RAM + headroom) + root (rest).
    disko.devices.disk.main = {
      device = cfg.disk;
      type   = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size    = "1G";
            type    = "EF00";
            content = {
              type         = "filesystem";
              format       = "vfat";
              mountpoint   = "/boot";
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };
          swap = {
            # Sized at activation time from /proc/meminfo. The
            # +swapExtraGiB headroom gives the hibernate image room.
            size = let
              memTotalKiB = lib.toInt (lib.removeSuffix " kB"
                (lib.head (lib.filter (l: lib.hasPrefix "MemTotal:" l)
                  (lib.splitString "\n" (builtins.readFile "/proc/meminfo")))));
              gib = (memTotalKiB / 1024 / 1024) + cfg.swapExtraGiB;
            in "${toString gib}G";
            content = {
              type         = "swap";
              resumeDevice = true;
            };
          };
          root = {
            size    = "100%";
            content = {
              type       = "filesystem";
              format     = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
