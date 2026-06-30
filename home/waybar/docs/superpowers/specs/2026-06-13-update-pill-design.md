# Standard-OS UPDATE subsystem: hyper-stable automatic hygiene with two-pill surface

**Date:** 2026-06-13
**Status:** Approved (pending user review of this written doc).
**Triggered by:** 2026-06-12 incident — full-day session migrating waybar daemons into a nix-store derivation was activated via `nixos-rebuild test`-style activations (10+ test generations, gens 378–387). When the user rebooted to validate, the boot entry pointed at the older gen whose systemd units still referenced the deleted `~/.config/waybar/scripts/*.sh` paths. Glass-text + workspace daemons came up exit-127; OPTIONS lost half its modules. Same failure mode had hit the day before. Root cause: no Standard-OS-blessed update workflow existed, so manual `nixos-rebuild` use was the path — and that path has footguns (`test` vs `switch`) the user shouldn't have to remember.
**Scope:** A complete automatic system-hygiene subsystem ("UPDATE") that leverages NixOS-stable's atomic generations, dry-build, bootable rollback, and per-gen retention to perform channel updates, source application, GC, store optimisation, and security-advisory checks **without user input**, with a verify-and-auto-rollback gate that makes "an update can never leave the system broken" the runtime invariant. The OPTIONS surface is two pills: an *update-pending* status indicator (visible only while the pipeline is working) and a *reboot-pending* pill (visible only when a successful update needs a reboot to fully apply). No click is required for normal operation; click on the error-state update pill opens the persisted log, click on reboot-pending opens a rofi reboot/dismiss prompt.

---

## Purpose

The 2026-06-12 incident was the second time in two days the same trap fired. The trap has three failure surfaces stacked on top of each other:

1. **Manual `nixos-rebuild` use is the only blessed update path.** The user has to remember the difference between `switch`, `test`, `boot`, `dry-activate`, and pick the right one — without a hint from the UI that the choice matters.
2. **Activation drift is invisible until reboot.** `nixos-rebuild test` activates the new system in RAM but does *not* update the bootloader. The bar looks fine. The user reboots — sometimes hours later, to validate unrelated work — and the boot entry restores the previous gen. Yesterday's edits silently vanish.
3. **Hygiene actions (GC, channel updates, store optimisation, security patches) are entirely on the user.** They never happen unless the user remembers. The "freshly-updated system" feeling that defines a healthy distro experience is replaced by ambient guilt.

This spec replaces all three with a single automatic pipeline. Detection runs every 5 minutes; when anything is pending AND the user isn't actively working in a fullscreen app, the pipeline fires in the background. Each phase is gated on safety invariants from NixOS's atomic model — the system cannot enter a broken state from an update, because every transition either verifies or rolls back. The user experience is "the system is always up to date, nothing nags, nothing needs deciding, and once in a while a soft tooltip mentions 'last updated 2 days ago'." The non-negotiables from the standard-os skill — OPTIONS as the shell, closed budget, parents-naturally-uncolored, input-acknowledged/context-silent, same-option-same-look — are preserved end-to-end. No new colours, motions, surfaces, or glyphs are introduced; the design composes from the existing primitives.

---

## Architecture overview

```
Before:

  /etc/nixos/home/                              (user edits source)
   ├─ commit                                    (HEAD advances)
   └─ ?                                         (no automatic activation)

  ~/.config/waybar/                             (manual workflow)
   └─ rebuild-pending pill (lit on commits ahead)
        click → standard-os-rebuild-prompt rofi
                → user picks `switch` / `test` / cancel
                → footgun: `test` doesn't survive reboot.

  GC, channel updates, optimisation, advisories: never happen.


After:

  /etc/nixos/home/                              (user edits source)
   ├─ commit                                    (HEAD advances)
   └─ standard-os-update.timer  (5min cadence)
        ↓
        scheduler decides:
          - check detection state (source, channel, boot, GC, optimise, advisories)
          - if nothing pending → exit
          - if idle gates fail → defer
          - else → spawn standard-os-update pipeline
        ↓
        Pipeline (Phases 0–7, atomic, auto-rollback on Phase 4 failure):
          0  pre-flight self-test          (refuse if existing bar is broken)
          1  channel update                (only if channel-ahead; safe — no activation)
          2  build                          (dry-build; failure → abort, no system change)
          3  switch                         (nixos-rebuild switch; atomic activation)
          4  verify                         (waybar-self-test; if RED → auto-rollback)
          5  GC                             (only if overdue + retention policy)
          6  optimise                       (only if monthly cadence elapsed)
          7  signal                         (lights reboot-pending if boot diverged;
                                            fires notify-send "system updated" toast)

  OPTIONS SYSTEM zone:
   ├─ custom/update-pending                 (hidden at rest; opt-breathe while pipeline runs;
                                            opt-no on error until acknowledged / 24h)
   └─ custom/reboot-pending                 (hidden at rest; opt-pin-orange when boot diverged;
                                            click → rofi reboot/dismiss)
```

