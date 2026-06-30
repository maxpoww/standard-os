{ config, lib, pkgs, ... }:

# ============================================================================
# focus-or-launch.nix — declarative singleton-app rescue wrappers
#
# Some apps (wpsoffice, slack, etc.) are singletons: a second launch is
# silently forwarded to the existing process. If that process's window has
# been moved to a hidden workspace (Hyprland's special:special), the user
# has no way back — re-launching does nothing visible.
#
# This module wraps named binaries with a thin script that, before exec'ing
# the real binary:
#   - no window of the matching class exists       → exec normally
#   - a window exists on the ACTIVE workspace      → just focus it, then exec
#   - a window exists on the SPECIAL workspace     → drag it to the active
#                                                    workspace, focus, exec
#   - a window exists on ANOTHER normal workspace  → focus it (Hyprland
#                                                    switches to that ws)
#
# Wrappers shadow the real binary on PATH via lib.hiPrio, so desktop files
# (`Exec=wps %F`) and shell launches both pick up the new behavior with no
# changes elsewhere.
# ============================================================================

let
  cfg = config.standardos.focusOrLaunch;

  hyprctl = "${pkgs.hyprland}/bin/hyprctl";
  jq      = "${pkgs.jq}/bin/jq";

  focusOrLaunch = pkgs.writeShellScript "focus-or-launch" ''
    set -u
    CLASS_RE="$1"; shift
    REAL="$1";    shift

    existing=$(${hyprctl} clients -j \
      | ${jq} -c --arg c "$CLASS_RE" \
        '[ .[] | select(.class | test($c)) ]')

    count=$(printf '%s' "$existing" | ${jq} 'length')
    if [ "$count" -eq 0 ]; then
      exec "$REAL" "$@"
    fi

    active_ws=$(${hyprctl} activeworkspace -j | ${jq} -r '.id')

    # Already on the active workspace → just focus and forward.
    on_active=$(printf '%s' "$existing" | ${jq} -r --argjson a "$active_ws" \
      '[ .[] | select(.workspace.id == $a) | .address ] | .[0] // empty')
    if [ -n "$on_active" ]; then
      ${hyprctl} dispatch focuswindow "address:$on_active" >/dev/null
      exec "$REAL" "$@"
    fi

    # Hidden (special) workspace → drag to active, then focus.
    hidden=$(printf '%s' "$existing" | ${jq} -r \
      '[ .[] | select(.workspace.id < 0) | .address ] | .[0] // empty')
    if [ -n "$hidden" ]; then
      ${hyprctl} dispatch movetoworkspace "$active_ws,address:$hidden" >/dev/null
      ${hyprctl} dispatch focuswindow "address:$hidden" >/dev/null
      exec "$REAL" "$@"
    fi

    # Another normal workspace → take the user there.
    other=$(printf '%s' "$existing" | ${jq} -r '.[0].address')
    ${hyprctl} dispatch focuswindow "address:$other" >/dev/null
    exec "$REAL" "$@"
  '';

  wrap = entry:
    let
      bin = if entry.bin != null then entry.bin else entry.name;

      wrapperBin = pkgs.writeShellScriptBin entry.name ''
        exec ${focusOrLaunch} ${lib.escapeShellArg entry.class} \
          ${entry.package}/bin/${bin} "$@"
      '';

      # Desktop files in nixpkgs's wpsoffice (and similar) hardcode the
      # ABSOLUTE store path to the binary — that bypasses PATH and our
      # wrapper. Shadow each colliding .desktop with a version whose
      # Exec= calls the wrapper name through PATH instead.
      desktopShadow = pkgs.runCommand "${entry.name}-desktop-shadow" {
        nativeBuildInputs = [ pkgs.gnused ];
      } ''
        mkdir -p $out/share/applications
        for src in ${entry.package}/share/applications/*.desktop; do
          [ -e "$src" ] || continue
          if grep -qE "/bin/${bin}( |$)" "$src"; then
            base=$(basename "$src")
            sed -E "s|Exec=[^ ]*/bin/${bin}( .*)?$|Exec=${entry.name}\1|" \
              "$src" > "$out/share/applications/$base"
          fi
        done
      '';
    in
    lib.hiPrio (pkgs.symlinkJoin {
      name = "${entry.name}-focus-or-launch";
      paths = [ wrapperBin desktopShadow ];
    });

  appType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Binary name to shadow on PATH (e.g. \"wps\").";
      };
      class = lib.mkOption {
        type = lib.types.str;
        description = "Hyprland window-class regex passed to jq's test() (e.g. \"^wps$\").";
      };
      package = lib.mkOption {
        type = lib.types.package;
        description = "Package that provides the real binary.";
      };
      bin = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Real binary inside the package, if it differs from `name`.";
      };
    };
  };
in
{
  options.standardos.focusOrLaunch = lib.mkOption {
    type = lib.types.listOf appType;
    default = [];
    example = lib.literalExpression ''
      [
        { name = "wps"; class = "^wps$"; package = pkgs.wpsoffice; }
        { name = "wpp"; class = "^wpp$"; package = pkgs.wpsoffice; }
        { name = "et";  class = "^et$";  package = pkgs.wpsoffice; }
      ]
    '';
    description = ''
      Singleton apps to wrap with focus-or-launch behavior. Each entry adds
      a hiPrio wrapper that rescues a hidden window or switches the user to
      the workspace that already owns the existing window before forwarding
      to the real binary.
    '';
  };

  config.environment.systemPackages = map wrap cfg;
}
