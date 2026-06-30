{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # NVIDIA — offload mode (NVIDIA renders, Intel drives display)
  # Verify bus IDs: lspci | grep -E "VGA|3D"
  # ---------------------------------------------------------------------------
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable          = true;
    open                        = false;
    nvidiaSettings              = true;
    package                     = config.boot.kernelPackages.nvidiaPackages.stable;
    powerManagement.enable      = true;
    powerManagement.finegrained = false;

    prime = {
      offload = {
        enable           = true;
        enableOffloadCmd = true;
      };
      intelBusId  = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # ---------------------------------------------------------------------------
  # Graphics stack
  # ---------------------------------------------------------------------------
  hardware.graphics = {
    enable      = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      nvidia-vaapi-driver
      intel-media-driver
      libva-vdpau-driver
      libvdpau-va-gl
      libva
      libva-utils
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      libva-vdpau-driver
    ];
  };

  # ---------------------------------------------------------------------------
  # Session environment
  # ---------------------------------------------------------------------------
  environment.sessionVariables = {
    # PRIME offload — tells Wayland/EGL apps to render on NVIDIA
#   __NV_PRIME_RENDER_OFFLOAD          = "1";
#   __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";

#   GBM_BACKEND                  = "nvidia-drm";
#   __GLX_VENDOR_LIBRARY_NAME    = "nvidia";
    __VK_LAYER_NV_optimus        = "NVIDIA_only";
    LIBVA_DRIVER_NAME            = "nvidia";
    NVD_BACKEND                  = "direct";
    WLR_NO_HARDWARE_CURSORS      = "1";
    NIXOS_OZONE_WL               = "1";
    MOZ_ENABLE_WAYLAND           = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    __GL_VRR_ALLOWED             = "0";
    __GL_SYNC_TO_VBLANK          = "1";
  };
}