Source-of-truth for the update pipeline lives in `/etc/nixos/home/waybar/scripts/` (the established waybar-scripts derivation, materialised into `/nix/store/` at build). System-level integration (polkit rule + tmpfiles entry for `/var/lib/standard-os/`) lives under `/etc/nixos/modules/`. Both are pure Nix; no `$HOME` runtime dependency.

---

## The umbrella verb: "update"

A single user-facing concept covers every hygiene action: **update**. The pill is called "update," the script is `standard-os-update`, the tooltip says "Updating…," the rofi prompt for reboot says "Reboot now / Dismiss." Internally each phase has a precise NixOS name (`nix-channel --update`, `nixos-rebuild dry-build`, `nixos-rebuild switch`, `nix-collect-garbage`, `nix-store --optimise`, vulnix), but the user surface never names them.

Why one word: every hygiene action belongs to the same conceptual cycle — bring the system to a newer, healthier state. Distinguishing between "channel update" and "garbage collection" in the UI would force the user to learn nix semantics. The umbrella also makes the pipeline composable — a click (or a timer fire) doesn't need to know what's pending; it just runs `standard-os-update`, which decides phase-by-phase what to do.

---

## Detection (what signals "something pending")

The scheduler script reads or refreshes six cached signals every 5 minutes:

1. **Source-ahead** — `git -C /etc/nixos/home rev-parse HEAD ≠ /run/standard-os/activated-commit`. Cheap, runs every tick.
2. **Boot-diverged** — `readlink /run/current-system ≠ readlink /run/booted-system`. Cheap, runs every tick. (Routes to the *reboot* pill, not the update pill — see "Pill-vs-pill responsibility" below.)
3. **Channel-ahead** — comparison of cached upstream channel hash against today's. Heavy (HTTP fetch), runs at most every 24h via `last-channel-check-hash` + `last-channel-check-time` files in `/var/lib/standard-os/`.
4. **GC overdue** — derived from `nix-env --list-generations -p /nix/var/nix/profiles/system | wc -l` and per-gen timestamps. Local-only check, runs every tick. Threshold: any gen older than 14 days **AND** total gen count > 10.
5. **Optimise overdue** — `last-optimise-timestamp` file in `/var/lib/standard-os/` more than 30 days old.
6. **Security advisory** — vulnix scan of installed packages (L5; not in L1). Heavy, runs at most every 24h.

The scheduler treats these as boolean "any pending?" inputs. The pipeline phases each have their own per-phase gate so a partial pipeline (channel-update-only, GC-only) is well-defined.

A single cache file `/tmp/waybar-cache/update-state` carries the detection summary as JSON: `{ "pending": ["source", "channel"], "phase": null, "error": null, "since": <epoch> }`. The update pill emitter reads this every 2s (existing pill_write cadence) and renders accordingly.

---

## The pipeline (Phases 0–7, the bullet-proof core)

The pipeline is `standard-os-update`, a single bash script with one execution lock (`/run/standard-os/update.lock`) — at most one run at a time, system-wide.

### Phase 0 — Pre-flight self-test

Run `waybar-self-test`. If failures detected (any required daemon down, any required cache empty), refuse to start the pipeline. Set `update-state.error = "pre-flight"`, fire the error pill with tooltip "Update deferred — existing issues to resolve first." Rationale: an update on top of a broken bar can mask the underlying problem, and the auto-rollback path depends on the post-switch self-test being a reliable signal. Phase 0 ensures Phase 4 has a known-good baseline to compare against.

