# Profile Purge + DND Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the six-profile notification-center machinery with a single Do-Not-Disturb boolean exposed as a child pill on the bell.

**Architecture:** State lives in one file (`~/.local/share/standard-os/notif-dnd`, presence ↔ ON). `notif-click dnd` toggles file existence + SIGUSR1s the bash `notif-daemon`. Daemon stat-checks per arrival to suppress wide-pill + sound; bell pin + journal keep working. New `render_dnd_for_state` writes `/tmp/waybar-cache/notif-dnd`, breathing continuously when ON.

**Tech Stack:** bash 5, NixOS home-manager, waybar 0.14, rofi 2.0 (untouched), Nerd Font glyphs.

**Spec:** `docs/superpowers/specs/2026-06-15-profile-purge-dnd-toggle-design.md`.

---

## Task ordering rationale

1. **Icon glyph verification first** — smallest discovery, blocks rendering if codepoint is wrong.
2. **TDD the decision function** — pure function, easiest to test in isolation.
3. **Wire the click toggle** — surface that's safe to add before stripping anything.
4. **Daemon rendering + DND check** — add new code before deleting the profile path.
5. **Strip profile internals from the daemon** — once new path is proven.
6. **Strip profile machinery from notif-center.nix** — last because it builds the binaries.
7. **Wire waybar + delete dead scripts + tests** — cleanup pass.

Each numbered task ends with a commit. Tests run between tasks where applicable.

---

### Task 1: Verify bell-off glyph renders in meslo-ng

**Files:**
- (None modified — discovery only.)

- [ ] **Step 1: Print the candidate codepoint and a few neighbours**

```bash
printf '\\uf1f7  \\uf0a40  \\uf1f6  \\ueab8\n'
```

Expected: you see a bell-with-slash for one of these glyphs in the terminal that uses meslo-ng. Note which codepoint actually renders the right icon.

- [ ] **Step 2: If the spec codepoint () is wrong, update the spec**

If a different glyph rendered, edit `docs/superpowers/specs/2026-06-15-profile-purge-dnd-toggle-design.md`'s "Icon glyph" line to reference the codepoint that worked. Use the same codepoint throughout the plan from this task forward.

(If  rendered correctly, skip this step.)

