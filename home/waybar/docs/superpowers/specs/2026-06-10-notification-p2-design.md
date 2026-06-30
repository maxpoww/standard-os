# Notification P2: action buttons + app icons + 2FA extraction

**Date:** 2026-06-10
**Status:** Approved (pending user review of this written doc).
**Builds on:** `2026-06-10-notification-drawer-dnd-design.md` (P1 ships drawer/DND/per-app rules; this spec composes onto the wide-pill transient and the rofi list without changing P1's invariants).
**Scope:** Phase 2 of "finish the notification setup" — three composers that surface inside the existing P1 architecture. Phase 3 (sound, focus modes) is a separate spec.

---

## Purpose

P1 made notifications visible, dismissible, and historic. P2 makes them **actionable** and **contextual**:

1. The user can act on a notification's offered actions (Reply / View / Snooze / etc.) directly from the bar — not just the default action.
2. The user can recognise which app sent a notification at a glance in rofi.
3. The user can grab 2FA / OTP codes with one click — no opening the source app, no manual retype.

All click semantics stay left-click + hover (no right-click — see [[no-right-click]]). Rofi remains the canonical "more OPTIONS" surface for browsing history.

---

## What changes (and what stays the same)

### Bell + DND + drawer (unchanged)

P1's group/notif retains its parent (custom/notif-bell) and DND child (custom/notif-dnd). The bell's state-paint table is unchanged. The wide-pill 5s transient mechanic is unchanged. The rofi launcher's list semantics are unchanged: clicking an entry runs default action + dismisses (no second-stage action list).

### Wide-pill text gains Pango bold

The transient face text changes from:

```
App · Title
```

to:

```
<b>App</b> · Title
```

Waybar's custom-module text supports Pango markup. The app-name becomes visually distinct from the title without taking extra space. Pango `<` and `>` interpretation requires the daemon to escape `<` / `>` / `&` in app/title/body (in addition to the existing JSON escape for `"` and `\`).

### Three new action child pills under group/notif

Three custom modules are added as children of group/notif (in addition to the existing custom/notif-dnd). They appear LEFT of the bell on hover (right-zone expansion):

```
"group/notif": {
  "modules": [
    "custom/notif-action-3",   ← leftmost on hover when populated
    "custom/notif-action-2",
    "custom/notif-action-1",
    "custom/notif-dnd",
    "custom/notif-bell"        ← parent, always visible
  ]
}
```

Each action pill reads `/tmp/waybar-cache/notif-action-N` (N = 1, 2, 3). When the current transient has no actions, action-N caches emit `.empty` and collapse to zero presence. When actions exist, they fill from index 0 upward; notifications with >3 actions render the first 3 in mako-emit order, the rest accessible via the default-action path through rofi.

Click handler: `notif-click action <N>` reads the corresponding cache, extracts the action key the daemon embedded, runs `makoctl invoke -n <transient-id> <action-key>` and dismisses.

### 2FA detection on the wide-pill

The daemon scans every arrival's `summary` and `body` text for a 4-8 digit code anchored to one of these keywords (case-insensitive, in summary or body):

```
code | código | codice | code-de | codigo | OTP | PIN |
verification | auth | login | log-in | token | cód | MFA |
2FA | one-time | one time
```

The regex finds the first `\b\d{4,8}\b` within a 40-character window of any keyword match.

When matched:

- Daemon embeds the extracted code in the bell cache (a non-standard `otp_code` field that waybar ignores).
- Daemon adds `opt-glow-green` to the bell's class array during the 5s transient window.
- Bell pill text remains `<b>App</b> · Title` (no `· OTP` indicator — the green glow is the offer).

When the user clicks the wide-pill:

1. notif-click reads `otp_code` from the cache.
2. notif-click pipes the code to `wl-copy` (Wayland clipboard).
3. notif-click signals the daemon (SIGUSR2) and writes `/tmp/notif-otp-clicked` with the current `id` so the daemon knows which transient transitioned.
4. Daemon's SIGUSR2 trap: transitions transient kind from `otp` → `otp_copied`, re-renders with text `<b>App</b> · Title · copied` (still opt-glow-green), and sets a 500ms collapse timer.
5. After 500ms, daemon runs `makoctl dismiss -n <id>` (which propagates back through the existing Dismissed flow → clears transient → bell returns to rest).

### Rofi icons

The rofi launcher already emits one line per entry via `format_rofi_entry`. P2 extends each row with a rofi icon hint:

```
HH:MM  App · Summary[ tags]\0icon\x1f<app_name>
```

Rofi's `-show-icons` mode (already passed in the launcher invocation) resolves `<app_name>` via the freedesktop icon theme. Apps whose theme entry matches their D-Bus `app_name` (slack, firefox, discord, spotify, code, mail, calendar, …) get their icon. Apps without a theme match render text-only (no icon). No new path resolution code is needed.

Implementation: `format_rofi_entry` gains the icon hint; rofi handles the rest.

---

## Bell pill state paint — additions

| State | Bell class composition (delta from P1) |
|---|---|
| Transient — normal (no actions, no OTP) | unchanged: `opt-pill dark` |
| Transient — normal with OTP code | adds `opt-glow-green` |
| Transient — normal with actions | unchanged (the children carry the action UI; bell stays the same) |
| Transient — normal with OTP code + actions | adds `opt-glow-green`; action children populated |
| Transient — critical (no OTP) | unchanged: `opt-pill dark opt-no opt-pulse-orange` |
| Transient — critical with OTP code | adds `opt-glow-green` (composes; both motions render) |
| Transient — `otp_copied` (post-click 500ms) | text becomes `<b>App</b> · Title · copied`; keeps `opt-glow-green` |

OTP code detection runs on EVERY arrival regardless of urgency. Critical notifications can also carry codes (e.g., bank alerts).

The glow-green + pulse-orange composition for critical+OTP is acceptable in OPTIONS' motion budget: pulse-orange and glow-green run on different CSS properties (background-color animation vs box-shadow animation) and don't interfere visually.

---

## Daemon changes

### Per-arrival pipeline

```
on_arrival():
    # ... existing P1 logic to set TRANSIENT_KIND etc ...
    TRANSIENT_ACTIONS=(action_key:label action_key:label ...)   # from D-Bus actions array
    TRANSIENT_OTP_CODE="$(detect_otp "$summary" "$body")"        # may be empty
    emit
```

### `query_mako_state` extension

`busctl ListNotifications` already returns the `actions` array on each notification. We add extraction:

```jq
[.data[0][]? | select(.id.data == $NEWEST_ID)][0].actions.data
```

The actions array is parsed as `[key, label, key, label, ...]` (mako's format — alternating). The daemon walks pairs and stores up to 3 in `TRANSIENT_ACTIONS`.

### `detect_otp` helper

```bash
detect_otp() {
    local summary="$1" body="$2"
    local combined="$summary $body"
    local keywords='code|codigo|código|codice|OTP|PIN|verification|auth|login|log-in|token|cód|MFA|2FA|one-time|one time'
    # Match: keyword followed within 40 chars by a 4-8 digit standalone code.
    # Anchored on word boundary to avoid catching phone numbers.
    local match
    match=$(grep -oP "(?i)(${keywords})[^[:digit:]]{0,40}\b\K\d{4,8}\b" <<< "$combined" 2>/dev/null | head -1)
    printf '%s' "$match"
}
```

Uses `grep -P` (PCRE). Available in NixOS via `gnugrep`. The `(?i)` makes it case-insensitive; `\K` resets the match start so only the digit run is returned.

### Action child cache writes

Three new cache writers in `emit()`:

```bash
emit_action_caches() {
    local i
    for i in 1 2 3; do
        local cache="/tmp/waybar-cache/notif-action-$i"
        local idx=$((i - 1))
        if (( idx < ${#TRANSIENT_ACTIONS[@]} && -n $TRANSIENT_KIND )); then
            local pair="${TRANSIENT_ACTIONS[$idx]}"
            local key="${pair%%:*}" label="${pair#*:}"
            local content
            content=$(render_action_for_state "$key" "$label")
            write_if_changed "$cache" "$content" "LAST_ACTION_${i}_RENDERED"
        else
            write_if_changed "$cache" '{"text":""}' "LAST_ACTION_${i}_RENDERED"
        fi
    done
}
```

`render_action_for_state` is a new pure function:

```bash
render_action_for_state() {
    local key="$1" label="$2"
    # opt-pill-child surface; opt-yes accent (action = forward intent).
    # Action key embedded in a non-standard `key` field (waybar ignores it;
    # notif-click reads it). Tooltip shows the label for clarity on hover.
    printf '{"text":"%s","class":["opt-pill-child","dark","opt-yes"],"tooltip":"%s","key":"%s"}' \
        "$(json_escape "$label")" "$(json_escape "$label")" "$(json_escape "$key")"
}
```

(Tested with the existing TDD pattern, like P1's renderers.)

### `otp_code` field in bell cache

`render_bell_for_state` is extended with an OTP_CODE arg. When non-empty:
- adds `opt-glow-green` to class array
- emits an additional `"otp_code":"<json-escaped-code>"` field at the END of the JSON object (waybar ignores it; notif-click reads it)

### SIGUSR2 handler — OTP-clicked transition

```bash
on_user_signal_2() {
    USR2_PENDING=1
}
trap on_user_signal_2 USR2
```

Main loop drains USR2_PENDING similarly to USR1, but the handler is different:

```bash
if (( USR2_PENDING )); then
    USR2_PENDING=0
    if [[ -f /tmp/notif-otp-clicked ]]; then
        local clicked_id
        clicked_id=$(cat /tmp/notif-otp-clicked)
        rm -f /tmp/notif-otp-clicked
        if (( clicked_id == TRANSIENT_ID )); then
            TRANSIENT_KIND="otp_copied"
            TRANSIENT_START=$(date +%s%3N)   # restart so 500ms calm runs
            TRANSIENT_OTP_COPIED_AT=$(date +%s%3N)
            emit
        fi
    fi
fi
```

`check_transient_timer` is extended: when kind is `otp_copied`, collapse at 500ms instead of TRANSIENT_MS, AND issue `makoctl dismiss -n $TRANSIENT_ID` before clearing.

### Pango-escape helper

```bash
pango_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}
```

Wide-pill renderer uses `pango_escape` BEFORE wrapping in `<b>...</b>`. Order matters: pango_escape FIRST, then add `<b>` markup, then json_escape the result. Otherwise the `&lt;` would get re-escaped.

---

## Click handler changes (notif-click)

### New subcommands

- `notif-click bell` — extended: detects `otp_code` in cache; if present, runs the OTP flow instead of the standard invoke-and-dismiss.
- `notif-click action <N>` — N = 1, 2, 3. Reads `notif-action-N` cache, extracts action key from the tooltip (which embeds it as `Action: <key>`), runs `makoctl invoke -n <transient-id> <key>` + dismiss.

### OTP flow in `notif-click bell`

```
otp_code=$(jq -r '.otp_code // empty' /tmp/waybar-cache/notif-bell)
if [[ -n $otp_code ]]; then
    printf '%s' "$otp_code" | wl-copy
    # tell the daemon to enter the 500ms "copied" hold
    busctl --user --json=short call \
        org.freedesktop.Notifications /fr/emersion/Mako \
        fr.emersion.Mako ListNotifications | \
        jq -r '[.data[0][]?.id.data] | max // empty' > /tmp/notif-otp-clicked
    systemctl --user kill --kill-who=main -s SIGUSR2 notif-daemon.service
    exit 0
fi
# else: existing bell behavior
```

### `notif-click action <N>` flow

```
N="$1"
cache=/tmp/waybar-cache/notif-action-$N
[[ -f $cache ]] || exit 0
key=$(jq -r '.key // empty' "$cache" 2>/dev/null)
[[ -z $key ]] && exit 0
# Use the latest unread id (the transient always represents the latest)
latest_id=$(busctl --user --json=short call \
    org.freedesktop.Notifications /fr/emersion/Mako \
    fr.emersion.Mako ListNotifications | \
    jq -r '[.data[0][]?.id.data] | max // empty')
[[ -z $latest_id ]] && exit 0
makoctl invoke -n "$latest_id" "$key" 2>/dev/null || true
makoctl dismiss -n "$latest_id" 2>/dev/null || true
```

---

## Rofi launcher changes (notif-rofi)

### `format_rofi_entry` gains an icon field

```bash
format_rofi_entry() {
    local ts="$1" app="$2" summary="$3" urgency="$4" unread="$5" critical="$6"
    local hhmm="${ts:11:5}"
    local tags=""
    if (( unread )); then
        tags+=" · unread"
        (( critical )) && tags+=" · critical"
    fi
    # Append rofi's icon hint: literal null + "icon" + literal US (0x1F) + value
    printf '%s  %s · %s%s\0icon\x1f%s' \
        "$hhmm" "$app" "$summary" "$tags" "$app"
}
```

The `\0icon\x1f<value>` sequence is rofi's row metadata format. `$app` doubles as both display text and the icon-theme lookup key. Apps whose D-Bus `app_name` matches their theme entry get an icon; the rest render text-only.

### Rofi invocation

The existing `rofi -dmenu` invocation gains `-show-icons`:

```bash
rofi -dmenu -i -p "notifications" -no-custom -show-icons -theme-str 'window { width: 50%; }'
```

`-show-icons` is mandatory; without it the row metadata is ignored.

---

## Waybar config (config.jsonc)

The existing `group/notif` modules list expands to 5 children:

```jsonc
"group/notif": {
  "orientation": "inherit",
  "drawer": {
    "transition-duration": 200,
    "transition-left-to-right": false
  },
  "modules": [
    "custom/notif-action-3",
    "custom/notif-action-2",
    "custom/notif-action-1",
    "custom/notif-dnd",
    "custom/notif-bell"
  ]
}
```

Three new module declarations:

```jsonc
"custom/notif-action-1": {
  "exec": "cat /tmp/waybar-cache/notif-action-1 2>/dev/null || echo '{\"text\":\"\"}'",
  "return-type": "json", "format": "{}", "interval": "once", "signal": 12,
  "tooltip": true,
  "on-click": "notif-click action 1"
},
"custom/notif-action-2": {
  "exec": "cat /tmp/waybar-cache/notif-action-2 2>/dev/null || echo '{\"text\":\"\"}'",
  "return-type": "json", "format": "{}", "interval": "once", "signal": 12,
  "tooltip": true,
  "on-click": "notif-click action 2"
},
"custom/notif-action-3": {
  "exec": "cat /tmp/waybar-cache/notif-action-3 2>/dev/null || echo '{\"text\":\"\"}'",
  "return-type": "json", "format": "{}", "interval": "once", "signal": 12,
  "tooltip": true,
  "on-click": "notif-click action 3"
}
```

`custom/notif-bell` gains `"markup": "pango"` (or relies on waybar's default Pango interpretation — check at implementation time and add explicitly if needed).

---

## Nix module changes

`/etc/nixos/home/modules/notif-center.nix`:

- `wl-clipboard` added to `runtimeDeps` (provides `wl-copy`).
- `gnugrep` already in runtime via `coreutils`; if PCRE (`-P`) isn't available in coreutils' grep, add `gnugrep` explicitly.
- No new typed options for P2; the action count (3) is structural; OTP detection has no user-facing toggle.

(Optional `services.notifCenter.otpDetection = lib.mkOption { type = bool; default = true; }` could be added if you want a kill switch, but YAGNI for v1.)

---

## Implementation seams

```
home/scripts/notif-daemon
  + detect_otp() helper
  + render_action_for_state() pure renderer
  + pango_escape() helper
  ~ render_bell_for_state extended: pango_escape app/title, wrap App in <b>, optional opt-glow-green + otp_code field
  ~ query_mako_state extended: parse actions array, fill TRANSIENT_ACTIONS
  ~ on_arrival extended: call detect_otp, set TRANSIENT_OTP_CODE
  + on_user_signal_2 + SIGUSR2 trap
  ~ main loop drains USR2_PENDING (otp_copied transition)
  ~ emit() calls emit_action_caches()
  + emit_action_caches() helper
  ~ check_transient_timer extended for kind=otp_copied (500ms + dismiss)

home/scripts/notif-click
  ~ bell handler: detect otp_code, run OTP flow (wl-copy + SIGUSR2 to daemon)
  + action handler: notif-click action <N>

home/scripts/notif-rofi
  ~ format_rofi_entry includes the icon hint
  ~ rofi invocation adds -show-icons

home/scripts/lib/notif-rofi-format.sh
  ~ format_rofi_entry signature unchanged but output now includes icon hint

home/modules/notif-center.nix
  + wl-clipboard in runtimeDeps
  ~ no new options

waybar/config.jsonc
  + 3 action child modules
  ~ group/notif modules list extended

waybar/ARCHITECTURE.md
  ~ note 5 cache files for notif-daemon (notif-bell, notif-dnd, notif-action-{1,2,3})

waybar/TODO.md
  + DONE entry

home/tests/notif-state-test.sh
  ~ extend bell renderer tests for pango-bold, opt-glow-green, otp_code field
  + render_action_for_state tests

home/tests/notif-click-test.sh
  ~ bell-decide cases for cache with otp_code
  + action subcommand decide cases

home/tests/notif-rofi-test.sh
  ~ format_rofi_entry tests verify icon hint format
```

---

## Verification / acceptance criteria

A fresh rebuild + restart, then:

1. **Wide-pill bold:** `notify-send "test"` → cache `text` field is `<b>notify-send</b> · test`. Render visually: "notify-send" bold, " · test" regular.
2. **Pango-escape:** `notify-send '<script>alert</script>' 'body'` → cache `text` is `<b>&lt;script&gt;alert&lt;/script&gt;</b> · body` (escaped). Renders literal `<script>alert</script>` not as HTML.
3. **No actions:** `notify-send "no actions"` → all 3 notif-action-N caches are `{"text":""}` and collapse.
4. **One action:** `notify-send -A reply=Reply "with action"` → notif-action-1 cache has `text:"Reply"` `class:[opt-pill-child,dark,opt-yes]`; notif-action-2/3 are empty.
5. **Three actions:** `notify-send -A a1=A1 -A a2=A2 -A a3=A3 "three"` → all three action caches populated.
6. **Click action 1:** invokes `makoctl invoke -n <id> reply` AND dismisses.
7. **OTP detected:** `notify-send "TestApp" "Your verification code is 348291"` → bell cache has `opt-glow-green` AND `"otp_code":"348291"`.
8. **OTP click:** click bell during OTP transient → `wl-paste` returns `348291` AND wide pill text becomes `<b>TestApp</b> · Your verification code is 348291 · copied` for 500ms AND then notif dismisses + bell returns to rest.
9. **OTP false-positive guard:** `notify-send "Prices" "1234"` → no opt-glow-green, no otp_code field (no anchoring keyword present).
10. **Rofi icons:** open rofi list when several apps' notifications are unread → icon column shows app-specific icons for slack/firefox/discord/etc.; unknown apps render text-only.
11. **Critical + OTP:** `notify-send --urgency=critical "auth" "code 1111"` → wide pill has BOTH opt-pulse-orange AND opt-glow-green AND otp_code.

Hazard audit:
- `class` JSON arrays on all 5 cache files.
- `dark` token on every non-empty cache.
- `<b>` only ever wraps pango-escaped content (never raw user-supplied strings).
- Atomic writes via `tmp + mv` on all 5 cache writers.
- `pkill -RTMIN+12` fires only on real-content change in ANY of the 5 caches.
- `wl-copy` invocations don't leak into stderr (`2>/dev/null` on all calls).
- `grep -P` available (`type grep` exits 0; otherwise fall back to a manual digit-scan loop).

---

## Open questions resolved

1. **What if a notification has both a known default action AND auxiliary actions?** Wide-pill click without hover runs the default action (as today). Hover then click an action child runs the chosen action. Both paths dismiss the notification. The two paths are exclusive — you can't do both for one notification.

2. **What if the user clicks an action child after the 5s window expires?** The action caches are `.empty` after the transient collapses; the click is on an invisible widget, which produces a `noop` (no transient → notif-click action falls through). Acceptable.

3. **What if mako reports >3 actions?** Render the first 3 in mako's emitted order. The 4th+ are reachable only via rofi → default action. Documented limitation; configurable in a follow-up if it bites.

4. **What if the OTP regex matches multiple codes?** Take the first. Most 2FA messages contain exactly one code; the first one is usually the intended one.

5. **What if the icon name doesn't match any theme entry?** Rofi silently renders no icon (text-only row). No code path needed; rofi handles fallback.

6. **What about Pango markup in the body / tooltip?** Body goes to the tooltip; tooltip doesn't use Pango by default. So no escaping needed there beyond the existing JSON escape. (If we ever surface body as markup, this changes.)

---

## Out of scope — Phase 3 (separate spec)

- Sound (canberra-gtk-play per urgency, honoring DND, per-app sound files).
- Focus modes (scheduled DND profiles, per-app exclusions).

P3 composes onto P1's DND mechanic and may add new typed options to the Nix module.

---

## Hazards specific to this design

- **Pango markup in app/title is a XSS-equivalent risk.** Without `pango_escape`, an app could send `<b>fake bold</b>` and inject styling. The daemon MUST escape `<`, `>`, `&` BEFORE wrapping in `<b>...</b>`. The test suite verifies this on real Pango-special-char inputs.
- **`grep -P` is GNU-specific.** NixOS has it via `gnugrep`. If `runtimeDeps` accidentally pulls a non-GNU grep, OTP detection silently fails (regex with `\K` is not portable). Pin gnugrep explicitly in runtimeDeps.
- **Non-standard `key` field on action cache JSON.** Daemon writes `"key":"<action_key>"` alongside the standard waybar fields. Waybar ignores it; notif-click reads it via `jq -r '.key'`. The field name is project-internal contract between the two scripts; if the format ever changes (e.g., key becomes per-language), both files need synchronised updates. Document loudly at both ends.
- **OTP `otp_code` field collides with future JSON schema additions.** Waybar ignores unknown fields, so safe today. Name conflicts are caller's responsibility.
- **The /tmp/notif-otp-clicked file is a single-shot rendezvous.** If two OTP-detected notifications arrive rapidly and the user clicks both, the second click's id might overwrite the first's before the daemon reads. Acceptable: at the speed of human click, this race is theoretical, and the 500ms hold makes it unlikely.
- **`wl-copy` outlives the process.** It forks a clipboard server that holds the data until clipboard ownership changes. We don't manage that lifecycle; the user's next copy supersedes. Documented behavior of wl-clipboard.
- **Rofi -show-icons increases startup time.** Icon-theme resolution adds ~50ms to rofi's first display. Acceptable for a click-triggered launcher.
- **The 500ms otp_copied transition uses the same TRANSIENT_KIND mechanism.** Care needed: the daemon must NOT enter `otp_copied` if `TRANSIENT_KIND` is empty (e.g., delayed SIGUSR2 after transient already collapsed). The handler checks `clicked_id == TRANSIENT_ID` before transitioning.
