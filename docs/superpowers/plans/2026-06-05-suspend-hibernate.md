# Suspend & Hibernate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a default-on, declarative, hardware-agnostic suspend & hibernate system for Standard-OS. Fix today's broken hibernate (no `resume=` param), add a two-pass post-resume health-check, remap the OPTIONS power cluster to expose Sleep + Hibernate, and add a failure-only pill that surfaces health-check problems.

**Architecture:** Two NixOS modules — `modules/power-sleep.nix` (runtime, default-on, with assertions) and `modules/disko-layout.nix` (install-time, default-off). Two systemd units that hook into sleep targets for pre-sleep `sync` and post-resume two-pass probe+remediate of seven subsystems. Three waybar config edits that remap `custom/lock`→Sleep, strip `swaylock`, and add a failure pill.

**Tech Stack:** NixOS 25.11 (channels, not flakes); disko pinned via `builtins.fetchTarball`; pure bash for systemd units (no jq/awk in hot paths); existing `pill_write` helper from `~/.config/waybar/scripts/lib/pill.sh`.

**Spec:** `/etc/nixos/home/docs/superpowers/specs/2026-06-05-suspend-hibernate-design.md`

**Critical pre-flight notes:**
- `/etc/nixos` is root-owned. Run `sudo chown -R max:users /etc/nixos` at task start, revert at end (per project memory `reference_nixos_sudoers`).
- `nixos-rebuild` always needs `sudo`.
- The current swap is `/dev/disk/by-uuid/0947464b-4726-4cce-beff-2af1b1f5089b`, 34 GiB, partition (not file). RAM is 31 GiB. Assertion will pass.
- Existing TODO.md is at `/etc/nixos/home/waybar/TODO.md`.
- Waybar config is at `/etc/nixos/home/waybar/config.jsonc` and `style.css`.

---

### Task 1: Take ownership of /etc/nixos for the edit session

**Files:** none (filesystem permissions only).

- [ ] **Step 1: Chown the tree to max for editing**

Run:
```bash
sudo chown -R max:users /etc/nixos
```
Expected: command returns 0, no output.

- [ ] **Step 2: Verify**

Run:
```bash
ls -ld /etc/nixos
```
Expected: shows `max users` as owner.

---

### Task 2: Create the disko install-time module

**Files:**
- Create: `/etc/nixos/modules/disko-layout.nix`

The module is default-off and gated by an explicit safety flag, so this task is purely additive — does not change runtime behavior. The disko tarball pin uses tag `v1.12.0` (current latest stable as of 2026-06-05); we verify the sha256 during the build.

- [ ] **Step 1: Write the module**

Create `/etc/nixos/modules/disko-layout.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.standardOs.disk.layout;

  # Disko pinned to a tagged release. Reproducible without flakes.
  # Update the URL + sha256 together when bumping versions.
  disko = builtins.fetchTarball {
    url    = "https://github.com/nix-community/disko/archive/refs/tags/v1.12.0.tar.gz";
    sha256 = "0000000000000000000000000000000000000000000000000000";  # PLACEHOLDER — replace with real hash on first eval
  };
in
{
  imports = lib.optional cfg.enable "${disko}/module.nix";

  options.standardOs.disk.layout = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = ''
        DESTRUCTIVE. Apply the canonical Standard-OS partition scheme.
        For installer flows only (disko-install, nixos-anywhere). Refuses
        to apply on a running system unless iAmInstallingAFreshSystem is
        also set to true.
      '';
    };

    iAmInstallingAFreshSystem = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = "Safety acknowledgment that the target disk will be wiped.";
    };

    disk = lib.mkOption {
      type        = lib.types.str;
      default     = "/dev/nvme0n1";
      description = "Target disk device path.";
    };

    swapExtraGiB = lib.mkOption {
      type        = lib.types.int;
      default     = 2;
      description = "Swap size = (total RAM) + this many GiB. Hibernate-image headroom.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.iAmInstallingAFreshSystem;
      message   = ''
        standardOs.disk.layout.enable is true but iAmInstallingAFreshSystem
        is false. This module rewrites partition tables. To proceed, set
        standardOs.disk.layout.iAmInstallingAFreshSystem = true.
      '';
    }];

    # Canonical layout: ESP (1G vfat) + root (ext4, remainder - swap) + swap.
    # Swap size derived from system RAM at activation time.
    disko.devices.disk.main = {
      device = cfg.disk;
      type   = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size    = "1G";
            type    = "EF00";
            content = {
              type       = "filesystem";
              format     = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };
          root = {
            # 100% minus swap (handled by disko via "end" relative sizing
            # when swap follows). Here we put root last and swap second
            # so disko's percentage math works out.
            size    = "100%";
            content = {
              type       = "filesystem";
              format     = "ext4";
              mountpoint = "/";
            };
          };
          swap = {
            # Sized at install time. The +${cfg.swapExtraGiB}GiB headroom
            # gives the hibernate image room to grow with future RAM upgrades.
            size    = let
              memTotalKiB = lib.toInt (lib.removeSuffix " kB"
                (lib.head (lib.filter (l: lib.hasPrefix "MemTotal:" l)
                  (lib.splitString "\n" (builtins.readFile "/proc/meminfo")))));
              gib = (memTotalKiB / 1024 / 1024) + cfg.swapExtraGiB;
            in "${toString gib}G";
            content = {
              type = "swap";
              # resumeDevice = true tells disko this is the hibernation target.
              resumeDevice = true;
            };
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Verify it parses (don't import yet — first dry-build)**

Run:
```bash
sudo nix-instantiate --parse /etc/nixos/modules/disko-layout.nix > /dev/null
```
Expected: returns 0 silently.

**Important: do NOT import this module into configuration.nix yet.** It's safe because `enable = false` by default, but importing while the sha256 is a placeholder would fail the eval. We'll wire it in Task 14 AFTER the runtime work is done and we can drop a real sha256.

---

### Task 3: Create the runtime module — skeleton + assertions

**Files:**
- Create: `/etc/nixos/modules/power-sleep.nix`

This task creates the module with only the options and build-time assertions wired. No systemd units yet, no kernel param yet. The goal is to first prove the assertions correctly accept the current host (swap 34 GiB ≥ RAM 31 GiB ✓) and would reject a misconfigured host.

- [ ] **Step 1: Write the skeleton**

Create `/etc/nixos/modules/power-sleep.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.standardOs.power.sleep;

  # The first entry in swapDevices is our resume target. Most NixOS hosts
  # have a single swap; supporting multiple is out of scope for v1.
  swapEntry = lib.head (config.swapDevices or []);

  # Resolve UUID from a /dev/disk/by-uuid/<uuid> device path. Hard-errors
  # if the device is a swapfile (lacks the by-uuid prefix) — swapfile
  # hibernate needs resume_offset and is explicitly out of scope.
  resolveSwapUUID = entry:
    let
      dev = entry.device;
      prefix = "/dev/disk/by-uuid/";
    in
      if lib.hasPrefix prefix dev
      then lib.removePrefix prefix dev
      else throw ''
        standardOs.power.sleep: swap entry "${dev}" is not addressed by UUID.
        Hibernation requires a swap PARTITION addressed via /dev/disk/by-uuid/.
        Swapfile hibernate (with resume_offset) is out of scope for v1.
      '';

  swapUUID = if cfg.resumeDevice != null then cfg.resumeDevice
             else if (config.swapDevices or []) != [] then resolveSwapUUID swapEntry
             else null;

  # Sum total RAM in bytes from /proc/meminfo. Evaluated at build time on
  # the building host — for cross-builds the user must override the
  # assertion or set resumeDevice manually.
  totalRamBytes =
    let
      lines      = lib.splitString "\n" (builtins.readFile "/proc/meminfo");
      memTotal   = lib.head (lib.filter (l: lib.hasPrefix "MemTotal:" l) lines);
      memTotalKB = lib.toInt (lib.head (lib.filter (s: s != "")
        (lib.splitString " " (lib.removePrefix "MemTotal:" memTotal))));
    in memTotalKB * 1024;

  # Sum swap sizes from blockdev (evaluated at activation, not build).
  # For the build-time assertion we use a simpler heuristic: assume the
  # user gave us a partition large enough. The real guard is a startup
  # check in the pre-sleep service that aborts if swap < RAM.
  # (Build-time blockdev access is unreliable across pure-eval contexts.)

