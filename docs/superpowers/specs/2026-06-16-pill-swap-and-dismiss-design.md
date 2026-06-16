# Bell ↔ DND pill swap + Dismiss child — design

**Date:** 2026-06-16
**Status:** Approved (brainstorming, this session).
**Goal:** Make the SYSTEM-zone notification cluster swap which pill is parent based on DND state, and add a Dismiss(X) child pill that surfaces when the user has unread notifs and is not silenced.

## Why

After shipping the DND toggle (2026-06-15 spec), the user observed a mismatch between **which pill carries the "active mode" identity** and **which pill is anchored as parent**. When DND is on, the silencer is the active state — but it stays a hover-revealed child, while the bell (which has no state in DND-on mode) keeps the parent slot. The user wants the parent slot to track the active mode: bell is the parent while notifs flow, DND is the parent while silenced.

A second observation: in DND-off mode, the bell's hover-revealed cluster could carry **more than one action**. The natural second action is dismissing all unread without having to open the rofi list. That's the new Dismiss child.

## Parent identity = DND state

There is **no separate "parent" state**. The existing `~/.local/share/standard-os/notif-dnd` file determines which pill is parent:

| DND state | Parent | Children (hover-revealed) |
|---|---|---|
| OFF (file absent) | bell | DND, Dismiss (Dismiss collapses if unread == 0) |
| ON (file present) | DND | bell only — Dismiss stays hidden while silenced |

Clicking the DND child toggles DND on, which makes DND the parent. Clicking the bell-as-child toggles DND off, which makes bell the parent. The "swap" is the visual side effect of the toggle — not a separate action.

## Click semantics

`notif-click bell`:
- If DND on (bell is currently child) → route to the existing `toggle-dnd` action (clears DND state file, SIGUSR1s daemon). Equivalent to clicking the DND-as-parent pill.
- If DND off (bell is currently parent) → existing bell decision (`notif_click_decide bell <cache>` → invoke-otp / open-rofi / invoke-and-dismiss / noop).

`notif-click dnd`:
- Unchanged — always `toggle-dnd`.

`notif-click dismiss` (NEW):
- Sources `lib/notif-os.sh`. Calls `mako_dismiss_all`.

The `notif_click_decide` pure function gains a `dismiss)` case that returns `"dismiss-all"`. The action runner case for `"dismiss-all"` already exists (legacy) and currently calls `mako_dismiss_all` — reuse it directly.

The `notif-click bell` branch on DND state is added inline at the action-runner level (before `notif_click_decide` is called), not inside the decision function — because the function is pure and shouldn't read the filesystem.

## Rendering

### Bell pill — `render_bell_for_state`

Branches at the top on DND state:

```bash
if [[ -e "$DND_STATE_FILE" ]]; then
    # Bell is now a child. Render the bell glyph on opt-pill-child, no
    # state classes (children stay default per spec). No transient face
    # (no wide-pill arrives when DND is on — the gate in on_arrival
    # blocks it before render).
    printf '{"text":"<bell-glyph>","class":["opt-pill-child","<theme>"],"tooltip":"Resume notifications"}'
    return 0
fi
# Otherwise: existing parent rendering (current code path).
```

The existing parent path stays exactly as it is today — transient kinds, OTP face, pin colors, all unchanged.

### DND pill — `render_dnd_for_state`

Branches at the top on DND state:

```bash
if [[ -e "$DND_STATE_FILE" ]]; then
    # DND is parent. opt-pill + opt-breathe always; opt-yes if unread.
    classes=("opt-pill" "<theme>" "opt-breathe")
    if (( UNREAD_COUNT > 0 )); then
        classes+=("opt-yes")
    fi
    printf '{"text":"<bell-slash>","class":[...],"tooltip":"DND on — click to resume"}'
    return 0
fi
# Otherwise: existing child rendering.
```

Compose: DND-parent + unread → `["opt-pill","<theme>","opt-breathe","opt-yes"]` (blue surface + breathing animation layered).

### Dismiss pill — `render_dismiss_for_state` (NEW)

```bash
render_dismiss_for_state() {
    local theme classes
    theme="$(glass_theme)"
    if [[ -e "$DND_STATE_FILE" ]] || (( UNREAD_COUNT == 0 )); then
        # No-op state: collapse via the empty-class pattern.
        printf '{"text":"","class":["empty"]}'
        return 0
    fi
    _classes_json classes "opt-pill-child" "$theme"
    # X glyph (FA times ).
    printf '{"text":"","class":%s,"tooltip":"Dismiss all unread"}' "$classes"
}
```

Cache file: `/tmp/waybar-cache/notif-dismiss`. Wired into `emit` alongside `CACHE_BELL` and `CACHE_DND`. Same atomic write + dedup pattern (`LAST_DISMISS_RENDERED`).

