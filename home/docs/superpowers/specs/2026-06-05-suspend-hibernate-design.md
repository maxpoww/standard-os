# Suspend & Hibernate — Design Spec

**Date:** 2026-06-05
**Status:** Approved, ready for implementation plan
**Related:** `2026-05-21-distro-portability-design.md` (modules referenced here ship under the same distro-portable layout)

## Goal

A perfect-by-default suspend & hibernate system for Standard-OS. On any Standard-OS machine, Sleep and Hibernate must:

- **Just work** — hibernate currently does not resume on this host (no `resume=` kernel param); fix that first.
- **Resume as fast as possible** — lz4 swap compression, NVIDIA preservation, minimal post-resume work.
- **Resume reliably** — a two-pass health-check verifies every flake-prone subsystem (audio, network, GPU, time, WM, Bluetooth, OPTIONS daemons) and remediates what it can.
- **Be declarative, default-on, hardware-agnostic** — one NixOS module shipped enabled; one assertion catches misconfiguration at build time.
- **Surface through OPTIONS** — repurposes the existing `group/group-power` cluster, adds one new failure pill, no new colors/motions/surfaces (closed-budget preserved).

## Non-goals

- **Building the installer ISO.** This spec ships the disko module that describes the canonical disk layout; consuming it from an installer flow is downstream.
- **Swap on a swapfile.** v1 requires a swap partition. Swapfile hibernation needs `resume_offset` computation and is hard-erroring out of scope.
- **Screen lock.** Per explicit user decision, all `swaylock` callsites are removed in this spec. Screen-lock as a concept is eliminated. If reintroduced later, it's a separate spec.
- **Repurposing the now-click-inert placeholder pills.** Six pills lose their `swaylock` `on-click` and become inert. Per Rule 7 they should collapse to `.empty`; assigning them new actions is a follow-up.
- **Migrating to flakes.** Disko is pinned via `builtins.fetchTarball` + sha256 — reproducible without flakes. Flake conversion is its own spec.
- **Logging resume duration / outcomes to disk.** OPTIONS is the surface. If the user can't see it in the bar, it didn't happen.

## User-facing model

Two distinct user intents, both explicit, both surfaced as pills in the existing TASK-zone `group/group-power` cluster:

| Intent | OPTIONS pill | Keybind | systemd action |
|---|---|---|---|
| Sleep | `custom/lock` (blue) | — | `systemctl suspend` |
| Hibernate | `custom/power` (red) | SUPER+ESC | `systemctl hibernate` |
| Reboot | `custom/reboot` (yellow) | — | `reboot` (unchanged) |
| Shutdown | — | hardware power button | logind `powerKey=poweroff` |

**No lock-on-resume.** Resume drops the user straight at the desktop. **No lid action.** Closing the lid does nothing — useful for clamshell / external-monitor flows.

**Safety net:** UPower fires `Hibernate` automatically when battery falls to ≤5%, but only as a safety net during Sleep. The default Sleep behavior is pure suspend.

**Resume feedback:** silent on success (per OPTIONS Rule 4 — context shifts are silent). The new `custom/power-resume` pill appears only when the health-check finds a subsystem still broken after pass 2.

## Architecture

Two NixOS modules under `/etc/nixos/modules/`:

### `modules/power-sleep.nix` — runtime, default-on

```nix
options.standardOs.power.sleep = {
  enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Standard-OS suspend & hibernate system.";
  };
  resumeDevice = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      UUID of the resume device (swap partition). If null, derived
      from the first entry in config.swapDevices.
    '';
  };
  criticalBatteryPercent = lib.mkOption {
    type = lib.types.int;
    default = 5;
    description = "Battery % at which UPower auto-hibernates during Sleep.";
  };
};
```

**Concerns owned by this module:**

1. Kernel/boot — `resume=`, `boot.resumeDevice`, `/sys/power/image_compression=lz4`, `/sys/power/disk=shutdown`.
2. NVIDIA preservation (no-op on non-NVIDIA hosts).
3. logind policy — lid ignore, power-key poweroff (explicit).
4. UPower critical-battery → Hibernate.
5. Pre-sleep + post-resume systemd units (system + user scope).
6. OPTIONS pill state writer (`/tmp/waybar-cache/power-resume`).

