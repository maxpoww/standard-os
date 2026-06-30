# Standard-OS UPDATE pill — L1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual `nixos-rebuild` workflow with an automatic, bullet-proof update pipeline that runs `nixos-rebuild switch` on a 5-min idle-gated cadence, verifies the result with `waybar-self-test`, and auto-rolls back on failure. Surfaces two SYSTEM-zone pills: `custom/update-pending` (status during pipeline) and `custom/reboot-pending` (after a successful update changes the booted gen). L1 closes the 2026-06-12 test-then-reboot incident class entirely.

**Architecture:** Three layers — (a) `/etc/nixos/modules/standard-os-update-{state,polkit,scheduler}.nix` declare tmpfiles, polkit scope, and the user-systemd timer; (b) four new shell scripts in `/etc/nixos/home/waybar/scripts/` (`standard-os-update`, `standard-os-update-scheduler`, `standard-os-update-pill-ack`, `standard-os-reboot-prompt`) implement the pipeline, scheduler, click-acknowledgement, and reboot rofi; (c) `waybar/config.jsonc` swaps `custom/rebuild-pending` → `custom/update-pending` and adds `custom/reboot-pending`, and `waybar-self-test.sh` emits the new `reboot-pending` cache instead of `rebuild-pending`. Every risky operation gates on dry-build pre-flight and post-switch verify+rollback.

**Tech Stack:** Nix (channels-based), NixOS 25.11, home-manager-as-NixOS-module, polkit, systemd-user timers, bash + lib/pill.sh, waybar custom modules, rofi, hyprctl, loginctl, notify-send.

**Spec:** `/etc/nixos/home/waybar/docs/superpowers/specs/2026-06-13-update-pill-design.md` (commit `d51c9a0`).

---

## Pre-flight checks (Task 0)

### Task 0: Confirm preconditions

**Files:** Read-only.

- [ ] **Step 1: Verify the working tree is clean**

Run: `cd /etc/nixos/home && git status -s`
Expected output: empty (no uncommitted edits).

- [ ] **Step 2: Verify the current bar is healthy**

Run: `systemctl --user is-active waybar waybar-glass-text-daemon waybar-workspace-daemon`
Expected: all three print `active`.
Run: `cat /tmp/waybar-cache/waybar-self-test`
Expected: `{"text":"","class":["opt-pill","dark"]}` or similar (empty text — pill hidden, meaning healthy).

- [ ] **Step 3: Confirm channel is nixos-25.11**

Run: `sudo nix-channel --list`
Expected: contains a line ending with `nixos-25.11`.

- [ ] **Step 4: Read the spec**

Run: `less /etc/nixos/home/waybar/docs/superpowers/specs/2026-06-13-update-pill-design.md`
Read the Architecture, Pipeline (Phases 0–7), Pill table, Scheduler sections in full.

---

## Phase A — System-level Nix modules

### Task 1: tmpfiles module for /var/lib/standard-os/

**Files:**
- Create: `/etc/nixos/modules/standard-os-update-state.nix`
- Modify: `/etc/nixos/configuration.nix` (imports list)

- [ ] **Step 1: Write the module**

Create `/etc/nixos/modules/standard-os-update-state.nix`:

```nix
# /var/lib/standard-os/ — persistent state for the UPDATE subsystem.
# Lives in /var/lib (not /tmp) so error logs and history survive reboots.
# Owned by user max:users so the user-systemd update pipeline can write
# without escalation.
{ config, lib, ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/standard-os 0755 max users -"
  ];
}
```

- [ ] **Step 2: Add to configuration.nix imports**

Open `/etc/nixos/configuration.nix`, find the `imports = [` block (around line 18). Add the new module to the list (alphabetical or trailing, matching the existing style):

```nix
  imports = [
    # ... existing entries ...
    ./modules/standard-os-update-state.nix
  ];
```

- [ ] **Step 3: Verify the module parses (no rebuild yet)**

Run: `sudo nix-instantiate --parse /etc/nixos/modules/standard-os-update-state.nix > /dev/null && echo OK`
Expected output: `OK`.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos
sudo git add /etc/nixos/configuration.nix /etc/nixos/modules/standard-os-update-state.nix 2>/dev/null || git add configuration.nix modules/standard-os-update-state.nix
# Note: /etc/nixos may or may not be a git repo. If not, skip git for this file.
```

(If `/etc/nixos` is not a git repo, skip commit for system files — they ride on the active nixos-rebuild generation.)

---

### Task 2: polkit module for pkexec scope

**Files:**
- Create: `/etc/nixos/modules/standard-os-update-polkit.nix`
- Modify: `/etc/nixos/configuration.nix` (imports list)

- [ ] **Step 1: Write the module**

Create `/etc/nixos/modules/standard-os-update-polkit.nix`:

```nix
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
```

- [ ] **Step 2: Add to configuration.nix imports**

Append to the `imports` block in `/etc/nixos/configuration.nix`:

```nix
    ./modules/standard-os-update-polkit.nix
```

- [ ] **Step 3: Verify the module parses**

Run: `sudo nix-instantiate --parse /etc/nixos/modules/standard-os-update-polkit.nix > /dev/null && echo OK`
Expected output: `OK`.

---

### Task 3: Activate Phase A and verify

- [ ] **Step 1: Build first (dry run, no activation)**

Run: `sudo nixos-rebuild dry-build 2>&1 | tail -20`
Expected: ends with no errors. The output should mention the new modules being evaluated.

- [ ] **Step 2: Switch**

Run: `sudo nixos-rebuild switch`
Expected: succeeds with no errors. New generation appears.

- [ ] **Step 3: Verify /var/lib/standard-os/ exists**

Run: `ls -la /var/lib/standard-os/`
Expected: directory exists, owned by max:users, mode 755.

- [ ] **Step 4: Verify polkit rule is registered**

Run: `pkaction --action-id org.freedesktop.policykit.exec --verbose 2>&1 | head -5`
Expected: lists the action; does not error.

- [ ] **Step 5: End-to-end polkit test**

Run (as user max): `pkexec /run/current-system/sw/bin/nixos-rebuild --version`
Expected: prints the nixos-rebuild version with NO password prompt, NO authentication agent popup. If a password prompt appears, the polkit rule has a typo or scope mismatch — debug before continuing.

- [ ] **Step 6: Negative-scope polkit test**

Run (as user max): `pkexec /run/current-system/sw/bin/ls /root 2>&1 | head -5`
Expected: prompts for authentication (because `ls` is NOT in the allowed list). Press Esc to cancel. This confirms the rule is properly scoped.

---

## Phase B — The pipeline script (standard-os-update)

### Task 4: Pipeline skeleton (lock, paths, dispatch)

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/standard-os-update`

- [ ] **Step 1: Write the skeleton**

Create `/etc/nixos/home/waybar/scripts/standard-os-update` (no `.sh` extension to match the existing `pill` / `pill-child` style and so the waybar-scripts derivation wraps it as a bin):

