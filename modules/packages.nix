{ config, lib, pkgs, ... }:
    #google-chrome

{
  environment.systemPackages = with pkgs; [
bc
playerctl
xprop
 steam
    sox
    nodejs
aria2
    # Gnome Keyring
    libsecret   

    # Github
    gh

    syncthing
    tree
    neovim
    scrcpy
    vscode
    lmstudio
    socat
    
    # Music / DAW
    lmms
    ardour
    audacity

    # Diagnostics
    mesa-demos
    lm_sensors
    nvtopPackages.full
    coolercontrol.coolercontrol-gui

    # Video codecs
    ffmpeg-full
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
    gst_all_1.gst-vaapi

    # Hardware acceleration
    libva-utils
    vdpauinfo

    # Codec libraries
    libaom
    libavif
    libde265
    libheif
    x264
    x265
    svt-av1
    dav1d
    openh264

    # Audio codecs
    fdk_aac
    fdk-aac-encoder
    lame
    opusTools
    libvorbis
    flac

    # Media — VLC is the distro's multimedia king. Default handler for every
    # common audio/video mime type (see xdg.mimeApps in home-nautilus.nix).
    # If a user wants something else they can install + reset defaults
    # themselves.
    vlc

    # mpv: opt-in for power users (terminal launch, scripting, network
    # streams). NOT registered as a default mime handler. Ships with the
    # MPRIS plugin so playerctl + our waybar miniplayer CAN see it if it's
    # used — but its single-instance "alias-only" bus naming is quirky and
    # the miniplayer doesn't promise perfect integration; that's an accepted
    # power-user trade-off.
    (mpv.override { scripts = [ mpvScripts.mpris ]; })
    mediainfo

    # Vulkan
    vulkan-tools
    vulkan-loader
    vulkan-validation-layers
    glslang
    shaderc

    # Virtualization
    virt-manager
    virt-viewer
    bridge-utils

    # Shell
    zoxide
    eza
    fzf
    yazi
    ripgrep
    zip
    p7zip
    fd

    # Desktop
    wpsoffice  # wrapped via standardos.focusOrLaunch below
    git
    brightnessctl
    libnotify
    mako
    waybar
    rofi
    wl-clipboard
    cliphist
    grim
    slurp
    swappy

    lua-language-server
    nixd
    rust-analyzer
    pyright
    kitty
    hyprsunset
    hyprpaper
    imagemagick
    firefox
    gimp
    obs-studio
    pavucontrol
    jq
    qmk
    dos2unix
    waypaper

    # Bluetooth
    bluez
    bluez-tools

    # Claude
    claude-code
    claude-monitor
  ];

 nixpkgs.config.allowUnfree = true;
 nixpkgs.config.permittedInsecurePackages = [ "electron-39.8.10" ];

   programs.kdeconnect.enable = true;
   programs.nix-ld.enable = true;

  # ---------------------------------------------------------------------------
  # Focus-or-launch wrappers for singleton apps.
  # See modules/focus-or-launch.nix for the mechanics.
  # ---------------------------------------------------------------------------
  standardos.focusOrLaunch = [
    { name = "wps"; class = "^wps$"; package = pkgs.wpsoffice; }
    { name = "wpp"; class = "^wpp$"; package = pkgs.wpsoffice; }
    { name = "et";  class = "^et$";  package = pkgs.wpsoffice; }
  ];

  systemd.services.coolercontrold = {
    description = "CoolerControl daemon";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "multi-user.target" ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "on-failure";
      RestartSec = "5s";
      ExecStart  = "${pkgs.coolercontrol.coolercontrold}/bin/coolercontrold";
    };
  };


}