### `modules/disko-layout.nix` — install-time, default-off

```nix
options.standardOs.disk.layout = {
  enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      DESTRUCTIVE. Apply the canonical Standard-OS partition scheme.
      For installer flows only. Refuses to apply on a running system
      unless iAmInstallingAFreshSystem = true.
    '';
  };
  iAmInstallingAFreshSystem = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Safety acknowledgment.";
  };
  disk = lib.mkOption {
    type = lib.types.str;
    default = "/dev/nvme0n1";
  };
  swapExtraGiB = lib.mkOption {
    type = lib.types.int;
    default = 2;
    description = "Swap size = total RAM + this many GiB. Default gives hibernate-image headroom.";
  };
};
```

Disko pulled via:
```nix
let
  disko = builtins.fetchTarball {
    url    = "https://github.com/nix-community/disko/archive/refs/tags/v1.<x>.<y>.tar.gz";
    sha256 = "<pin during implementation>";
  };
in { imports = [ "${disko}/module.nix" ]; ... }
```

**Canonical layout:**
- ESP (`vfat`, 1 GiB, mounted at `/boot`)
- root (`ext4`, remainder minus swap, mounted at `/`)
- swap (`linux-swap`, size = RAM + `swapExtraGiB` GiB)

### Imports

`configuration.nix` adds both modules to its `imports`:

```nix
imports = [
  ./modules/boot.nix
  # ... existing imports ...
  ./modules/power-sleep.nix
  ./modules/disko-layout.nix   # default disabled, available for installer
];
```

Since `power-sleep.enable` defaults to `true`, no per-host enable is needed.

## System layer (`power-sleep.nix` details)

### Kernel / boot

```nix
boot.resumeDevice = cfg.resumeDevice or derivedSwapUUID;
boot.kernelParams = [ "resume=UUID=${swapUUID}" ];
systemd.tmpfiles.rules = [
  "w- /sys/power/image_compression - - - - lz4"
  "w- /sys/power/disk - - - - shutdown"
];
```

UUID derivation: walks `config.swapDevices`, picks first entry, resolves via `lib.removePrefix "/dev/disk/by-uuid/" device.device`. Errors with a clear message if the device path isn't a `by-uuid` reference or if the entry is a swapfile.

### NVIDIA

```nix
hardware.nvidia.powerManagement = lib.mkIf
  (config.hardware.nvidia.modesetting.enable or false)
  {
    enable      = true;
    finegrained = false;
  };
```

Verifies (via assertion) that `boot.nix`'s `NVreg_PreserveVideoMemoryAllocations=1` is still present.

### logind

```nix
services.logind = {
  lidSwitch              = "ignore";
  lidSwitchExternalPower = "ignore";
  lidSwitchDocked        = "ignore";
  powerKey               = "poweroff";
  powerKeyLongPress      = "poweroff";
};
```

### UPower

```nix
services.upower = {
  enable              = true;
  criticalPowerAction = "Hibernate";
  percentageLow       = 15;
  percentageCritical  = 5;
  percentageAction    = cfg.criticalBatteryPercent;   # default 5
};
```

### Sysctl

```nix
boot.kernel.sysctl = {
  "vm.swappiness" = lib.mkDefault 10;
};
```

## Pre-sleep + post-resume hooks (the double-check)

### Sleep targets all four trigger paths

```
suspend.target | hibernate.target | hybrid-sleep.target | suspend-then-hibernate.target
```

Pre-sleep services use `Before=` + `WantedBy=` these. Post-resume services use `After=` + `WantedBy=` (systemd inverts on target deactivation).

### `standard-os-presleep.service` (system, oneshot)

```bash
sync
date -Iseconds > /run/standard-os/last-sleep
```

`/run/standard-os/` created via `systemd.tmpfiles.rules`.

### `standard-os-resume.service` (system) + `standard-os-resume-user.service` (user)

Both run in parallel after wake. Two-pass structure:

```
t=0          resume fires
t=+1.0s      PASS 1 — probe + remediate failures
t=+3.0s      PASS 2 — probe again, pass 2 is source of truth
             clean → atomic-mv empty file into /tmp/waybar-cache/power-resume
             still broken → write failure pill
```

### Subsystem matrix