```bash
#!/usr/bin/env bash
# standard-os-update — the L1 UPDATE pipeline.
#
# Phases (L1 subset; L2–L5 add 1, 5, 6, and CVE checks):
#   0  pre-flight self-test          (refuse if existing bar is broken)
#   2  dry-build                     (nixos-rebuild dry-build)
#   3  switch                        (nixos-rebuild switch — atomic)
#   4  verify + auto-rollback        (waybar-self-test post-switch)
#   7  signal post-state             (notify-send toast, history append)
#
# Invariants:
#   - At most one instance system-wide. /run/standard-os/update.lock is
#     the mutex; flock-acquired with non-blocking flag.
#   - Every phase logs to /var/lib/standard-os/last-update-error.log
#     (truncated on success at Phase 7, preserved on failure).
#   - The "update-pending" pill cache file at /tmp/waybar-cache/update-pending
#     is the user-visible state. Pipeline writes it via pill_write.
#   - On any failure post Phase 3 (switch already happened), execute
#     `nixos-rebuild switch --rollback` before exiting.
#
# Tests source this with STANDARD_OS_UPDATE_LIB_ONLY=1 to skip the main
# body and exercise individual functions.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

# ─── Paths ────────────────────────────────────────────────────────────────
LOCK_FILE="/run/standard-os/update.lock"
ERROR_LOG="/var/lib/standard-os/last-update-error.log"
SUMMARY_LOG="/var/lib/standard-os/last-update-summary.log"
PILL_NAME="update-pending"
# FA sync glyph (U+F021) — 3 bytes UTF-8.
SYNC_GLYPH=$'\xef\x80\xa1'

# ─── Pill helpers (compose with lib/pill.sh's pill_write) ─────────────────
# pill_state_working <phase_label> — show opt-pin-orange + opt-breathe.
pill_state_working() {
    local phase="$1"
    pill_write "$PILL_NAME" "$SYNC_GLYPH" \
        "opt-pill opt-pin-orange opt-breathe" \
        "$phase"
}
# pill_state_error <one_line_summary>
pill_state_error() {
    local summary="$1"
    pill_write "$PILL_NAME" "$SYNC_GLYPH" \
        "opt-pill opt-no" \
        "Update failed — click for details: $summary"
}
# pill_state_clear — empty text → waybar collapses the module.
pill_state_clear() {
    pill_write "$PILL_NAME" "" "opt-pill" ""
}

# ─── Logging ──────────────────────────────────────────────────────────────
log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >> "$ERROR_LOG"
}
log_summary() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >> "$SUMMARY_LOG"
}

# ─── Phase entrypoints (filled in by Tasks 5–9) ───────────────────────────
phase_pre_flight() { return 0; }   # Task 5 fills this
phase_dry_build()  { return 0; }   # Task 6 fills this
phase_switch()     { return 0; }   # Task 7 fills this
phase_verify()     { return 0; }   # Task 8 fills this
phase_signal()     { return 0; }   # Task 9 fills this

# ─── Main pipeline (filled in by Task 10) ─────────────────────────────────
run_pipeline() {
    return 0
}

# ─── Library-only guard ───────────────────────────────────────────────────
[ "${STANDARD_OS_UPDATE_LIB_ONLY:-0}" = "1" ] && return 0

# ─── Single-instance lock ─────────────────────────────────────────────────
mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$ERROR_LOG")"
exec {LOCK_FD}>"$LOCK_FILE"
if ! flock -n "$LOCK_FD"; then
    # Already running — exit silently. Scheduler will retry on next tick.
    exit 0
fi
# Truncate error log only at the START of a successful Phase 7 (Task 10
# handles the lifecycle). Errors from this run accumulate first.

run_pipeline
exit $?
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x /etc/nixos/home/waybar/scripts/standard-os-update`

- [ ] **Step 3: Smoke-test the skeleton runs**

Run: `STANDARD_OS_UPDATE_LIB_ONLY=1 bash /etc/nixos/home/waybar/scripts/standard-os-update && echo OK`
Expected: prints `OK`. (Skeleton sources lib/pill.sh, defines stubs, exits early.)

- [ ] **Step 4: Shellcheck the skeleton**

Run: `shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/standard-os-update`
Expected: no ERROR-severity findings (warnings are OK; the existing scripts also have informational/warning findings).

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add waybar/scripts/standard-os-update
git commit -m "update-pipeline: skeleton (lock, paths, pill helpers, phase stubs)"
```

---

### Task 5: Phase 0 — pre-flight self-test

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/standard-os-update` (fill in `phase_pre_flight`)

- [ ] **Step 1: Write the test first**

Create `/etc/nixos/home/tests/standard-os-update-phases-test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for standard-os-update pipeline phase functions.
# Each phase is exercised in isolation via STANDARD_OS_UPDATE_LIB_ONLY=1.
set -uo pipefail

HERE=$(dirname "$(readlink -f "$0")")
STANDARD_OS_UPDATE_LIB_ONLY=1
# shellcheck source=../waybar/scripts/standard-os-update
. "$HERE/../waybar/scripts/standard-os-update"

fail=0
assert_eq() {
    local got=$1 want=$2 label=$3
    if [[ $got != "$want" ]]; then
        printf '✗ %s\n   got:  %q\n   want: %q\n' "$label" "$got" "$want" >&2
        fail=1
    else
        printf '✓ %s\n' "$label"
    fi
}

# ─── phase_pre_flight ─────────────────────────────────────────────────────
# Stub waybar-self-test to return 0 (healthy) — phase returns 0.
fake_self_test_green() { return 0; }
fake_self_test_red()   { return 1; }

WAYBAR_SELF_TEST_CMD=fake_self_test_green
phase_pre_flight; rc=$?
assert_eq "$rc" "0" "phase_pre_flight: green self-test → 0"

WAYBAR_SELF_TEST_CMD=fake_self_test_red
phase_pre_flight; rc=$?
assert_eq "$rc" "1" "phase_pre_flight: red self-test → 1"

exit "$fail"
```

Make executable: `chmod +x /etc/nixos/home/tests/standard-os-update-phases-test.sh`

- [ ] **Step 2: Run the test — it should fail**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: ✓ for green, ✗ for red (the stub always returns 0 because phase_pre_flight is still `return 0`).

- [ ] **Step 3: Implement phase_pre_flight**

Edit `/etc/nixos/home/waybar/scripts/standard-os-update`. Replace the stub `phase_pre_flight() { return 0; }` with:

```bash
# WAYBAR_SELF_TEST_CMD allows tests to substitute a stub. In production
# it falls back to running the actual waybar-self-test binary, which is
# in our PATH via the waybar-scripts derivation wrapper.
WAYBAR_SELF_TEST_CMD="${WAYBAR_SELF_TEST_CMD:-waybar-self-test}"

phase_pre_flight() {
    pill_state_working "Checking…"
    if "$WAYBAR_SELF_TEST_CMD" >/dev/null 2>&1; then
        return 0
    fi
    log "[pre-flight] waybar-self-test reports failures; deferring update"
    pill_state_error "Existing issues to resolve first"
    return 1
}
```

- [ ] **Step 4: Run the test — should pass**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: both assertions ✓; exit code 0.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add tests/standard-os-update-phases-test.sh waybar/scripts/standard-os-update
git commit -m "update-pipeline: Phase 0 — pre-flight self-test (TDD)"
```

---

### Task 6: Phase 2 — dry-build

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/standard-os-update` (fill in `phase_dry_build`)
- Modify: `/etc/nixos/home/tests/standard-os-update-phases-test.sh` (add test)

- [ ] **Step 1: Append the test**

Add to `tests/standard-os-update-phases-test.sh` before `exit "$fail"`:

```bash
# ─── phase_dry_build ──────────────────────────────────────────────────────
fake_pkexec_ok()   { return 0; }
fake_pkexec_fail() { echo "fake build error" >&2; return 1; }

PKEXEC_CMD=fake_pkexec_ok
phase_dry_build; rc=$?
assert_eq "$rc" "0" "phase_dry_build: pkexec ok → 0"

PKEXEC_CMD=fake_pkexec_fail
phase_dry_build; rc=$?
assert_eq "$rc" "1" "phase_dry_build: pkexec fail → 1"
```

- [ ] **Step 2: Run — should fail**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: ✗ on phase_dry_build assertions (stub returns 0 unconditionally).

- [ ] **Step 3: Implement phase_dry_build**

Replace the stub in `standard-os-update`:

```bash
PKEXEC_CMD="${PKEXEC_CMD:-pkexec}"

phase_dry_build() {
    pill_state_working "Building…"
    local out
    if out=$("$PKEXEC_CMD" /run/current-system/sw/bin/nixos-rebuild dry-build 2>&1); then
        return 0
    fi
    log "[build] dry-build failed:"
    log "$out"
    pill_state_error "Build failed"
    notify-send -a "Standard-OS" "Update failed" "System unchanged — click pill for details" 2>/dev/null || true
    return 1
}
```

- [ ] **Step 4: Run — should pass**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: all 4 ✓, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/standard-os-update-phases-test.sh waybar/scripts/standard-os-update
git commit -m "update-pipeline: Phase 2 — dry-build (TDD)"
```

---

### Task 7: Phase 3 — switch

**Files:**
- Modify: `standard-os-update` (fill `phase_switch`)
- Modify: test file (add test)

- [ ] **Step 1: Append the test**

```bash
# ─── phase_switch ─────────────────────────────────────────────────────────
PKEXEC_CMD=fake_pkexec_ok
phase_switch; rc=$?
assert_eq "$rc" "0" "phase_switch: pkexec ok → 0"

PKEXEC_CMD=fake_pkexec_fail
phase_switch; rc=$?
assert_eq "$rc" "1" "phase_switch: pkexec fail → 1"
```

- [ ] **Step 2: Run — should fail**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: ✗ on phase_switch assertions.

- [ ] **Step 3: Implement phase_switch**

Replace the stub:

```bash
phase_switch() {
    pill_state_working "Activating…"
    local out
    if out=$("$PKEXEC_CMD" /run/current-system/sw/bin/nixos-rebuild switch 2>&1); then
        log "[switch] succeeded"
        return 0
    fi
    log "[switch] failed:"
    log "$out"
    pill_state_error "Activation failed"
    notify-send -a "Standard-OS" "Update failed" "System unchanged — click pill for details" 2>/dev/null || true
    return 1
}
```

- [ ] **Step 4: Run — should pass**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: all 6 ✓, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/standard-os-update-phases-test.sh waybar/scripts/standard-os-update
git commit -m "update-pipeline: Phase 3 — switch (TDD)"
```

---

### Task 8: Phase 4 — verify + auto-rollback

**Files:**
- Modify: `standard-os-update` (fill `phase_verify`)
- Modify: test file (add tests)

- [ ] **Step 1: Append the tests**

```bash
# ─── phase_verify ─────────────────────────────────────────────────────────
# Scenario: self-test green post-switch → no rollback needed → return 0.
WAYBAR_SELF_TEST_CMD=fake_self_test_green
PKEXEC_CMD=fake_pkexec_ok
VERIFY_SETTLE_SEC=0   # skip the 5s sleep in tests
phase_verify; rc=$?
assert_eq "$rc" "0" "phase_verify: green post-switch → 0"

# Scenario: self-test red post-switch, rollback succeeds, post-rollback green → return 1.
# Use a counter so the same stub returns red on first call, green on second.
ST_CALLS=0
fake_self_test_red_then_green() {
    ST_CALLS=$((ST_CALLS + 1))
    [ "$ST_CALLS" -eq 1 ] && return 1
    return 0
}
WAYBAR_SELF_TEST_CMD=fake_self_test_red_then_green
PKEXEC_CMD=fake_pkexec_ok
ST_CALLS=0
phase_verify; rc=$?
assert_eq "$rc" "1" "phase_verify: red→rollback→green → 1 (rolled back)"
```

- [ ] **Step 2: Run — should fail**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: ✗ on phase_verify assertions.

- [ ] **Step 3: Implement phase_verify**

Replace the stub:

```bash
# How long to wait after switch for systemd-user reloads to settle.
# 5s in production; tests can override to 0.
VERIFY_SETTLE_SEC="${VERIFY_SETTLE_SEC:-5}"

phase_verify() {
    pill_state_working "Verifying…"
    sleep "$VERIFY_SETTLE_SEC"
    if "$WAYBAR_SELF_TEST_CMD" >/dev/null 2>&1; then
        return 0
    fi
    # Post-switch self-test failed → roll back.
    log "[verify] post-switch self-test FAILED; rolling back"
    local out
    if ! out=$("$PKEXEC_CMD" /run/current-system/sw/bin/nixos-rebuild switch --rollback 2>&1); then
        log "[verify] ROLLBACK ITSELF FAILED — system may be in a bad state:"
        log "$out"
        pill_state_error "Rollback failed — manual intervention needed"
        notify-send -u critical -a "Standard-OS" "Critical" \
            "Update rollback failed — see /var/lib/standard-os/last-update-error.log" \
            2>/dev/null || true
        return 2
    fi
    sleep "$VERIFY_SETTLE_SEC"
    if "$WAYBAR_SELF_TEST_CMD" >/dev/null 2>&1; then
        log "[verify] rolled back successfully; previous gen restored"
        pill_state_error "Update reverted — system unchanged"
        notify-send -a "Standard-OS" "Update was reverted" \
            "System is unchanged — click pill for details" 2>/dev/null || true
        return 1
    fi
    log "[verify] rollback completed but self-test STILL red — system was already broken"
    pill_state_error "System was already broken pre-update"
    notify-send -u critical -a "Standard-OS" "Update aborted" \
        "Pre-existing system issues — see log" 2>/dev/null || true
    return 2
}
```

- [ ] **Step 4: Run — should pass**

Run: `bash /etc/nixos/home/tests/standard-os-update-phases-test.sh`
Expected: all 8 ✓, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/standard-os-update-phases-test.sh waybar/scripts/standard-os-update
git commit -m "update-pipeline: Phase 4 — verify + auto-rollback (TDD)"
```

---

### Task 9: Phase 7 — signal post-state (success path)

**Files:**
- Modify: `standard-os-update` (fill `phase_signal`)

- [ ] **Step 1: Implement phase_signal**

Replace the stub:

```bash
phase_signal() {
    # Reboot-pending is emitted by waybar-self-test.sh (the daemon) — it
    # owns the boot-divergence check and runs every 60s. Phase 7 just
    # nudges it to refresh sooner so the user sees the reboot pill
    # within seconds of a successful switch.
    pkill -RTMIN+10 waybar 2>/dev/null || true

    pill_state_clear
    log_summary "update succeeded"
    notify-send -a "Standard-OS" "System updated" \
        "Click the reboot pill to finalize when convenient" 2>/dev/null || true
    # Truncate the error log on success so the next failure starts clean.
    : > "$ERROR_LOG"
    return 0
}
```

- [ ] **Step 2: Smoke test (no test stub needed — pure side-effect function)**

Run: `mkdir -p /tmp/test-state-dir && ERROR_LOG=/tmp/test-state-dir/err SUMMARY_LOG=/tmp/test-state-dir/sum STANDARD_OS_UPDATE_LIB_ONLY=1 bash -c '. /etc/nixos/home/waybar/scripts/standard-os-update; phase_signal' && cat /tmp/test-state-dir/sum`
Expected: prints a line like `[2026-06-13T...] update succeeded`.

- [ ] **Step 3: Commit**

```bash
git add waybar/scripts/standard-os-update
git commit -m "update-pipeline: Phase 7 — signal post-state (notify, summary log, refresh reboot pill)"
```

---

### Task 10: Wire phases into run_pipeline

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/standard-os-update` (fill `run_pipeline`)

