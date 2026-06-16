# Bell ↔ DND Pill Swap + Dismiss Child Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SYSTEM-zone notification cluster swap parent identity based on the existing DND state file (no new state), and add a Dismiss(X) child pill that surfaces when there are unread notifs and DND is off.

**Architecture:** Three pills in fixed waybar order `[DND, Dismiss, Bell]`. Each pill's render function branches on `[[ -e $DND_STATE_FILE ]]` to render parent (`opt-pill`) vs child (`opt-pill-child`). `notif-click bell` gains a runner-level DND check that routes to `toggle-dnd` when bell is child. New `render_dismiss_for_state` collapses to `["empty"]` when DND on OR `UNREAD_COUNT == 0` per Standard-OS's no-op-options rule.

**Tech Stack:** bash 5, waybar 0.14, GTK 3 CSS, NixOS home-manager. Nerd Font glyphs (FA bell ``, FA bell-slash ``, FA times ``).

**Spec:** `docs/superpowers/specs/2026-06-16-pill-swap-and-dismiss-design.md`.

---

## Task ordering rationale

1. **TDD `dismiss → dismiss-all`** in the pure decision function — smallest, isolated, can land before any rendering work.
2. **Daemon adds Dismiss render + emit** — wires `/tmp/waybar-cache/notif-dismiss`. Still in DND-off mode only; no parent/child swap yet.
3. **waybar config + style.css for Dismiss** — module + empty-collapse + bell:hover reveal extended to Dismiss. Ship + visually verify Dismiss works end-to-end (DND off only) before changing anything about bell or DND rendering.
4. **Daemon branches DND render on DND state** (parent face when ON, child face when OFF).
5. **Daemon branches Bell render on DND state** (child face when DND ON).
6. **style.css adjacent-sibling reveal for DND-parent → bell-child** (right-side reveal) and the bell-child empty-collapse hover-only.
7. **`notif-click bell` runner-level DND check** routes to `toggle-dnd` when DND on.
8. **Live verify swap end-to-end + TODO + closeout.**

Each numbered task ends with a commit; verification commands appear before the commit step.

---

### Task 1: TDD — `notif_click_decide dismiss <cache>` returns `"dismiss-all"`

**Files:**
- Modify: `/etc/nixos/home/tests/notif-click-test.sh`
- Modify: `/etc/nixos/home/scripts/notif-click`

- [ ] **Step 1: Add failing test rows**

In `tests/notif-click-test.sh`, near the `dnd` block (search for `# ─── dnd subcommand`), append:

```bash
# ─── dismiss subcommand ───────────────────────────────────────────────────
# Dismiss-all is content-agnostic — the cache is irrelevant; the decision
# only depends on the subcommand. Always returns "dismiss-all".
assert_eq "$(notif_click_decide dismiss "$EMPTY")" "dismiss-all" \
    "[dismiss → dismiss-all regardless of cache (empty)]"
assert_eq "$(notif_click_decide dismiss "$REST_GREEN")" "dismiss-all" \
    "[dismiss → dismiss-all regardless of cache (rest)]"
assert_eq "$(notif_click_decide dismiss '')" "dismiss-all" \
    "[dismiss → dismiss-all with bare empty-string (≠ EMPTY sentinel)]"
```

- [ ] **Step 2: Run tests to verify the dismiss block fails**

```bash
bash /etc/nixos/home/tests/notif-click-test.sh
```

Expected: 3 failures on `[dismiss → ...]` lines (decision returns `"noop"` via the default branch).

- [ ] **Step 3: Implement the dismiss branch in `notif_click_decide`**

In `scripts/notif-click`, inside the `case "$action" in` block of `notif_click_decide`, add a new branch beside the `dnd)` case:

```bash
        dismiss)
            # Dismiss-all — fires mako_dismiss_all in the action runner.
            # Cache content is ignored. The runner case "dismiss-all" is
            # the existing legacy branch (kept around for waybar custom
            # 'invoke' on rest face); we reuse it here.
            printf 'dismiss-all'
            ;;
```

- [ ] **Step 4: Run tests to verify pass**

```bash
bash /etc/nixos/home/tests/notif-click-test.sh
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-click tests/notif-click-test.sh && \
git commit -m "notif-click: notif_click_decide gains dismiss → dismiss-all"
```

---