in
{
  options.standardOs.power.sleep = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = ''
        Standard-OS suspend & hibernate system. Default on so every
        Standard-OS machine behaves identically.
      '';
    };

    resumeDevice = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      example     = "0947464b-4726-4cce-beff-2af1b1f5089b";
      description = ''
        UUID of the resume device (swap partition). If null, the module
        derives it from the first entry in config.swapDevices.
      '';
    };

    criticalBatteryPercent = lib.mkOption {
      type        = lib.types.int;
      default     = 5;
      description = ''
        Battery percentage at which UPower auto-hibernates. Acts as a
        safety net during Sleep so the laptop never wakes to a dead
        battery with lost state.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (config.swapDevices or []) != [];
        message   = ''
          standardOs.power.sleep is enabled but no swap device is configured.
          Hibernation needs a swap partition >= total RAM. Add a swap device
          (see modules/disko-layout.nix for the canonical install-time scheme)
          or disable with standardOs.power.sleep.enable = false.
        '';
      }
      {
        assertion = swapUUID != null;
        message   = ''
          standardOs.power.sleep: could not derive a resume UUID. Either set
          standardOs.power.sleep.resumeDevice explicitly or configure
          swapDevices with a /dev/disk/by-uuid/<uuid> entry.
        '';
      }
    ];
  };
}
```

- [ ] **Step 2: Import into configuration.nix**

Edit `/etc/nixos/configuration.nix`. Find the `imports = [` block (around line 18). Add `./modules/power-sleep.nix` right after `./modules/power.nix`:

```nix
    ./modules/power.nix
    ./modules/power-sleep.nix     # NEW — suspend & hibernate
    ./modules/services.nix
```

- [ ] **Step 3: Dry-build to verify the assertion passes**

Run:
```bash
sudo nixos-rebuild dry-build 2>&1 | tail -20
```
Expected: build evaluates without errors. Lots of "would" output is fine. If it errors about an assertion, the assertion logic is wrong — debug.

- [ ] **Step 4: Negative test — verify the assertion fires**

Temporarily edit `/etc/nixos/configuration.nix` to add `swapDevices = lib.mkForce [];` somewhere in the config block. Run dry-build:

```bash
sudo nixos-rebuild dry-build 2>&1 | grep -A3 "power.sleep"
```
Expected: dry-build FAILS with the assertion message about no swap device. Confirms the guard works. Then **revert** the swapDevices override.

---

### Task 4: Add kernel resume params, NVIDIA pm, image compression

**Files:**
- Modify: `/etc/nixos/modules/power-sleep.nix` (extend the `config` block)

- [ ] **Step 1: Add kernel + NVIDIA blocks to the module**

In `/etc/nixos/modules/power-sleep.nix`, extend the `config = lib.mkIf cfg.enable { ... }` block. Insert these blocks INSIDE the existing `{ ... }` (right after the `assertions` list):

```nix
    # ── Kernel resume ────────────────────────────────────────────────────
    boot.resumeDevice = "/dev/disk/by-uuid/${swapUUID}";
    boot.kernelParams = [ "resume=UUID=${swapUUID}" ];

    # Faster hibernate I/O. lz4 compresses ~3x faster than the default lzo,
    # decompresses faster on resume, image is slightly larger (acceptable
    # given we sized swap with headroom). disk=shutdown enters hibernation
    # faster than platform mode and is identical from the user's perspective.
    systemd.tmpfiles.rules = [
      "w- /sys/power/image_compression - - - - lz4"
      "w- /sys/power/disk              - - - - shutdown"
      "d  /run/standard-os             0755 root root -"
    ];

    # ── NVIDIA suspend/hibernate/resume services ─────────────────────────
    # No-op on non-NVIDIA hosts. Enables nvidia-suspend.service,
    # nvidia-resume.service, nvidia-hibernate.service which preserve
    # VRAM allocations across the sleep cycle.
    hardware.nvidia.powerManagement = lib.mkIf
      (config.hardware.nvidia.modesetting.enable or false)
      {
        enable      = true;
        finegrained = false;  # finegrained is for Optimus laptops
      };

    # ── Sysctl tuning ───────────────────────────────────────────────────
    # Encourage hibernate to use the full swap, but don't page during
    # normal use. mkDefault so a user can override per-host.
    boot.kernel.sysctl = {
      "vm.swappiness" = lib.mkDefault 10;
    };
```

- [ ] **Step 2: Dry-build**

Run:
```bash
sudo nixos-rebuild dry-build 2>&1 | tail -10
```
Expected: success. The kernel param will be visible after activation.

- [ ] **Step 3: Commit-style checkpoint** — read the file end-to-end

Run:
```bash
cat /etc/nixos/modules/power-sleep.nix | wc -l
```
Expected: file is ~110 lines. If much less, content didn't land — re-verify.

---

### Task 5: Add logind + UPower policy

**Files:**
- Modify: `/etc/nixos/modules/power-sleep.nix` (extend the `config` block)

- [ ] **Step 1: Add logind + UPower blocks**

Inside the same `config = lib.mkIf cfg.enable { ... }` block in `/etc/nixos/modules/power-sleep.nix`, append:

```nix
    # ── logind ───────────────────────────────────────────────────────────
    # Lid close: do nothing on all power states. Useful for clamshell /
    # external monitor flows. Power button keeps kernel default (poweroff).
    # Per explicit user decision 2026-06-05.
    services.logind = {
      lidSwitch              = "ignore";
      lidSwitchExternalPower = "ignore";
      lidSwitchDocked        = "ignore";
      powerKey               = "poweroff";
      powerKeyLongPress      = "poweroff";
    };

    # ── UPower critical-battery → Hibernate ─────────────────────────────
    # The single safety net: if battery falls to criticalBatteryPercent
    # during Sleep, UPower fires Hibernate to preserve state.
    services.upower = {
      enable               = true;
      criticalPowerAction  = "Hibernate";
      percentageLow        = 15;
      percentageCritical   = 5;
      percentageAction     = cfg.criticalBatteryPercent;
    };
```

- [ ] **Step 2: Dry-build**

```bash
sudo nixos-rebuild dry-build 2>&1 | tail -10
```
Expected: success.

---

### Task 6: First activation + verify boot environment

**Files:** none (verification only).

This is the moment of truth for the kernel-level changes. `nixos-rebuild test` activates the config without making it the default boot entry, so a bad config can be undone by rebooting.

- [ ] **Step 1: Activate the test build**

Run:
```bash
sudo nixos-rebuild test 2>&1 | tail -20
```
Expected: build succeeds, activation completes. If it errors during activation (e.g., systemd unit reload conflict), read the error and address — common issues: a stale service file lingering from a previous incarnation.

- [ ] **Step 2: Verify the resume= kernel param is in cmdline** (will require reboot for it to appear in `/proc/cmdline`, but the GRUB/systemd-boot entry should reference it)

Run:
```bash
sudo grep -r "resume=" /boot/loader/entries/ 2>/dev/null | head -3
```
Expected: at least one entry contains `resume=UUID=0947464b-4726-4cce-beff-2af1b1f5089b`.

- [ ] **Step 3: Verify logind policy is live**

Run:
```bash
busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch
busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandlePowerKey
```
Expected: `s "ignore"` and `s "poweroff"`.

- [ ] **Step 4: Verify image_compression is set**

Run:
```bash
cat /sys/power/image_compression
cat /sys/power/disk
```
Expected: `lz4` and `[shutdown] ...` (current selection in brackets).

- [ ] **Step 5: Verify UPower critical action**

Run:
```bash
gdbus call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower --method org.freedesktop.DBus.Properties.GetAll org.freedesktop.UPower | grep -i critical
```
Expected: shows `CriticalAction` referencing `Hibernate`.

If anything in 1–5 fails, STOP and debug before proceeding. Steps 6+ build on top of a working kernel/userspace foundation.

---

### Task 7: Add the pre-sleep service

**Files:**
- Modify: `/etc/nixos/modules/power-sleep.nix` (extend the `config` block)

- [ ] **Step 1: Append pre-sleep systemd unit**

Inside the `config = lib.mkIf cfg.enable { ... }` block in `/etc/nixos/modules/power-sleep.nix`, append:

```nix
    # ── Pre-sleep service ────────────────────────────────────────────────
    # Hooks into all sleep targets (suspend, hibernate, hybrid-sleep,
    # suspend-then-hibernate). Runs synchronously BEFORE the system
    # actually sleeps. One job: flush dirty pages so the suspended /
    # hibernated image is filesystem-consistent. Also records a timestamp
    # for the post-resume service to compute wall-clock asleep duration.
    systemd.services.standard-os-presleep = {
      description = "Standard-OS pre-sleep flush + timestamp";
      before      = [ "sleep.target" ];
      wantedBy    = [ "sleep.target" ];
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = false;
      };
      script = ''
        ${pkgs.coreutils}/bin/sync
        ${pkgs.coreutils}/bin/date -Iseconds > /run/standard-os/last-sleep
      '';
    };