- [ ] **Step 1: Implement run_pipeline**

Replace `run_pipeline() { return 0; }`:

```bash
run_pipeline() {
    log "[pipeline] start"
    if ! phase_pre_flight; then
        log "[pipeline] aborted at pre-flight"
        return 1
    fi
    if ! phase_dry_build; then
        log "[pipeline] aborted at dry-build"
        return 1
    fi
    if ! phase_switch; then
        log "[pipeline] aborted at switch (no rollback needed — switch didn't activate)"
        return 1
    fi
    if ! phase_verify; then
        log "[pipeline] verify failed (rollback handled within phase)"
        return 1
    fi
    phase_signal
    log "[pipeline] complete"
    return 0
}
```

- [ ] **Step 2: End-to-end smoke test on a no-op change**

This will run the real pipeline. Only do this when the working tree is committed and clean.

Run: `cd /etc/nixos/home && git status -s`
Expected: empty.

Run: `/etc/nixos/home/waybar/scripts/standard-os-update`
Expected:
- Pill emits "Checking…" → "Building…" → "Activating…" → "Verifying…", then clears.
- A notify-send "System updated" toast appears.
- `/var/lib/standard-os/last-update-summary.log` gets a new "update succeeded" line.
- A new system generation appears in `sudo nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3`.
- `/run/current-system != /run/booted-system` (because Phase 3 just made a new gen).

If anything in the pipeline fails, check `cat /var/lib/standard-os/last-update-error.log` for the captured stderr.

- [ ] **Step 3: Commit**

```bash
git add waybar/scripts/standard-os-update
git commit -m "update-pipeline: wire phases into run_pipeline (L1 complete)"
```

---

## Phase C — The scheduler

### Task 11: Scheduler skeleton + detection helpers

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/standard-os-update-scheduler`

- [ ] **Step 1: Write the script**

Create `/etc/nixos/home/waybar/scripts/standard-os-update-scheduler`:

```bash
#!/usr/bin/env bash
# standard-os-update-scheduler — fires from a user-systemd timer every
# 5 minutes. Decides whether to run the UPDATE pipeline:
#
#   1. Detection: is anything pending? (source-ahead, boot-diverged in L1;
#      channel-ahead, GC-overdue, optimise-overdue, CVE in L2–L5)
#   2. Lock check: is a pipeline already running?
#   3. Idle gates: is the user in focus? (fullscreen, idle time, DND)
#   4. Spawn the pipeline detached via systemd-run --user --scope.
#
# Each gate exits 0 (silently) — the timer retries at the next tick.
# Library mode (STANDARD_OS_UPDATE_SCHEDULER_LIB_ONLY=1) skips main body.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

LOCK_FILE="/run/standard-os/update.lock"
PIPELINE_BIN="${PIPELINE_BIN:-standard-os-update}"

# ─── Detection (L1 conditions only) ───────────────────────────────────────
is_source_ahead() {
    [ -f /run/standard-os/activated-commit ] || return 1
    local activated head
    activated=$(cat /run/standard-os/activated-commit 2>/dev/null) || return 1
    head=$(git -C /etc/nixos/home rev-parse HEAD 2>/dev/null) || return 1
    [ "$activated" != "$head" ]
}

# Anything pending → returns 0. L2–L5 add more conditions here.
detection_any_pending() {
    is_source_ahead && return 0
    return 1
}

# ─── Idle gates ───────────────────────────────────────────────────────────
# Fullscreen guard: if the focused window is fullscreen, the user is busy.
gate_fullscreen() {
    local fs
    fs=$(hyprctl -j activewindow 2>/dev/null | jq -r '.fullscreen // 0')
    [ "$fs" = "0" ] || [ -z "$fs" ]
}

# Input-idle guard: at least IDLE_THRESHOLD_SEC seconds since last input.
# Uses logind IdleSinceHint (microseconds since CLOCK_MONOTONIC reset).
# If the value is unavailable, fail open (assume idle).
IDLE_THRESHOLD_SEC="${IDLE_THRESHOLD_SEC:-300}"
gate_input_idle() {
    local session idle_since now idle_sec
    session=$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null)
    [ -n "$session" ] || return 0
    idle_since=$(loginctl show-session "$session" -p IdleSinceHint --value 2>/dev/null)
    [ -n "$idle_since" ] && [ "$idle_since" != "0" ] || return 0
    now=$(date +%s%N)
    # idle_since is microseconds; convert to seconds for comparison.
    idle_sec=$(( (now / 1000 - idle_since) / 1000000 ))
    [ "$idle_sec" -ge "$IDLE_THRESHOLD_SEC" ]
}

# DND respect: if DND is on, the user explicitly asked for quiet.
gate_dnd_off() {
    local dnd
    dnd=$(jq -r '.text // ""' /tmp/waybar-cache/notif-dnd 2>/dev/null)
    # DND pill text contains the bell-slash glyph when DND is ON.
    # Fail open: if cache missing/unreadable, treat as DND off (allow update).
    [ -z "$dnd" ] || ! grep -q $'\xef\x86\xa4' <<<"$dnd"
}

# ─── Main dispatch ────────────────────────────────────────────────────────
schedule() {
    detection_any_pending || return 0
    # Lock-file check: skip if a pipeline is already running.
    if [ -e "$LOCK_FILE" ] && fuser "$LOCK_FILE" >/dev/null 2>&1; then
        return 0
    fi
    gate_fullscreen   || return 0
    gate_input_idle   || return 0
    gate_dnd_off      || return 0
    # Spawn the pipeline detached so the timer service exits promptly.
    systemd-run --user --scope --unit="standard-os-update-run-$(date +%s)" \
        "$PIPELINE_BIN" >/dev/null 2>&1 &
    return 0
}