| # | Subsystem | Probe | Remediation | Scope |
|---|---|---|---|---|
| 1 | pipewire | `systemctl --user is-active pipewire pipewire-pulse wireplumber` all `active` | restart failing units | user |
| 2 | NetworkManager | `nmcli -t -f STATE g` ∉ {`asleep`, `disconnected`} | `nmcli networking on && nmcli radio wifi on` | system |
| 3 | NVIDIA | `nvidia-smi -L \| grep -q '^GPU'` (only when module loaded) | none — surface only | system |
| 4 | Time | `timedatectl show -p NTPSynchronized --value` = `yes` | `systemctl restart systemd-timesyncd` | system |
| 5 | Hyprland | `hyprctl -j monitors` returns non-empty array | none — surface only | user |
| 6 | OPTIONS daemons | `pgrep -f workspace-daemon.sh` etc. | `pkill -RTMIN+0 waybar` nudge | user |
| 7 | Bluetooth | `systemctl is-active bluetooth` + previously-connected trusted devices reconnect | `bluetoothctl power on`, `bluetoothctl connect <mac>` for each pre-sleep-connected trusted device | system |

### Failure pill writer

Uses `pill_emit` from `~/.config/waybar/scripts/lib/pill.sh` (atomic tmp+mv, JSON-array `class` field, light/dark via `pill_theme`). No `jq` / `awk` in hot path — pure bash. Since user-scope services have access to `$HOME`, they `source` pill.sh directly. The system-scope resume service writes its pill via a small embedded equivalent (3-line `printf` + `mv` atomic) rather than depending on `$HOME` paths.

Pill format on failure:

```json
{
  "text": "Resume: pipewire",
  "class": ["opt-pill", "opt-flash", "opt-no", "dark"],
  "tooltip": "Sleep duration: 23m. Failed: pipewire (restarted, still inactive). Click to retry."
}
```

Single failure → `Resume: <name>`. Multiple → `Resume: N issues`, tooltip lists them.

### Meta-failure

`OnFailure=` on both resume services points at `standard-os-resume-crashed.service`, which writes a generic `Resume: check crashed` pill. So a bash error still surfaces.

## OPTIONS surface

### `group/group-power` remap

| Pill | Color | On-click before | On-click after | Tooltip after |
|---|---|---|---|---|
| `custom/power` | red | `systemctl hibernate` | unchanged | `"Hibernate"` |
| `custom/lock` | blue | `swaylock` | `systemctl suspend` | `"Sleep"` |
| `custom/reboot` | yellow | `reboot` | unchanged | `"Reboot"` |

Module names unchanged (avoiding cascading ID-selector edits in `style.css`).

### swaylock cleanup

`grep -n swaylock config.jsonc` returns 6 callsites — all in fallback `pill-child` definitions (lock/disabled glyphs). Each has its `on-click: "swaylock"` line **deleted**, leaving the pill click-inert. **Follow-up:** Rule 7 wants these collapsed to `.empty` or reassigned; that is a separate spec.

### New module: `custom/power-resume`

Inserted into `modules-right` before `custom/clock`:

```jsonc
"custom/power-resume": {
  "exec": "cat /tmp/waybar-cache/power-resume 2>/dev/null || echo '{\"text\":\"\"}'",
  "return-type": "json",
  "format": "{}",
  "interval": "once",
  "signal": 10,
  "on-click": "systemctl start standard-os-resume.service",
  "tooltip": true
},
```

Signal RTMIN+10 — matches `pill_write`'s hardcoded ping (every daemon-driven pill listens on the same global "refresh" signal; this is the project's existing pattern).

### `style.css` additions

```css
window#waybar #custom-power-resume label {
  /* uses existing .opt-pill .opt-no .opt-flash composition; no new rules */
}
window#waybar #custom-power-resume.light label { color: @opt-text-light-on-no; }
window#waybar #custom-power-resume.empty {
  padding: 0; margin: 0; opacity: 0; font-size: 0;
}
```

Zero new colors, motions, surfaces — closed budget preserved.

### TODO.md entry

Adds one item:
> **Sleep + Hibernate system + OPTIONS remap** — power-sleep.nix runtime module (default-on), disko-layout.nix install-time scheme (default-off), group-power remap (lock→Sleep, swaylock cleanup), new custom/power-resume failure pill. See spec at `docs/superpowers/specs/2026-06-05-suspend-hibernate-design.md`.