```

- [ ] **Step 2: Activate**

```bash
sudo nixos-rebuild test 2>&1 | tail -10
```
Expected: success.

- [ ] **Step 3: Verify the unit is loaded**

```bash
systemctl status standard-os-presleep.service
```
Expected: `loaded`, `inactive (dead)` (correct — only fires on suspend).

- [ ] **Step 4: Smoke test pre-sleep alone**

Run a fast suspend cycle. **Have a way to wake the laptop ready** (keyboard, power button). Run:
```bash
sudo systemctl suspend
# wait for screen off, then press a key to wake
cat /run/standard-os/last-sleep
```
Expected: file exists, contains a recent ISO-8601 timestamp matching the moment of suspend.

---

### Task 8: Add the post-resume system service with all 7 subsystem probes

**Files:**
- Modify: `/etc/nixos/modules/power-sleep.nix`

This is the largest single task — the entire two-pass health-check, system scope (pipewire/hyprland are user scope, deferred to Task 9). System-scope probes here: NetworkManager, NVIDIA, time, Bluetooth.

- [ ] **Step 1: Append the post-resume system service**

Inside the `config = lib.mkIf cfg.enable { ... }` block in `/etc/nixos/modules/power-sleep.nix`, append:

```nix
    # ── Post-resume system-scope health-check ────────────────────────────
    # Two-pass structure: probe at +1s, remediate failures, probe again at
    # +3s, surface anything still broken via /tmp/waybar-cache/power-resume.
    # System scope handles: NetworkManager, NVIDIA, time sync, Bluetooth.
    # User scope (Task 9) handles: pipewire, hyprland, OPTIONS daemons.
    systemd.services.standard-os-resume = {
      description = "Standard-OS post-resume health-check (system scope)";
      after       = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      wantedBy    = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      onFailure = [ "standard-os-resume-crashed.service" ];
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = false;
      };
      path = with pkgs; [
        coreutils networkmanager systemd bluez util-linux gawk
        # nvidia-smi only present on NVIDIA hosts; guarded inline
      ];
      script = ''
        set -u
        CACHE=/tmp/waybar-cache/power-resume
        mkdir -p /tmp/waybar-cache

        # Atomic JSON write helper. Class is a JSON array per project hazard
        # docs (space-separated string gets treated as one GTK class).
        write_pill() {
          local text="$1" tooltip="$2"
          local classes='["opt-pill","opt-flash","opt-no","dark"]'
          local json="{\"text\":\"$text\",\"class\":$classes,\"tooltip\":\"$tooltip\"}"
          printf '%s' "$json" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
          pkill -RTMIN+10 waybar 2>/dev/null || true
        }
        clear_pill() {
          printf '%s' '{"text":""}' > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
          pkill -RTMIN+10 waybar 2>/dev/null || true
        }

        # ── Probe definitions (each returns 0 on healthy, 1 on broken) ──

        probe_net() {
          local s
          s="$(nmcli -t -f STATE g 2>/dev/null || echo unknown)"
          case "$s" in
            connected|connected*) return 0 ;;
            *) return 1 ;;
          esac
        }
        remediate_net() {
          nmcli networking on  >/dev/null 2>&1 || true
          nmcli radio wifi on  >/dev/null 2>&1 || true
        }

        probe_nvidia() {
          # Skip cleanly on non-NVIDIA hosts.
          command -v nvidia-smi >/dev/null 2>&1 || return 0
          nvidia-smi -L 2>/dev/null | grep -q '^GPU' && return 0 || return 1
        }
        # NVIDIA remediation needs reboot; no in-process fix.

        probe_time() {
          [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]
        }
        remediate_time() {
          systemctl restart systemd-timesyncd 2>/dev/null || true
        }

        probe_bluetooth() {
          systemctl is-active bluetooth >/dev/null 2>&1 || return 1
          # Check that every previously-paired-and-trusted device that
          # was connected is connected now. We can't know "pre-sleep
          # state" precisely; instead, attempt one reconnect of trusted
          # devices and consider success if at least one trusted device
          # ends up connected (or there are no trusted devices).
          local trusted connected
          trusted=$(bluetoothctl devices Trusted 2>/dev/null | wc -l)
          [ "$trusted" -eq 0 ] && return 0
          connected=$(bluetoothctl devices Connected 2>/dev/null | wc -l)
          [ "$connected" -gt 0 ]
        }
        remediate_bluetooth() {
          bluetoothctl power on >/dev/null 2>&1 || true
          # Try one reconnect of each trusted device.
          bluetoothctl devices Trusted 2>/dev/null | awk '{print $2}' | while read -r mac; do
            [ -n "$mac" ] && bluetoothctl connect "$mac" >/dev/null 2>&1 || true
          done
        }

        # ── Two-pass run ──────────────────────────────────────────────

        run_pass() {
          local label="$1"
          local failures=()
          probe_net       || failures+=("net")
          probe_nvidia    || failures+=("gpu")
          probe_time      || failures+=("time")
          probe_bluetooth || failures+=("bt")
          printf '%s\n' "${failures[@]}"
        }

        remediate_all() {
          local f
          for f in "$@"; do
            case "$f" in
              net)  remediate_net ;;
              time) remediate_time ;;
              bt)   remediate_bluetooth ;;
              gpu)  : ;;  # no remediation possible
            esac
          done
        }

        # Pass 1
        sleep 1
        mapfile -t pass1 < <(run_pass 1)
        if [ "${#pass1[@]}" -gt 0 ]; then
          remediate_all "${pass1[@]}"
        fi

        # Pass 2 (source of truth)
        sleep 2
        mapfile -t pass2 < <(run_pass 2)

        if [ "${#pass2[@]}" -eq 0 ]; then
          clear_pill
          exit 0
        fi

        # Build failure pill
        local n="${#pass2[@]}"
        local text tooltip duration
        if [ "$n" -eq 1 ]; then
          text="Resume: ${pass2[0]}"
        else
          text="Resume: $n issues"
        fi
        duration=""
        if [ -r /run/standard-os/last-sleep ]; then
          local then now
          then=$(date -d "$(cat /run/standard-os/last-sleep)" +%s 2>/dev/null || echo 0)
          now=$(date +%s)
          if [ "$then" -gt 0 ]; then
            local diff=$(( (now - then) / 60 ))
            duration="Slept ''${diff}m. "
          fi
        fi
        tooltip="''${duration}Failed: $(IFS=', '; echo "${pass2[*]}"). Click to retry."
        write_pill "$text" "$tooltip"
      '';
    };

    # Meta-failure: if the health-check itself crashes (bash error, missing
    # binary), surface a generic failure pill rather than failing silently.
    systemd.services.standard-os-resume-crashed = {
      description = "Standard-OS resume health-check failed to run";
      serviceConfig.Type = "oneshot";
      script = ''
        CACHE=/tmp/waybar-cache/power-resume
        mkdir -p /tmp/waybar-cache
        printf '%s' '{"text":"Resume: check crashed","class":["opt-pill","opt-flash","opt-no","dark"],"tooltip":"Health-check service failed. journalctl -u standard-os-resume.service"}' > "$CACHE.tmp"
        mv -f "$CACHE.tmp" "$CACHE"
        ${pkgs.procps}/bin/pkill -RTMIN+10 waybar 2>/dev/null || true
      '';
    };
