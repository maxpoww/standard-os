# Notification P3: focus profiles + sound

**Date:** 2026-06-11
**Status:** Approved (pending user review of this written doc).
**Builds on:** P1 spine + P2 composers; replaces the binary DND mechanic with named profiles and adds the sound subsystem.
**Scope:** Phase 3 of the notification roadmap. Phases 1 + 2 are live; P3 closes the original roadmap.

---

## Purpose

P1 + P2 made notifications visible, browsable, actionable, and (in the OTP case) immediately useful. P3 adds the **mode** dimension: the user picks how aggressively the OS interrupts them based on context — and a default sound when interruption is the right choice. Six profiles (Off, DND, Sleep, Work, Gaming, Media), each with declarative silence rules, optional schedules, and per-profile sound behavior.

The DND binary toggle from P1 retires. Its UX home — the hover-revealed child pill under `group/notif` — is repurposed as the profile pill. All P1 invariants (atomic cache writes, RTMIN+12 signal, JSON-array class, Rule 4) carry over.

Discipline: no right-click ([[no-right-click]]); rofi handles overflow / setup ([[rofi-as-more-options]]).

---

## The six profiles

| Profile | silenceMode | criticalPulse | criticalSound | Default sound | Use case |
|---|---|---|---|---|---|
| **Off** | `none` | true | true | default | no focus active |
| **DND** | `transient` | true | true | mute | meetings / focused work |
| **Sleep** | `all-but-critical-silent` | false | false | mute | overnight; don't startle |
| **Work** | `non-allowed` | true | true | default for allowed; mute else | working hours |
| **Gaming** | `all` | true | true | mute | gameplay; allow critical alerts |
| **Media** | `all-but-critical-silent` | false | false | mute | watching/listening |

### silenceMode meanings

- **none** — all arrivals proceed normally (current P1/P2 behavior).
- **transient** — non-critical arrivals do NOT raise the wide-pill transient; the bell silently bumps to opt-pin-green. Critical pierces with the full opt-pulse-orange + opt-no transient.
- **all-but-critical-silent** — non-critical → silent pin bump. Critical → silent pin bump too (opt-pin-orange), NO transient, NO opt-pulse-orange. The only signal is the orange bell glyph.
- **non-allowed** — arrival's `app_name` is checked against `allowedApps`. Match → behaves like silenceMode=none. No match → behaves like silenceMode=transient.
- **all** — same as `all-but-critical-silent` for non-critical (silent pin); critical still gets the full pulse+sound transient (Gaming wants to know if something urgent fires).

### criticalPulse / criticalSound

Independent overrides for whether critical urgency:
- triggers opt-pulse-orange + opt-no on the bell wide-pill (`criticalPulse`).
- plays the urgent-sound (`criticalSound`).

These default to `true` and only `Sleep` + `Media` set them `false`.

### Schedule format

```
schedule = "HH:MM-HH:MM Mon-Sun"
        | "HH:MM-HH:MM Mon-Fri"
        | "HH:MM-HH:MM *"           # all days, abbreviation
        | "HH:MM-HH:MM"             # same as *
        |  []                       # no schedule
```

Single range per profile (multi-range is YAGNI for v1; user can layer two profiles via overlap rules in a follow-up).