### Task 2: Daemon — `render_dismiss_for_state` + emit

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-daemon`

- [ ] **Step 1: Add `CACHE_DISMISS` constant**

Find the section near the top of `notif-daemon` that defines `CACHE_BELL`, `CACHE_DND`, etc. Add adjacent:

```bash
CACHE_DISMISS="${NOTIF_CACHE_DISMISS:-/tmp/waybar-cache/notif-dismiss}"
```

- [ ] **Step 2: Add the render function near `render_dnd_for_state`**

Insert this function next to `render_dnd_for_state`:

```bash
# ─── render_dismiss_for_state — Dismiss(X) child pill ──────────────────────
# Pure function. Reads UNREAD_COUNT global + DND_STATE_FILE presence. Emits
# the X glyph as a child pill when DND is OFF and there is at least one
# unread; otherwise emits the empty-class collapse pattern per Standard-OS's
# no-op-options rule.
render_dismiss_for_state() {
    local theme classes
    if [[ -e "$DND_STATE_FILE" ]] || (( UNREAD_COUNT == 0 )); then
        printf '{"text":"","class":["empty"]}'
        return 0
    fi
    theme="$(glass_theme)"
    _classes_json classes "opt-pill-child" "$theme"
    #  is FA times (U+F00D) — same Nerd Font set used elsewhere.
    printf '{"text":"\xef\x80\x8d","class":%s,"tooltip":"Dismiss all unread"}' "$classes"
}
```

- [ ] **Step 3: Add `LAST_DISMISS_RENDERED` state variable**

Find the line `LAST_DND_RENDERED=""` and add immediately below:

```bash
LAST_DISMISS_RENDERED=""
```

- [ ] **Step 4: Wire it into `emit()`**

In the `emit()` function, find the existing `write_if_changed "$CACHE_DND" "$dnd_json" LAST_DND_RENDERED && changed=1` line. After it, add:

```bash
    local dismiss_json
    dismiss_json=$(render_dismiss_for_state)
    write_if_changed "$CACHE_DISMISS" "$dismiss_json" LAST_DISMISS_RENDERED && changed=1
```

- [ ] **Step 5: Update `cleanup()` to clear the Dismiss cache too**

Find `cleanup()`. Currently it writes empty JSON to `CACHE_BELL` and `CACHE_DND`. Add:

```bash
    printf '%s' '{"text":""}' > "${CACHE_DISMISS}.tmp.$$" 2>/dev/null && mv -f "${CACHE_DISMISS}.tmp.$$" "$CACHE_DISMISS" 2>/dev/null