The pre-flight check is non-destructive — exit and try again at the next 5-minute tick. If the system stabilises on its own (e.g., a transient daemon restart cycle completes), the next pipeline run proceeds.

### Phase 1 — Channel update

Run only if `channel-ahead` was detected. Execute `pkexec nix-channel --update` and re-run the channel-hash check to confirm the new hash. On non-zero exit, abort the pipeline before any activation — the running system is untouched. Channel update is a pure metadata fetch; it doesn't change `/run/current-system`.

### Phase 2 — Build (dry)

Execute `pkexec nixos-rebuild dry-build` against the current source + (possibly newly-fetched) channels. If the build fails — missing dependency, syntax error in a .nix file, broken upstream package — the pipeline aborts before activation. The running system is unchanged; the error log captures the failure for the user.

Dry-build is the cheapest safety gate Nix gives us. It catches every error that would otherwise surface as "the activation script crashed halfway through, leaving the system in a hybrid state." After dry-build succeeds, the new derivation is realised in the store and ready for atomic switch — Phase 3 is just a bootloader update + activation script run, both atomic.

### Phase 3 — Switch (atomic activation)

Execute `pkexec nixos-rebuild switch`. This:
- Creates a new system generation (bootloader entry).
- Updates `/run/current-system` to point at the new derivation.
- Runs activation scripts (writes `/run/standard-os/activated-commit`, replays systemd-user unit files, etc.).
- Reloads / restarts changed systemd units.

The switch itself is atomic at the bootloader and `/run/current-system` symlink layers. The activation script's individual operations (systemd unit reload, etc.) are not transactional, but each is local and idempotent — a partial activation leaves the system in a known state that Phase 4 will catch.

### Phase 4 — Verify + auto-rollback

Wait 5 seconds for systemd-user reloads to settle. Run `waybar-self-test`. If GREEN, proceed to Phase 5. If RED:

1. Execute `pkexec nixos-rebuild switch --rollback` — atomic return to the previous generation.
2. Wait 5 more seconds; run `waybar-self-test` again. (If THIS fails too, the system was already broken pre-update and the pipeline writes a CRITICAL error state — this is the case where human intervention is genuinely needed.)
3. Write the verify failure details to `/var/lib/standard-os/last-update-error.log`.
4. Set `update-state.error = "verify-failed-rolled-back"`. Fire the error pill: tooltip "Update reverted: <one-line summary>".
5. Fire `notify-send` "Update was reverted — system is unchanged" with action "Show details" that opens the log.

Auto-rollback is the runtime invariant that makes "an update can never break the system" true. The previous generation's derivation, systemd units, kernel, and initrd are all still in the store; `--rollback` repoints `/run/current-system` and re-activates that gen. The maximum visible duration of a broken state is ~10 seconds.

### Phase 5 — GC

Only runs if `GC overdue` was true at Phase 0 AND the new gen from Phase 3 has been verified GREEN. Execute `pkexec nix-collect-garbage --delete-older-than 14d`, then post-process to enforce the gen-count floor: if fewer than 10 system generations remain after the time-based delete, abort GC mid-flight (no nixpkgs primitive does this directly; the script lists generations, sorts by index, and either accepts the delete-older-than result or restores by skipping deletes that would breach the floor).

Retention policy as approved: **keep last 10 system generations AND anything from the last 14 days**, whichever is more conservative. Rollback within 2 weeks is always available; in heavy iteration weeks (10+ rebuilds/day) extra gens stay.

### Phase 6 — Optimise

Only runs if `optimise overdue` was true. Execute `pkexec nix-store --optimise`. Pure dedup operation — replaces identical store entries with hardlinks. No risk to the running system. Runs at most monthly.

### Phase 7 — Signal post-state