- [ ] **Step 3: No commit (no file changes yet; spec edit if any rides task 7's commit)**

---

### Task 2: TDD — `notif_click_decide dnd <cache>` returns `"toggle-dnd"`

**Files:**
- Modify: `tests/notif-click-test.sh`

- [ ] **Step 1: Add failing test rows**

Open `tests/notif-click-test.sh`. Add these blocks adjacent to the existing `bell` decision tests:

```bash
# ─── dnd subcommand ───────────────────────────────────────────────────────
# DND toggle is content-agnostic — the cache is irrelevant; the decision
# only depends on the subcommand. Always returns "toggle-dnd".
assert_eq "$(notif_click_decide dnd "$EMPTY")" "toggle-dnd" \
    "[dnd → toggle-dnd regardless of cache (empty)]"
assert_eq "$(notif_click_decide dnd "$REST_GREEN")" "toggle-dnd" \
    "[dnd → toggle-dnd regardless of cache (rest)]"
assert_eq "$(notif_click_decide dnd '')" "toggle-dnd" \
    "[dnd → toggle-dnd with empty string cache]"
```

- [ ] **Step 2: Drop the obsolete profile assertions**

Search the same file for any `notif_click_decide profile ...` assertion lines and delete them.

- [ ] **Step 3: Run tests to verify the dnd block fails**

```bash
bash /etc/nixos/home/tests/notif-click-test.sh
```

Expected: 3 new failures on the `[dnd → ...]` lines (decision returns `"noop"` because `dnd` falls through to the default branch).

- [ ] **Step 4: Implement the dnd branch in `notif_click_decide`**

Edit `/etc/nixos/home/scripts/notif-click`. Inside the `case "$action" in` block, add a new branch alongside `profile)` (which gets deleted in Task 6):

```bash
        dnd)
            # Pure toggle — cache is ignored. The action runner below
            # creates / removes ~/.local/share/standard-os/notif-dnd
            # and signals the bash notif-daemon to re-emit the pill cache.
            printf 'toggle-dnd'
            ;;
```

- [ ] **Step 5: Run tests to verify pass**

```bash
bash /etc/nixos/home/tests/notif-click-test.sh
```

Expected: all tests pass including the 3 new `dnd` assertions.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-click tests/notif-click-test.sh && \
git commit -m "notif-click: notif_click_decide gains dnd → toggle-dnd"
```

---

### Task 3: Wire the toggle action runner in `notif-click`

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-click`

- [ ] **Step 1: Add the `toggle-dnd` case to the action runner**

In `notif-click`, find the `case "$decision" in` block (around the lines containing `open-rofi)`). Add this branch alongside the others:

```bash
    toggle-dnd)
        # Single state file: presence ↔ DND ON. Empty body is fine;
        # presence is the signal (same convention the old notif-active-
        # profile file used). SIGUSR1 wakes the daemon's main loop so
        # the DND pill cache + tooltip flip without a notif arriving.
        DND_STATE_FILE="${NOTIF_DND_FILE:-$HOME/.local/share/standard-os/notif-dnd}"
        mkdir -p "$(dirname "$DND_STATE_FILE")"
        if [[ -e $DND_STATE_FILE ]]; then
            rm -f "$DND_STATE_FILE"
        else
            : > "$DND_STATE_FILE"
        fi
        systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service 2>/dev/null || true
        ;;
```

- [ ] **Step 2: Sanity check — file flip works in isolation**

```bash
unset NOTIF_DND_FILE
DND=/tmp/_dnd_test
rm -f "$DND"
NOTIF_DND_FILE="$DND" bash -c '
  set -uo pipefail
  source <(grep -A30 "toggle-dnd)" /etc/nixos/home/scripts/notif-click \
            | sed "1d;/^        ;;/q;s/^        ;;//")
  # Manual: just test the file flip part inline
  DND_STATE_FILE="$NOTIF_DND_FILE"
  [[ -e $DND_STATE_FILE ]] && rm -f "$DND_STATE_FILE" || : > "$DND_STATE_FILE"
  ls "$DND_STATE_FILE" 2>/dev/null && echo "ON" || echo "OFF"
'
NOTIF_DND_FILE="$DND" bash -c '
  DND_STATE_FILE="$NOTIF_DND_FILE"
  [[ -e $DND_STATE_FILE ]] && rm -f "$DND_STATE_FILE" || : > "$DND_STATE_FILE"
  ls "$DND_STATE_FILE" 2>/dev/null && echo "ON" || echo "OFF"
'
```

Expected: first invocation prints `ON`, second prints `OFF`, alternating.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-click && \
git commit -m "notif-click: toggle-dnd handler writes state file + SIGUSR1s daemon"
```

---

### Task 4: Add `render_dnd_for_state` to the bash daemon + emit it

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-daemon`

- [ ] **Step 1: Add the state-file constant near the other env-defaulted paths**

Open `/etc/nixos/home/scripts/notif-daemon`. Find the section near the top that sets `JOURNAL_PATH`, `JOURNAL_LIMIT`, etc. Add adjacent:

```bash
DND_STATE_FILE="${NOTIF_DND_FILE:-$HOME/.local/share/standard-os/notif-dnd}"
CACHE_DND="${NOTIF_CACHE_DND:-/tmp/waybar-cache/notif-dnd}"
```

- [ ] **Step 2: Add the render function near `render_bell_for_state`**

Insert this function (next to `render_bell_for_state` and `render_action_for_state`):

```bash
# ─── render_dnd_for_state — DND child pill ─────────────────────────────────
# Pure function. Reads presence of DND_STATE_FILE; emits the bell-off glyph
# with opt-breathe motion when ON, plain child surface when OFF. Icon stays
# bell-slash in both states — state is shown via animation, not icon swap.
render_dnd_for_state() {
    local theme dnd_on classes tooltip
    theme="$(glass_theme)"
    [[ -e $DND_STATE_FILE ]] && dnd_on=1 || dnd_on=0
    if (( dnd_on )); then
        _classes_json classes "opt-pill-child" "$theme" "opt-breathe"
        tooltip="DND on — click to resume notifications"
    else
        _classes_json classes "opt-pill-child" "$theme"
        tooltip="Stop notifications"
    fi
    #  is the Nerd Font bell-off glyph (verified in Task 1).
    printf '{"text":"","class":%s,"tooltip":"%s"}' "$classes" "$tooltip"
}
```

- [ ] **Step 3: Wire it into `emit`**

Find the `emit()` function. It currently writes `CACHE_BELL` (and used to write `CACHE_PROFILE`). After the `write_if_changed "$CACHE_BELL" "$bell_json"` call, add:

```bash
    local dnd_json
    dnd_json=$(render_dnd_for_state)
    write_if_changed "$CACHE_DND" "$dnd_json"
```

If the existing `emit` still references `CACHE_PROFILE` or `render_profile_for_state`, **leave those lines intact for now** — Task 5 strips them in a separate commit so each step stays small.

- [ ] **Step 4: Smoke test the render function in isolation**

```bash
bash -c '
  set -uo pipefail
  NOTIF_DND_FILE=/tmp/_dnd_smoke; rm -f "$NOTIF_DND_FILE"
  source <(awk "/^glass_theme\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^_classes_json\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^json_escape\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  DND_STATE_FILE="$NOTIF_DND_FILE"
  source <(awk "/^render_dnd_for_state\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  echo "OFF: $(render_dnd_for_state)"
  : > "$NOTIF_DND_FILE"
  echo "ON:  $(render_dnd_for_state)"
  rm -f "$NOTIF_DND_FILE"
'
```

Expected: two JSON lines. OFF has no `opt-breathe`; ON includes `opt-breathe`. Both include the bell-off glyph.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-daemon && \
git commit -m "notif-daemon: render_dnd_for_state + CACHE_DND wired into emit()"
```

---

### Task 5: Daemon DND gate on arrival + SIGUSR1 re-emit

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-daemon`

- [ ] **Step 1: Gate the transient block on DND state**

Find `on_arrival()`. At its top, before the existing `transient_kind_for_state` call, add:

```bash
    local dnd_on=0
    [[ -e $DND_STATE_FILE ]] && dnd_on=1
```

Then wrap the transient-setup block (the `kind=$(...)` call + the `if [[ -n $TRANSIENT_KIND ]]; then ... fi` body that sets TRANSIENT_*) so it only runs when `dnd_on` is 0:

```bash
    if (( ! dnd_on )); then
        local kind
        kind=$(transient_kind_for_state "$urg" "$ACTIVE_SILENCE_MODE" "$ACTIVE_CRIT_PULSE" "$NEWEST_APP" "$ACTIVE_ALLOWED_CSV")
        TRANSIENT_KIND="$kind"
        if [[ -n $TRANSIENT_KIND ]]; then
            # (existing TRANSIENT_ID / TITLE / OTP / actions setup — unchanged)
        fi
    else
        TRANSIENT_KIND=""
    fi
```

Keep the existing body inside the `if [[ -n $TRANSIENT_KIND ]]` block exactly as it is. We're only adding the outer `if (( ! dnd_on ))`.

- [ ] **Step 2: Gate the sound block on DND state**

In the same function, find the `canberra-gtk-play` invocation (rate-limited sound playback). Wrap it:

```bash
    if (( ! dnd_on )); then
        local sound_id
        sound_id=$(sound_for_state "$urg" "$ACTIVE_SILENCE_MODE" "$ACTIVE_CRIT_SOUND" "$NEWEST_APP" "$ACTIVE_ALLOWED_CSV")
        if [[ -n $sound_id ]]; then
            local now_ms
            now_ms=$(date +%s%3N)
            if (( now_ms - LAST_SOUND_AT >= 500 )); then
                canberra-gtk-play -i "$sound_id" 2>/dev/null & disown
                LAST_SOUND_AT="$now_ms"
            fi
        fi
    fi
```

Leave the sound machinery (`sound_for_state`, `LAST_SOUND_AT`) intact — Task 7 simplifies it after profiles are gone.

- [ ] **Step 3: Repurpose the SIGUSR1 handler**

Find the existing `on_user_signal()` function (handles `USR1_PENDING`). It currently calls `resolve_and_load_profile`. Replace that call with an `emit` so the DND pill cache flips immediately on toggle:

```bash
on_user_signal() {
    USR1_PENDING=1
}
# (existing definition is just the flag set — the consumer below changes)
```

Then find the main-loop block that consumes `USR1_PENDING`:

```bash
    if (( USR1_PENDING )); then
        USR1_PENDING=0
        sleep 0.05   # filesystem sync window — same reason as before
        emit
    fi
```

(The old block called `resolve_and_load_profile` then `emit`. We just emit now — DND state is read live by `render_dnd_for_state` from the file at emit time.)

- [ ] **Step 4: Live verify — touch state file, observe emit cycle**

```bash
sudo nixos-rebuild switch 2>&1 | tail -3
DND=$HOME/.local/share/standard-os/notif-dnd
rm -f "$DND"
notify-send dnd-off-test "should pop the wide-pill"
sleep 1
cat /tmp/waybar-cache/notif-bell; echo
cat /tmp/waybar-cache/notif-dnd; echo
: > "$DND"
systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service
sleep 0.3
cat /tmp/waybar-cache/notif-dnd; echo
notify-send dnd-on-test "should NOT pop the wide-pill"
sleep 1
cat /tmp/waybar-cache/notif-bell; echo  # expect "text":"" — no transient
rm -f "$DND"
```

Expected:
- After `dnd-off-test`: `notif-bell` shows the wide-pill text (App · Title), `notif-dnd` has no `opt-breathe`.
- After enabling DND + signal: `notif-dnd` has `opt-breathe`.
- After `dnd-on-test`: `notif-bell` returns to rest face (`"text":""`) with the new pin from the unread count.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-daemon && \
git commit -m "notif-daemon: DND gate suppresses wide-pill + sound; SIGUSR1 re-emits"
```

---

### Task 6: Drop the `profile` subcommand from `notif-click`

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-click`

- [ ] **Step 1: Delete the `profile)` case in `notif_click_decide`**

Find:

```bash
        profile)
            printf 'open-profile-rofi'
            ;;
```

Delete that block entirely.

- [ ] **Step 2: Delete the `open-profile-rofi)` action-runner case**

Find:

```bash
    open-profile-rofi)
        exec notif-rofi-profiles
        ;;
```

Delete that block.

- [ ] **Step 3: Tests still pass**

```bash
bash /etc/nixos/home/tests/notif-click-test.sh
```

Expected: all green. The `profile` assertions were removed in Task 2.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-click && \
git commit -m "notif-click: drop profile subcommand + open-profile-rofi handler"
```

---

### Task 7: Strip profile machinery from `notif-daemon`

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-daemon`

- [ ] **Step 1: Delete profile helper functions**

Delete these whole functions from the daemon:
- `resolve_and_load_profile`
- `profile_display_name`
- `load_profile_into_active`
- `render_profile_for_state`

- [ ] **Step 2: Delete profile global state declarations**

Find and remove (these are scattered near the top of the script):
- `ACTIVE_SILENCE_MODE=...`
- `ACTIVE_CRIT_PULSE=...`
- `ACTIVE_CRIT_SOUND=...`
- `ACTIVE_ALLOWED_CSV=...`
- `LAST_PROFILE_RESOLVED_AT=...`
- `NOTIF_DEFAULT_PROFILE` defaults / reads
- `CACHE_PROFILE=...` (replaced by `CACHE_DND` in Task 4)
- `PROFILES_JSON_PATH=...` if present

- [ ] **Step 3: Drop the schedule lib source line**

Find and delete:

```bash
source "$LIB_DIR/notif-schedule.sh"
```

- [ ] **Step 4: Simplify `transient_kind_for_state` and `sound_for_state`**

These currently take `silence_mode`, `crit_pulse`/`crit_sound`, `allowed_csv` parameters. With DND already gated in `on_arrival` (Task 5), these reduce to urgency + app decisions only.

For `transient_kind_for_state`:

```bash
# transient_kind_for_state URGENCY APP → "" | "wide" | "beat"
# (Pure function. DND suppression is handled in on_arrival before this is called.)
transient_kind_for_state() {
    local urg="$1" app="$2"
    if (( urg == 2 )); then
        printf 'beat'
    elif [[ -n "$app" ]]; then
        printf 'wide'
    fi
}
```

For `sound_for_state`:

```bash
# sound_for_state URGENCY → sound theme id or empty
sound_for_state() {
    local urg="$1"
    if (( urg == 2 )); then
        printf 'dialog-warning'
    else
        printf 'message-new-instant'
    fi
}
```

(Adjust the exact sound IDs to whatever the current `freedesktop` theme uses for normal vs critical — match the current hard-coded values.)

- [ ] **Step 5: Update the two `on_arrival` call sites to match the new signatures**

In `on_arrival`, replace:

```bash
kind=$(transient_kind_for_state "$urg" "$ACTIVE_SILENCE_MODE" "$ACTIVE_CRIT_PULSE" "$NEWEST_APP" "$ACTIVE_ALLOWED_CSV")
```

with:

```bash
kind=$(transient_kind_for_state "$urg" "$NEWEST_APP")
```

And:

```bash
sound_id=$(sound_for_state "$urg" "$ACTIVE_SILENCE_MODE" "$ACTIVE_CRIT_SOUND" "$NEWEST_APP" "$ACTIVE_ALLOWED_CSV")
```

with:

```bash
sound_id=$(sound_for_state "$urg")
```

- [ ] **Step 6: Drop the per-arrival profile re-resolve at the top of `on_arrival`**

Find and remove the block that re-resolves the profile every 60 s at the top of `on_arrival`:

```bash
    local now_epoch
    now_epoch=$(date +%s)
    if (( now_epoch - LAST_PROFILE_RESOLVED_AT >= 60 )); then
        resolve_and_load_profile
    fi
```

- [ ] **Step 7: Drop the boot-time `resolve_and_load_profile` call**

Near the main-loop init (search for the first call to `resolve_and_load_profile` outside of `on_arrival`), delete it.

- [ ] **Step 8: Drop the `cleanup`'s profile-cache write**

Find `cleanup()` which writes empty JSON to `CACHE_BELL` and (currently) `CACHE_PROFILE`. Replace the `CACHE_PROFILE` line with one for `CACHE_DND`:

```bash
    printf '%s' '{"text":""}' > "${CACHE_DND}.tmp.$$" 2>/dev/null && mv -f "${CACHE_DND}.tmp.$$" "$CACHE_DND" 2>/dev/null
```

- [ ] **Step 9: Run the existing tests that exercise the daemon helpers**

```bash
bash /etc/nixos/home/tests/notif-state-test.sh
```

Expected: tests that hit `transient_kind_for_state` / `sound_for_state` are likely broken by signature changes. **Fix the test fixtures to call the new signatures** (urgency + app for transient, urgency for sound). Delete any test cases that asserted profile-specific behavior (silence-mode / allowed-app branches).

If after this the file has no remaining tests, delete it.

- [ ] **Step 10: Live verify**

```bash
sudo nixos-rebuild switch 2>&1 | tail -3
journalctl --user -u notif-daemon -n 20 --no-pager 2>&1 | tail -10
# Should NOT see any "command not found" / unbound-variable errors.
notify-send "profile-strip-test" "should pop normally with DND off"
sleep 1
cat /tmp/waybar-cache/notif-bell; echo  # expect text contains the test summary
```

Expected: daemon healthy, transient pill renders, no errors in journal.

- [ ] **Step 11: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-daemon tests/notif-state-test.sh && \
git commit -m "notif-daemon: strip profile resolver, schedule lib, ACTIVE_* globals"
```

---

### Task 8: Strip profile options from `notif-center.nix`

**Files:**
- Modify: `/etc/nixos/home/modules/notif-center.nix`

- [ ] **Step 1: Remove profile mkOptions**

Delete in this order (each is a contiguous block):
- `profiles = lib.mkOption { ... };` (the big attrsOf submodule, around lines 141–163)
- `defaultProfile = lib.mkOption { ... };`
- `soundTheme = lib.mkOption { ... };`

- [ ] **Step 2: Remove the profile JSON materialization**

Delete:

```nix
    home.file.".local/share/standard-os/notif-profiles.json".text =
      builtins.toJSON cfg.profiles;
```

(plus its surrounding comment block).

- [ ] **Step 3: Remove `notifRofiProfilesBin`**

Delete the derivation line:

```nix
  notifRofiProfilesBin = mkScript "notif-rofi-profiles" ./../scripts/notif-rofi-profiles;
```

and remove `notifRofiProfilesBin` from the `home.packages` list.

- [ ] **Step 4: Remove the lib copies**

In the `libDir` derivation (the one that builds the `notif-libs` store path), delete these `cp` lines:

```nix
    cp ${../scripts/lib/notif-profile-format.sh} $out/lib/notif-profile-format.sh
    cp ${../scripts/lib/notif-schedule.sh}       $out/lib/notif-schedule.sh
```

- [ ] **Step 5: Remove `NOTIF_DEFAULT_PROFILE` from the daemon service Environment**

In `systemd.user.services.notif-daemon`, find the `Environment = [...]` array and delete the `"NOTIF_DEFAULT_PROFILE=${cfg.defaultProfile}"` line.

- [ ] **Step 6: Rebuild — surfaces any remaining reference**

```bash
sudo nixos-rebuild switch 2>&1 | tail -20
```

Expected: build succeeds. If `cfg.profiles` / `cfg.defaultProfile` / `cfg.soundTheme` errors fire, find and remove those references in `notif-center.nix` (most likely in a comment or a leftover string interpolation).

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home && git add modules/notif-center.nix && \
git commit -m "notif-center.nix: drop profile mkOptions + JSON + profile rofi binary"
```

---

### Task 9: Swap `custom/notif-profile` for `custom/notif-dnd` in waybar

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`

- [ ] **Step 1: Edit the module list (modules-right)**

Search the `"modules-right"` array. Find `"custom/notif-profile"` and replace with `"custom/notif-dnd"`.

- [ ] **Step 2: Replace the module config block**

Find the `"custom/notif-profile": { ... }` block. Replace it with:

```jsonc
  "custom/notif-dnd": {
    "exec": "cat /tmp/waybar-cache/notif-dnd 2>/dev/null || echo '{\"text\":\"\"}'",
    "interval": "once",
    "signal": 12,
    "return-type": "json",
    "format": "{}",
    "on-click": "notif-click dnd"
  },
```

(Match the field set the old `custom/notif-profile` block had — if it included a `tooltip` directive or `format-icons`, preserve the same style; the rendered JSON already carries `tooltip` so the module just passes it through.)

- [ ] **Step 3: Update the comment block describing bell children**

Find the comment paragraph around line 594 that describes child order. Replace `profile` with `dnd`:

```
// → bell (rightmost, always visible) → dnd → action-{1,2,3} (leftmost
```

- [ ] **Step 4: Restart waybar to pick up the config**

```bash
systemctl --user restart waybar
sleep 0.5
pgrep -a waybar | head -1   # confirm running
```

- [ ] **Step 5: Live verify the DND pill renders**

Hover the bell pill. The DND child pill should appear immediately to the left, showing the bell-off glyph at rest.

Click it. The pill should switch to breathing animation. Tooltip on hover should read "DND on — click to resume notifications".

Click again. Pill returns to rest face. Tooltip: "Stop notifications".

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home && git add waybar/config.jsonc && \
git commit -m "waybar: custom/notif-profile → custom/notif-dnd"
```

---

### Task 10: Delete dead scripts, libs, and tests

**Files:**
- Delete: `scripts/notif-rofi-profiles`
- Delete: `scripts/lib/notif-profile-format.sh`
- Delete: `scripts/lib/notif-schedule.sh`
- Delete: `tests/notif-profile-format-test.sh`
- Delete: `tests/notif-schedule-test.sh`

- [ ] **Step 1: Confirm no remaining references**

```bash
grep -rn "notif-rofi-profiles\|notif-profile-format\|notif-schedule" \
    /etc/nixos/home/scripts/ /etc/nixos/home/modules/ /etc/nixos/home/waybar/ \
    --include="*.sh" --include="*.nix" --include="*.jsonc" 2>/dev/null
```

Expected: no output. If there are any matches, follow them and remove the references before deleting the files.

- [ ] **Step 2: Delete the runtime override file (one-shot manual cleanup)**

```bash
rm -f ~/.local/share/standard-os/notif-active-profile
```

(Not declarative; safe to remove now that nothing reads it.)

- [ ] **Step 3: Delete the dead source files**

```bash
cd /etc/nixos/home
git rm scripts/notif-rofi-profiles
git rm scripts/lib/notif-profile-format.sh
git rm scripts/lib/notif-schedule.sh
git rm tests/notif-profile-format-test.sh
git rm tests/notif-schedule-test.sh
```

- [ ] **Step 4: Rebuild — make sure nothing breaks**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git commit -m "notif: delete profile scripts, libs, tests (replaced by DND toggle)"
```

---

### Task 11: TODO entry + spec acceptance closure

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Move the relevant TODO/NEXT line and add a DONE entry**

If `TODO.md` had a profile-related NEXT/TODO line, delete it. Add a DONE entry at the top of the DONE list:

```markdown
- **2026-06-15** — **profile machinery purged → single DND toggle pill.**
  Replaced six profiles (off/dnd/sleep/work/gaming/media), the
  notif-rofi-profiles picker, lib/notif-profile-format.sh, lib/notif-schedule.sh,
  the profiles JSON materialization, and ~150 lines of profile-resolution
  logic in the bash daemon with a single state file
  ~/.local/share/standard-os/notif-dnd (presence ↔ ON).
  Click `notif-click dnd` (bell-child pill) toggles + SIGUSR1s the daemon.
  When ON: wide-pill suppressed, sound suppressed, journal + pin keep working.
  Visible from the moment of toggle via `opt-breathe` on the DND child pill.
  **Hint:** spec at `docs/superpowers/specs/2026-06-15-profile-purge-dnd-toggle-design.md`.
  **Hint:** notif-rofi-profiles is gone from PATH; any hyprland keybinding
  that called it should now call `notif-click dnd` directly.
```

- [ ] **Step 2: Commit**

```bash
cd /etc/nixos/home && git add waybar/TODO.md && \
git commit -m "TODO: profile machinery purged — DND toggle shipped"
```

---

## Self-review pass

1. **Spec coverage:** every spec section maps to at least one task.
   - State model → Task 3 (state file conventions), Task 4 (daemon reads it).
   - Click handler → Task 2 (decision) + Task 3 (runner).
   - Daemon behavior → Task 4 (render), Task 5 (gate).
   - Rendering / icon → Task 1 (verify), Task 4 (render function).
   - waybar swap → Task 9.
   - Module deletions in nix → Task 8.
   - Files removed → Task 10.
   - Tests → Task 2 (new), Task 7 step 9 (audit/trim notif-state-test.sh), Task 10 (deletes).

2. **Placeholder scan:** no TBDs. Every step shows actual code or commands. Task 7 step 4's "match the current hard-coded values" depends on what the existing daemon hard-codes — the worker can read the current `sound_for_state` body before rewriting.

3. **Type consistency:** function signature simplifications are stated explicitly with call-site updates in the same task (Task 7 step 5).

4. **Verify-friendly:** every commit-producing task ends with at least one live-system observation (rebuild + notify-send + cat cache files).

---

Plan complete and saved to `docs/superpowers/plans/2026-06-15-profile-purge-dnd-toggle.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