```

- [ ] **Step 6: Smoke test the render function in isolation**

```bash
bash -c '
  set -uo pipefail
  NOTIF_DND_FILE=/tmp/_dnd_smoke; rm -f "$NOTIF_DND_FILE"
  source <(awk "/^glass_theme\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^_classes_json\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^json_escape\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  DND_STATE_FILE="$NOTIF_DND_FILE"
  source <(awk "/^render_dismiss_for_state\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  UNREAD_COUNT=0
  echo "DND_off + unread=0: $(render_dismiss_for_state)"
  UNREAD_COUNT=3
  echo "DND_off + unread=3: $(render_dismiss_for_state)"
  : > "$NOTIF_DND_FILE"
  echo "DND_on  + unread=3: $(render_dismiss_for_state)"
  rm -f "$NOTIF_DND_FILE"
'
```

Expected:
- `DND_off + unread=0` → `{"text":"","class":["empty"]}`.
- `DND_off + unread=3` → JSON containing the X glyph + `"opt-pill-child"` + tooltip.
- `DND_on  + unread=3` → `{"text":"","class":["empty"]}`.

Paste all three lines verbatim in your report.

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-daemon && \
git commit -m "notif-daemon: render_dismiss_for_state + CACHE_DISMISS wired into emit()"
```

---

### Task 3: waybar config + style.css for Dismiss

**Files:**
- Modify: `/etc/nixos/home/waybar/config.jsonc`
- Modify: `/etc/nixos/home/waybar/style.css`

- [ ] **Step 1: Add the `custom/notif-dismiss` module**

In `waybar/config.jsonc`, find `"modules-right"` (or wherever the module list lives). Add `"custom/notif-dismiss"` between `"custom/notif-dnd"` and `"custom/notif-bell"`. The order in the array determines DOM order:

```jsonc
"custom/notif-dnd",
"custom/notif-dismiss",
"custom/notif-bell",
```

- [ ] **Step 2: Add the module config block**

Add to the same file, alongside `"custom/notif-dnd"` and `"custom/notif-bell"`:

```jsonc
"custom/notif-dismiss": {
    "exec": "cat /tmp/waybar-cache/notif-dismiss 2>/dev/null || echo '{\"text\":\"\"}'",
    "interval": "once",
    "signal": 12,
    "return-type": "json",
    "format": "{}",
    "on-click": "notif-click dismiss"
},
```

- [ ] **Step 3: Add empty-collapse CSS for the new module**

In `waybar/style.css`, find the existing empty-collapse pattern (search for `.empty` rules). Add:

```css
window#waybar #custom-notif-dismiss.empty {
    padding: 0;
    margin: 0;
    opacity: 0;
    font-size: 0;
}
```

If the existing CSS uses a shared `.opt-pill-child.empty` selector that already collapses, this step may be a no-op — confirm by greppinging for `.empty` in `style.css` first.

- [ ] **Step 4: Extend the hover-reveal rule to include Dismiss**

Find the existing rule that reveals `custom/notif-dnd` on bell hover. Most likely it uses an adjacent-sibling pattern. Extend the selector to include Dismiss. Example shape (adapt to the existing rule's structure):

```css
window#waybar #custom-notif-bell.opt-pill:hover ~ #custom-notif-dnd.opt-pill-child,
window#waybar #custom-notif-bell.opt-pill:hover ~ #custom-notif-dismiss.opt-pill-child {
    /* reveal: copy the existing reveal declarations */
}
```

If the existing reveal uses `:has()` or a different selector chain, mirror it for the Dismiss ID. Keep ALL existing reveal declarations identical — Dismiss just joins the comma list.

- [ ] **Step 5: Rebuild + restart waybar**

```bash
sudo nixos-rebuild switch 2>&1 | tail -3
systemctl --user restart waybar
sleep 0.5
```

- [ ] **Step 6: Live verify (DND off only)**

1. `rm -f ~/.local/share/standard-os/notif-dnd && systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service`
2. With no unread notifs: hover the bell. Dismiss pill should NOT appear (collapsed via `.empty`).
3. `notify-send dismiss-test "should make Dismiss appear on hover"` → hover bell → Dismiss(X) pill appears alongside DND.
4. Click the Dismiss pill → notif clears. Hover bell again → Dismiss collapses again (no unread).

Confirm steps 2–4 visually before committing.

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home && git add waybar/config.jsonc waybar/style.css && \
git commit -m "waybar: add custom/notif-dismiss module + empty-collapse + hover reveal"
```

---

### Task 4: Daemon — branch `render_dnd_for_state` on DND state (parent mode when ON)

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-daemon`

- [ ] **Step 1: Update `render_dnd_for_state` to render parent face when DND on**

Read the current function. Replace it with this branched version that uses `UNREAD_COUNT` for the blue compose:

```bash
# ─── render_dnd_for_state — DND pill (child when off, parent when on) ──────
# Pure function. Reads DND_STATE_FILE presence + UNREAD_COUNT global.
# DND off (default): child surface, bell-slash glyph, no state classes.
# DND on:            parent surface, bell-slash glyph, opt-breathe always,
#                    opt-yes compose if unread (blue surface + breathing).
render_dnd_for_state() {
    local theme classes tooltip
    theme="$(glass_theme)"
    if [[ -e "$DND_STATE_FILE" ]]; then
        # Parent mode.
        if (( UNREAD_COUNT > 0 )); then
            _classes_json classes "opt-pill" "$theme" "opt-breathe" "opt-yes"
        else
            _classes_json classes "opt-pill" "$theme" "opt-breathe"
        fi
        tooltip="DND on — click to resume notifications"
    else
        # Child mode.
        _classes_json classes "opt-pill-child" "$theme"
        tooltip="Stop notifications"
    fi
    printf '{"text":"\xef\x87\xb7","class":%s,"tooltip":"%s"}' "$classes" "$tooltip"
}
```

- [ ] **Step 2: Smoke test**

```bash
bash -c '
  set -uo pipefail
  NOTIF_DND_FILE=/tmp/_dnd_smoke; rm -f "$NOTIF_DND_FILE"
  source <(awk "/^glass_theme\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^_classes_json\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^json_escape\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  DND_STATE_FILE="$NOTIF_DND_FILE"
  source <(awk "/^render_dnd_for_state\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  UNREAD_COUNT=0
  echo "OFF + unread=0: $(render_dnd_for_state)"
  UNREAD_COUNT=3
  echo "OFF + unread=3: $(render_dnd_for_state)"
  : > "$NOTIF_DND_FILE"
  UNREAD_COUNT=0
  echo "ON  + unread=0: $(render_dnd_for_state)"
  UNREAD_COUNT=3
  echo "ON  + unread=3: $(render_dnd_for_state)"
  rm -f "$NOTIF_DND_FILE"
'
```

Expected:
- `OFF + unread=0` → child surface (`opt-pill-child`), no state classes, tooltip "Stop notifications".
- `OFF + unread=3` → same (child surface, no state classes even with unread — child stays default per spec).
- `ON  + unread=0` → `opt-pill` + `opt-breathe`, no `opt-yes`.
- `ON  + unread=3` → `opt-pill` + `opt-breathe` + `opt-yes` (compose).

Paste all four lines in your report.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-daemon && \
git commit -m "notif-daemon: render_dnd_for_state branches parent/child on DND state"
```

---

### Task 5: Daemon — branch `render_bell_for_state` on DND state (child mode when ON)

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-daemon`

- [ ] **Step 1: Add the DND-on branch at the top of `render_bell_for_state`**

Find `render_bell_for_state()`. Immediately inside the function (after `local unread="${1:-0}" ...` line), add an early-return for DND-on:

```bash
    # When DND is on, bell is the child of DND-parent. Render as default
    # child surface — no state classes (per spec: children stay default
    # color even when there are unread notifs). No transient face either
    # — the DND gate in on_arrival blocks transient setup, so the bell
    # cache will never carry wide-pill text while DND is on.
    if [[ -e "$DND_STATE_FILE" ]]; then
        local theme child_classes
        theme="$(glass_theme)"
        _classes_json child_classes "opt-pill-child" "$theme"
        printf '{"text":"\xef\x83\xb3","class":%s,"tooltip":"Resume notifications","otp_code":""}' \
            "$child_classes"
        return 0
    fi
```

The glyph `\xef\x83\xb3` is the FA bell (U+F0F3) — same bytes the existing parent path already uses.

KEEP everything else in `render_bell_for_state` exactly as it is — the existing parent-mode rendering only runs when DND is off.

- [ ] **Step 2: Smoke test**

```bash
bash -c '
  set -uo pipefail
  NOTIF_DND_FILE=/tmp/_dnd_smoke; rm -f "$NOTIF_DND_FILE"
  source <(awk "/^glass_theme\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^_classes_json\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^json_escape\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  source <(awk "/^pango_escape\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  DND_STATE_FILE="$NOTIF_DND_FILE"
  source <(awk "/^render_bell_for_state\(\)/,/^}/" /etc/nixos/home/scripts/notif-daemon)
  echo "OFF + unread=0: $(render_bell_for_state 0 0)"
  echo "OFF + unread=3: $(render_bell_for_state 3 0)"
  : > "$NOTIF_DND_FILE"
  echo "ON  + unread=0: $(render_bell_for_state 0 0)"
  echo "ON  + unread=3: $(render_bell_for_state 3 0)"
  rm -f "$NOTIF_DND_FILE"
'
```

Expected:
- DND off, unread=0 → existing rest face (opt-pill + dark + bell glyph; no opt-yes).
- DND off, unread=3 → existing rest with `opt-yes` (blue parent).
- DND on, unread=0 → child surface (`opt-pill-child` + dark), bell glyph, tooltip "Resume notifications".
- DND on, unread=3 → same child surface (no state classes — child stays default).

Paste all four lines.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-daemon && \
git commit -m "notif-daemon: render_bell_for_state child mode when DND on"
```

---

### Task 6: style.css — adjacent-sibling reveal for DND-parent and bell-child collapse

**Files:**
- Modify: `/etc/nixos/home/waybar/style.css`

- [ ] **Step 1: Add bell-child empty-state collapse**

When DND is on, the bell pill carries `opt-pill-child`. Without a hover-reveal it would render at child size always-visible. Add a default-collapse for bell-as-child, matched only when it carries `opt-pill-child`:

```css
window#waybar #custom-notif-bell.opt-pill-child {
    padding: 0 6px;
    margin: 0;
    opacity: 0;
    transition: opacity 0.15s ease-out, padding 0.15s ease-out;
}
```

(Match the timing + padding values to whatever other `.opt-pill-child` collapsed-default rules use; this is the "child at rest" face.)

- [ ] **Step 2: Add right-side hover-reveal for DND-as-parent**

When DND is rendered with `opt-pill` (parent mode), hovering it should reveal the bell child (which is positioned to its right in the DOM). Use adjacent-sibling `+` selector, possibly skipping past the empty Dismiss pill:

```css
window#waybar #custom-notif-dnd.opt-pill:hover ~ #custom-notif-bell.opt-pill-child {
    opacity: 1;
    padding: 0 12px;
}
```

(Adapt declarations to match what the existing left-direction reveal uses for the DND-child case.)

- [ ] **Step 3: Rebuild + restart waybar**

```bash
sudo nixos-rebuild switch 2>&1 | tail -3
systemctl --user restart waybar
sleep 0.5
```

- [ ] **Step 4: Live verify**

1. Ensure DND is on: `: > ~/.local/share/standard-os/notif-dnd && systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service`.
2. In the bar: the DND pill should be visible as parent (bell-slash + breathing). Bell pill collapsed (invisible).
3. Hover the DND pill → bell pill reveals to its right with the bell glyph.
4. Turn DND off: `rm ~/.local/share/standard-os/notif-dnd && systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service`.
5. In the bar: bell visible as parent. Hover bell → DND + Dismiss (if unread) appear to its left.

If hover-reveal direction is wrong or timing feels off, iterate on the CSS values (padding, opacity, timing). DO NOT commit until both reveal directions work.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add waybar/style.css && \
git commit -m "waybar/style.css: bell-child collapse + right-side reveal for DND-parent"
```

---

### Task 7: `notif-click bell` runner-level DND gate

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-click`

- [ ] **Step 1: Add the DND check before `notif_click_decide` runs**

Find the action runner section (after the `if [[ "${NOTIF_CLICK_LIB_ONLY:-0}" == "1" ]]` short-circuit). Before the line `decision=$(notif_click_decide "$action" "$cache_content")`, insert:

```bash
# When bell is currently a child (DND is on), clicking it should toggle
# DND off — equivalent to clicking the DND-as-parent pill. The pure
# decision function shouldn't read the filesystem, so this gate lives
# in the runner.
if [[ "$action" == "bell" && -e "${NOTIF_DND_FILE:-$HOME/.local/share/standard-os/notif-dnd}" ]]; then
    action="dnd"
fi
```

This rewrites `$action` from `bell` to `dnd` BEFORE `notif_click_decide` is called. The downstream chain then runs: `dnd) → toggle-dnd → toggle-dnd action runner`. No new decision string, no new action runner case — pure reuse.

- [ ] **Step 2: Test the routing in isolation**

```bash
bash -c '
  set -uo pipefail
  NOTIF_DND_FILE=/tmp/_dnd_route; rm -f "$NOTIF_DND_FILE"
  export NOTIF_CLICK_LIB_ONLY=1
  source /etc/nixos/home/scripts/notif-click
  # DND off: bell stays bell
  action="bell"
  if [[ "$action" == "bell" && -e "${NOTIF_DND_FILE:-$HOME/.local/share/standard-os/notif-dnd}" ]]; then
      action="dnd"
  fi
  echo "DND off → action=$action"
  # DND on: bell rewrites to dnd
  : > "$NOTIF_DND_FILE"
  action="bell"
  if [[ "$action" == "bell" && -e "${NOTIF_DND_FILE:-$HOME/.local/share/standard-os/notif-dnd}" ]]; then
      action="dnd"
  fi
  echo "DND on  → action=$action"
  rm -f "$NOTIF_DND_FILE"