[ "${STANDARD_OS_UPDATE_SCHEDULER_LIB_ONLY:-0}" = "1" ] && return 0
schedule
exit 0
```

- [ ] **Step 2: Make executable + shellcheck**

Run: `chmod +x /etc/nixos/home/waybar/scripts/standard-os-update-scheduler`
Run: `shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/standard-os-update-scheduler`
Expected: no ERROR-severity findings.

- [ ] **Step 3: Test detection function in isolation**

Run: `STANDARD_OS_UPDATE_SCHEDULER_LIB_ONLY=1 bash -c '. /etc/nixos/home/waybar/scripts/standard-os-update-scheduler; detection_any_pending && echo PENDING || echo CLEAN'`
Expected (with clean tree): `CLEAN`.

Now make a temporary mismatch — edit a file, don't commit:
Run: `echo "" >> /tmp/test-edit && cp /etc/nixos/home/waybar/style.css /tmp/style-bak && echo "/* test */" >> /etc/nixos/home/waybar/style.css`
Wait — this WON'T trigger source-ahead because activated-commit compares HEAD, not the working tree.

Better test: simulate by overwriting activated-commit with an old SHA.
Run: `OLD_SHA=$(cd /etc/nixos/home && git rev-parse HEAD~3) && echo "Will test with old SHA: $OLD_SHA"`
Run: `sudo bash -c "echo $OLD_SHA > /run/standard-os/activated-commit"`
Run: `STANDARD_OS_UPDATE_SCHEDULER_LIB_ONLY=1 bash -c '. /etc/nixos/home/waybar/scripts/standard-os-update-scheduler; detection_any_pending && echo PENDING || echo CLEAN'`
Expected: `PENDING`.

Restore: `sudo bash -c "git -C /etc/nixos/home rev-parse HEAD > /run/standard-os/activated-commit"`
Verify: `cat /run/standard-os/activated-commit` matches `git -C /etc/nixos/home rev-parse HEAD`.

- [ ] **Step 4: Test idle gates work without erroring**

Run: `STANDARD_OS_UPDATE_SCHEDULER_LIB_ONLY=1 bash -c '. /etc/nixos/home/waybar/scripts/standard-os-update-scheduler; gate_fullscreen && echo "fs:ok"; gate_dnd_off && echo "dnd:ok"; gate_input_idle && echo "idle:ok" || echo "idle:busy"'`
Expected: gates print their status without errors. `idle:busy` is fine if you're actively typing — it means the gate is doing its job.

- [ ] **Step 5: Commit**

```bash
git add waybar/scripts/standard-os-update-scheduler
git commit -m "update-scheduler: detection + idle gates + dispatch (L1)"
```

---

### Task 12: User-systemd timer + service Nix module

**Files:**
- Create: `/etc/nixos/home/modules/standard-os-update-scheduler.nix`
- Modify: `/etc/nixos/home.nix` (imports list)

- [ ] **Step 1: Write the module**

Create `/etc/nixos/home/modules/standard-os-update-scheduler.nix`:

```nix
# User-systemd timer that fires the UPDATE scheduler every 5 minutes.
# The scheduler itself (waybar-scripts/bin/standard-os-update-scheduler)
# decides whether to run the pipeline based on detection + idle gates.
# Type=oneshot — the scheduler exits quickly; the pipeline runs detached
# via systemd-run --user --scope.
#
# PATH: home-manager-as-NixOS-module installs user packages into
# /etc/profiles/per-user/<username>/bin. Systemd-user services don't
# inherit that path by default, so we set it explicitly. The bare-name
# `standard-os-update-scheduler` ExecStart then resolves via PATH lookup,
# matching the same pattern waybar.service uses.
{ config, ... }:
{
  systemd.user.services.standard-os-update-scheduler = {
    Unit = {
      Description = "Standard-OS UPDATE scheduler (detection + idle gating)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      ExecStart = "standard-os-update-scheduler";
    };
  };

  systemd.user.timers.standard-os-update-scheduler = {
    Unit.Description = "Periodic trigger for the UPDATE scheduler";
    Install.WantedBy = [ "timers.target" ];
    Timer = {
      OnBootSec       = "5min";
      OnUnitActiveSec = "5min";
      Unit            = "standard-os-update-scheduler.service";
    };
  };
}
```

- [ ] **Step 2: Add to home.nix imports**

Open `/etc/nixos/home.nix`. Find the imports block (around line 10–22). Append:

```nix
    ./home/modules/standard-os-update-scheduler.nix
```

- [ ] **Step 3: Parse-check the module**

Run: `nix-instantiate --parse /etc/nixos/home/modules/standard-os-update-scheduler.nix > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Rebuild and verify timer is registered**

Run: `sudo nixos-rebuild switch`
Expected: succeeds.

Run: `systemctl --user list-timers | grep update-scheduler`
Expected: a line showing `standard-os-update-scheduler.timer` with `NEXT` in ~5min.

- [ ] **Step 5: Manually fire the scheduler to verify**

Run: `systemctl --user start standard-os-update-scheduler.service`
Run: `systemctl --user status standard-os-update-scheduler.service --no-pager | head -10`
Expected: shows "Finished" with no error. Active state `inactive` (because it's `Type=oneshot`).

- [ ] **Step 6: Commit**

```bash
git add home.nix home/modules/standard-os-update-scheduler.nix
git commit -m "update-scheduler: user-systemd timer + service (5min cadence)"
```

---

## Phase D — Pill emitter + waybar wiring

### Task 13: Update-pending pill click-acknowledge script

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/standard-os-update-pill-ack`

- [ ] **Step 1: Write the script**

Create `/etc/nixos/home/waybar/scripts/standard-os-update-pill-ack`:

```bash
#!/usr/bin/env bash
# Click handler for custom/update-pending.
# Behaviour:
#   - If pill is in Working state (opt-breathe in class), do nothing — the
#     pipeline is running; let it finish.
#   - If pill is in Error state (opt-no in class), open the error log in a
#     terminal AND clear the pill (acknowledge).
#   - Hidden state has no click target (waybar collapses the module).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

CACHE="/tmp/waybar-cache/update-pending"
ERROR_LOG="/var/lib/standard-os/last-update-error.log"

if ! [ -r "$CACHE" ]; then
    exit 0
fi

content=$(cat "$CACHE")
case "$content" in
    *opt-breathe*)
        # Pipeline running — no-op.
        exit 0
        ;;
    *opt-no*)
        # Error state — open log + clear pill.
        if [ -s "$ERROR_LOG" ]; then
            kitty --hold sh -c "less +G '$ERROR_LOG'" &
        else
            notify-send -a "Standard-OS" "Update error" "No log captured." 2>/dev/null || true
        fi
        pill_write update-pending "" "opt-pill" ""
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
```

- [ ] **Step 2: Make executable + shellcheck**

Run: `chmod +x /etc/nixos/home/waybar/scripts/standard-os-update-pill-ack`
Run: `shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/standard-os-update-pill-ack`
Expected: no ERROR findings.

- [ ] **Step 3: Smoke test the ack with a synthesized error pill**

Run: `echo '{"text":"sync","class":["opt-pill","opt-no"]}' > /tmp/waybar-cache/update-pending`
Run: `echo "fake error contents" | sudo tee /var/lib/standard-os/last-update-error.log >/dev/null`
Run: `/etc/nixos/home/waybar/scripts/standard-os-update-pill-ack`
Expected: a kitty window opens showing the fake error log. Close it.
Run: `cat /tmp/waybar-cache/update-pending`
Expected: contains `"text":""` (pill cleared).

- [ ] **Step 4: Commit**

```bash
git add waybar/scripts/standard-os-update-pill-ack
git commit -m "update-pill-ack: click handler for error-state acknowledge + log view"
```

---

### Task 14: Reboot prompt rofi script

**Files:**
- Create: `/etc/nixos/home/waybar/scripts/standard-os-reboot-prompt`

- [ ] **Step 1: Write the script**

Create `/etc/nixos/home/waybar/scripts/standard-os-reboot-prompt`:

```bash
#!/usr/bin/env bash
# Click handler for custom/reboot-pending.
# Rofi: "Reboot now" or "Dismiss".
#   - Reboot now → standard-os-shutdown-guard reboot (existing path).
#   - Dismiss   → write /run/standard-os/reboot-dismissed with the current
#                 booted-system path. The pill emitter checks this marker
#                 and stays hidden as long as it matches the current booted
#                 system. New switch or actual reboot invalidates it.
set -uo pipefail

DISMISS_MARKER="/run/standard-os/reboot-dismissed"

choice=$(printf '%s\n' \
    "Reboot now" \
    "Dismiss" \
    | rofi -dmenu -p "system" \
           -mesg "Reboot recommended to finalize the latest update." \
           -theme-str 'window {width: 480px;}')

