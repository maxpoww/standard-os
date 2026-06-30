# =============================================================================
# chrome.nix — google-chrome with --password-store=basic
#
# Silos Chrome saved passwords inside Chrome's own profile (basic obfuscation)
# instead of routing through the libsecret/gnome-keyring secret service.
# Pairs with the home-manager keyring-unlocked module: a libsecret app compro-
# mise can't reach Chrome's password bucket because Chrome no longer uses it.
#
# Requires google-chrome to expose 'commandLineArgs' as an override argument
# (it does, in nixpkgs 25.11). If a future bump removes it, this overlay fails
# loudly at eval time.
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.chromeBasicPasswordStore;
in
{
  options.services.chromeBasicPasswordStore.enable =
    lib.mkEnableOption "google-chrome --password-store=basic override";

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      (final: prev: {
        google-chrome = prev.google-chrome.override {
          commandLineArgs = "--password-store=basic";
        };
      })
    ];
  };
}