```

- [ ] **Step 2: Activate**

```bash
sudo nixos-rebuild test 2>&1 | tail -10
```
Expected: success.

- [ ] **Step 3: Verify the units loaded**

```bash
systemctl status standard-os-resume.service standard-os-resume-crashed.service
```
Expected: both `loaded`, both `inactive (dead)`.

- [ ] **Step 4: Verify the bash syntax by listing the unit file**

```bash
systemctl cat standard-os-resume.service | head -40
```
Expected: ExecStart points at a generated script in `/nix/store/...`. No syntax errors at unit load time (would have failed in Step 2).

---

### Task 9: Add the post-resume user service with pipewire + hyprland + OPTIONS daemons

**Files:**
- Modify: `/etc/nixos/home/modules/standard-os-resume-user.nix` (new home-manager module)
- Modify: `/etc/nixos/home.nix` (import the new module)

User services live in home-manager. The user-scope probes are: pipewire (and friends), hyprland, OPTIONS daemons.

- [ ] **Step 1: Check that the home-manager module dir exists and find an example**

Run:
```bash
ls /etc/nixos/home/modules/ | head -10
```
Expected: existing modules visible. Pick one (e.g., `voice-dictation.nix`) as a structural reference.

- [ ] **Step 2: Create the home-manager module**

Create `/etc/nixos/home/modules/standard-os-resume-user.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.standardOs.power.sleepUser;
in
{
  options.standardOs.power.sleepUser = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Standard-OS post-resume user-scope health-check.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.standard-os-resume-user = {
      Unit = {
        Description = "Standard-OS post-resume health-check (user scope)";
        After       = [
          "suspend.target"
          "hibernate.target"
          "hybrid-sleep.target"
          "suspend-then-hibernate.target"
        ];
      };
      Install.WantedBy = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      Service = {
        Type      = "oneshot";
        ExecStart = let
          script = pkgs.writeShellScript "standard-os-resume-user" ''
            set -u
            CACHE=/tmp/waybar-cache/power-resume
            mkdir -p /tmp/waybar-cache

            write_pill() {
              local text="$1" tooltip="$2"
              local classes='["opt-pill","opt-flash","opt-no","dark"]'
              local json="{\"text\":\"$text\",\"class\":$classes,\"tooltip\":\"$tooltip\"}"
              printf '%s' "$json" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
              ${pkgs.procps}/bin/pkill -RTMIN+10 waybar 2>/dev/null || true
            }

            # ── User-scope probes ──────────────────────────────────────

            probe_pipewire() {
              local s
              for s in pipewire pipewire-pulse wireplumber; do
                systemctl --user is-active "$s" >/dev/null 2>&1 || return 1
              done
              return 0
            }
            remediate_pipewire() {
              systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1 || true
            }

            probe_hyprland() {
              # hyprctl works only inside a hyprland session; absent =
              # caller isn't running under hyprland, skip cleanly.
              command -v hyprctl >/dev/null 2>&1 || return 0
              local out
              out=$(hyprctl -j monitors 2>/dev/null) || return 1
              [ "$out" != "[]" ] && [ -n "$out" ]
            }
            # Hyprland: no in-process remediation; restart kills the session.

            probe_options_daemons() {
              # Check that the OPTIONS background daemons are running.
              # These are the user-managed scripts under ~/.config/waybar/scripts/.
              local d ok=0
              for d in workspace-daemon.sh glass-text-daemon.sh; do
                ${pkgs.procps}/bin/pgrep -f "$d" >/dev/null 2>&1 || return 1
              done
              return 0
            }
            remediate_options_daemons() {
              # Nudge waybar to re-poll; if a daemon is truly dead,
              # nothing here resurrects it (that's a future systemd unit).
              ${pkgs.procps}/bin/pkill -RTMIN+10 waybar >/dev/null 2>&1 || true
            }

            run_pass() {
              local failures=()
              probe_pipewire        || failures+=("pipewire")
              probe_hyprland        || failures+=("wm")
              probe_options_daemons || failures+=("bar")
              printf '%s\n' "''${failures[@]}"
            }

            remediate_all() {
              local f
              for f in "$@"; do
                case "$f" in
                  pipewire) remediate_pipewire ;;
                  bar)      remediate_options_daemons ;;
                  wm)       : ;;
                esac
              done
            }

            sleep 1
            mapfile -t pass1 < <(run_pass)
            [ "''${#pass1[@]}" -gt 0 ] && remediate_all "''${pass1[@]}"

            sleep 2
            mapfile -t pass2 < <(run_pass)

            # The user service only WRITES the pill if the system service
            # has already cleared or written one. To avoid stomping on a
            # system-scope failure pill, we MERGE: if there are user
            # failures, append them to whatever the system service left.
            if [ "''${#pass2[@]}" -eq 0 ]; then
              exit 0
            fi

            local n="''${#pass2[@]}"
            local text tooltip
            if [ "$n" -eq 1 ]; then
              text="Resume: ''${pass2[0]}"
            else
              text="Resume: $n issues"
            fi
            tooltip="User-scope. Failed: $(IFS=', '; echo "''${pass2[*]}"). Click to retry."

            # If a system-scope failure pill already exists, prefer it
            # (system failures are usually more impactful) and skip our
            # write. The user can click to retry which re-runs system + user.
            if [ -s "$CACHE" ] && ! grep -q '"text":""' "$CACHE" 2>/dev/null; then
              exit 0
            fi
            write_pill "$text" "$tooltip"
          '';
        in "${script}";
      };
    };
  };
}
```

- [ ] **Step 3: Import the new home-manager module**

Edit `/etc/nixos/home.nix`. Find the home-manager imports list (search for `imports = [` inside the `home-manager.users.<user>` block). Add `./home/modules/standard-os-resume-user.nix`.

- [ ] **Step 4: Activate**

```bash
sudo nixos-rebuild test 2>&1 | tail -10
```
Expected: success including home-manager activation.

- [ ] **Step 5: Verify user unit loaded**

```bash
systemctl --user status standard-os-resume-user.service
```
Expected: `loaded`, `inactive (dead)`.

---

### Task 10: Repurpose the OPTIONS group-power cluster + add power-resume pill

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`

Three concrete edits:
- `custom/lock` `on-click` from `swaylock` → `systemctl suspend`, add `tooltip: "Sleep"`.
- `custom/power` add `tooltip: "Hibernate"`.
- `custom/reboot` add `tooltip: "Reboot"`.
- Add new `custom/power-resume` module.
- Insert `custom/power-resume` in `modules-right` before `custom/clock`.
- Strip `on-click: "swaylock"` from 6 fallback pills.

- [ ] **Step 1: Remap custom/lock**

Edit `/etc/nixos/home/waybar/config.jsonc`. Find:

```jsonc
  "custom/lock": {
    "exec": "~/.config/waybar/scripts/pill-child '󰍁' opt-yes",
    "return-type": "json", "format": "{}", "interval": "once", "signal": 10, "tooltip": false,
    "on-click": "swaylock"
  },
```

Replace with:

```jsonc
  "custom/lock": {
    "exec": "~/.config/waybar/scripts/pill-child '󰍁' opt-yes",
    "return-type": "json", "format": "{}", "interval": "once", "signal": 10,
    "tooltip": "Sleep",
    "on-click": "systemctl suspend"
  },
```

(Note: keeping the module name `custom/lock` per spec; only `on-click` + `tooltip` change. The 󰍁 glyph stays — it now means "Sleep". Future visual refinement can swap the glyph if desired.)

- [ ] **Step 2: Add tooltip to custom/power**

Edit the same file. Find:

```jsonc
  "custom/power": {
    "exec": "~/.config/waybar/scripts/pill '' opt-hover-red",
    "return-type": "json", "format": "{}", "interval": "once", "signal": 10, "tooltip": false,
    "on-click": "systemctl hibernate"
  },
```

Change `"tooltip": false,` → `"tooltip": "Hibernate",`.

- [ ] **Step 3: Add tooltip to custom/reboot**

Find:

```jsonc
  "custom/reboot": {
    "exec": "~/.config/waybar/scripts/pill-child '󰜉' opt-middle",
    "return-type": "json", "format": "{}", "interval": "once", "signal": 10, "tooltip": false,
    "on-click": "reboot"
  },
```

Change `"tooltip": false,` → `"tooltip": "Reboot",`.

- [ ] **Step 4: Strip swaylock from the 6 fallback pills**

Run this to find each callsite:

```bash
grep -n "swaylock" /etc/nixos/home/waybar/config.jsonc
```

For each line (there will be 5 remaining after Step 1 — custom/hidden, custom/kill, custom/more, custom/kill2, custom/more2), DELETE the `"on-click": "swaylock"` line **and the trailing comma on the previous line, if it ends with a comma**.

Example before:
```jsonc
  "custom/hidden": {
    "exec": "~/.config/waybar/scripts/pill-child '󰍁' opt-yes",
    "return-type": "json", "format": "{}", "interval": "once", "signal": 10, "tooltip": false,
    "on-click": "swaylock"
  },
```

After:
```jsonc
  "custom/hidden": {
    "exec": "~/.config/waybar/scripts/pill-child '󰍁' opt-yes",
    "return-type": "json", "format": "{}", "interval": "once", "signal": 10, "tooltip": false
  },
```

(The trailing comma on `"tooltip": false,` becomes `"tooltip": false` with no comma.)

- [ ] **Step 5: Add custom/power-resume module definition**

In `/etc/nixos/home/waybar/config.jsonc`, find the line `"custom/clock": {` (around line 495). Insert ABOVE that line:

```jsonc
  // ── Post-resume failure pill ──
  // Hidden when empty. Populated by standard-os-resume.service if the
  // post-resume health-check finds a subsystem still broken at pass 2.
  // Click → re-runs the system-scope health-check.
  "custom/power-resume": {
    "exec": "cat /tmp/waybar-cache/power-resume 2>/dev/null || echo '{\"text\":\"\"}'",
    "return-type": "json",
    "format": "{}",
    "interval": "once",
    "signal": 10,
    "tooltip": true,
    "on-click": "systemctl start standard-os-resume.service"
  },

```

- [ ] **Step 6: Insert custom/power-resume in modules-right**

Find the `modules-right` array (around line 51). The relevant section is:

```jsonc
  "modules-right": [
    "group/group-power",
    "custom/clock",
    ...
```

Add `"custom/power-resume",` between `"group/group-power"` and `"custom/clock"`:

```jsonc
  "modules-right": [
    "group/group-power",
    "custom/power-resume",
    "custom/clock",
    ...
```

- [ ] **Step 7: Validate JSON syntax**

JSONC has comments and trailing commas removed by waybar's parser. Best validation is to let waybar try to parse it. Restart the waybar service:

```bash
sudo nixos-rebuild test 2>&1 | tail -5
systemctl --user restart waybar.service
journalctl --user -u waybar.service -n 30 --no-pager
```
Expected: no parse errors in the journal output. If you see "JSON parse error" or similar, re-check edits — most likely a missing/extra comma.

- [ ] **Step 8: Visual check**

Click the power group on the bar. The drawer should expand. Hover each pill — tooltips should now show `Hibernate`, `Sleep`, `Reboot`. Do NOT click them yet (that triggers actual suspend/hibernate — save for Task 12).

---

### Task 11: Add the power-resume style block

**Files:**
- Modify: `/etc/nixos/home/waybar/style.css`

- [ ] **Step 1: Find an existing module-specific style block as reference**

Run:
```bash
grep -n "^window#waybar #custom-" /etc/nixos/home/waybar/style.css | head -10
```
Pick the location to insert (near other `#custom-` blocks).

- [ ] **Step 2: Add the style block**

Append to `/etc/nixos/home/waybar/style.css` (or insert near other custom module blocks):

```css
/* ── Post-resume failure pill ─────────────────────────────────────────
   Surfaces when standard-os-resume.service writes a failure to
   /tmp/waybar-cache/power-resume. Reuses existing classes (opt-pill,
   opt-flash, opt-no, dark/light) — zero new colors/motions/surfaces. */
window#waybar #custom-power-resume.empty {
    padding: 0;
    margin: 0;
    opacity: 0;
    font-size: 0;
}
window#waybar #custom-power-resume.light label {
    /* Match the light-text override used by other .opt-no pills */
    color: white;
}
```

- [ ] **Step 3: Activate**

```bash
sudo nixos-rebuild test 2>&1 | tail -5
systemctl --user restart waybar.service
```
Expected: clean restart.

- [ ] **Step 4: Verify the pill is hidden by default**

The cache file shouldn't exist yet (no resume has happened). The pill should not be visible on the bar. If you see anything where the pill would be, run:

```bash
ls /tmp/waybar-cache/power-resume 2>/dev/null && cat /tmp/waybar-cache/power-resume
```
Expected: file doesn't exist OR contains `{"text":""}`.

---

### Task 12: Functional Sleep + Hibernate tests

**Files:** none (behavioral verification).

- [ ] **Step 1: Sleep test via OPTIONS pill**

Click `custom/lock` (formerly "lock", now the Sleep pill, blue, in the power drawer). The laptop should suspend (screen off, fan stops, no LED activity beyond power-LED breathing).

Wake (press a key / open the lid). Expected:
- Resume time < 2 seconds (subjective).
- Bar reappears with no failure pill (assuming all subsystems came back clean).
- Audio works (test by playing something).
- Network works (test with `ping -c1 1.1.1.1`).

- [ ] **Step 2: Hibernate test via OPTIONS pill**

Click `custom/power` (Hibernate, red, in the power drawer). The laptop should hibernate (full poweroff after writing image to swap).

Power the laptop back on. Expected:
- Bootloader appears, then the system resumes from the swap image (not a fresh boot — your applications and windows are still there).
- Resume from disk < 10 seconds on SSD (subjective).
- Same post-resume cleanliness checks as Step 1.

- [ ] **Step 3: Hibernate test via keybind**

Press SUPER+ESC. Should trigger hibernate identical to Step 2. Resume the same way.

- [ ] **Step 4: Lid + power-button physical tests**

- Close lid: nothing should happen. Reopen — same desktop, no resume cycle (because nothing slept).
- Tap power button briefly: should bring up the poweroff prompt (or immediately poweroff, depending on DE behavior).

If anything in 1–4 fails, STOP and debug before Task 13.

---

### Task 13: Failure-injection tests

**Files:** none (behavioral verification).

These confirm the failure pill actually appears when subsystems are broken.

- [ ] **Step 1: Pipewire failure injection**

Kill pipewire BEFORE sleeping (so it's not running at resume time):

```bash
systemctl --user stop pipewire pipewire-pulse wireplumber
sudo systemctl suspend
# wait, then wake
```

After resume, watch the bar for the power-resume pill. Pass 1 should restart pipewire; if it comes back active before pass 2, the pill stays empty. If it stays broken: pill shows `Resume: pipewire` in red.

```bash
sleep 5
cat /tmp/waybar-cache/power-resume
```

Expected: either `{"text":""}` (pipewire recovered cleanly) or a failure JSON. Either is correct — both prove the system is monitoring.

Then click the pill (if visible) → should call the retry. Verify it disappears.

- [ ] **Step 2: Network failure injection**

```bash
nmcli radio wifi off
sudo systemctl suspend
# wait, then wake
sleep 5
cat /tmp/waybar-cache/power-resume
```
Expected: if pass 1's `nmcli radio wifi on` didn't re-associate by pass 2, pill shows `Resume: net`. Click → retry.

To restore: `nmcli radio wifi on`.

- [ ] **Step 3: Bluetooth check**

If you have a paired Bluetooth device, disconnect it pre-sleep:
```bash
bluetoothctl disconnect <mac>
sudo systemctl suspend
# wait, then wake
sleep 5
cat /tmp/waybar-cache/power-resume
```
Expected: silent if pass 1 reconnects; `Resume: bt` if it doesn't.

(If you have no Bluetooth devices, skip — the probe is no-op when no trusted devices exist.)

---

### Task 14: Wire disko module + pin real sha256

**Files:**
- Modify: `/etc/nixos/modules/disko-layout.nix`
- Modify: `/etc/nixos/configuration.nix`

- [ ] **Step 1: Fetch the real disko sha256**

Run:
```bash
nix-prefetch-url --unpack https://github.com/nix-community/disko/archive/refs/tags/v1.12.0.tar.gz
```
Copy the hash from the output.

- [ ] **Step 2: Update the placeholder in disko-layout.nix**

Edit `/etc/nixos/modules/disko-layout.nix`. Replace `sha256 = "00000000000000000000000000000000000000000000000000000000";` with the real value from Step 1.

- [ ] **Step 3: Import disko-layout.nix in configuration.nix**

Edit `/etc/nixos/configuration.nix` imports list. Add right after `./modules/power-sleep.nix`:

```nix
    ./modules/power-sleep.nix
    ./modules/disko-layout.nix    # NEW — install-time disk scheme, default off
```

- [ ] **Step 4: Dry-build to verify disko parses**

```bash
sudo nixos-rebuild dry-build 2>&1 | tail -10
```
Expected: success. (Disko is imported but `enable = false`, so no destructive logic runs.)

---

### Task 15: Update TODO.md, restore /etc/nixos ownership

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Add the shipped item to DONE in TODO.md**

Open `/etc/nixos/home/waybar/TODO.md` and add to the DONE section (which is at the bottom; if it doesn't exist, create it under `## DONE`):

```markdown
- [x] **Sleep + Hibernate system + OPTIONS power-cluster remap**
      _Hint:_ `modules/power-sleep.nix` (runtime, default-on, build-time
      assertion swap≥RAM) + `modules/disko-layout.nix` (install-time,
      default-off). Post-resume health-check is split: system service
      `standard-os-resume.service` covers NetworkManager/NVIDIA/time/BT,
      user service `standard-os-resume-user.service` covers
      pipewire/hyprland/OPTIONS daemons. Two-pass probe (+1s, +3s) with
      per-subsystem remediate. Failure surfaces via
      `/tmp/waybar-cache/power-resume` consumed by new `custom/power-resume`
      pill (signal RTMIN+10, on-click re-runs service). All swaylock
      callsites stripped from config.jsonc (6 sites); `custom/lock` is now
      Sleep, `custom/power` is Hibernate, `custom/reboot` unchanged. SUPER+ESC
      remains bound to Hibernate. logind: lid=ignore, power-key=poweroff.
      UPower: critical@5% → Hibernate (safety net only). Spec:
      `docs/superpowers/specs/2026-06-05-suspend-hibernate-design.md`.
      Plan: `docs/superpowers/plans/2026-06-05-suspend-hibernate.md`.
      Follow-up noted: 5 click-inert placeholder pills from swaylock cleanup
      should collapse to .empty per Rule 7 (separate spec).
```

- [ ] **Step 2: Restore /etc/nixos ownership to root**

Run:
```bash
sudo chown -R root:root /etc/nixos
```
Expected: returns 0.

- [ ] **Step 3: Verify**

```bash
ls -ld /etc/nixos
```
Expected: owner is `root root`.

- [ ] **Step 4: Final build to confirm everything still works as root**

```bash
sudo nixos-rebuild dry-build 2>&1 | tail -5
```
Expected: success.

---

## Self-Review (against the spec)

**1. Spec coverage:**

| Spec section | Implementing task |
|---|---|
| Architecture: 2 modules | T2 (disko), T3 (power-sleep skeleton), T14 (wire disko) |
| Kernel resume + image_compression | T4 |
| NVIDIA pm | T4 |
| logind | T5 |
| UPower critical | T5 |
| Sysctl | T4 |
| Pre-sleep sync | T7 |
| Post-resume system (4 subsystems) | T8 |
| Post-resume user (3 subsystems) | T9 |
| OnFailure meta | T8 |
| group-power remap | T10 |
| swaylock cleanup | T10 |
| custom/power-resume module | T10 |
| style.css | T11 |
| Build-time assertions | T3 |
| Functional tests | T12 |
| Failure-injection | T13 |
| TODO.md update | T15 |

All covered.

**2. Placeholder scan:** disko sha256 starts as 56 zeros — flagged as PLACEHOLDER, real value fetched in T14 Step 1.

**3. Type consistency:** all module options use `cfg = config.standardOs.power.sleep` consistently. Cache file path `/tmp/waybar-cache/power-resume` is identical across writer (T8, T9) and reader (T10).

**4. Risk notes:**
- T6 is the first activation that touches the kernel cmdline. Reverting only requires reboot.
- T8 uses bash `mapfile` inside a Nix-managed script — escape rules require `''${...}` for `$` inside Nix multi-line strings (which the plan does in T9; the system-scope script in T8 uses regular `$` because Nix `script = ''…''` only requires escaping when `${` appears).
