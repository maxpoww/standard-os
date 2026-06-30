{ config, lib, pkgs, ... }:

# =============================================================================
# nautilus-system.nix — System-level Nautilus configuration
# Import this in configuration.nix:  imports = [ ./modules/nautilus-system.nix ];
#
# Paired with: home-nautilus.nix (Home Manager user-level config)
# =============================================================================

{
  # ---------------------------------------------------------------------------
  # BUG 4 FIX: Nautilus A/V Properties pane — "missing GStreamer plug-in"
  # ---------------------------------------------------------------------------
  # Nautilus is built with wrapGAppsHook, which sets runtime paths relative to
  # its own closure. GStreamer plugins installed in systemPackages are NOT
  # automatically visible unless they are in Nautilus's closure at build time.
  # This overlay rebuilds Nautilus locally with the GStreamer plugins baked in.
  # This causes a one-time rebuild (a few minutes) on first nixos-rebuild.
  # Source: NixOS Wiki / Nautilus page
  # ---------------------------------------------------------------------------
  nixpkgs.overlays = [
    (final: prev: {
      nautilus = prev.nautilus.overrideAttrs (old: {
        buildInputs = old.buildInputs ++ (with final.gst_all_1; [
          gst-plugins-good
          gst-plugins-bad
          gst-plugins-ugly
          gst-libav
        ]);
      });
    })
  ];

  # ---------------------------------------------------------------------------
  # Core GNOME/GVfs services (required even without the GNOME DE)
  # ---------------------------------------------------------------------------

  # GVfs: Virtual filesystem daemon. Provides Trash, MTP, SMB, SFTP, etc.
  # services.gvfs.enable is already set in services.nix — kept there.

  # Polkit: Required for mount/unmount privilege escalation via UDisks2.
  security.polkit.enable = true;

  # FUSE with user_allow_other: Required for gvfsd-fuse to mount gvfs paths
  # (trash://, mtp://) into the POSIX namespace so applications can access them.
  programs.fuse.userAllowOther = true;

  # dconf: GNOME settings backend. Required for Nautilus preferences persistence.
  programs.dconf.enable = true;

  # ---------------------------------------------------------------------------
  # GNOME Keyring — PAM unlock at TTY/login-manager login
  # (gnome-keyring.enable + dbus.packages are centralised in modules/services.nix;
  # only the PAM-side enable lives here because it's a Nautilus/login-path concern.)
  # ---------------------------------------------------------------------------
  security.pam.services.login.enableGnomeKeyring = true;

  # ---------------------------------------------------------------------------
  # Android MTP + udev rules
  # ---------------------------------------------------------------------------
  # android-udev-rules was removed from nixpkgs 25.11 — systemd's built-in uaccess
  # rules now handle Android USB device access. libmtp still needed for the protocol.
  services.udev.packages = with pkgs; [ libmtp ];

  # plugdev group: Required for raw USB access to MTP/PTP devices.
  # Users must be added to this group to access Android phones without root.
  # Add the user to this group in users.nix:
  #   extraGroups = [ ... "plugdev" "storage" "disk" ];
  users.groups.plugdev = { };

  # ---------------------------------------------------------------------------
  # BUG 5 FIX: Tumbler thumbnailer plugin discovery + GDK pixbuf loaders
  # ---------------------------------------------------------------------------
  # NixOS packages install to their own /nix/store/... paths. The system
  # profile only merges subdirectory contents explicitly listed here.
  # Without /share/thumbnailers, Tumbler finds zero thumbnailer plugins.
  # Without /lib/gdk-pixbuf-2.0, WebP/HEIC/SVG format support is broken.
  # Source: NixOS Wiki / Nautilus page
  environment.pathsToLink = [
    "/share/thumbnailers"        # Tumbler plugin .service files
    "/lib/gdk-pixbuf-2.0"        # GDK pixbuf format loaders (.so files)
    "/share/nautilus-python/extensions"  # Python extensions for Nautilus
  ];

  # NOTE: GIO_EXTRA_MODULES is set in home-nautilus.nix (home.sessionVariables)
  # rather than here, because setting it at system level conflicts with the
  # Home Manager dconf module which also sets it. The HM value in
  # home.sessionVariables always wins on Wayland sessions and is the canonical fix.
  # See: home-manager issue #7143

  # ---------------------------------------------------------------------------
  # BUG 7 FIX: boot.supportedFilesystems — attrset form required on NixOS ≥ 24.05
  # ---------------------------------------------------------------------------
  # On NixOS < 24.05 this was a list; from 24.05+ it is an attrset of name→bool.
  # Using the list form causes a type error during nixos-rebuild eval.
  boot.supportedFilesystems = {
    ntfs  = true;   # NTFS: external drives, Windows dual-boot partitions
    exfat = true;   # exFAT: SD cards, modern USB drives
    vfat  = true;   # FAT32: legacy USB drives, embedded devices
    btrfs = true;   # Btrfs: Linux filesystem (copy-on-write, snapshots)
    xfs   = true;   # XFS: high-performance Linux filesystem
    f2fs  = true;   # F2FS: flash-friendly filesystem (eMMC, NVMe)
    # zfs = true;   # ZFS: uncomment if needed (requires extra kernel config)
  };

  # FUSE module: Required for gvfsd-fuse to create POSIX mountpoints for gvfs paths.
  # nls_utf8/nls_cp437: Required for correct filename encoding on VFAT/NTFS volumes.
  boot.kernelModules = [ "fuse" "nls_utf8" "nls_cp437" ];

  # ---------------------------------------------------------------------------
  # BUG 6 FIX: XDG portal interface routing — see desktop.nix
  # ---------------------------------------------------------------------------
  # The XDG portal fix is applied in desktop.nix where xdg.portal is already
  # declared. The key change: explicit per-interface routing, FileChooser→gtk
  # only (avoids 30-second timeout from XDPH not implementing FileChooser).

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [

    # ── Core file manager ────────────────────────────────────────────────────
    nautilus                    # The file manager (rebuilt with GStreamer via overlay)
    sushi                       # Space-key quick-look previewer (GNOME Sushi)
    file-roller                 # Archive manager (integrates with Nautilus)
    baobab                      # Disk usage analyzer
    nautilus-open-any-terminal  # "Open Terminal Here" context menu extension

    # ── Filesystem tools ─────────────────────────────────────────────────────
    ntfs3g         # NTFS read/write support in userspace (attr: ntfs3g, not ntfs-3g)
    exfatprogs     # exFAT filesystem utilities (mkfs, fsck)
    dosfstools     # FAT12/16/32 utilities (mkfs.vfat, fsck.fat)
    e2fsprogs      # ext2/3/4 utilities
    btrfs-progs    # Btrfs utilities
    xfsprogs       # XFS utilities
    f2fs-tools     # F2FS utilities
    reiserfsprogs  # ReiserFS utilities (legacy drives)
    jfsutils       # JFS utilities (legacy IBM drives)
    hfsprogs       # HFS/HFS+ utilities (old macOS drives)
    udftools       # UDF utilities (optical media, Blu-ray)
    smartmontools  # Drive health monitoring (S.M.A.R.T.)
    parted         # Partition management
    gptfdisk       # GPT partition tool (gdisk, sgdisk, cgdisk)

    # ── Android MTP ──────────────────────────────────────────────────────────
    # gvfs-mtp (via services.gvfs) handles MTP automatically for most devices.
    # The tools below are fallbacks for non-standard Android ROMs.
    libmtp          # MTP protocol library (also used by gvfs-mtp-volume-monitor)
    simple-mtpfs    # FUSE-based MTP mount: simple-mtpfs --device 1 /mnt/android
    jmtpfs          # Alternative FUSE MTP client: jmtpfs /mnt/android
    android-file-transfer  # GUI-based MTP file transfer
    # gmtp is not packaged in nixpkgs 25.11 — simple-mtpfs/jmtpfs cover the same use case

    # ── Thumbnailing ─────────────────────────────────────────────────────────
    # Tumbler: D-Bus thumbnail generation service (backend for Nautilus thumbnails)
    xfce.tumbler
    # Video thumbnails (MP4, MKV, AVI, MOV, WEBM, any FFmpeg-supported format)
    ffmpegthumbnailer
    # PDF, PS, DjVu thumbnails
    evince        # PDF/PS/DjVu viewer + thumbnailer
    djvulibre     # DjVu support library
    # ePub cover thumbnails
    gnome-epub-thumbnailer
    # PDF processing (used by some thumbnailers)
    poppler-utils

    # ── Image format support (GDK pixbuf loaders) ───────────────────────────
    # These loaders extend the image formats that GTK and Tumbler can decode.
    libheif      # HEIC/HEIF header/library (dev outputs)
    libheif.out  # REQUIRED: the actual GDK pixbuf loader .so is in the .out output
                 # omitting libheif.out means HEIC files show no thumbnail or preview
    webp-pixbuf-loader  # WebP support for GDK pixbuf
    librsvg             # SVG rendering (also used for icon theming)

    # ── GStreamer (also needed for Nautilus A/V Properties — see overlay above) ──
    # These are installed here for system-wide use (mpv, vlc, etc.).
    # The Nautilus overlay above puts them in Nautilus's closure separately.
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav

    # ── GTK theming ──────────────────────────────────────────────────────────
    adwaita-icon-theme     # Adwaita icon set (required by Nautilus)
    adw-gtk3               # Adwaita-compatible GTK3 theme (adw-gtk3-dark variant)
    gnome-themes-extra     # Additional GTK themes (includes Adwaita dark)
    gsettings-desktop-schemas  # GSettings schemas for desktop settings
    glib                   # GLib utilities (gsettings CLI tool)

    # ── System integration ───────────────────────────────────────────────────
    dconf        # GSettings dconf backend (also registers the GIO module)
    polkit_gnome # Polkit authentication agent for GTK environments
    udiskie      # Automount daemon with system tray, integrates with UDisks2

    # ── Viewers / utilities ──────────────────────────────────────────────────
    eog          # Eye of GNOME — image viewer
    totem        # GNOME video player (also provides A/V codec info)
    font-manager # Font preview and management
    p7zip        # 7-Zip support (available via file-roller)
    unrar-wrapper  # RAR archive support
    usbutils     # lsusb — diagnose USB/MTP detection issues
  ];
}
