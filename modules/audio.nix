{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Audio
  # ---------------------------------------------------------------------------
  services.pipewire = {
    enable            = true;
    alsa.enable       = true;
    alsa.support32Bit = true;
    pulse.enable      = true;
    jack.enable       = true;
  };

  services.pipewire.wireplumber.extraConfig."10-no-suspend-tas2781" = {
    "monitor.alsa.rules" = [{
      matches = [{ "node.name" = "~alsa_output.*"; }];
      actions.update-props = {
        "session.suspend-timeout-seconds" = 0;
      };
    }];
  };

  # Prevent bluetooth headsets from auto-switching to HSP/HFP profile when
  # any audio capture client connects. cava listens on the sink monitor and
  # would otherwise trigger the switch — that flips A2DP stereo off, drops
  # quality, and lights up the "mic in use" tray indicator.
  services.pipewire.wireplumber.extraConfig."51-bluez-no-autoswitch" = {
    "monitor.bluez.properties" = {
      "bluez5.autoswitch-profile" = false;
    };
  };

  security.rtkit.enable = true;

  # Keep TAS2781 amp DSP state alive between tracks
  # Plays inaudible silence to prevent the HDA controller from power-gating the amp
  systemd.user.services.audio-keepalive = {
    description   = "TAS2781 audio keepalive — Slim Pro 9i";
    wantedBy      = [ "default.target" ];
    after         = [ "pipewire.service" "pipewire-pulse.service" ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "always";
      RestartSec = "2s";
      ExecStart  = "${pkgs.ffmpeg-full}/bin/ffplay -nodisp -autoexit -f lavfi -i anullsrc=r=44100:cl=mono -loglevel quiet";
    };
  };
}
