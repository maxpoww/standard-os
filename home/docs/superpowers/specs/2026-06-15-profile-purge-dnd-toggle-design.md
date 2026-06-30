# Profile purge + DND toggle — design

**Date:** 2026-06-15
**Status:** Approved (brainstorming session, this session).
**Goal:** Replace the six-profile notification-center machinery with a single Do-Not-Disturb toggle exposed as a child pill on the bell.

## Why

The profile system (`off`, `dnd`, `sleep`, `work`, `gaming`, `media`) was P3 of the notification-center spine. In practice the only profile state the user toggles is "shut up for a while" — the multi-mode generality (allowed-app lists, schedules, sound-theme variation, criticalSound/criticalPulse independence) carries cost (113-line picker script, two lib files, ~150 lines of daemon logic, a JSON materialization, a runtime override file, a SIGUSR1 path) for behavior the user never reaches for. The whole subsystem collapses to one boolean, surfaced as one pill, that toggles silence on the bell's existing pin/journal path.

## Behavior contract

| State | Wide-pill (transient) | Sound | Bell pin | Journal |
|---|---|---|---|---|
| DND OFF | shown 5 s on arrival | `canberra-gtk-play` per urgency | updates from `UNREAD_COUNT` / `CRITICAL_COUNT` | written by `notif-os-daemon` |
| DND ON | **suppressed** | **suppressed** | updates from `UNREAD_COUNT` / `CRITICAL_COUNT` (unchanged) | written by `notif-os-daemon` (unchanged) |

Effect: when DND is on, a notif arrives silently and shows up as a pin pulse on the bell. The user can click the bell at their convenience to read it through `notif-menu`'s L1 list. No notification is lost.

## State model

- **Single state file:** `~/.local/share/standard-os/notif-dnd`. Existence ↔ ON. Body irrelevant (presence is the signal — same convention the obsolete `notif-active-profile` used).
- **Persistence:** survives logout, reboot, daemon restart.
- **Discoverability of ON state:** the DND child pill continuously breathes (see Rendering) for the lifetime of the ON state, so a hover on the bell makes the state visible immediately.

## Click handler — `notif-click dnd`

New subcommand in `notif-click`:

```
if [[ -e $DND_STATE_FILE ]]; then
    rm -f "$DND_STATE_FILE"
else
    : > "$DND_STATE_FILE"     # create empty
fi
systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service
```

SIGUSR1 was previously used to re-resolve the active profile on external change (`notif-rofi-profiles` wrote the override file then signalled). The handler keeps its name and is repurposed: on signal, re-stat the DND file and re-emit the pill cache.

`notif_click_decide`'s `dnd` branch always returns `"toggle-dnd"` regardless of pill cache contents — the click is a pure toggle, no state inspection of the pill itself.

## Daemon behavior — `scripts/notif-daemon`

### Per-notif decision

`on_arrival` consults `[[ -e $DND_STATE_FILE ]]` once at the top:

```
dnd_on=0
[[ -e $DND_STATE_FILE ]] && dnd_on=1

# Transient suppression
if (( dnd_on )); then
    TRANSIENT_KIND=""
    # skip OTP code parsing, action parsing — no wide-pill to render
else
    # existing transient logic
fi

# Sound suppression
if (( ! dnd_on )); then
    # existing canberra-gtk-play branch
fi
```

`UNREAD_COUNT`, `CRITICAL_COUNT`, `NEWEST_*` populate as normal (via `query_mako_state`); the pin in `render_bell_for_state` reads these regardless of DND. Journal is written by `notif-os-daemon` upstream of the bash daemon and is unaffected.

### Stripped surface

- `resolve_and_load_profile`, `profile_display_name`, `load_profile_into_active`, `render_profile_for_state` → deleted.
- `ACTIVE_SILENCE_MODE`, `ACTIVE_CRIT_PULSE`, `ACTIVE_CRIT_SOUND`, `ACTIVE_ALLOWED_CSV`, `LAST_PROFILE_RESOLVED_AT` globals → deleted.
- `source "$LIB_DIR/notif-schedule.sh"` → deleted.
- `transient_kind_for_state` / `sound_for_state` / `render_bell_for_state` lose their `silence_mode` / `crit_*` / `allowed_csv` parameters; signatures simplify to urgency + app.

### Rendering

New `render_dnd_for_state`:

```
render_dnd_for_state() {
    local theme dnd_on
    theme="$(glass_theme)"
    [[ -e $DND_STATE_FILE ]] && dnd_on=1 || dnd_on=0
    local classes tooltip
    if (( dnd_on )); then
        _classes_json classes "opt-pill-child" "$theme" "opt-breathe"
        tooltip="DND on — click to resume notifications"
    else
        _classes_json classes "opt-pill-child" "$theme"
        tooltip="Stop notifications"
    fi
    # Bell-slash glyph at all times — state shown via animation, not icon swap.
    printf '{"text":"\\uf1f7","class":%s,"tooltip":"%s"}' "$classes" "$tooltip"
}
```

Wired into `emit` via the same atomic-write pattern as the existing pill caches.
Cache file: `/tmp/waybar-cache/notif-dnd`.

Icon glyph: `` (Nerd Font / Material Design `bell-off`). Bell with a line through it.
Animation: `opt-breathe` — the Standard-OS continuous "ongoing background state" motion. Single closed-budget motion class, composes with the child surface and theme class per Rule 2 (children carry color/state at rest).

## waybar — `config.jsonc`

Module list edit:
- `custom/notif-profile` → `custom/notif-dnd` (identifier in both the modules array and the `"modules-right"` config block).
- `"exec"` → `cat /tmp/waybar-cache/notif-dnd 2>/dev/null || echo '{"text":""}'`.
- `"signal": 12` unchanged (DND pill rides the same RTMIN+12 the daemon already signals).
- `"on-click"` → `notif-click dnd`.

Comment on the children-of-bell paragraph (~line 594) updated to name `dnd` instead of `profile`.

## Files removed

- `scripts/notif-rofi-profiles`
- `scripts/lib/notif-profile-format.sh`
- `scripts/lib/notif-schedule.sh`
- `tests/notif-profile-format-test.sh`
- `tests/notif-schedule-test.sh`

## Module — `modules/notif-center.nix`

Deletions:
- `profiles` mkOption (lines ~141–163).
- `defaultProfile` mkOption.
- `soundTheme` mkOption (was tied to per-profile theme; hard-code `"freedesktop"` inline in the daemon's sound table).
- `home.file.".local/share/standard-os/notif-profiles.json"` block.
- `notifRofiProfilesBin` derivation + the entry in `home.packages`.
- `cp ${../scripts/lib/notif-profile-format.sh} …` and `cp ${../scripts/lib/notif-schedule.sh} …` in the `libDir` derivation.
- `NOTIF_DEFAULT_PROFILE=…` from the `notif-daemon.service` Environment array.

## Tests

`tests/notif-click-test.sh`:
- Drop the `profile → open-profile-rofi` cases.
- Add `dnd → toggle-dnd` cases (decision-function level).
- Add a state-file integration check (file-exists path vs not) if cheap.

`tests/notif-state-test.sh` (if it touches profile state machines) — audit and trim.

## Untouched

- `notif-os-daemon` (Rust) — DND lives in bash daemon only. Rust still owns dbus capture + journal + source-window.
- `notif-menu` (L1 / L2 / View) — entirely unaffected. List still shows everything; click flow stays single-click via the rofi binding fix shipped earlier today.
- The bell pill itself — pin/transient rendering stay the same; DND just gates whether the transient path runs.

## Non-goals

- Scheduled DND ("DND from 22:00 to 08:00") — old `sleep` profile had this; YAGNI for now, re-add when actually wanted.
- Per-app allowlist ("everything silent except Slack") — old `work` profile had this; YAGNI.
- Critical-urgency override ("DND on, but still beep for criticals") — old `sleep` profile had this; user spec explicitly said "only see the pulse" with no sound exception. Re-add if needed.

## Risks

1. **Forgotten DND.** Persistent state means the user could leave DND on for days. Mitigated by the breathing animation being visible whenever the user hovers the bell — every glance at the SYSTEM zone reveals the state.
2. **Stale `~/.local/share/standard-os/notif-active-profile` after rebuild.** The home-manager rebuild will not delete the runtime override file (it was never declarative). One-shot `rm -f` in a `home.activation` block (or just manually after switch) cleans it.
3. **SIGUSR1 handler timing.** The bash daemon already buffers `USR1_PENDING` and re-emits on the next loop tick (~50–250 ms). Click feedback is bounded by that tick; should feel instant.

## Rollback

Single commit reverts the whole change. `notif-active-profile` file (if present) is ignored by everything post-revert — no live regression.
