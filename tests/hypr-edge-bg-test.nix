{ pkgs ? import <nixpkgs> { } }:

# nixosTest for hypr-edge-bg.
#
# Strategy: replace hyprctl, grim, hyprpaper, gsettings, socat (events end) with
# scripted stubs that produce canned JSON / log invocations to side-channel files.
# Then drive scenarios by writing snapshots into the activities snapshot file and
# sending SIGUSR1 to the bg daemon, asserting on the hyprpaper-call log.

let
  scriptsDir = ../scripts;
in
pkgs.nixosTest {
  name = "hypr-edge-bg";

  nodes.machine = { config, pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      bash coreutils gawk gnused jq imagemagick
    ];

    # Stub binaries: install them with priority over real tools.
    environment.etc."hypr-edge-bg-stubs/hyprctl".source = pkgs.writeShellScript "hyprctl" ''
      printf '%s ' "$@" >>/tmp/hyprctl-call.log
      printf '\n' >>/tmp/hyprctl-call.log
      case "$1 $2" in
        "hyprpaper preload"|"hyprpaper wallpaper"|"hyprpaper unload")
          printf 'ok' ;;
        "activewindow -j")
          cat /tmp/fixtures/activewindow.json 2>/dev/null || echo '{}' ;;
        "monitors -j")
          cat /tmp/fixtures/monitors.json 2>/dev/null || echo '[]' ;;
        "clients -j")
          cat /tmp/fixtures/clients.json 2>/dev/null || echo '[]' ;;
        "getoption "*)
          echo '{"int":0}' ;;
        *) echo '{}' ;;
      esac
    '';

    environment.etc."hypr-edge-bg-stubs/grim".source = pkgs.writeShellScript "grim" ''
      # Emit a fixed-color PNG; the color is read from /tmp/fixtures/grim-hex.
      hex=$(cat /tmp/fixtures/grim-hex 2>/dev/null || echo aabbcc)
      ${pkgs.imagemagick}/bin/magick -size 1x1 "xc:#$hex" png:-
    '';

    environment.etc."hypr-edge-bg-stubs/gsettings".source = pkgs.writeShellScript "gsettings" ''
      v=$(cat /tmp/fixtures/dark 2>/dev/null || echo "'default'")
      printf "%s\n" "$v"
    '';
  };

  testScript = ''
    machine.start()
    machine.succeed("mkdir -p /tmp/fixtures /run/user/0 /tmp/hypr-edge-bg")
    machine.succeed("export XDG_RUNTIME_DIR=/run/user/0 XDG_STATE_HOME=/tmp/state")

    # Inject stubs ahead of $PATH.
    machine.succeed("ln -sf /etc/hypr-edge-bg-stubs/hyprctl /usr/local/bin/hyprctl || true")

    # === Scenario 1: empty workspace, dive=off, waypaper image present ===
    machine.succeed("mkdir -p /tmp/state/hypr-edge-bg && echo off > /tmp/state/hypr-edge-bg/dive")
    machine.succeed("echo '/tmp/fixtures/wp.jpg' > /tmp/wp_path && touch /tmp/fixtures/wp.jpg")
    # Build a minimal snapshot and feed the consumer directly.
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":0,"window_count":0,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"off","class":"","address":"","at":[0,0],"size":[0,0],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":false,"dark_theme":false}
      JSON
    """)

    # === Scenario 2: gaps off, single window, dive=on → match color ===
    machine.succeed("echo on > /tmp/state/hypr-edge-bg/dive && echo aabbcc > /tmp/fixtures/grim-hex")
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":1,"window_count":1,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"off","class":"foo","address":"0xaaa","at":[0,0],"size":[1920,1080],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[{"address":"0xaaa","at":[0,0],"size":[1920,1080],"workspace":{"id":1}}],"waypaper_bg":"","waypaper_changed":false,"dark_theme":false}
      JSON
    """)

    # === Scenario 3: dive=on, gapson, two windows → mixed ===
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":1,"window_count":2,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"on","class":"foo","address":"0xaaa","at":[0,0],"size":[960,1080],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[{"address":"0xaaa","at":[0,0],"size":[960,1080],"workspace":{"id":1}},{"address":"0xbbb","at":[960,0],"size":[960,1080],"workspace":{"id":1}}],"waypaper_bg":"","waypaper_changed":false,"dark_theme":false}
      JSON
    """)

    # === Scenario 4: silent dive-off via waypaper change ===
    machine.succeed("""
      cat > /run/user/0/hypr-activities.json <<'JSON'
      {"flag":0,"window_count":0,"workspace":1,"fullscreen":0,"floating":false,"pseudo":false,"grouped":false,"gaps":"off","class":"","address":"","at":[0,0],"size":[0,0],"focused_monitor":"DP-1","monitors":[{"name":"DP-1","width":1920,"height":1080}],"clients":[],"waypaper_bg":"/tmp/fixtures/wp.jpg","waypaper_changed":true,"dark_theme":false}
      JSON
    """)

    # NOTE: Full daemon orchestration in the VM requires Hyprland; this sketch
    # demonstrates fixture shape. The unit-level tests in tests/colors-test.sh
    # cover the math deterministically.
  '';
}