- Update `update-state` cache: `pending = []`, `phase = null`, `error = null`. Update pill clears.
- If `readlink /run/current-system ≠ readlink /run/booted-system` (which Phase 3 just made true): the reboot pill lights via its own emitter on the next 2s tick.
- If anything user-visible happened (channel update applied, source switched), fire `notify-send "System updated — X packages refreshed"` toast (auto-dismiss after 5s). This is the "freshly-updated" tactile feedback.
- Append a notif-center entry summarising what ran: timestamp, phases executed, bytes reclaimed by GC, brief subject of source commits applied. The notif-center entry is silent (no badge bump) — it's history for the curious, not a notification.
- Update `/var/lib/standard-os/last-known-good-gen` if the booted gen has now been verified GREEN for >60s. (Used by future boot-watchdog logic; not load-bearing in L1.)

Each phase aborts the next on failure. A successful Phase 3 + Phase 4 stays — a failed Phase 5 (GC) doesn't roll back the switch; it just leaves GC un-run with an error log entry. The conservative rule: anything that touches `/run/current-system` is gated on verify; anything that only touches store state (GC, optimise) is best-effort.

---

## The scheduler

`standard-os-update-scheduler` is the entry point fired by `standard-os-update-check.timer` (user-systemd, `OnBootSec=5min`, `OnUnitActiveSec=5min`). Each tick:

```
1. Refresh detection state.
   - Cheap checks (source-ahead, boot-diverged, GC count) every tick.
   - Heavy checks (channel-ahead, vulnix) only if cached result is >24h old.
   - Update /tmp/waybar-cache/update-state with current pending list.

2. If no pending work AND no active pipeline → exit silently.
3. If pipeline lock /run/standard-os/update.lock exists → exit (already running).
4. Idle gates:
     a. hyprctl -j activewindow | jq '.fullscreen' — must be 0 (no fullscreen app).
     b. last input idle time — must be >5 minutes.
     c. DND state (/tmp/waybar-cache/notif-dnd "on") — must be off.
   If any gate fails → exit; try again next tick.
5. Spawn standard-os-update detached (systemd-run --user --scope) and exit.
```

The scheduler's job is timing, not pipeline logic. It never invokes nix commands directly. The pipeline's lock file is the single source of truth for "already in progress."

Idle detection details:

- **Fullscreen**: `hyprctl -j activewindow | jq '.fullscreen != 0'` reliably indicates the focused window is in fullscreen mode (gaming, video, presentations).
- **Input idle**: best signal on Wayland/Hyprland is logind's `IdleHint` (via `loginctl show-session $XDG_SESSION_ID -p IdleHint -p IdleSinceHint`). Fallback: `who -u` IDLE column. The 5-minute threshold gives normal task-switching room without deferring forever during steady work.
- **DND**: the notif spine writes `/tmp/waybar-cache/notif-dnd` with the current DND state. Respecting DND treats the user's explicit focus signal as authoritative — if they've turned on DND to concentrate, the pipeline waits.

Future hooks (out of L1, reserved): mpris active-playback gate, PulseAudio mic-active gate (conference call detection), networking-class gate (defer on metered connections). The scheduler is structured so adding a guard is a one-line check.

---

## The pills (the OPTIONS surface)

### `custom/update-pending` (SYSTEM zone, slot just before `waybar-self-test`)

| State | Class | Glyph | Tooltip | Visible when |
|---|---|---|---|---|
| Hidden | `opt-pill`, text="" | — | — | Steady-state (most of the time) |
| Working | `opt-pill opt-pin-orange opt-breathe` | FA sync U+F021 | Phase-specific: "Checking…", "Updating channels…", "Building…", "Activating…", "Verifying…", "Cleaning up…", "Optimising…" + elapsed seconds | Pipeline lock held |
| Error | `opt-pill opt-no` | FA sync U+F021 | "Update failed and was reverted — click for details" | Error not acknowledged; auto-clears after 24h |

Click behaviour:
- Hidden / Working: no click handler (the pill is a status indicator; nothing to act on).
- Error: opens `/var/lib/standard-os/last-update-error.log` in `${EDITOR:-less}` via a notify-send action button, OR — fallback for desktop click — spawns a kitty/foot window with the log. Click also acknowledges the error and clears the pill.

The pill emitter is a tiny script (`standard-os-update-pill-emitter`) that reads `/tmp/waybar-cache/update-state`, follows the lock-file state, and renders one of the three rows above. Wakeup signal RTMIN+10 (existing global pill refresh signal).

### `custom/reboot-pending` (SYSTEM zone, immediately right of `update-pending`)

