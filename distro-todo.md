# Distro cleanup TODO

Operational TODO list for getting `focus/` to fully declarative, distro-ready
state. Each item is a self-contained follow-up; nothing here blocks shipping
voice-dictation as-is.

Last updated: 2026-05-21

---

## 1. VAD pre-filter for voice-dictation

**Symptom:** whisper.cpp hallucinates phantom phrases on silent / very-quiet
clips. Observed: "Thank you.", "Welcome", "El evento", Russian subtitle
credits. The `dictate-toggle` script's empty-text guard does not catch these
because Whisper's output isn't actually empty.

**Fix:** add a voice activity detection step between `pw-record` and
`whisper-cli`. If no speech-band energy is detected in the clip, abort with
"No speech detected" instead of feeding silence to Whisper.

**Library options (small → large):**
- `webrtcvad` (≈30 KB, integer-only, ships in nixpkgs as
  `python3Packages.webrtcvad`). The standard choice.
- `silero-vad` (PyTorch model, larger, more accurate, multilingual).

**Where:** new helper inside `services.voiceDictation`, called between the
pw-record stop and the whisper-cli invocation in `dictate-toggle`. Add an
option `services.voiceDictation.vad.enable` (default true).

---

## 2. Port Hyprland modular config into home-manager

**Symptom:** `~/.config/hypr/hyprland.conf` is hand-written (not Nix-managed),
sourcing 17 hand-written files under `~/.config/hypr/modules/*.conf`. As a
result, `wayland.windowManager.hyprland.settings.*` declarations in
`/etc/nixos/home-nautilus.nix` and `home-screen-type.nix` have been
silently inactive — the SUPER+N → nautilus bind has never worked.

**Fix:** create `services.hyprlandConfig` (or extend the existing pattern)
that owns `~/.config/hypr/{hyprland.conf,modules/*.conf}` via
`xdg.configFile` with `force = true`, mirroring how `services.waybarBar`
already manages `~/.config/waybar/{config.jsonc,style.css}`.

**Files to bring under Nix:**
- `~/.config/hypr/hyprland.conf` (19 lines, source = list)
- `~/.config/hypr/modules/Animations.conf`
- `~/.config/hypr/modules/Autostart.conf`
- `~/.config/hypr/modules/Binds.conf`
- `~/.config/hypr/modules/Devices.conf`
- `~/.config/hypr/modules/Dispatchers.conf`
- `~/.config/hypr/modules/Environment_Variables.conf`
- `~/.config/hypr/modules/Gestures.conf`
- `~/.config/hypr/modules/Hypr_Ecosystem.conf`
- `~/.config/hypr/modules/Monitors.conf`
- `~/.config/hypr/modules/Nix.conf`
- `~/.config/hypr/modules/Nvidia.conf`
- `~/.config/hypr/modules/Performance.conf`
- `~/.config/hypr/modules/Permissions.conf`
- `~/.config/hypr/modules/Plugins.conf`
- `~/.config/hypr/modules/Visual.conf`
- `~/.config/hypr/modules/Window_Rules.conf`
- `~/.config/hypr/modules/Workspace_Rules.conf`

**Layout suggestion:** mirror the `focus/waybar/` pattern — keep the source
files as plain `.conf` text under `focus/hypr/modules/`, with a Nix module
under `focus/modules/hyprland.nix` that wires each one via `xdg.configFile`.
Hardware-specific bits (Monitors, Nvidia, Devices) should be parameterised
via module options so the same module ships across machines.

**Migration risk:** the user's hand-written config is the source of truth for
their current desktop behavior. Diff before-and-after carefully. The
`Binds.conf` and `Monitors.conf` files are highest-risk because they're
most user-specific.

**Side-effect fix:** once hyprland.conf is Nix-managed, drop the explicit
`source = ~/.config/hypr/modules/VoiceDictation.conf` line that was added
imperatively during voice-dictation install; emit it from Nix instead.

---

## 3. Port waybar custom scripts into home-manager

**Symptom:** `~/.config/waybar/config.jsonc` is now Nix-managed (since
voice-dictation install), but the scripts it references at
`~/.config/waybar/scripts/*.sh` and `~/.config/waybar/offers/empty-dock/`
are still loose files in the home tree — not reproducible on a fresh
install.

**Files to bring under Nix:**
- `~/.config/waybar/scripts/win-action.sh`
- `~/.config/waybar/scripts/swap-smart.sh`
- `~/.config/waybar/scripts/warm-cycle.sh`
- `~/.config/waybar/scripts/shader-toggle.sh`
- `~/.config/waybar/scripts/night-dimmer.sh`
- `~/.config/waybar/scripts/restore-minimized.sh`
- `~/.config/waybar/scripts/screen-type.sh`
- `~/.config/waybar/offers/empty-dock/waybar-monitor.sh`
- Anything else referenced from `config.jsonc` via `exec` or `on-click`.

**Fix:** wrap each as `pkgs.writeShellApplication`, expose via `home.packages`,
and rewrite the `exec` / `on-click` lines in `focus/waybar/config.jsonc` to
call the wrapper names directly (e.g. `"exec": "warm-cycle exec"` instead
of `"exec": "~/.config/waybar/scripts/warm-cycle.sh exec"`). That removes
the dependency on absolute home paths and makes the bar fully
reproducible.

**Pattern reference:** see `focus/modules/voice-dictation.nix` —
`dictateToggle` is a worked example of `writeShellApplication` with
`runtimeInputs` for the bash dependencies.

---

## 4. Fix the chowned hyprland.conf

**Symptom:** during voice-dictation install we ran
`sudo chown -R max:users ~/.config/hypr` because the directory was
root-owned and home-manager couldn't drop symlinks into it. That's a
side-effect of a past root-mode rebuild — fine for now but the distro's
installer / first-boot activation should never leave `~/.config/*` as
root-owned.

**Fix:** identify which step in the user's existing NixOS setup wrote those
files as root and either change it to user, or add an `home.activation`
chown at the top of the activation chain that defensively reclaims
`~/.config` for the user.

---

## 5. Move the voice-dictation source-line out of imperative state

**Symptom:** during voice-dictation install we appended one line:
`source = ~/.config/hypr/modules/VoiceDictation.conf` to
`~/.config/hypr/hyprland.conf` by hand. That line is the only piece of the
voice-dictation install that isn't declarative.

**Fix:** resolved automatically once item #2 (Hyprland config under
home-manager) lands — the Nix-managed hyprland.conf can include the
source line directly.

---

## Done / decided

- Voice-dictation feature lands as `services.voiceDictation.enable = true;` at
  `/home/max/focus/modules/voice-dictation.nix`. CUDA optional. Multilingual.
  Mic-in-use indicator daemon included.
- Waybar declarative at `/home/max/focus/modules/waybar.nix` (config.jsonc +
  style.css).
- Whisper model pinned by SHA256; future bumps documented in module options.
