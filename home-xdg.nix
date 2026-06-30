{ config, lib, pkgs, ... }:

# =============================================================================
# home-xdg.nix — XDG user directories (declarative, GTK + Qt aware)
# =============================================================================
# Writes ~/.config/user-dirs.dirs and ~/.config/user-dirs.locale, and creates
# every standard directory referenced by the freedesktop spec so apps that
# expect them (Wine, screenshot tools, LibreOffice, file managers, GTK and
# Qt file pickers) never fall back to $HOME or fail silently.
#
# Both GTK and Qt resolve these via the same mechanism: GTK reads
# user-dirs.dirs directly, Qt's QStandardPaths reads XDG_*_DIR env vars and
# falls back to the same file. One declaration covers both toolkits.
#
# Custom dirs (XDG_PROJECTS_DIR) go in extraConfig and are created by the
# activation script below — createDirectories only handles standard XDG.
# =============================================================================

let
  home = config.home.homeDirectory;
in
{
  xdg.userDirs = {
    enable            = true;
    createDirectories = true;

    desktop     = "${home}/Desktop";
    documents   = "${home}/Documents";
    download    = "${home}/Downloads";
    music       = "${home}/Music";
    pictures    = "${home}/Pictures";
    videos      = "${home}/Videos";
    templates   = "${home}/Templates";
    publicShare = "${home}/Public";

    extraConfig = {
      XDG_PROJECTS_DIR = "${home}/Projects";
    };
  };

  home.activation.createProjectsDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "${home}/Projects"
    '';

  # xdg-user-dirs ships the `xdg-user-dir` CLI; scripts and a few apps
  # (e.g. some screenshot tools) shell out to it instead of parsing the
  # config file. The home-manager option writes the file but doesn't pull
  # the package, so add it explicitly.
  home.packages = [ pkgs.xdg-user-dirs ];
}