| State | Class | Glyph | Tooltip | Visible when |
|---|---|---|---|---|
| Hidden | `opt-pill`, text="" | — | — | Boot parity holds OR dismissed |
| Available | `opt-pill opt-pin-orange` | FA power U+F011 | "Reboot recommended to finalize updates" | `current-system ≠ booted-system` AND not dismissed |

Click → opens `standard-os-reboot-prompt` rofi dialog:
- **Reboot now** → invokes `standard-os-shutdown-guard reboot` (existing path; respects guard semantics).
- **Dismiss** → writes `/run/standard-os/reboot-dismissed` containing the current `readlink /run/booted-system`. Pill emitter stays hidden while marker matches current booted-system; the moment a new switch produces a different booted-system relationship, the marker invalidates and the pill returns. `/run` is tmpfs, so an actual reboot also clears the marker.

The reboot pill is the ONE place in the design where the user is asked to act. The pill is informational — the user keeps full control of reboot timing.

### Closed-budget audit

- Colours used: `opt-pin-orange` (already in budget), `opt-no` (already). 0 new.
- Motions used: `opt-breathe` (already). 0 new.
- Surfaces: `opt-pill` (parent). 0 new.
- Borders: none. (Rule 3 respected.)
- Glyphs: FA sync U+F021 (already used by retired rebuild-pending), FA power U+F011 (already in SYSTEM power pill). 0 new.

---

## Pill-vs-pill responsibility (no overlap)

To prevent the bar from ever showing two SYSTEM-zone pills for one conceptual problem, the conditions partition cleanly:

| Condition | Update pill | Reboot pill |
|---|---|---|
| Source-ahead | yes (drives pipeline) | no |
| Channel-ahead | yes (drives pipeline) | no |
| GC overdue | yes (drives pipeline) | no |
| Optimise overdue | yes (drives pipeline) | no |
| Security advisory | yes (drives pipeline) | no |
| Pipeline currently running | yes (Working state) | no |
| Pipeline failed and rolled back | yes (Error state) | no |
| `current ≠ booted` AND nothing-else-pending | no | yes |

After a successful pipeline, source-ahead / channel-ahead / GC-overdue clear, and the only remaining non-steady-state condition is the post-switch boot divergence. The update pill clears; the reboot pill lights. Clean handoff.