case "$choice" in
    "Reboot now")
        exec standard-os-shutdown-guard reboot
        ;;
    "Dismiss")
        mkdir -p "$(dirname "$DISMISS_MARKER")"
        readlink /run/booted-system > "$DISMISS_MARKER" 2>/dev/null || true
        # Nudge the bar to re-evaluate.
        pkill -RTMIN+10 waybar 2>/dev/null || true
        ;;
    *)
        exit 0
        ;;
esac
```

- [ ] **Step 2: Make executable + shellcheck**

Run: `chmod +x /etc/nixos/home/waybar/scripts/standard-os-reboot-prompt`
Run: `shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/standard-os-reboot-prompt`
Expected: no ERROR findings.

- [ ] **Step 3: Commit**

```bash
git add waybar/scripts/standard-os-reboot-prompt
git commit -m "update-pipeline: reboot-pending rofi prompt (reboot / dismiss)"
```

---

### Task 15: Wire reboot-pending emission into waybar-self-test.sh

**Files:**
- Modify: `/etc/nixos/home/waybar/scripts/waybar-self-test.sh`

- [ ] **Step 1: Replace `emit_rebuild_pending` with `emit_reboot_pending`**

Open `/etc/nixos/home/waybar/scripts/waybar-self-test.sh`. The bottom of the file (lines 43–73) currently has `check_rebuild_pending` and `emit_rebuild_pending` plus the call. Replace that whole block (everything from line 43 to end) with:

```bash
# ---- reboot-pending check ----
# Fires when /run/current-system != /run/booted-system AND the user has
# not dismissed for the current booted gen. The check runs every self-test
# tick (60s default) so the pill appears within ~1min of a successful
# update activating a new gen.

DISMISS_MARKER="/run/standard-os/reboot-dismissed"
# FA power glyph (U+F011) — 3 bytes UTF-8.
POWER_GLYPH=$'\xef\x80\x91'

check_reboot_pending() {
    local current booted
    current=$(readlink /run/current-system 2>/dev/null) || return 1
    booted=$(readlink /run/booted-system 2>/dev/null) || return 1
    [ "$current" = "$booted" ] && return 1
    # Dismissed for THIS booted gen?
    if [ -r "$DISMISS_MARKER" ]; then
        local dismissed
        dismissed=$(cat "$DISMISS_MARKER" 2>/dev/null) || dismissed=""
        [ "$dismissed" = "$booted" ] && return 1
    fi
    return 0
}

emit_reboot_pending() {
    if check_reboot_pending; then
        pill_write reboot-pending "$POWER_GLYPH" "opt-pill opt-pin-orange" \
            "Reboot recommended to finalize updates"
    else
        pill_write reboot-pending "" "opt-pill" ""
    fi
}

emit_reboot_pending
```

- [ ] **Step 2: Shellcheck**

Run: `shellcheck -S error -s bash /etc/nixos/home/waybar/scripts/waybar-self-test.sh`
Expected: no ERROR findings.

- [ ] **Step 3: Run it manually to confirm it writes the new cache file**

Run: `bash /etc/nixos/home/waybar/scripts/waybar-self-test.sh`
Run: `cat /tmp/waybar-cache/reboot-pending`
Expected: either an empty-text pill JSON (if currently `current == booted`) or the orange-pin JSON.

Run: `ls /tmp/waybar-cache/rebuild-pending 2>&1`
Expected: `No such file or directory` — the old cache is no longer written.

- [ ] **Step 4: Commit**

```bash
git add waybar/scripts/waybar-self-test.sh
git commit -m "self-test: emit reboot-pending instead of rebuild-pending (boot-diverged + dismiss marker)"
```

---

### Task 16: Update config.jsonc — swap rebuild-pending → update-pending, add reboot-pending

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`

- [ ] **Step 1: Find the modules-right list and the module definition**

Read the current state. `custom/rebuild-pending` appears at line 63 (in `modules-right`) and at line 523 (definition). Confirm with:

Run: `grep -nE "rebuild-pending|reboot-pending|update-pending" /etc/nixos/home/waybar/config.jsonc`

- [ ] **Step 2: Rename in modules-right**

Edit `config.jsonc`. In the `modules-right` array, change:

```jsonc
    "custom/rebuild-pending",
```

to:

```jsonc
    "custom/update-pending",
    "custom/reboot-pending",
```

The new pills sit in the same position the old `rebuild-pending` occupied (between `custom/notif-bell` and `custom/waybar-self-test`, or wherever the existing line is).

- [ ] **Step 3: Replace the rebuild-pending module definition**

Find the `custom/rebuild-pending` block (around line 519–531). Replace it entirely with:

```jsonc
  // ── Update-pending pill ──
  // Hidden when steady-state (empty text — waybar collapses the module).
  // Lights opt-pin-orange + opt-breathe while the UPDATE pipeline is
  // running, with phase-specific tooltip text. Lights opt-no on error.
  // Click handler: standard-os-update-pill-ack (no-op while working,
  // opens log + clears pill when in error state).
  "custom/update-pending": {
    "exec": "cat /tmp/waybar-cache/update-pending 2>/dev/null",
    "return-type": "json",
    "format": "{}",
    "interval": 2,
    "signal": 10,
    "tooltip": true,
    "on-click": "standard-os-update-pill-ack"
  },

  // ── Reboot-pending pill ──
  // Hidden unless /run/current-system != /run/booted-system AND not
  // dismissed for the current booted gen. Written by waybar-self-test.sh
  // every 60s + signal-driven. Click → standard-os-reboot-prompt rofi.
  "custom/reboot-pending": {
    "exec": "cat /tmp/waybar-cache/reboot-pending 2>/dev/null",
    "return-type": "json",
    "format": "{}",
    "interval": 2,
    "signal": 10,
    "tooltip": true,
    "on-click": "standard-os-reboot-prompt"
  },
```

- [ ] **Step 4: Validate JSON-with-comments parses**

Run: `jq 'del(..|select(type=="string" and test("^//")?))' /etc/nixos/home/waybar/config.jsonc 2>&1 | tail -5`
This won't be perfectly clean (jsonc isn't standard JSON), but waybar itself uses a jsonc parser. The real test is restarting waybar.

Run: `systemctl --user restart waybar.service`
Run: `systemctl --user status waybar.service --no-pager -l | head -10`
Expected: `Active: active (running)`. If `failed`, check `journalctl --user -u waybar.service -n 20` for the JSON parse error.

- [ ] **Step 5: Verify the new pills exist and render correctly**