'
```

Expected:
- `DND off → action=bell`
- `DND on  → action=dnd`

- [ ] **Step 3: Live verify the click flow**

```bash
sudo nixos-rebuild switch 2>&1 | tail -3
# DND off → click bell goes to notif-menu (visually).
# DND on  → click bell toggles DND off.
: > ~/.local/share/standard-os/notif-dnd
systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service
sleep 0.3
# Simulate a click programmatically by calling notif-click directly:
notif-click bell &
sleep 0.5
echo "DND state after bell click while DND on:"
[[ -e ~/.local/share/standard-os/notif-dnd ]] && echo "STILL ON" || echo "TOGGLED OFF"
```

Expected: `TOGGLED OFF` — the runner gate routed the bell click to the toggle.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-click && \
git commit -m "notif-click: bell-click routes to dnd toggle when DND is on (bell is child)"
```

---

### Task 8: End-to-end live verify + TODO entry

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Full click-flow verification**

Reset to clean state: `rm -f ~/.local/share/standard-os/notif-dnd && systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service`.

Visual checks (paste a brief PASS/FAIL line for each in your report):

1. Bar at rest, DND off, no unread → bell pill visible as parent (default), DND and Dismiss collapsed (invisible).
2. Hover bell → DND pill appears to its left (no Dismiss — no unread).
3. `notify-send "check-1" "should pop wide-pill"` → wide-pill shows on bell for 5s.
4. After 5s: bell shows `opt-yes` (blue pin). Hover bell → DND + Dismiss now both appear.
5. Click Dismiss → bell returns to rest face (no pin); next hover shows DND but no Dismiss.
6. Click DND child → DND turns on → DND becomes parent (visible with breathing), bell collapses.
7. Hover DND parent → bell child appears to its right.
8. Send notif while DND on: `notify-send "check-2" "should NOT pop"` → no wide-pill, no sound, but DND parent goes blue (`opt-yes` compose with `opt-breathe`) because unread > 0.
9. Click bell child (or DND parent) → DND turns off → bell becomes parent. Bell shows blue pin because notif from step 8 is still unread.
10. Click bell parent → notif-menu opens with the missed notif in Unread.