If both source-ahead AND boot-diverged exist at scheduler time (rare; would mean a prior pipeline succeeded but the user hasn't rebooted AND new commits arrived since), the scheduler still runs the pipeline. Phase 3's new switch supersedes the prior unresolved boot-diverged state — there's now only one outstanding "you should reboot," not two.

---

## Privilege escalation (polkit)

New module `/etc/nixos/modules/standard-os-update-polkit.nix`:

```nix
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
```

Scope: exactly four binaries from `/run/current-system/sw/bin/`. No password prompt; non-interactive (the rule is `polkit.Result.YES`, not `polkit.Result.AUTH_ADMIN_KEEP`). Subject must be local, active session, in wheel — sane defaults that limit the rule's reach to the actual logged-in user.

Verification: a user-systemd-service can invoke `pkexec nixos-rebuild switch` and it will run as root without a password challenge. Verified by `pkaction --action-id org.freedesktop.policykit.exec --verbose` post-rebuild.

Why polkit over sudoers NOPASSWD: polkit's rule engine evaluates per-call; sudoers is binary. Polkit also integrates cleanly with systemd-user-services and notification daemons. Sudoers would require a `Defaults!CMD setenv` workaround for the systemd-user execution context.

---

## Channel pinning and version-jump policy

NixOS channels are pinned to `nixos-25.11` (stable). The update pipeline applies:
- Patches within 25.11: security fixes, bug fixes, dependency rebuilds. Always safe to auto-apply.
- Does NOT apply: cross-version jumps (25.11 → 26.05). These require schema migrations, occasional breakage, and explicit user acknowledgment.

Version-jump path (out-of-pill, deliberate):
- User runs `sudo nix-channel --add https://nixos.org/channels/nixos-26.05 nixos`.
- Next scheduler tick detects the channel name changed (cached `last-channel-name` differs).
- Pipeline does NOT auto-run the cross-version switch. Instead, update pill lights opt-no (warning, not error) with tooltip "Cross-version upgrade staged — manual review required" and a notif-center entry explaining the procedure.
- The actual cross-version switch happens manually with full user attention, after backups, etc.

This pinning is the single biggest "an update will never break the system" lever NixOS gives us, and the design protects it explicitly. The auto-pipeline is for stable-channel hygiene only.

---

## Error UX

Three failure classes, three behaviours:

1. **Pre-flight failure** (Phase 0): pill goes opt-no with tooltip "Update deferred — existing issues to resolve first." No notify-send (this is recoverable). Auto-clears the moment the underlying issue clears (i.e., waybar-self-test goes GREEN). No error log entry — the existing self-test pill is the user-visible signal for the underlying issue.

2. **Channel or build failure** (Phase 1 or Phase 2): pill goes opt-no with tooltip "Update failed — click for details." Single notify-send "Update failed — system unchanged" with "Show details" action. Error log at `/var/lib/standard-os/last-update-error.log` captures the failed nix command + stderr, prefixed with which phase failed (`[channel]` or `[build]`). Running system is untouched.

3. **Verify failure with auto-rollback** (Phase 4): pill goes opt-no with tooltip "Update reverted — click for details." Single notify-send "Update was reverted — system is unchanged" with "Show details" action. Error log captures the new derivation hash, the self-test failure messages, and the rollback exit status. The running system is identical to what it was before the pipeline started.

In all three cases, clicking the error-state pill opens the log AND acknowledges the error (pill returns to hidden). If the next scheduler tick still detects pending work, the pipeline retries — L1 retries at the base 5-minute cadence until the user intervenes or the underlying issue resolves. A smarter backoff (e.g., "after 3 failures, defer until midnight") is L2 work and is explicitly out of L1 scope; the trade-off is that a persistently-broken upstream channel can produce up to ~288 retries/day, which is annoying but never destructive (every retry aborts before activation).

---

## State files

All state lives under `/var/lib/standard-os/` (persistent) and `/run/standard-os/` (tmpfs, per-boot):

```
/var/lib/standard-os/
  last-channel-check-time             (epoch; updated every channel check)
  last-channel-check-hash             (sha; the upstream hash we last fetched)
  last-channel-name                   (e.g. "nixos-25.11"; version-jump detection)
  last-optimise-timestamp             (epoch; updated after Phase 6)
  last-update-error.log               (most recent failure; persists across reboot)
  last-known-good-gen                 (the booted-system path that's been verified GREEN
                                      for >60s; future boot-watchdog use)
  last-update-summary.log             (history; each successful pipeline appends one line)

/run/standard-os/
  activated-commit                    (existing; written by standard-os-commit-tracking)
  update.lock                         (created by pipeline; deleted on exit)
  reboot-dismissed                    (created by reboot-pill dismiss; matched against
                                      current booted-system)
```

The `/var/lib/standard-os/` directory is created by a `systemd.tmpfiles` rule wired in `standard-os-update-state.nix`. The `/run/standard-os/` directory is already created by `standard-os-commit-tracking.nix`'s activation script.

---

## The "updated system" feeling

The user-experience principle: NO badges, NO "update available" nags, NO persistent indicators. The bar is silent unless work is in progress or attention is required.

Sources of "freshly-updated" sensation:

1. **Absence of nagging**: there is no "update available" state. The pipeline either runs (and the bar shows "Updating…" briefly) or it doesn't (and nothing visible changes). The user never has to decide whether to update.

2. **Reassurance toast on success**: when a pipeline finishes with at least one user-visible action (channel update applied, source switched), fire `notify-send "System updated — X packages refreshed • Y MB downloaded"` with a 5-second timeout. Looks like macOS's update toast. Single source of "freshly-updated" feedback.

3. **Tooltip-on-demand**: hovering the `waybar-self-test` slot (hidden when healthy) shows the system age in its tooltip: "All clear · last updated 2 days ago · 18 generations". Information available when sought, never in the way.

4. **Notif-center history**: each pipeline run appends an entry: timestamp, phases executed, packages refreshed, GC bytes reclaimed, commit subjects applied. Silent (no badge bump). User can scroll through "what changed when" if curious. Builds trust over time.

5. **No version anxiety**: the channel-pin policy means the user never sees a major-version surprise. The system stays on 25.11 indefinitely; only patches roll in.

---

## Phased rollout

The spec is one cohesive design but ships in layers. Each layer is independently useful, reversible, and tested before the next.

### L1 — Foundation: auto-switch + verify + auto-rollback + reboot pill

Smallest unit that fixes today's incident class entirely. Includes:
- Polkit rule + state dir + scheduler timer + scheduler script.
- Pipeline phases 0, 2, 3, 4, 7 (no channels, no GC, no optimise yet).
- `custom/update-pending` pill (Hidden / Working / Error states).
- `custom/reboot-pending` pill + rofi dismiss prompt.
- Idle gates: fullscreen + input-idle + DND.
- Retire `custom/rebuild-pending` from config.jsonc; keep `standard-os-rebuild-prompt.sh` one cycle then delete.
- Migrate `waybar-self-test.sh` to emit `update-pending` and `reboot-pending` instead of the legacy `rebuild-pending`.

L1 alone kills "the test-then-reboot bug": no Standard-OS path runs `test`, and every switch is gated by verify+rollback. Source-ahead commits get picked up within 10 minutes automatically.

### L2 — Channel updates (weekly stable refresh)

Adds Phase 1. Adds the 24h-cached channel-ahead detection in scheduler. Adds the `last-channel-check-*` state files. The pipeline now keeps the system on the freshest 25.11 patch tip.

### L3 — Garbage collection with retention

Adds Phase 5. Implements the keep-10-AND-keep-14d retention. Wires the gen-count and gen-age detection into the scheduler. First run will likely reclaim multi-GB on most boxes.

### L4 — Store optimisation

Adds Phase 6 and the monthly cadence check. Pure dedup; user-invisible.

### L5 — Security advisories + escalation

Adds vulnix integration. Critical CVEs may bypass the idle gates (configurable via Nix flag). Notif-center entries for CVE matches. This layer is exploratory and the polkit scope may need re-evaluation.

Each layer adds detection conditions and pipeline phases without changing earlier layers' contracts. The L1 safety nets (pre-flight, dry-build, verify+rollback) protect every later addition.

---

## File layout (what gets added / changed)

```
/etc/nixos/modules/                                (new files / one edit)
  standard-os-update-polkit.nix                    (new) — polkit rule
  standard-os-update-scheduler.nix                 (new) — user-systemd timer + service
  standard-os-update-state.nix                     (new) — tmpfiles for /var/lib/standard-os/
  standard-os-commit-tracking.nix                  (existing; unchanged)

/etc/nixos/home/waybar/scripts/                    (new scripts / two edits)
  standard-os-update                               (new) — the pipeline
  standard-os-update-scheduler                     (new) — timer entry point
  standard-os-update-pill-emitter                  (new) — reads cache, writes pill
  standard-os-reboot-prompt                        (new) — rofi dialog
  waybar-self-test.sh                              (edit) — emit update-pending + reboot-pending instead of rebuild-pending
  standard-os-rebuild-prompt.sh                    (delete after one cycle)

/etc/nixos/home/waybar/                            (two edits)
  config.jsonc                                     (edit) — rename custom/rebuild-pending → custom/update-pending; add custom/reboot-pending
  style.css                                        (no changes expected — composes from existing primitives)

/var/lib/standard-os/                              (new dir, created by tmpfiles)
  (see "State files" above for contents)
```

The waybar-scripts derivation already includes the source dir under `/etc/nixos/home/waybar/scripts/`; new scripts there are picked up automatically by the next rebuild. The polkit, scheduler, and state modules import in `home.nix` (for the waybar-side) and `configuration.nix` (for the system-side).

---

## Testing

Manual verification on each layer before promotion:

**L1**:
- After a rebuild, edit `/etc/nixos/home/waybar/config.jsonc` (e.g., change a tooltip), commit, wait 10 minutes. Pipeline should fire; pill should show "Updating…" → clear; reboot pill should light.
- Force a build failure (introduce a syntax error in a .nix file, commit). Pipeline should abort at Phase 2; pill should show error; running system untouched. Fix the error; pipeline auto-retries on next tick.
- Force a verify failure: rebuild with a waybar.nix change that breaks a daemon's ExecStart. Pipeline should switch then auto-rollback at Phase 4; pill should show error; `systemctl --user is-active` for daemons should be green (because rollback restored prior gen).
- Click error pill → log opens, pill clears.
- Reboot pill click → rofi → dismiss → pill hides; new commit → pill reappears.
- Open a fullscreen video → scheduler should defer; close video → pipeline fires.

**L2**: requires upstream channel actually advancing. Simulate by setting `last-channel-check-hash` to an old known hash; scheduler should detect channel-ahead next tick. Verify `nix-channel --update` runs in the pipeline and the cache updates.

**L3**: requires gen accumulation. After 10+ rebuilds, verify scheduler detects GC overdue and Phase 5 runs. Verify the retention floor: after GC, `nixos-rebuild list-generations | wc -l` ≥ 10. Verify no gen newer than 14 days was deleted.

**L4**: verify `nix-store --optimise` runs once monthly and the timestamp updates.

**L5**: requires vulnix wiring. Defer test plan to L5 spec.

---

## Open questions deferred to implementation

- **Rofi dismiss action** for the reboot pill: matches the existing `standard-os-shutdown-guard` rofi shape, but the dismiss option text needs UX tuning. "Dismiss" is the spec wording; implementer may prefer "Not now" or "Later" — to be decided at writing-plans time with a one-line note in the plan.
- **Error log viewer**: spec says `${EDITOR:-less}` via terminal pop, fallback notify-send action. Exact terminal binary (`foot`, `kitty`, etc.) to be chosen at implementation time to match the standard-os hyprland config.
- **Cooldown algorithm** for repeated failures: L1 uses base 5min retry indefinitely. The "after 3 failures, defer until midnight" backoff is L2 work. Spec out of scope here.
- **Notif-center entry format**: should match the existing entry format used by other system events. Implementer to confirm shape against current notif-center daemon.

---

## Why this prevents the original bug (recap)

1. **No more `test` in any path.** Pipeline always runs `switch`; the option doesn't exist for the user.
2. **Activation drift made visible AND ephemeral.** Reboot pill lights immediately when boot diverges. No silent days-long drift between activation and reboot.
3. **Bad activations auto-revert.** Phase 4 verify + auto-rollback means the maximum visible duration of a broken state is ~10 seconds, and the previous gen is always preserved.
4. **No manual rebuild workflow needed.** The scheduler runs the pipeline; the user doesn't need to remember `nixos-rebuild`, `switch`, `test`, etc. The whole footgun-shaped surface area is removed.
5. **Hygiene actions happen automatically.** GC, channel updates, store optimisation, security patches all roll in on the timer. The system stays healthy without anyone thinking about it.
6. **NixOS-stable as foundation.** Channel-pin policy means only within-25.11 patches auto-apply. Major-version risk is gated behind explicit user action.
7. **Defense in depth.** The existing `custom/waybar-self-test` pill remains as a downstream catch-all: anything that escapes the pipeline (e.g., a daemon crash unrelated to update activity) surfaces as opt-no warning. The new design supersedes the upstream cause of yesterday's bug; the existing layer continues to catch unrelated runtime issues.

For the AI / future agents working on this distro, the existing feedback memory `feedback_nixos_rebuild_switch_not_test.md` is the discipline-layer fix — agents will never instruct "reboot to test" after a `test` activation again. The auto-pipeline removes the manual `nixos-rebuild` surface area, so the discipline memory becomes a belt-and-suspenders backup, not the primary defense.

---

## Non-goals

- **Cross-version channel jumps** (25.11 → 26.05). Out of scope. User-deliberate path.
- **Hyprland or kernel-config changes** that require user judgment (e.g., experimental kernel modules). The pipeline applies what's in `/etc/nixos/home/*.nix` after the user's commit; the user controls what those files say.
- **Multi-machine coordination.** Single-machine design. Standard-OS-as-distribution-fleet is a separate spec.
- **Network-awareness for metered connections.** Reserved hook; not in L1.
- **Auto-reboot during idle windows.** Considered and rejected: data-loss risk outweighs the marginal "no reboot pill" benefit. The reboot pill stays user-controlled.
