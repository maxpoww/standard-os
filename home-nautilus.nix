{ config, lib, pkgs, ... }:

# =============================================================================
# home-nautilus.nix — Home Manager user-level Nautilus configuration
# Import this in home.nix:  imports = [ ./home-nautilus.nix ];
#
# Paired with: modules/nautilus-system.nix (system-level config)
# =============================================================================

{
  # ---------------------------------------------------------------------------
  # BUG 1 FIX (CRITICAL): GIO_EXTRA_MODULES — Home Manager overwrites system value
  # ---------------------------------------------------------------------------
  # Home Manager's dconf module automatically sets GIO_EXTRA_MODULES to only
  # dconf's own path. On Wayland, home.sessionVariables is evaluated AFTER the
  # system environment and OVERWRITES it instead of appending. This causes:
  #   - Trash showing "Operation not supported"
  #   - MTP file operations failing
  #   - Network mounts unavailable
  # The fix: set GIO_EXTRA_MODULES here to the complete correct value so that
  # when HM overwrites the variable, it overwrites it with ALL required paths.
  # Source: home-manager issue #7143 (open as of 2025)
  home.sessionVariables = {
    GIO_EXTRA_MODULES = lib.concatStringsSep ":" [
      "${pkgs.dconf}/lib/gio/modules"
      "${pkgs.gvfs}/lib/gio/modules"
      "${pkgs.glib-networking}/lib/gio/modules"
    ];

    # GTK dark mode environment variables
    GTK_THEME      = "adw-gtk3-dark";
    XCURSOR_THEME  = "Adwaita";
    XCURSOR_SIZE   = "24";
  };

  # ---------------------------------------------------------------------------
  # GTK theme — Adwaita dark across GTK3 and GTK4
  # ---------------------------------------------------------------------------
  gtk = {
    enable = true;

    theme = {
      name    = "adw-gtk3-dark";
      package = pkgs.adw-gtk3;
    };

    iconTheme = {
      name    = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };

    cursorTheme = {
      name    = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size    = 24;
    };

    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
    };

    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = true;
    };
  };

  # ---------------------------------------------------------------------------
  # Qt theme — use GTK theme for consistent appearance
  # ---------------------------------------------------------------------------
  qt = {
    enable             = true;
    platformTheme.name = "gtk";
    style.name         = "adwaita-dark";
  };

  # ---------------------------------------------------------------------------
  # dconf settings — GNOME preferences backend
  # ---------------------------------------------------------------------------
  dconf.settings = {

    # Dark mode for all libadwaita (GTK4) applications
    "org/gnome/desktop/interface" = {
      color-scheme          = "prefer-dark";
      gtk-theme             = "adw-gtk3-dark";
      icon-theme            = "Adwaita";
      cursor-theme          = "Adwaita";
      cursor-size           = 24;
      font-antialiasing     = "rgba";
      font-hinting          = "slight";
    };

    # Nautilus general preferences
    "org/gnome/nautilus/preferences" = {
      default-folder-viewer         = "list-view";   # list view by default
      show-hidden-files             = true;           # show dotfiles
      show-create-link              = true;           # "Make Link" in context menu
      show-delete-permanently       = true;           # "Delete Permanently" option
      automatic-decompression       = false;          # don't auto-extract archives
      executable-text-activation    = "ask";          # ask before running scripts
      search-filter-time-type       = "last_modified";
      search-view                   = "list-view";
      recursive-search              = "always";       # search file contents recursively
    };

    # Nautilus list view settings — tree expansion, columns
    "org/gnome/nautilus/list-view" = {
      use-tree-view       = true;    # expand folders as tree in list view
      default-zoom-level  = "small"; # compact rows
      default-visible-columns = [
        "name" "size" "type" "date_modified"
      ];
    };

    # Nautilus icon view settings
    "org/gnome/nautilus/icon-view" = {
      default-zoom-level = "medium";
    };

    # Nautilus window initial state
    "org/gnome/nautilus/window-state" = {
      initial-size           = lib.hm.gvariant.mkTuple [ 1200 700 ];
      maximized              = false;
      start-with-sidebar     = true;
      sidebar-width          = 220;
    };

    # Nautilus sidebar sections: show Places, Devices, Network, Bookmarks
    "org/gnome/nautilus/sidebar-panels" = { };

    "org/gnome/nautilus/compression" = {
      default-compression-format = "zip";
    };

    # nautilus-open-any-terminal extension: open kitty from context menu
    # Change "kitty" to your terminal if you switch terminals later.
    "com/github/stunkymonkey/nautilus-open-any-terminal" = {
      terminal    = "kitty";    # ← your terminal (detected from hyprland.conf)
      new-tab     = false;
      keybindings = "<Ctrl><Alt>t";
    };
  };

  # ---------------------------------------------------------------------------
  # udiskie — automount daemon with system tray
  # ---------------------------------------------------------------------------
  # udiskie watches UDisks2 signals and automounts removable media. It also
  # provides a tray icon to manually mount/unmount. The "auto" tray mode
  # shows the icon only when a mountable device is connected.
  services.udiskie = {
    enable    = true;
    tray      = "auto";
    automount = true;
  };

  # ---------------------------------------------------------------------------
  # BUG 3 FIX: gvfsd-fuse — missing on non-GNOME Wayland sessions
  # ---------------------------------------------------------------------------
  # gvfsd-fuse creates a FUSE mountpoint at $XDG_RUNTIME_DIR/gvfs/ that bridges
  # gvfs virtual paths (trash://, mtp://) into the POSIX namespace. Without it:
  #   - "Move to Trash" silently deletes files permanently
  #   - trash:/// returns "Operation not supported"
  #   - MTP device directories fail to open
  # GNOME Shell starts this automatically; Hyprland has no equivalent.
  # Solution: declare it as a systemd user service.
  systemd.user.services.gvfsd-fuse = {
    Unit = {
      Description = "GVfs FUSE bridge (POSIX mountpoint for trash://, mtp://)";
      Documentation = "man:gvfsd-fuse(1)";
      Requires = [ "gvfs-daemon.service" ];
      After    = [ "gvfs-daemon.service" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      # Create the mountpoint before starting (systemd %t = $XDG_RUNTIME_DIR)
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %t/gvfs";
      ExecStart    = "${pkgs.gvfs}/libexec/gvfsd-fuse %t/gvfs -f -o auto_unmount";
      Restart      = "on-failure";
    };
  };

  # ---------------------------------------------------------------------------
  # BUG 2 FIX: gvfs volume monitors not starting on NixOS ≥ 25.05
  # ---------------------------------------------------------------------------
  # In NixOS/GNOME 48+, gvfs volume monitor services rely on D-Bus activation
  # that never fires on non-GNOME sessions (Hyprland has no Session Manager).
  # Result: USB drives and Android phones are not detected on first login.
  # Fix: declare user-scope systemd units with WantedBy = graphical-session.target.
  # User-scope units (~/.config/systemd/user/) override system-level units.
  # Source: NixOS Discourse "GVFS user services not starting since 25.05",
  #         NixOS/nixpkgs issue #412131

  # Block-device volume monitor — detects HDDs, SSDs, USB sticks
  systemd.user.services.gvfs-udisks2-volume-monitor = {
    Unit = {
      Description   = "GVfs UDisks2 volume monitor (detects block devices)";
      Documentation = "man:gvfsd-trash(1)";
      Requires = [ "gvfs-daemon.service" ];
      After    = [ "graphical-session.target" "gvfs-daemon.service" ];
      WantedBy = [ "graphical-session.target" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type     = "simple";
      ExecStart = "${pkgs.gvfs}/libexec/gvfs-udisks2-volume-monitor";
      Restart  = "on-failure";
    };
  };

  # MTP volume monitor — detects Android phones in File Transfer mode
  systemd.user.services.gvfs-mtp-volume-monitor = {
    Unit = {
      Description   = "GVfs MTP volume monitor (detects Android phones)";
      Documentation = "man:gvfs-mtp(1)";
      Requires = [ "gvfs-daemon.service" ];
      After    = [ "graphical-session.target" "gvfs-daemon.service" ];
      WantedBy = [ "graphical-session.target" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type      = "simple";
      ExecStart = "${pkgs.gvfs}/libexec/gvfs-mtp-volume-monitor";
      Restart   = "on-failure";
    };
  };

  # GPhoto2 volume monitor — detects cameras in PTP mode
  systemd.user.services.gvfs-gphoto2-volume-monitor = {
    Unit = {
      Description   = "GVfs GPhoto2 volume monitor (detects cameras)";
      After    = [ "graphical-session.target" "gvfs-daemon.service" ];
      WantedBy = [ "graphical-session.target" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type      = "simple";
      ExecStart = "${pkgs.gvfs}/libexec/gvfs-gphoto2-volume-monitor";
      Restart   = "on-failure";
    };
  };

  # Metadata service — stores Nautilus emblems and custom file metadata
  systemd.user.services.gvfs-metadata = {
    Unit = {
      Description = "GVfs metadata service (Nautilus emblems, file tags)";
      After    = [ "gvfs-daemon.service" ];
      WantedBy = [ "graphical-session.target" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type      = "simple";
      ExecStart = "${pkgs.gvfs}/libexec/gvfs-metadata";
      Restart   = "on-failure";
    };
  };

  # ---------------------------------------------------------------------------
  # Polkit authentication agent
  # ---------------------------------------------------------------------------
  # Required for GUI privilege escalation (mount operations, admin file access).
  # Without this, UDisks2/Polkit actions silently fail because no agent is
  # listening to present the password dialog to the user.
  systemd.user.services.polkit-gnome-agent = {
    Unit = {
      Description = "Polkit GNOME authentication agent";
      After    = [ "graphical-session.target" ];
      WantedBy = [ "graphical-session.target" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type      = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart   = "on-failure";
    };
  };

  # ---------------------------------------------------------------------------
  # Tumbler — D-Bus thumbnail generation service
  # ---------------------------------------------------------------------------
  # Tumbler is activated by D-Bus when Nautilus requests a thumbnail. Declaring
  # it here ensures it starts with the graphical session and the environment
  # variables (including GST plugin paths and GDK pixbuf loaders) are correct.
  systemd.user.services.tumbler = {
    Unit = {
      Description = "Tumbler thumbnail service";
      After    = [ "graphical-session.target" ];
      WantedBy = [ "graphical-session.target" ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
    Service = {
      Type      = "simple";
      ExecStart = "${pkgs.xfce.tumbler}/libexec/tumblerd";
      Restart   = "on-failure";
    };
  };

  # ---------------------------------------------------------------------------
  # Tumbler configuration — enable all thumbnailer plugins
  # ---------------------------------------------------------------------------
  # Without this file, Tumbler uses built-in defaults that may miss plugins.
  # MaxFileSize = 0 disables the size limit (thumbnails for large video files).
  xdg.configFile."tumbler/tumbler.rc".text = ''
    [DesktopThumbnailer]
    Disabled=false
    MaxFileSize=0

    [FfmpegThumbnailer]
    Disabled=false
    MaxFileSize=0

    [GStreamerThumbnailer]
    Disabled=false
    MaxFileSize=0

    [OdfThumbnailer]
    Disabled=false
    MaxFileSize=0

    [PixbufThumbnailer]
    Disabled=false
    MaxFileSize=0

    [PopperThumbnailer]
    Disabled=false
    MaxFileSize=0

    [RawThumbnailer]
    Disabled=false
    MaxFileSize=0
  '';

  # ---------------------------------------------------------------------------
  # MIME type associations — Nautilus as default file manager,
  # VLC as the distro's default for all audio/video. VLC is the multimedia
  # king: handles every common format, polished GUI, well-behaved MPRIS
  # (org.mpris.MediaPlayer2.vlc[.instance<pid>]) — works out of the box with
  # the mpris-publisher's event-driven discovery. mpv stays installed for
  # power users who launch it explicitly (terminal / scripted / network
  # streams) but is NOT a default handler for any mime type.
  # ---------------------------------------------------------------------------
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      let
        vlc = [ "vlc.desktop" ];
        nautilus = [ "org.gnome.Nautilus.desktop" ];
      in {
        "inode/directory"                  = nautilus;
        "application/x-gnome-saved-search" = nautilus;

        # Audio — every common container/codec routed to VLC
        "audio/mpeg"          = vlc;  # mp3
        "audio/mp4"           = vlc;
        "audio/x-m4a"         = vlc;
        "audio/aac"           = vlc;
        "audio/flac"          = vlc;
        "audio/x-flac"        = vlc;
        "audio/ogg"           = vlc;
        "audio/x-vorbis+ogg"  = vlc;
        "audio/opus"          = vlc;
        "audio/x-opus+ogg"    = vlc;
        "audio/wav"           = vlc;
        "audio/x-wav"         = vlc;
        "audio/x-ms-wma"      = vlc;
        "audio/webm"          = vlc;

        # Video — every common container routed to VLC
        "video/mp4"           = vlc;
        "video/x-matroska"    = vlc;  # mkv
        "video/webm"          = vlc;
        "video/quicktime"     = vlc;  # mov
        "video/x-msvideo"     = vlc;  # avi
        "video/x-ms-wmv"      = vlc;
        "video/ogg"           = vlc;
        "video/x-flv"         = vlc;
        "video/3gpp"          = vlc;
        "video/mpeg"          = vlc;
        "video/x-theora+ogg"  = vlc;

        # Playlists / streams
        "audio/x-mpegurl"     = vlc;  # m3u
        "audio/x-scpls"       = vlc;  # pls
        "application/vnd.apple.mpegurl" = vlc;  # m3u8
      };
  };

  # ---------------------------------------------------------------------------
  # Nautilus sidebar bookmarks (Places panel)
  # ---------------------------------------------------------------------------
  # Add or remove entries here to customize the sidebar.
  # Format: <URI> <display name>
  xdg.configFile."gtk-3.0/bookmarks".text = ''
    file:///home/max/Documents Documents
    file:///home/max/Downloads Downloads
    file:///home/max/Pictures Pictures
    file:///home/max/Videos Videos
    file:///home/max/Music Music
    file:///home/max/Projects Projects
  '';

  # ---------------------------------------------------------------------------
  # User-scope packages
  # ---------------------------------------------------------------------------
  home.packages = with pkgs; [
    simple-mtpfs  # Fallback MTP FUSE mount for non-standard Android ROMs
    jmtpfs        # Alternative MTP FUSE client
    file-roller   # Archive manager (GUI, integrates with Nautilus)
    eog           # Image viewer
    evince        # PDF/DjVu viewer
    totem         # Video player
    hexyl         # Hex viewer (for debugging binary files)
    baobab        # Disk usage analyzer
    file          # MIME type detection utility
    mediainfo     # Media file technical info
  ];
}
