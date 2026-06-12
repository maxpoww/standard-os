# =============================================================================
# voice-dictation.nix — push-to-talk voice dictation via whisper.cpp
#
# A home-manager module that adds a system-wide, push-to-talk-style voice
# dictation feature: a hotkey toggles recording, transcription runs locally
# with whisper.cpp, and the resulting text is typed into the focused window
# via wtype. A waybar custom module ("custom/dictate") reflects state via a
# Nerd Font microphone glyph (green when recording, amber when transcribing,
# hidden when idle).
#
# Designed to ship in a distro: opt-in via `services.voiceDictation.enable`,
# CUDA acceleration optional, all paths derived from Nix.
#
# Usage:
#   services.voiceDictation = {
#     enable       = true;
#     cudaSupport  = true;        # set false on machines without NVIDIA
#     hotkey       = "SUPER ALT, Space";
#     language     = "auto";
#   };
#
# To disable: set enable = false (or comment the import) and rebuild.
# =============================================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.voiceDictation;

  # The whisper.cpp package, optionally with CUDA acceleration.
  whisperCpp =
    if cfg.cudaSupport
    then pkgs.whisper-cpp.override { cudaSupport = true; }
    else pkgs.whisper-cpp;

  # The Whisper model file, fetched once and pinned by content hash.
  whisperModel = pkgs.fetchurl {
    url    = cfg.model.url;
    sha256 = cfg.model.sha256;
  };

  # Two short tones (start/stop) synthesized at build time with ffmpeg.
  beeps = pkgs.runCommand "voice-dictation-beeps" {
    nativeBuildInputs = [ pkgs.ffmpeg ];
  } ''
    mkdir -p $out
    # 800 Hz start blip, 80 ms, 5 ms fade in/out.
    ffmpeg -nostdin -loglevel error \
      -f lavfi -i "sine=frequency=800:duration=0.08" \
      -af "afade=t=in:st=0:d=0.005,afade=t=out:st=0.075:d=0.005,volume=0.4" \
      -ar 48000 -ac 1 $out/start.wav
    # 400 Hz stop blip, same envelope.
    ffmpeg -nostdin -loglevel error \
      -f lavfi -i "sine=frequency=400:duration=0.08" \
      -af "afade=t=in:st=0:d=0.005,afade=t=out:st=0.075:d=0.005,volume=0.4" \
      -ar 48000 -ac 1 $out/stop.wav
  '';

  # The script bound to the hotkey: starts recording on first press, stops &
  # transcribes & types on second press.
  dictateToggle = pkgs.writeShellApplication {
    name = "dictate-toggle";
    runtimeInputs = with pkgs; [
      pipewire        # pw-record, pw-cat
      wireplumber     # wpctl (unmute / inspect default source)
      whisperCpp      # whisper-cli
      wtype
      wl-clipboard    # wl-copy fallback
      libnotify       # notify-send
      coreutils
      procps          # pkill
      gnused
      gawk
    ];
    text = ''
      set -uo pipefail

      STATE_DIR=/tmp/waybar-cache
      STATE=$STATE_DIR/dictate
      PIDF=/tmp/dictate.pid
      WAV=/tmp/dictate.wav
      TXT_BASE=/tmp/dictate
      TXT=$TXT_BASE.txt
      BUSY=/tmp/dictate.busy

      START_WAV="${beeps}/start.wav"
      STOP_WAV="${beeps}/stop.wav"
      MODEL="${whisperModel}"
      LANGUAGE="${cfg.language}"
      SIGNAL="${toString cfg.waybarSignal}"

      # Nerd Font microphone glyph (U+F130). Built from its UTF-8 byte
      # sequence so the source file never has to hold a Private-Use-Area
      # codepoint directly — some editors and transport layers strip PUA
      # characters silently. \xEF\x84\xB0 is the UTF-8 encoding of U+F130.
      MIC_GLYPH=$(printf "\xef\x84\xb0")

      mkdir -p "$STATE_DIR"

      write_state() {
        # $1 = idle|recording|transcribing
        # `class` MUST be a JSON array — waybar/GTK 3 treats a space-separated
        # string as a single class name (see waybar/CLAUDE.md "Known hazards").
        # The opt-pill class is mandatory: it carries the canonical pill
        # geometry (font-size 13px, padding 3/8, border-radius 30px). Without
        # it the pill falls back to the universal `* { font-size:13px }` rule
        # but loses padding/background and looks wrong next to its neighbours.
        # Theme: read /tmp/glass-mode fresh per emit so the pill flips text
        # color when the wallpaper changes (defense in depth against the
        # glass-text-daemon central rewrite).
        local theme
        theme=$(cat /tmp/glass-mode 2>/dev/null) || theme=dark
        case "$theme" in light|dark) ;; *) theme=dark ;; esac
        case "$1" in
          idle)
            printf '{"text":""}\n' > "$STATE"
            ;;
          recording)
            printf '{"text":"%s","tooltip":"Recording…","class":["opt-pill","%s","recording"],"alt":"recording"}\n' \
              "$MIC_GLYPH" "$theme" > "$STATE"
            ;;
          transcribing)
            printf '{"text":"%s","tooltip":"Transcribing…","class":["opt-pill","%s","transcribing"],"alt":"transcribing"}\n' \
              "$MIC_GLYPH" "$theme" > "$STATE"
            ;;
        esac
        # Tell waybar to re-render the custom/dictate module.
        pkill "-RTMIN+$SIGNAL" waybar >/dev/null 2>&1 || true
      }

      notify() {
        notify-send -a "voice-dictation" -t 3000 "$1" "''${2:-}" || true
      }

      play() {
        # Fire-and-forget; never block the user.
        pw-cat -p "$1" >/dev/null 2>&1 &
      }

      # --- Reject overlapping toggles during transcription. -------------------
      if [ -f "$BUSY" ]; then
        notify "Voice dictation" "Still transcribing… please wait."
        exit 0
      fi

      # --- STOP branch: a recording is in progress. ---------------------------
      if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        RECPID=$(cat "$PIDF")
        touch "$BUSY"
        write_state transcribing
        play "$STOP_WAV"

        # Send SIGINT so pw-record flushes the WAV header.
        kill -INT "$RECPID" 2>/dev/null || true
        # Wait up to 2 s for the recorder to exit.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          if ! kill -0 "$RECPID" 2>/dev/null; then break; fi
          sleep 0.2
        done
        rm -f "$PIDF"

        if [ ! -s "$WAV" ]; then
          notify "Voice dictation" "No audio captured."
          write_state idle
          rm -f "$WAV" "$BUSY"
          exit 0
        fi

        # Transcribe. whisper-cli writes "$TXT_BASE.txt".
        if ! whisper-cli \
              --model "$MODEL" \
              --file  "$WAV" \
              --language "$LANGUAGE" \
              --no-prints \
              --output-txt \
              --output-file "$TXT_BASE" \
              --threads "$(nproc)" 2> /tmp/dictate.err; then
          ERR=$(tail -n 2 /tmp/dictate.err | tr '\n' ' ')
          notify "Transcription failed" "$ERR"
          write_state idle
          rm -f "$WAV" "$TXT" "$BUSY"
          exit 1
        fi

        TEXT=$(tr -d '\r' < "$TXT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        if [ -z "$TEXT" ]; then
          notify "Voice dictation" "No speech detected."
        elif ! printf '%s' "$TEXT" | wtype - 2>/dev/null; then
          # wtype may fail if the focused surface doesn't expose the virtual-keyboard protocol.
          printf '%s' "$TEXT" | wl-copy
          notify "Voice dictation" "Transcription on clipboard — paste manually."
        fi

        # Restore the mic's prior mute state, if we touched it on start.
        if [ -f /tmp/dictate.prior-mute ]; then
          wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1 >/dev/null 2>&1 || true
          rm -f /tmp/dictate.prior-mute
        fi

        write_state idle
        rm -f "$WAV" "$TXT" "$BUSY"
        exit 0
      fi

      # --- START branch: no recording in progress (or stale pidfile). ---------
      rm -f "$PIDF" "$WAV" "$TXT" "$BUSY"

      # Ensure the default audio source isn't muted — pipewire will happily
      # record silence from a muted mic, which Whisper turns into hallucinated
      # text (e.g. "Thank you."). Save the prior mute state so we can restore
      # it after the recording finishes.
      PRIOR_MUTE=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -o '\[MUTED\]' || true)
      if [ -n "$PRIOR_MUTE" ]; then
        wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 >/dev/null 2>&1 || true
        printf '%s\n' muted > /tmp/dictate.prior-mute
      else
        rm -f /tmp/dictate.prior-mute
      fi

      write_state recording
      play "$START_WAV"

      # 16 kHz mono is what whisper.cpp expects internally; using it here
      # saves a resample later.
      pw-record --format=s16 --rate=16000 --channels=1 "$WAV" \
        > /tmp/dictate.recerr 2>&1 &
      echo $! > "$PIDF"

      # Give pw-record a moment to actually open the source. If it dies in
      # under 300 ms, the mic is unavailable — bail out cleanly.
      sleep 0.3
      if ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        ERR=$(tail -n 2 /tmp/dictate.recerr | tr '\n' ' ')
        notify "Mic unavailable" "$ERR"
        # Restore prior mute state if we toggled it on start.
        if [ -f /tmp/dictate.prior-mute ]; then
          wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1 >/dev/null 2>&1 || true
          rm -f /tmp/dictate.prior-mute
        fi
        write_state idle
        rm -f "$PIDF" "$WAV"
        exit 1
      fi
    '';
  };

  # The script waybar invokes to read current state.
  #
  # State file priority (highest wins, so the icon reflects what the user
  # most cares about right now):
  #   1. dictation transcribing  → amber mic, tooltip "Transcribing…"
  #   2. dictation recording      → green mic, tooltip "Recording…"
  #   3. mic-in-use (any other app capturing audio) → green mic,
  #      tooltip "Mic in use: <comma-separated app list>"
  #   4. idle                     → empty text (module renders nothing)
  dictateWaybar = pkgs.writeShellApplication {
    name = "dictate-waybar";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -u
      DICT=/tmp/waybar-cache/dictate
      MIC=/tmp/waybar-cache/mic-monitor

      MIC_GLYPH=$(printf "\xef\x84\xb0")

      dict_state=""
      if [ -r "$DICT" ]; then
        dict_state=$(cat "$DICT")
      fi

      # Dictation transcribing or recording — pass the dictate state JSON
      # through unchanged so its tooltip/class wins. The state file emits
      # class as a JSON array (see write_state in voice-dictation.nix), so
      # match the array form, e.g. `"class":["opt-pill","dark","recording"]`.
      case "$dict_state" in
        *'"recording"'*|*'"transcribing"'*)
          printf '%s\n' "$dict_state"
          exit 0
          ;;
      esac

      # Otherwise check if any other app is holding the mic. Emit class as a
      # JSON array including `opt-pill` so the pill picks up canonical
      # geometry (13px font, padding, border-radius) instead of GTK defaults.
      apps=""
      if [ -r "$MIC" ]; then
        apps=$(cat "$MIC")
      fi
      if [ -n "$apps" ]; then
        theme=$(cat /tmp/glass-mode 2>/dev/null) || theme=dark
        case "$theme" in light|dark) ;; *) theme=dark ;; esac
        printf '{"text":"%s","tooltip":"Mic in use: %s","class":["opt-pill","%s","recording"],"alt":"mic-active"}\n' \
          "$MIC_GLYPH" "$apps" "$theme"
        exit 0
      fi

      printf '{"text":""}\n'
    '';
  };

  # Daemon that polls pipewire and writes the comma-joined list of apps
  # currently holding an input stream to /tmp/waybar-cache/mic-monitor.
  # When the list changes, it signals waybar so the indicator updates.
  micMonitor = pkgs.writeShellApplication {
    name = "dictate-mic-monitor";
    runtimeInputs = with pkgs; [ pipewire jq coreutils procps ];
    text = ''
      set -uo pipefail

      STATE=/tmp/waybar-cache/mic-monitor
      SIGNAL="${toString cfg.waybarSignal}"
      INTERVAL=0.5

      mkdir -p "$(dirname "$STATE")"
      : > "$STATE"          # truncate the state file to empty
      prev=""

      while true; do
        # Inspect every Pipewire node, keep input streams in the "running"
        # state, and grab a human-readable app name. node.name is the most
        # consistent fallback when application.name isn't set.
        # `stream.capture.sink == true` is PipeWire's flag for "this stream
        # is reading a sink monitor, not a microphone". Visualizers like cava
        # set it; real mic apps (zoom, recordings) do not. Excluding those
        # keeps the indicator focused on actual microphone use.
        apps=$(pw-dump 2>/dev/null | jq -r '
          [ .[]
            | select(.type=="PipeWire:Interface:Node")
            | select(.info.props["media.class"]=="Stream/Input/Audio")
            | select(.info.state=="running")
            | select((.info.props["stream.capture.sink"] // false) != true)
            | (.info.props["application.name"]
               // .info.props["application.process.binary"]
               // .info.props["node.name"]
               // "unknown")
          ] | unique | join(", ")' 2>/dev/null || true)
        apps=''${apps:-}

        if [ "$apps" != "$prev" ]; then
          printf '%s' "$apps" > "$STATE"
          pkill "-RTMIN+$SIGNAL" waybar >/dev/null 2>&1 || true
          prev="$apps"
        fi
        sleep "$INTERVAL"
      done
    '';
  };

in
{
  options.services.voiceDictation = {
    enable = lib.mkEnableOption "push-to-talk voice dictation (whisper.cpp + wtype)";

    cudaSupport = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build whisper.cpp with CUDA acceleration. Set true on machines with
        an NVIDIA GPU; leave false otherwise (transcription falls back to CPU).
      '';
    };

    hotkey = lib.mkOption {
      type = lib.types.str;
      default = "SUPER ALT, Space";
      description = ''
        Hyprland bind key combination. The bind is wired via extraConfig as
        `bind = <hotkey>, exec, dictate-toggle`.
      '';
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = ''
        Whisper language code passed to `whisper-cli --language`. "auto"
        autodetects per clip; "en", "es", etc. force a specific language.
      '';
    };

    waybarSignal = lib.mkOption {
      type = lib.types.ints.between 1 30;
      default = 11;
      description = ''
        RTMIN+N signal number used to ask waybar to re-render the dictate
        module. Must match the `signal` field in the waybar custom/dictate
        module definition. Default 11 (1–10 are commonly reserved).
      '';
    };

    model = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
        description = "URL of the ggml Whisper model to fetch.";
      };
      sha256 = lib.mkOption {
        type = lib.types.str;
        default = "sha256-H8cPd0046xaZk6w5Huo1fvR8iHV+9y7llDh5t+jivGk=";
        description = ''
          SRI hash of the model file. To switch models: change `url`, set
          `sha256` to `lib.fakeSha256`, build, copy the reported hash here.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      whisperCpp
      dictateToggle
      dictateWaybar
      micMonitor
      pkgs.wtype
      pkgs.wl-clipboard
      pkgs.libnotify
      pkgs.jq
    ];

    # Background daemon that watches pipewire for active input streams and
    # writes the app list to /tmp/waybar-cache/mic-monitor. Bound to the
    # graphical session so it starts/stops with the user's desktop.
    systemd.user.services.dictate-mic-monitor = {
      Unit = {
        Description = "voice-dictation: indicator daemon for mic-in-use state";
        PartOf = [ "graphical-session.target" ];
        After  = [ "graphical-session.target" ];
      };
      Install = { WantedBy = [ "graphical-session.target" ]; };
      Service = {
        Type      = "simple";
        ExecStart = "${micMonitor}/bin/dictate-mic-monitor";
        Restart   = "always";
        RestartSec = 1;
      };
    };

    xdg.configFile = {
      "waybar/offers/dictate/start.wav".source = "${beeps}/start.wav";
      "waybar/offers/dictate/stop.wav".source  = "${beeps}/stop.wav";

      # Hyprland keybind. The user's hyprland.conf is currently hand-written
      # and sources ~/.config/hypr/modules/*.conf, so we drop our bind there
      # under a unique filename. The user adds one `source = ...` line to
      # hyprland.conf once; from then on every change to cfg.hotkey
      # reproduces declaratively without touching hyprland.conf again.
      #
      #   source = ~/.config/hypr/modules/VoiceDictation.conf
      "hypr/modules/VoiceDictation.conf" = {
        text  = ''
          # Generated by services.voiceDictation — do not edit by hand.
          bind = ${cfg.hotkey}, exec, dictate-toggle
        '';
        force = true;
      };
    };

    # Reset stale state on each rebuild so the waybar dot is never stuck
    # after a crash, suspend, or reboot.
    home.activation.resetDictateState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p /tmp/waybar-cache
      printf '{"text":""}\n' > /tmp/waybar-cache/dictate
      rm -f /tmp/dictate.pid /tmp/dictate.busy /tmp/dictate.wav /tmp/dictate.txt
    '';
  };
}
