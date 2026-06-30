# Records the /etc/nixos/home HEAD SHA at every nixos-rebuild switch.
# /run is a tmpfs, so the file regenerates at every boot from the
# already-activated derivation. The waybar-self-test rebuild-pending
# check + standard-os-shutdown-guard pre-shutdown gate both use this
# file as ground truth for "is the working tree ahead of the running
# system?"
#
# safe.directory: the activation script runs as root, but /etc/nixos/home
# is owned by user max. Git 2.35+ refuses to operate on repos owned by
# a different user ("dubious ownership") unless safe.directory is set.
# We override per-invocation rather than touching global config.
{ pkgs, lib, ... }:
{
  system.activationScripts.standardOsCommit = lib.stringAfter [ "users" ] ''
    mkdir -p /run/standard-os
    if [ -d /etc/nixos/.git ]; then
      ${pkgs.git}/bin/git -c safe.directory=/etc/nixos \
        -C /etc/nixos rev-parse HEAD \
        > /run/standard-os/activated-commit 2>/dev/null || true
    fi
  '';
}