Visually: look at the bar. Both `custom/update-pending` and `custom/reboot-pending` should be present in the SYSTEM zone. If steady-state, both should be hidden. If `current != booted` (you may be in this state right now after Task 12's rebuild), the reboot pill should be visible with the FA power glyph.

Run: `cat /tmp/waybar-cache/reboot-pending`
Expected: either empty-text JSON (hidden) or opt-pin-orange JSON (visible).

- [ ] **Step 6: Commit**

```bash
git add waybar/config.jsonc
git commit -m "waybar/config: replace rebuild-pending with update-pending + reboot-pending"
```

---

## Phase E — Integration verification

### Task 17: End-to-end happy path

- [ ] **Step 1: Confirm starting state**

Run: `cd /etc/nixos/home && git status -s` — empty.
Run: `cat /tmp/waybar-cache/update-pending` — empty-text JSON or absent.
Visually: update pill hidden.

- [ ] **Step 2: Make a trivial commit to /etc/nixos/home**

Edit `/etc/nixos/home/waybar/style.css` — add a harmless comment at the very top:
`/* test: update-pipeline e2e — TASK 17 */`

Run: `cd /etc/nixos/home && git add waybar/style.css && git commit -m "test: trivial change for update pipeline e2e"`

- [ ] **Step 3: Wait for the scheduler**

The scheduler fires every 5 minutes. To speed the test, fire it manually:

Run: `systemctl --user start standard-os-update-scheduler.service`

- [ ] **Step 4: Watch the pill cycle**

Within ~30 seconds you should see:
- Update pill appears with sync glyph + opt-breathe motion.
- Tooltip cycles through "Checking…" → "Building…" → "Activating…" → "Verifying…".
- Pill clears.
- A notify-send "System updated" toast.
- Reboot pill appears (because the switch created a new gen → boot diverged).

Run: `cat /var/lib/standard-os/last-update-summary.log | tail -3`
Expected: a "update succeeded" line with today's timestamp.

Run: `readlink /run/current-system /run/booted-system`
Expected: different store paths.

- [ ] **Step 5: Test the reboot pill click — dismiss path**

Click the reboot pill (the orange one with the power glyph). Rofi opens with "Reboot now" / "Dismiss".
Pick **Dismiss**.

Expected: reboot pill disappears immediately. `/run/standard-os/reboot-dismissed` exists and matches `readlink /run/booted-system`.

Run: `cat /run/standard-os/reboot-dismissed`
Expected: a `/nix/store/...nixos-system-...` path matching `readlink /run/booted-system`.

- [ ] **Step 6: Trigger a new update to confirm dismiss invalidates correctly**

Repeat Step 2 (another trivial commit) and Step 3 (start the scheduler manually).
After the pipeline completes, the reboot pill should reappear — because the new switch produced a new current-system, and the dismiss-marker now mismatches the booted-system.

(Reasoning: dismiss only suppresses the pill for the SPECIFIC dismissed-against booted gen. Any change invalidates it.)

---

### Task 18: Test build-failure path

- [ ] **Step 1: Introduce a syntax error**

Edit `/etc/nixos/home/modules/standard-os-update-scheduler.nix`. Break the syntax — e.g., add an unmatched `{` somewhere. Commit:

Run: `cd /etc/nixos/home && git add home/modules/standard-os-update-scheduler.nix && git commit -m "test: deliberately break syntax for update pipeline e2e"`

- [ ] **Step 2: Trigger the scheduler manually**

Run: `systemctl --user start standard-os-update-scheduler.service`

- [ ] **Step 3: Expect the pipeline to abort at dry-build**

Within ~15 seconds:
- Update pill appears, cycles through "Checking…" → "Building…".
- Then turns opt-no (red) with tooltip "Update failed — click for details".
- notify-send "Update failed" toast appears.
- Running system unchanged (no new gen).

Run: `cat /var/lib/standard-os/last-update-error.log | head -10`
Expected: contains the `[build]` log entry with the captured stderr.

Run: `cat /tmp/waybar-cache/update-pending | jq -r .class`
Expected: array containing `"opt-no"`.

- [ ] **Step 4: Click the error pill**

Click the red update pill. A kitty window opens with `less` showing the error log. Close it.
The pill should now be hidden (acknowledged).

- [ ] **Step 5: Fix and retry**

Run: `cd /etc/nixos/home && git revert HEAD --no-edit`
Run: `systemctl --user start standard-os-update-scheduler.service`

Expected: pipeline runs successfully this time, reboot pill lights.

---

### Task 19: Test idle gates

- [ ] **Step 1: Make a pending commit**

Run: `cd /etc/nixos/home && echo "/* fullscreen-gate test */" >> waybar/style.css && git add waybar/style.css && git commit -m "test: change for idle-gate test"`

- [ ] **Step 2: Open a fullscreen video / fullscreen application**

Use mpv, a browser fullscreen, anything that `hyprctl -j activewindow | jq .fullscreen` reports non-zero.

Run (in a separate workspace): `hyprctl -j activewindow | jq -r .fullscreen`
Expected: non-zero (`1` or `2`).

- [ ] **Step 3: Fire the scheduler — pipeline should defer**

To isolate the fullscreen gate from the input-idle gate (which would also fail while you're actively setting up the test), run the scheduler directly with `IDLE_THRESHOLD_SEC=0`:

Run: `IDLE_THRESHOLD_SEC=0 standard-os-update-scheduler`
Wait 5 seconds. Update pill should NOT appear.

Run: `cat /var/lib/standard-os/last-update-summary.log | tail -1`
Expected: the last line is from the PRIOR successful update, not a new one (the scheduler exited at the fullscreen gate).

- [ ] **Step 4: Exit fullscreen, retry**

Close the fullscreen app. Wait until `hyprctl -j activewindow | jq .fullscreen` returns `0`.
Run: `IDLE_THRESHOLD_SEC=0 standard-os-update-scheduler`
Expected: pipeline now runs (both fullscreen and input-idle gates pass).

---

### Task 20: Test verify-failure path with auto-rollback

This test deliberately breaks the system to confirm Phase 4 catches it.

- [ ] **Step 1: Make a change that breaks a daemon**

Edit `/etc/nixos/home/modules/waybar.nix`. Find the `waybar-glass-text-daemon` service's `ExecStart` (around line 263):

```nix
ExecStart = "${waybar-scripts}/bin/glass-text-daemon";
```

Change to a non-existent binary:

```nix
ExecStart = "${waybar-scripts}/bin/glass-text-daemon-nonexistent";
```

Commit:
Run: `cd /etc/nixos/home && git add home/modules/waybar.nix && git commit -m "test: deliberately break glass-text-daemon ExecStart"`

- [ ] **Step 2: Trigger the scheduler**

Run: `systemctl --user start standard-os-update-scheduler.service`

- [ ] **Step 3: Watch the pipeline run, switch, fail verify, auto-rollback**

Within ~30 seconds:
- Update pill: "Building…" → "Activating…" (switch succeeds — the build is valid even if the runtime ExecStart is broken).
- Pill stays in "Verifying…" for ~5–10s.
- Pipeline detects glass-text-daemon failed → rolls back.
- Pill turns opt-no "Update reverted — system unchanged".
- notify-send "Update was reverted".

Run: `systemctl --user is-active waybar-glass-text-daemon`
Expected: `active` — because the rollback restored the previous gen with the working ExecStart.

Run: `cat /var/lib/standard-os/last-update-error.log | head -20`
Expected: contains the `[verify]` log entries indicating rollback.

- [ ] **Step 4: Revert the broken commit**

Run: `cd /etc/nixos/home && git revert HEAD --no-edit`
Run: `systemctl --user start standard-os-update-scheduler.service`
Expected: pipeline succeeds, system is back to a fully working state.

---

## Phase F — Cleanup

### Task 21: Delete the retired rebuild-pending machinery

After all integration tests pass and the new pipeline has been running stably for at least one wake cycle, retire the old script.

- [ ] **Step 1: Delete standard-os-rebuild-prompt.sh**

Run: `rm /etc/nixos/home/waybar/scripts/standard-os-rebuild-prompt.sh`

- [ ] **Step 2: Verify nothing references it**

Run: `grep -rn "standard-os-rebuild-prompt\|rebuild-pending" /etc/nixos/home/ 2>&1 | grep -v "\.git/" | grep -v "docs/superpowers" | grep -v "TODO.md"`
Expected: empty, or only references inside docs/superpowers (history) and TODO.md (historic mentions).

- [ ] **Step 3: Rebuild to confirm the deletion didn't break anything**

Run: `sudo nixos-rebuild switch`
Expected: succeeds. The waybar-scripts derivation no longer includes the deleted script, but nothing should reference it.

- [ ] **Step 4: Verify the bar still works**

Run: `systemctl --user status waybar.service waybar-glass-text-daemon waybar-workspace-daemon --no-pager -l | grep Active`
Expected: all three active.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add -A waybar/scripts/standard-os-rebuild-prompt.sh
git commit -m "waybar: retire standard-os-rebuild-prompt (superseded by UPDATE pipeline)"
```

---

### Task 22: Update TODO.md

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Add a DONE entry**

Open `/etc/nixos/home/waybar/TODO.md`. Add to the top of the DONE section:

```markdown
- **UPDATE pill — L1 foundation (auto-pipeline + verify-rollback)** — 2026-06-13
  Replaced the manual rebuild workflow with an automatic 5-min-cadence
  pipeline gated on idle (fullscreen/IdleHint/DND). Pipeline phases:
  pre-flight self-test → dry-build → switch → verify → signal. Verify
  failure triggers immediate `nixos-rebuild switch --rollback`.
  Two new SYSTEM pills: `custom/update-pending` (Hidden / Working /
  Error states) and `custom/reboot-pending` (lights when current ≠
  booted; click → rofi reboot/dismiss). Polkit rule scoped to four
  nix binaries.
  **Hint:** spec at `docs/superpowers/specs/2026-06-13-update-pill-design.md`,
  plan at `docs/superpowers/plans/2026-06-13-update-pill-l1.md`.
  L2–L5 (channels, GC, optimise, CVE) are separate plans.
```

- [ ] **Step 2: Commit**

```bash
git add waybar/TODO.md
git commit -m "TODO: UPDATE pill L1 → DONE"
```

---

### Task 23: Final verification + memory update

- [ ] **Step 1: Final smoke test**

After all the deliberate-break tests in Phase E:
- Tree is clean: `cd /etc/nixos/home && git status -s` → empty.
- Bar healthy: `systemctl --user is-active waybar waybar-glass-text-daemon waybar-workspace-daemon` → all `active`.
- Self-test green: `cat /tmp/waybar-cache/waybar-self-test` → empty-text JSON (hidden).
- Update pill hidden: `cat /tmp/waybar-cache/update-pending` → empty or absent.
- Reboot pill hidden: `cat /tmp/waybar-cache/reboot-pending` → empty-text JSON.

- [ ] **Step 2: One more end-to-end (silent) commit + wait pattern**

Make a trivial commit. Do NOT manually fire the scheduler. Walk away for 10–15 minutes (or just simulate by running `systemctl --user list-timers | grep update-scheduler` to confirm the next fire time).

Expected within the next timer cycle (≤10 min after the commit): the pipeline runs and the reboot pill is up.

- [ ] **Step 3: Update the memory note about the waybar/scripts/ dir**

The memory note `feedback_waybar_source_edits_and_out_of_store_symlinks` still describes `~/.config/waybar/scripts/` as an out-of-store symlink (step 4 of the "How to apply" section). The 2026-06-12 bulletproof migration removed that dir entirely; scripts now live exclusively in the `waybar-scripts` /nix/store derivation. Update the memory to reflect current reality.

Edit `/home/max/.claude/projects/-home-max/memory/feedback_waybar_source_edits_and_out_of_store_symlinks.md`. Replace the existing step 4 paragraph (the one starting "Scripts in `~/.config/waybar/scripts/` are now ALSO out-of-store symlinks…") with:

```markdown
4. **Scripts live in /nix/store, not in $HOME.** Since the 2026-06-12 bulletproof migration (commit `72aa9a8`), `~/.config/waybar/scripts/` no longer exists. Scripts are packaged in the `waybar-scripts` derivation defined in `/etc/nixos/home/modules/waybar.nix`. To edit a script: change the source at `/etc/nixos/home/waybar/scripts/<name>` then `sudo nixos-rebuild switch` so the new `waybar-scripts` store path is built and the wrapped binaries land in `${waybar-scripts}/bin/`. After rebuild, restart the owning daemon (`systemctl --user restart waybar-glass-text-daemon` etc.). The UPDATE pipeline (Task 4–10 of this plan) automates the rebuild step — committing a change to scripts/ triggers the auto-pipeline within ~10 min.
```

Save the file. The `description:` frontmatter field also references "the WHOLE scripts/ dir use mkOutOfStoreSymlink" — that's now wrong too. Update the description to:

```yaml
description: "Waybar style.css + config.jsonc use mkOutOfStoreSymlink — ~/.config/waybar/{style.css,config.jsonc} symlink DIRECTLY to /etc/nixos/home/waybar/*. Edits are live; only `systemctl restart waybar` needed. Scripts moved to nix-store derivation since 2026-06-12 — those need `nixos-rebuild switch` (now automated via the UPDATE pipeline)."
```

- [ ] **Step 4: Final commit**

```bash
cd /etc/nixos/home && git log --oneline -25
```

Expected: a clean history of the L1 implementation, each task = one well-described commit.

---

## Done criteria

L1 is complete when ALL of the following are true:

1. The two new pills (`custom/update-pending`, `custom/reboot-pending`) are wired into `config.jsonc` and visible in the SYSTEM zone with correct hide/show behaviour.
2. The user-systemd timer `standard-os-update-scheduler.timer` is registered and fires every 5 minutes.
3. A trivial commit to `/etc/nixos/home/` results in an automatic pipeline run within 10 minutes, with the update pill showing the live phase cycle, and the reboot pill appearing afterwards.
4. A deliberate `.nix` syntax error → pipeline aborts at dry-build, pill goes opt-no, system unchanged. Fixing the error + next scheduler tick → pipeline succeeds.
5. A deliberate runtime breakage (e.g. broken daemon `ExecStart`) → pipeline switches, verify fails, auto-rollback restores the previous gen, pill goes opt-no "Update reverted — system unchanged".
6. Fullscreen app deferral works — scheduler exits early when fullscreen is active.
7. Reboot pill click → rofi → Dismiss writes the marker; pill hides; next switch invalidates the marker.
8. Polkit allows passwordless `nixos-rebuild` from the user-systemd service.
9. `standard-os-rebuild-prompt.sh` is deleted; no references remain.
10. TODO.md DONE entry exists. Spec + plan committed.

---

## Out of scope (L2–L5 — separate plans)

- **L2**: Channel-update detection + Phase 1 (`nix-channel --update`) + the 24h-cached upstream-hash check. The polkit rule already allows `nix-channel`, so the L2 plan only adds detection state files and a new pipeline phase.
- **L3**: GC + retention. Adds Phase 5 (`nix-collect-garbage --delete-older-than 14d` + gen-count floor enforcement). Polkit already allows `nix-collect-garbage`.
- **L4**: Store optimisation. Adds Phase 6 (`nix-store --optimise` monthly cadence). Polkit already allows `nix-store`.
- **L5**: Security advisories. Adds vulnix wiring + bumped scheduler urgency on critical CVE matches. May expand the polkit scope.

L1 is shippable on its own and provides the safety nets (pre-flight, dry-build, verify+rollback) that all later layers depend on.
