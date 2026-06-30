{ config, lib, pkgs, ... }:

let
  # =========================================================================
  # primaryUser — the ONE knob a fresh-PC distro install edits.
  # The future installer ISO writes this line based on the username the user
  # entered at install time. Every other /home/<user>/... reference in this
  # config derives from it (via _module.args + home-manager.extraSpecialArgs).
  # =========================================================================
  primaryUser = "max";
  userHome    = "/home/${primaryUser}";
in
{
  # Make primaryUser + userHome available to every imported system module
  # (users.nix etc.) without threading them by hand.
  _module.args = { inherit primaryUser userHome; };

  imports = [
    ./hardware-configuration.nix
    ./modules/boot.nix
    ./modules/nvidia.nix
    ./modules/networking.nix
    ./modules/locale.nix
    ./modules/users.nix
    ./modules/desktop.nix
    ./modules/audio.nix
    ./modules/bluetooth.nix
    ./modules/power.nix
    ./modules/power-sleep.nix     # Suspend & hibernate (runtime, default-on)
    ./modules/disko-layout.nix    # Install-time disk scheme (default-off)
    ./modules/services.nix
    ./modules/packages.nix
    ./modules/standard-os-commit-tracking.nix
    ./modules/standard-os-update-state.nix
    ./modules/standard-os-update-polkit.nix
    ./home/modules/standardos-canvas-prefs.nix

    # Gaming — Bazzite-inspired gaming stack
    ./modules/gaming.nix

    # Web design / full-stack dev — runtimes, deploy CLIs, design apps, fonts
    ./modules/web-design.nix

    # Nautilus file manager — system-level config
    ./modules/nautilus-system.nix

    # Permissions (backlight, udev rules, etc.)
    ./modules/permissions.nix

    # Chrome — google-chrome with --password-store=basic
    ./modules/chrome.nix

    # Focus-or-launch — singleton-app rescue wrappers (wps, etc.)
    ./modules/focus-or-launch.nix

    # Home Manager as a NixOS module (channels, not flakes)
    <home-manager/nixos>
  ];

  # ---------------------------------------------------------------------------
  # Home Manager configuration for user max
  # ---------------------------------------------------------------------------
  home-manager = {
    useGlobalPkgs   = true;   # share nixpkgs with system (avoids double evaluation)
    useUserPackages = true;   # install home.packages into the user profile
    backupFileExtension = "hm-bak";  # back up conflicting files instead of failing

    # Propagate identity to every home-manager module so they can use
    # primaryUser / userHome in their function head.
    extraSpecialArgs = { inherit primaryUser userHome; };

    users.${primaryUser} = import ./home.nix;
  };

  services.chromeBasicPasswordStore.enable = true;

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # Hyprland Binds.conf — keybinds with brightness.sh script keybinds
  # ---------------------------------------------------------------------------
  system.activationScripts.hyprBindsConf =
    let
      bindsConf = pkgs.writeText "Binds.conf" ''
        # Key bindings
        $mainMod = SUPER

        # Custom binds
        bind = $mainMod, ESCAPE, exec, systemctl hibernate
        bind = $mainMod, SPACE, exec, rofi -show drun
        bind = $mainMod, E, exec, kitty
        bind = $mainMod, P, exec, grim -g "''$(slurp)"

        # Window management
        bind = $mainMod, Q, killactive
        bind = $mainMod, F, fullscreen
        bind = $mainMod, C, togglefloating
        bind = $mainMod, X, pseudo
        bind = $mainMod, R, togglesplit

        # Move window position
        bind = $mainMod SHIFT, A, movewindow, l
        bind = $mainMod SHIFT, D, movewindow, r
        bind = $mainMod SHIFT, W, movewindow, u
        bind = $mainMod SHIFT, S, movewindow, d

        # Move focus
        bind = $mainMod, A, movefocus, l
        bind = $mainMod, D, movefocus, r
        bind = $mainMod, W, movefocus, u
        bind = $mainMod, S, movefocus, d

        # Resize active window
        binde = $mainMod, right, resizeactive, 50 0
        binde = $mainMod, left, resizeactive, -50 0
        binde = $mainMod, up, resizeactive, 0 -50
        binde = $mainMod, down, resizeactive, 0 50

        # Move active window precisely
        binde = CONTROL, right, moveactive, 50 0
        binde = CONTROL, left, moveactive, -50 0
        binde = CONTROL, up, moveactive, 0 -50
        # binde = CONTROL, down, moveactive, 0 50   # uncomment if desired

        # Mouse bindings
        bindm = $mainMod, mouse:272, movewindow
        bindm = $mainMod, mouse:273, resizewindow

        # Workspace switching
        bind = $mainMod, 1, exec, ~/.config/hypr/scripts/1.sh
        bind = $mainMod, 2, exec, ~/.config/hypr/scripts/2.sh
        bind = $mainMod, 3, exec, ~/.config/hypr/scripts/3.sh
        bind = $mainMod, 4, exec, ~/.config/hypr/scripts/4.sh
        bind = $mainMod, 5, exec, ~/.config/hypr/scripts/5.sh
        bind = $mainMod, 6, exec, ~/.config/hypr/scripts/6.sh
        bind = $mainMod, 7, exec, ~/.config/hypr/scripts/7.sh
        bind = $mainMod, 8, exec, ~/.config/hypr/scripts/8.sh
        bind = $mainMod, 9, exec, ~/.config/hypr/scripts/9.sh

        # Move workspace to other monitor
        bind = $mainMod, TAB, focusmonitor, +1
        bind = $mainMod SHIFT, TAB, exec, ~/.config/hypr/scripts/10.sh

        # Move window to workspace
        bind = $mainMod SHIFT, 1, exec, ~/.config/hypr/scripts/11.sh
        bind = $mainMod SHIFT, 2, exec, ~/.config/hypr/scripts/12.sh
        bind = $mainMod SHIFT, 3, exec, ~/.config/hypr/scripts/13.sh
        bind = $mainMod SHIFT, 4, exec, ~/.config/hypr/scripts/14.sh
        bind = $mainMod SHIFT, 5, exec, ~/.config/hypr/scripts/15.sh
        bind = $mainMod SHIFT, 6, exec, ~/.config/hypr/scripts/16.sh
        bind = $mainMod SHIFT, 7, exec, ~/.config/hypr/scripts/17.sh
        bind = $mainMod SHIFT, 8, exec, ~/.config/hypr/scripts/18.sh
        bind = $mainMod SHIFT, 9, exec, ~/.config/hypr/scripts/19.sh
      '';
    in
    {
      text = ''
        install -d -m 755 ${userHome}/.config/hypr/modules
        install -m 644 ${bindsConf} ${userHome}/.config/hypr/modules/Binds.conf
      '';
      deps = [];
    };

  # ---------------------------------------------------------------------------
  # Hyprland volume script — simple volume control with 100% cap and mute
  # ---------------------------------------------------------------------------
  system.activationScripts.hyprVolumeScript =
    let
      volumeScript = pkgs.writeShellScript "volume.sh" ''
        MAX=100
        STEP=5

        if [[ "''${1}" == "mute" ]]; then
            wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
            exit 0
        fi

        current=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2 * 100)}')

        if [[ "''${1}" == "up" ]]; then
            target=$(( current + STEP ))
            (( target > MAX )) && target=$MAX
        elif [[ "''${1}" == "down" ]]; then
            target=$(( current - STEP ))
            (( target < 0 )) && target=0
        else
            exit 1
        fi

        wpctl set-volume @DEFAULT_AUDIO_SINK@ "''${target}%"
      '';
    in
    {
      text = ''
        install -d -m 755 ${userHome}/.config/hypr/scripts
        install -m 755 ${volumeScript} ${userHome}/.config/hypr/scripts/volume.sh
      '';
      deps = [];
    };

  # ---------------------------------------------------------------------------
  # Hyprland brightness script — simple brightness control with 2% floor
  # ---------------------------------------------------------------------------
  system.activationScripts.hyprBrightnessScript =
    let
      brightnessScript = pkgs.writeShellScript "brightness.sh" ''
        DEVICE="intel_backlight"
        MIN=2
        MAX=100
        STEP=5
        NIGHT_DIM_STATE="/tmp/night-dim-level"

        max_val=$(brightnessctl -d "$DEVICE" max)
        cur_val=$(brightnessctl -d "$DEVICE" get)
        current=$(( cur_val * 100 / max_val ))

        if [[ "''${1}" == "up" ]]; then
            target=$(( current + STEP ))
            (( target > MAX )) && target=$MAX
        elif [[ "''${1}" == "down" ]]; then
            target=$(( current - STEP ))
            (( target < MIN )) && target=$MIN
        else
            exit 1
        fi

        brightnessctl -d "$DEVICE" set "''${target}%" -q

        # Tear down the night-dim shader as soon as brightness climbs off
        # the 2% floor. The dim shader is only meaningful at the hardware
        # minimum; leaving it active above 2% silently shades the screen.
        #
        # Route through shader-stack so we only clear the dim slot — any
        # active texture shader (paper / newspaper) is preserved. Writing
        # decoration:screen_shader directly here was the source of the
        # paper-vs-dim stomping bug.
        if (( target > 2 )); then
            level=$(cat "$NIGHT_DIM_STATE" 2>/dev/null || echo 0)
            if (( level > 0 )); then
                ${userHome}/.config/waybar/scripts/shader-stack.sh clear dim >/dev/null 2>&1 || true
                printf '0' > "$NIGHT_DIM_STATE"
                pkill -RTMIN+10 waybar 2>/dev/null || true
            fi
        fi
      '';
    in
    {
      text = ''
        install -d -m 755 ${userHome}/.config/hypr/scripts
        install -m 755 ${brightnessScript} ${userHome}/.config/hypr/scripts/brightness.sh
      '';
      deps = [];
    };
}
