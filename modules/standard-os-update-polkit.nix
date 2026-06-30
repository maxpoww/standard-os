# polkit rule for the UPDATE pipeline.
# Allows wheel-group users to pkexec the four nix binaries the pipeline
# uses, without a password prompt. Scope is exactly:
#   - /run/current-system/sw/bin/nixos-rebuild
#   - /run/current-system/sw/bin/nix-channel
#   - /run/current-system/sw/bin/nix-collect-garbage
#   - /run/current-system/sw/bin/nix-store
# subject.local && subject.active limits to interactively-logged-in users.
# L1 only needs nixos-rebuild; the others are listed up-front so L2–L4
# don't need to touch this file again.
{ ... }:
{
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id !== "org.freedesktop.policykit.exec") return;
      if (!subject.local || !subject.active) return;
      if (!subject.isInGroup("wheel")) return;
      var program = action.lookup("program");
      var allowed = [
        "/run/current-system/sw/bin/nixos-rebuild",
        "/run/current-system/sw/bin/nix-channel",
        "/run/current-system/sw/bin/nix-collect-garbage",
        "/run/current-system/sw/bin/nix-store"
      ];
      if (allowed.indexOf(program) !== -1) {
        return polkit.Result.YES;
      }
    });
  '';
}