- [ ] **Step 2: Add the DONE entry**

In `/etc/nixos/home/waybar/TODO.md`, at the TOP of the `## DONE` section, insert:

```markdown
- **2026-06-16** — **bell ↔ DND pill swap + Dismiss(X) child.**
  Parent identity = DND state. DND off → bell is parent, DND is hover-revealed
  child. DND on → DND is parent (opt-breathe always, opt-yes compose if
  unread), bell is hover-revealed child. The swap is a side effect of the
  DND toggle — no separate state file. Bell-click while DND on (bell is
  child) routes to the DND toggle via a runner-level action rewrite, not a
  new decision branch.
  New third pill: Dismiss(X). Hover-revealed alongside DND when bell is
  parent AND unread > 0. Click fires `mako_dismiss_all`. Collapses to
  `["empty"]` via the no-op-options rule whenever DND is on OR unread == 0.
  **Hint:** spec at `docs/superpowers/specs/2026-06-16-pill-swap-and-dismiss-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-16-pill-swap-and-dismiss.md`.
  **Hint:** when DND is parent, the hover-reveal direction is RIGHT-ward
  (bell child sits to the DOM-right of DND). Standard-OS's "right-zone
  groups expand left" rule has an exception here — documented in the spec
  under Risks. The empty-collapsed Dismiss between them keeps the visual
  feeling clean.
```

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home && git add waybar/TODO.md && \
git commit -m "TODO: bell ↔ DND pill swap + Dismiss(X) shipped"
```

---

## Self-review pass

1. **Spec coverage:**
   - Parent identity = DND state → Tasks 4 + 5 (DND + bell render branches), Task 7 (click runner gate).
   - Dismiss pill → Tasks 1 + 2 + 3 (decision + render + waybar wiring).
   - Click semantics → Tasks 1 + 5 + 7.
   - Compose rules (DND parent + breathing + unread blue) → Task 4 step 1.
   - Empty-collapse for Dismiss → Task 2 step 2 + Task 3 step 3.
   - CSS adjacent-sibling reveal → Tasks 3 + 6.
   - Live verify → Task 8.
   - TODO entry → Task 8 step 2.

2. **Placeholder scan:** No TBDs. Each rendering branch shows the exact bash code. CSS rules give shape; exact declaration values are "match existing reveal rule" — that's a guided substitution, not a placeholder.

3. **Type consistency:** Every render function returns JSON as a printf format string. `UNREAD_COUNT` global referenced in render_dismiss + render_dnd is the same name used elsewhere in the daemon. State file constant `DND_STATE_FILE` named consistently across all tasks.

---

Plan complete and saved to `docs/superpowers/plans/2026-06-16-pill-swap-and-dismiss.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