`HH:MM-HH:MM` may cross midnight (e.g., Sleep `22:00-08:00 *` — the daemon's evaluator handles wraparound).

### Default Nix config (factory)

```nix
services.notifCenter.profiles = {
  off = {
    silenceMode = "none";
    schedule = null;            # always implicit fallback
  };
  dnd = {
    silenceMode = "transient";
    schedule = null;            # manual only
  };
  sleep = {
    silenceMode = "all-but-critical-silent";
    criticalPulse = false;
    criticalSound = false;
    schedule = "22:00-08:00 *";
  };
  work = {
    silenceMode = "non-allowed";
    allowedApps = [];           # user fills in (empty default = everything blocked while Work active)
    schedule = "09:00-17:00 Mon-Fri";
  };
  gaming = {
    silenceMode = "all";
    schedule = null;
  };
  media = {
    silenceMode = "all-but-critical-silent";
    criticalPulse = false;
    criticalSound = false;
    schedule = null;
  };
};
services.notifCenter.defaultProfile = "off";
services.notifCenter.soundTheme = "freedesktop";  # canberra theme name
```

`profileOrder` (used by the rofi picker + cycle order) defaults to the dict declaration order. The Nix module can expose a `profileOrder = [ "off" "dnd" "sleep" "work" "gaming" "media" ]` if explicit control is wanted; YAGNI for v1.

---

## Active-profile resolution

State files:
- `~/.local/share/standard-os/notif-active-profile` — written by notif-click on user pick. Format:

  ```
  profile=<name>
  valid_until=<ISO 8601 timestamp>
  ```

  `valid_until` is computed by the daemon at write time = next schedule boundary (the earliest moment any profile's schedule transitions in or out). If no schedule applies (all profiles `schedule=null`), `valid_until` is empty → manual override is permanent until the user re-picks.

Resolution algorithm (runs in the daemon on every 60s tick + on every relevant event):

```
1. Read manual override file.
2. If override exists AND now < valid_until: active = override.profile.
3. Else: clear override file. Resolve from schedules:
     for each profile in profileOrder (default order):
         if profile.schedule != null and schedule_matches(now, profile.schedule):
             active = profile
             break
     else:
         active = services.notifCenter.defaultProfile  (default: "off")
```

Schedule match: `weekday IN day_mask AND (start_hhmm <= now < end_hhmm)` with cross-midnight wraparound (`start > end` → match if `now >= start OR now < end`).

The daemon polls every 60s (cheap, single date+string compare) to detect schedule boundary crossings. On boundary cross, re-resolves; if active changes, emit re-render.

---

## Bell pill (rest face) — P3 paint

The bell carries TWO independent signals:

1. **Glyph** = profile-suppress indicator
   - Active profile's `silenceMode in {transient, all-but-critical-silent, non-allowed, all}` → bell-slash glyph (FA solid bell-slash U+F1F7 — bytes `\xef\x87\xb7`).
   - Active profile's `silenceMode == none` → regular bell glyph (FA solid bell U+F0F3 — bytes `\xef\x83\xb3`).
   - Note: `non-allowed` (Work) shows bell-slash even though *some* apps come through — the visual signal is "this is a filtered mode, not normal."

2. **Pin color** = unread state (unchanged from P1)
   - No unread → no pin.
   - Unread normal → opt-pin-green.
   - Unread critical → opt-pin-orange.

The bell **drops `opt-pushed`** entirely — the glyph swap subsumes the "engaged" hint.

State paint table (transient face unchanged from P2). Glyph is bell when `silenceMode == none` (Off only) and bell-slash everywhere else.

| Active profile | silenceMode | Glyph | Class composition (rest) |
|---|---|---|---|
| Off | none | bell | `opt-pill dark` (+pin if unread) |
| DND | transient | bell-slash | `opt-pill dark` (+pin if unread) |
| Sleep | all-but-critical-silent | bell-slash | `opt-pill dark` (+pin if unread) |
| Work | non-allowed | bell-slash | `opt-pill dark` (+pin if unread) |
| Gaming | all | bell-slash | `opt-pill dark` (+pin if unread) |
| Media | all-but-critical-silent | bell-slash | `opt-pill dark` (+pin if unread) |

Pin colors (opt-pin-green / opt-pin-orange) compose with the glyph independently of profile — they always reflect mako's unread / critical counts.

---

## Profile child pill (replaces DND child)

`custom/notif-profile` replaces `custom/notif-dnd` in `group/notif`'s `modules`. Hover-revealed, sits left of the bell.

| Daemon state | Cache content |
|---|---|
| Active = off | `{"text":"Off","class":["opt-pill-child","dark"],"tooltip":"Focus profile"}` |
| Active = dnd | `{"text":"DND","class":["opt-pill-child","dark","opt-yes"],"tooltip":"Focus profile"}` |
| Active = sleep | `{"text":"Sleep","class":["opt-pill-child","dark","opt-yes"],"tooltip":"Focus profile"}` |
| Active = work | `{"text":"Work","class":["opt-pill-child","dark","opt-yes"],"tooltip":"Focus profile"}` |
| Active = gaming | `{"text":"Gaming","class":["opt-pill-child","dark","opt-yes"],"tooltip":"Focus profile"}` |
| Active = media | `{"text":"Media","class":["opt-pill-child","dark","opt-yes"],"tooltip":"Focus profile"}` |

`opt-yes` accent only when active != off (so the pill subtly highlights non-default focus). Off shows neutral child surface.

**Click** routes to `notif-click profile` → `open-profile-rofi` → exec `notif-rofi-profiles`.

---

## `notif-rofi-profiles` — the profile picker

A new bash script, packaged via writeShellScriptBin alongside notif-rofi.

```
> [filter]
   ── Active: Work — until 17:00 ──
   Off
 ✓ Work        (active)
   DND
   Sleep       — 22:00-08:00
   Gaming
   Media
```

- Active row is marked with `✓` prefix (or `▶`); the header line shows when the active profile's schedule expires (if any).
- Selecting a profile writes `~/.local/share/standard-os/notif-active-profile` with `profile=<name>` + `valid_until=<computed>` and sends SIGUSR1 to notif-daemon to re-resolve immediately.
- "Off" cancels any active focus.
- Escape closes without change.

Implementation seams: reads the active-profile file + the schedule-derived `valid_until` from the same state file. Uses `format_rofi_entry`-style helpers; lib at `home/scripts/lib/notif-profile-format.sh` (small).

---

## Sound subsystem

Default sound IDs (freedesktop sound theme via canberra):
- Normal arrival: `message-new-instant`
- Critical arrival: `dialog-warning`
- Low arrival: silent (no sound regardless of profile)

Daemon helper `play_sound URGENCY APP`:

```
case profile.silenceMode in
  none) ... default mapping
  transient)
    if urgency == critical and profile.criticalSound: play "dialog-warning"
    else: silent
  all-but-critical-silent | all) silent
  non-allowed)
    if app in profile.allowedApps:
        same as silenceMode=none mapping
    else:
        silent
```

Implementation: `canberra-gtk-play -i <event-id> 2>/dev/null & disown`. Fire-and-forget; sound failure (no sound theme installed) silently no-ops.

Per-app sound override is **out of scope for P3** — Nix option name reserved (`services.notifCenter.appSounds = {}`) for a future spec.

### Sound rate limit

To prevent a sound bomb on a notification burst, the daemon tracks `LAST_SOUND_AT` (epoch ms) and refuses to play if `now - LAST_SOUND_AT < 500ms`. The first arrival in a burst always plays; subsequent ones within the 500ms window silently skip the sound (the visual transient + journal entry still fire normally).

---

## Daemon changes

### New state

```
ACTIVE_PROFILE=""                 # resolved on every relevant event + 60s tick
PROFILE_VALID_UNTIL=""            # ISO 8601 or empty
LAST_PROFILE_RESOLVED_AT=0        # epoch ms; throttle the 60s tick
```

Replaces P1's `DND_ON` state (the "DND is on" predicate becomes `ACTIVE_PROFILE != "off" && profiles[ACTIVE_PROFILE].silenceMode != "none"`).

### Schedule evaluator

A pure function:

```
resolve_active_profile <now-epoch> <override-file>
  → echoes "<profile>\t<valid_until_iso>"
```

Reads `services.notifCenter.profiles` from a daemon-side JSON snapshot at `/etc/notif-profiles.json` (materialized by the Nix module from `services.notifCenter.profiles`). This decouples runtime config from the bash daemon and lets the daemon read profiles deterministically.

### `on_arrival` extension

```
1. Read active profile + rules (cached in shell vars; refreshed on USR1).
2. Apply silence rule for the arrival's urgency + app_name → decide
     transient_kind  (normal|critical|"")
     play_sound      (default|silent)
3. Emit caches.
4. play_sound (if play_sound != silent): canberra-gtk-play -i ... & disown
```

### Tick polling

The 60s schedule re-evaluation is added to the main-loop polling cadence. The capped `read -t` from P2 (≤0.5s during transient, ≤0.1s during otp_copied, 1s idle) provides natural cadence; we add a "next-resolve-at" sentinel and re-resolve when crossed.

### SIGUSR1 reuse

P1's SIGUSR1 (DND wake) now means "user changed profile or schedule" — same trap, same flag, same drain (re-resolve + re-emit). `notif-rofi-profiles` sends SIGUSR1 after writing the override file.

P2's SIGUSR2 (OTP-copied) unchanged.

### Bell glyph computation

`render_bell_for_state` gains a SILENCE_MODE arg (string). When mode != "none", the bell glyph swaps to bell-slash. Existing tests for bell glyph bytes get a second case for `silenceMode=transient` etc.

Bell now also drops opt-pushed everywhere. The render function's 9-arg signature from P2 grows to 10 args:

```
render_bell_for_state UNREAD CRITICAL SILENCE_MODE KIND APP TITLE BODY OTP_CODE OTP_COPIED PROFILE
```

(`DND_ON` becomes `SILENCE_MODE`; `PROFILE` is added for tooltip text "Profile: Work" etc.)

### Render delta on critical-silent

When ACTIVE_PROFILE has `criticalPulse=false`, the daemon's on_arrival does NOT set kind="critical" for critical urgency — it just lets the pin color reflect the unread state via emit's normal logic. So Sleep + critical arrival → silent pin bump to opt-pin-orange, no wide pill at all.

---

## Click handler changes (notif-click)

- `dnd` subcommand removed.
- `profile` subcommand added: `notif-click profile` → execs `notif-rofi-profiles`.
- `profile-toggle` subcommand reserved: a future hotkey path could cycle profiles, but P3 ships rofi-only for selection.

---

## Waybar config (config.jsonc)

`group/notif` modules list:

```jsonc
"modules": [
  "custom/notif-action-3",
  "custom/notif-action-2",
  "custom/notif-action-1",
  "custom/notif-profile",
  "custom/notif-bell"
]
```

`custom/notif-dnd` is removed. `custom/notif-profile`:

```jsonc
"custom/notif-profile": {
  "exec": "cat /tmp/waybar-cache/notif-profile 2>/dev/null || echo '{\"text\":\"\"}'",
  "return-type": "json",
  "format": "{}",
  "interval": "once",
  "signal": 12,
  "tooltip": true,
  "on-click": "notif-click profile"
}
```

Cache file: `/tmp/waybar-cache/notif-profile` (was `notif-dnd`).

---

## Nix module updates

```nix
services.notifCenter = {
  profiles = lib.mkOption { type = ...; default = (the 6-profile factory above); };
  defaultProfile = lib.mkOption { type = lib.types.str; default = "off"; };
  soundTheme = lib.mkOption { type = lib.types.str; default = "freedesktop"; };
};
```

`runtimeDeps` adds `libcanberra-gtk3` (provides `canberra-gtk-play`) and `sound-theme-freedesktop`.

The materialized `/etc/notif-profiles.json` is built by `pkgs.writeText "notif-profiles.json" (builtins.toJSON cfg.profiles)` and symlinked from the daemon's PATH-resolvable config dir.

---

## File inventory

```
home/scripts/notif-daemon              ← signature change (render_bell takes SILENCE_MODE); profile resolution; sound playback
home/scripts/notif-click               ← profile subcommand; dnd removed
home/scripts/notif-rofi-profiles       ← NEW — profile picker
home/scripts/lib/notif-profile-format.sh  ← NEW — pure formatters for the rofi rows
home/modules/notif-center.nix          ← profiles option, defaultProfile, soundTheme, runtimeDeps += libcanberra-gtk3, sound-theme-freedesktop
waybar/config.jsonc                    ← custom/notif-dnd → custom/notif-profile in group/notif.modules + module def
waybar/ARCHITECTURE.md                 ← notif-daemon cache list updates (notif-dnd → notif-profile)
waybar/TODO.md                         ← DONE entry
home/tests/notif-state-test.sh         ← render_bell_for_state with SILENCE_MODE; render_profile_for_state
home/tests/notif-click-test.sh         ← profile subcommand decide
home/tests/notif-profile-test.sh       ← NEW — schedule evaluator unit tests
```

---

## Verification / acceptance criteria

A fresh rebuild + restart:

1. **Default at Off:** `notif-active-profile` file absent at start. Daemon resolves to `off`. Bell shows regular bell glyph. Profile child shows "Off" on hover.
2. **Click profile child → rofi opens** with 6 entries; Off is marked active.
3. **Pick Work via rofi:** override file written; daemon SIGUSR1 wakes; resolves to `work`; bell switches to bell-slash; profile pill shows "Work" + `opt-yes`.
4. **Work + allowedApps=["Slack"] + Slack arrival:** transient + sound fire normally.
5. **Work + non-Slack arrival:** silent pin bump only; no transient; no sound.
6. **Schedule auto-engage:** with `sleep = { schedule = "22:00-08:00 *" }`, set system time to 22:00; daemon's 60s tick triggers re-resolution → active = sleep; bell becomes bell-slash; sleep critical arrives silent.
7. **Manual override beats schedule:** during the 22:00 Sleep window, user picks "Off" via rofi. Override file written with `valid_until=08:00`. Sleep-suppressed arrivals now play normally. At 08:00, daemon's tick re-resolves; override cleared; back to schedule-driven Off.
8. **Sleep + critical arrival:** no transient, no opt-pulse-orange, no sound. Bell silently bumps to opt-pin-orange.
9. **Gaming + critical arrival:** full transient with opt-pulse-orange + sound.
10. **Off + normal arrival:** sound = `message-new-instant` fires; transient as before.
11. **Off + critical arrival:** sound = `dialog-warning` fires; transient with opt-pulse-orange.
12. **Low arrival (any profile):** no sound, no transient. Pin bumps if unread > 0.
13. **Sound disabled (no canberra-gtk-play binary):** all flows still work; sound silently no-ops.

Hazard audit:
- Bell glyph byte verification (od) for both bell + bell-slash codepoints.
- Profile cache JSON is valid (array `class`, `dark` token).
- `/etc/notif-profiles.json` exists post-rebuild and is valid JSON.
- Override file format is `key=value\nkey=value`; trailing newline tolerated.
- Schedule wraparound `22:00-08:00` correctly matches 22:00, 23:59, 00:00, 07:59 and rejects 08:01, 21:59.
- Canberra-gtk-play backgrounded via `& disown` — no zombie subprocesses on rapid arrivals.

---

## Out of scope (future)

- Multiple schedules per profile.
- Per-app sound overrides (`appSounds`).
- Per-profile sound overrides (custom file path instead of canberra event ID).
- Hotkey profile cycle.
- Calendar-driven schedules (free/busy from Google Calendar).
- "Until end of meeting" temporary profiles.
- Per-profile waybar bar visuals (e.g., dim the whole bar in Sleep).
- "Wake from Sleep" notification (alarm-style override).

---

## Hazards

- **`/etc/notif-profiles.json` rebuild gate.** Profile changes via Nix require `nixos-rebuild switch`. The daemon reads the file fresh on every resolve, so a rebuild without daemon restart still picks up new profiles on the next tick.
- **Date/time math in bash:** day-of-week parsing varies per locale. The daemon uses `date +%u %H%M` (POSIX, locale-independent) for resolution.
- **Schedule overlap:** if Sleep and Work overlap (impossible by default but user-configurable), `profileOrder` wins. Document loudly.
- **Cross-midnight schedules:** `22:00-08:00 *` is one logical range that crosses midnight. Evaluator handles by checking `start <= now OR now < end` when start > end.
- **Sound bombing:** if 50 notifications arrive in 5 seconds, 50 canberra-gtk-play processes spawn. Mitigation: rate-limit at 1 sound per 500ms via a `LAST_SOUND_AT` timestamp in the daemon.
- **bell-slash glyph byte verification:** U+F1F7 = `\xef\x87\xb7` (FA solid bell-slash). Pasting in editors may strip the bytes — daemon source uses `$'\xef\x87\xb7'` raw escape and tests verify with `od -An -tx1`.
- **The `dnd` subcommand removal:** any user-defined keybinding that ran `notif-click dnd` breaks. Document in TODO.md so the user updates their hyprland config (if any). Migrated to `notif-click profile` (opens rofi).
- **Manual override vs schedule re-engage:** the file's `valid_until` is computed at override time. If the user reboots between override and `valid_until`, the daemon reads the file on startup and respects the timestamp; once past it, the file is cleared on next resolve.