## waybar — `config.jsonc`

Module list (`modules-right`): add `"custom/notif-dismiss"` between `"custom/notif-dnd"` and `"custom/notif-bell"`. Final order: `... custom/notif-dnd, custom/notif-dismiss, custom/notif-bell` (left to right; bell rightmost in the cluster).

Module config block:

```jsonc
"custom/notif-dismiss": {
    "exec": "cat /tmp/waybar-cache/notif-dismiss 2>/dev/null || echo '{\"text\":\"\"}'",
    "interval": "once",
    "signal": 12,
    "return-type": "json",
    "format": "{}",
    "on-click": "notif-click dismiss"
}
```

Same RTMIN+12 signal — daemon already emits all pill caches in one `emit()`.

## CSS — `style.css`

Existing pattern: bell parent (`opt-pill`) reveals adjacent `opt-pill-child` siblings on hover (drawer expansion, left-direction in the right zone).

New rule needed: when DND is rendered as parent (`opt-pill`), its right-side sibling `opt-pill-child` (the bell-child) needs to reveal on hover. CSS adjacent-sibling `+` selector works for right-side siblings:

```css
window#waybar #custom-notif-dnd.opt-pill:hover + #custom-notif-dismiss.opt-pill-child,
window#waybar #custom-notif-dnd.opt-pill:hover + .empty + #custom-notif-bell.opt-pill-child {
    /* expand to revealed face — copy from existing left-direction rule */
}
```

(The actual selector chain depends on whether Dismiss is between DND and Bell in the DOM; the rendered Dismiss is `.empty` when DND is on, so the right-side reveal has to skip past it. Implementation will land the exact selector after testing.)

For the **empty-collapse pattern** on Dismiss when unread == 0 or DND on:

```css
window#waybar #custom-notif-dismiss.empty {
    padding: 0;
    margin: 0;
    opacity: 0;
    font-size: 0;
}
```

(Standard Standard-OS empty-collapse, including the mandatory `font-size: 0`.)

## Tests

- `tests/notif-click-test.sh`:
  - `bell` with DND on (cache irrelevant) → existing decision function output (still does the right thing, but the runner-level branch is what shifts behavior; the pure decide function continues to return the same value when DND off). Or add a new test that confirms the runner-level routing without leaking filesystem state — gate it behind `NOTIF_DND_FILE` env override.
  - `dismiss` → `dismiss-all`.
- `tests/notif-state-test.sh`:
  - `render_bell_for_state` in child mode (DND on) → opt-pill-child, no state colors.
  - `render_bell_for_state` in parent mode (DND off) — already covered.
  - `render_dnd_for_state` in parent mode (DND on, unread=0) → opt-pill + opt-breathe, no opt-yes.
  - `render_dnd_for_state` in parent mode (DND on, unread>0) → opt-pill + opt-breathe + opt-yes.
  - `render_dnd_for_state` in child mode (DND off) — already covered.
  - `render_dismiss_for_state` with unread=0 → `["empty"]`.
  - `render_dismiss_for_state` with DND on, unread=5 → `["empty"]` (DND suppresses Dismiss).
  - `render_dismiss_for_state` with DND off, unread=5 → opt-pill-child + X glyph + tooltip.

## Untouched

- `notif-os-daemon` (Rust) — pure dbus owner; unaffected.
- `notif-menu` (L1/L2/View) — unaffected.
- DND-on suppression of wide-pill + sound — already correct (shipped 2026-06-15).
- Click handlers on DND and the action pills — unaffected.

## Risks

1. **CSS adjacent-sibling reveal complexity.** The right-side reveal (DND-parent hovering bell-child) has to skip past a potentially-empty Dismiss. The selector might end up brittle. Mitigation: ship and tune in front of the actual bar.
2. **Dismiss accidental click.** A child pill with destructive behavior (`mako_dismiss_all`) revealed only on hover is reasonable, but a misclick clears everything. Mitigation: tooltip says "Dismiss all unread"; consider a 1-second confirmation hold if it becomes an issue in practice. YAGNI for v1.
3. **Mismatch between parent-pill anchor convention and waybar fixed DOM order.** Standard-OS's "right-zone groups expand left" rule assumes the parent is the rightmost pill. When DND is parent, it's in the middle of the [DND, Dismiss, Bell] cluster, with bell to its right — so the reveal is right-ward. Document this as an exception to the rule. The visual effect (DND visible + bell hover-revealed-on-its-right) reads correctly because Dismiss collapses to zero width while DND is on.

## Rollback

Single commit reverts: bell render branches collapse back, DND render branches collapse back, Dismiss module + render gone, click runner-level DND check removed. State file (notif-dnd) is unaffected — DND toggle keeps working without the swap, which is the pre-swap behavior.