## Error handling

### Build-time guards

| Condition | Response |
|---|---|
| `enable=true` but `config.swapDevices` empty | assertion: "Standard-OS hibernation needs a swap device. Use modules/disko-layout.nix or add swap manually." |
| Swap total < RAM total | assertion: "Hibernate image won't fit. Swap is ${X}GiB, RAM is ${Y}GiB. Need swap ≥ RAM (RAM + 2GiB recommended)." |
| Swap entry is a swapfile | hard error: "Swapfile hibernate requires resume_offset and is out of scope for v1." |
| `disko-layout.enable=true` on a running system without `iAmInstallingAFreshSystem=true` | hard error refusing to repartition. |

### Runtime failures (system functional, surfaced via OPTIONS)

Each subsystem's pass-2-still-broken state maps to a `Resume: <name>` pill. Click → retry. Multiple failures collapse to `Resume: N issues` with enumeration in tooltip. Pill clears on next clean health-check.

### Policy edge cases

- Sleep + battery hits 5% while asleep → UPower fires Hibernate. (Intended.)
- Hibernate image write fails → kernel cancels, system stays awake, logind logs. No OPTIONS surface in v1.
- `enable=false` after previously true → kernel param removed on rebuild, services unload, UPower action reverts. Clean.
- Pass 1 remediates, pass 2 sees healthy → pill stays empty. Pass 2 is truth.

## Testing & verification

### Build-time

```bash
sudo nixos-rebuild dry-build
sudo nixos-rebuild build
```

Positive: current host passes (swap 34 GiB ≥ RAM 31 GiB).
Negative regression: with `swapDevices=[]`, assertion fires with documented message.

### Pre-activation

```bash
sudo nixos-rebuild test
```

Then verify:
```bash
cat /proc/cmdline | tr ' ' '\n' | grep resume       # resume=UUID=...
systemctl status standard-os-resume.service         # loaded, inactive
loginctl show-session $XDG_SESSION_ID | grep -i lid # ignore
```

### Functional sleep tests

| Test | Trigger | Expected |
|---|---|---|
| Sleep via OPTIONS | click `custom/lock` | resume in < 2s, bar silent |
| Hibernate via OPTIONS | click `custom/power` | cold boot resumes from swap, bar silent |
| Hibernate via keybind | SUPER+ESC | same as above |
| Reboot regression | click `custom/reboot` | reboot |
| Lid close (battery + AC) | physical | nothing |
| Power button tap | physical | poweroff |

### Failure injection

| Inject | Trigger | Expected pill |
|---|---|---|
| `systemctl --user stop pipewire pipewire-pulse wireplumber` then suspend | suspend cycle | `Resume: pipewire` (cleared by click → restart) |
| `nmcli radio wifi off` then suspend | suspend cycle | `Resume: net` if pass 2 still disconnected |
| `bluetoothctl disconnect <mac>` then suspend | suspend cycle | silent if pass 1 reconnects; `Resume: bt` otherwise |

### Battery safety-net (manual)

Set `criticalBatteryPercent = 90` temporarily, sleep at 95%, observe auto-hibernate as battery falls to 90%, revert. One-shot test.

### Installer flow

Deferred — blocked until installer scaffolding exists.

### Navigator's verification checklist

- [x] Class emitted as JSON array — via `pill_emit`
- [x] light/dark class present — via `pill_theme`
- [x] Light-text selector block updated
- [x] CSS scoped with `window#waybar`
- [x] Cache writes atomic — tmp+mv via pill_emit
- [x] `pkill -RTMIN+N` only on real-content change
- [x] No fork-per-tick — oneshot service, not a daemon
- [x] TODO.md updated
- [x] Commit message phrased as behavior change

## Open items (resolve during implementation)

- Pin a specific disko tag + sha256.
- ~~Confirm signal slot~~ resolved: RTMIN+10 (matches `pill_write` hardcoded ping).
- Define exact `OnFailure=` unit name and its writer.
- Decide whether the OPTIONS daemon probe should enumerate against an explicit list or `find /home/*/.config/waybar/scripts/*.sh` — the explicit list is more deterministic and matches the project's "no fork-per-tick" preference.
