# Rofi pill styling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the rofi popup visually indistinguishable from a waybar pill cluster by giving every row a parent-surface pill at rest, dropping the window to bar-veil so the pills inside become visible, and adding the only missing palette token to both rasi files.

**Architecture:** All changes land in three rasi files (no scripts, no Nix). `rofi/options-dark.rasi` and `rofi/options-light.rasi` get one new token, `@opt-bar-veil`. `rofi/options-base.rasi` gets rule edits on `window`, `listview`, `element`, `element normal.active`, and `element normal.urgent`. The notif-menu binary is unaffected because rofi reads its theme files at launch.

**Tech Stack:** rofi-wayland 2.0.0 + cairo (rasi syntax). No build step — rasi files are mounted via out-of-store symlinks from `modules/rofi.nix`, edits are live without `nixos-rebuild switch`.

## Global Constraints

- **Closed budget (Rule 1):** no new colors, motions, or surfaces beyond what the bar already uses. `@opt-bar-veil` is reused from waybar, not invented here.
- **No hard borders (Rule 3):** zero outline rules; tint + border-radius only.
- **Same option, same look (Rule 6):** action rows use `@opt-surface-child`, the same token bar action pills use.
- **Token mirroring:** rgba literals in rasi files must byte-for-byte match `@define-color` in `waybar/style.css`. `@opt-bar-veil` lives at `waybar/style.css:50` as `rgba(128, 128, 128, 0.10)` — copy verbatim.
- **Symlink discipline (per global memory):** rasi files at `/etc/nixos/home/rofi/*.rasi` are referenced via `mkOutOfStoreSymlink` in `modules/rofi.nix` — edits are live; no rebuild needed.

---

### Task 1: Apply pill-styling rasi changes

**Files:**
- Modify: `rofi/options-dark.rasi` (add one token)
- Modify: `rofi/options-light.rasi` (add one token)
- Modify: `rofi/options-base.rasi` (edit window, listview, element, element normal.active, element normal.urgent)
- Modify: `waybar/TODO.md` (DONE entry)
- Test (no edit): `tests/rofi-anchor-test.sh`, `tests/notif-menu-format-test.sh`, `tests/pill-geom-test.sh` — must stay green (rasi edits should not affect any of them)

**Interfaces:**
- Consumes: existing `@opt-surface-parent`, `@opt-surface-child`, `@opt-hover-bright`, `@opt-text`, `@opt-text-dim` tokens defined in both rasi theme files
- Produces: `@opt-bar-veil` token (mirrored from `waybar/style.css` line 50) used by `window` background-color in base rasi

- [ ] **Step 1: Add `@opt-bar-veil` to options-dark.rasi**

Open `/etc/nixos/home/rofi/options-dark.rasi`. Inside the `* { ... }` token block, insert `opt-bar-veil` BEFORE `opt-surface-parent` so the bar-veil → surface-parent → surface-child ordering matches the waybar palette comment block. Final state of the `*` block:

```rasi
* {
    opt-bar-veil:       rgba(128, 128, 128, 0.10);
    opt-surface-parent: rgba(128, 128, 128, 0.30);
    opt-surface-child:  rgba(170, 170, 170, 0.30);
    opt-hover-bright:   rgba(255, 255, 255, 0.30);
    opt-text:           rgba(255, 255, 255, 1.00);
    opt-text-dim:       rgba(255, 255, 255, 0.55);
}
```

Verify the rgba literal matches `waybar/style.css:50`:

```bash
grep -n 'opt-bar-veil' /etc/nixos/home/waybar/style.css
```

Expected output line ends with `rgba(128, 128, 128, 0.10);` — byte-for-byte identical to what was added.

- [ ] **Step 2: Add `@opt-bar-veil` to options-light.rasi**

Same insertion in `/etc/nixos/home/rofi/options-light.rasi`. The light theme uses the SAME bar-veil literal (matches the bar's behavior where bar-veil is theme-neutral — only text colors flip between modes). Final state:

```rasi
* {
    opt-bar-veil:       rgba(128, 128, 128, 0.10);
    opt-surface-parent: rgba(128, 128, 128, 0.30);
    opt-surface-child:  rgba(170, 170, 170, 0.30);
    opt-hover-bright:   rgba(255, 255, 255, 0.30);
    opt-text:           rgba(  0,   0,   0, 0.85);
    opt-text-dim:       rgba(  0,   0,   0, 0.55);
}
```

- [ ] **Step 3: Edit `window` rule in options-base.rasi**

Open `/etc/nixos/home/rofi/options-base.rasi`. Find:

```rasi
window {
    width:            480px;
    padding:          6px;
    background-color: @opt-surface-parent;
    border-radius:    14px;
}
```

Replace with:

```rasi
window {
    width:            480px;
    padding:          6px;
    background-color: @opt-bar-veil;
    border-radius:    30px;
}
```

Rationale (already in the spec's "Architecture" table): the window now mirrors `window#waybar` (bar-veil background, 30px radius) so it reads as "a fragment of the bar dropped down" rather than "a big pill."

- [ ] **Step 4: Edit `listview` spacing in options-base.rasi**

Find:

```rasi
listview {
    spacing:      2px;
    scrollbar:    false;
    fixed-height: 0;
    lines:        12;
}
```

Change ONLY the `spacing` line to `4px`. Final state:

```rasi
listview {
    spacing:      4px;
    scrollbar:    false;
    fixed-height: 0;
    lines:        12;
}
```

This gives the pill stack the bar's rhythm — bar pills are spaced ~4 px apart, not crammed.

- [ ] **Step 5: Edit `element` (normal row) in options-base.rasi**

Find:

```rasi
/* Row, default — transparent at rest; hover film provides selection. */
element {
    padding:       4px 10px;
    border-radius: 10px;
    cursor:        pointer;
}
```

Replace with the pill-at-rest version. Comment is updated to reflect the new behavior:

```rasi
/* Row, default — parent-surface pill at rest (mirrors .opt-pill).
   Hover film replaces the surface to brighten on selection. */
element {
    padding:          6px 12px;
    border-radius:    18px;
    background-color: @opt-surface-parent;
    cursor:           pointer;
}
```

This is the headline change of the whole effort: every row is now a visible pill.

- [ ] **Step 6: Update `element normal.active` (action rows) radius in options-base.rasi**

Find:

```rasi
/* Action rows — emitted by format_rofi_action with a leading \x02
   sentinel. rofi treats them as `active` rows; we give them the child
   surface so they read as action pills. */
element normal.active {
    background-color: @opt-surface-child;
    border-radius:    10px;
}
```

Change ONLY the `border-radius` line to `18px` (keeps radius consistent with normal rows now that they share the pill identity). Final state:

```rasi
/* Action rows — emitted by format_rofi_action with a leading \x02
   sentinel. rofi treats them as `active` rows; we give them the child
   surface so they read as action pills. */
element normal.active {
    background-color: @opt-surface-child;
    border-radius:    18px;
}
```

- [ ] **Step 7: Update `element normal.urgent` (section headers) in options-base.rasi**

Find:

```rasi
/* Section headers — emitted with the existing dim-non-selectable
   format. rofi treats them as `urgent` rows; we make them small + dim
   and non-clickable visually. */
element normal.urgent {
    background-color: transparent;
    text-color:       @opt-text-dim;
    padding:          2px 10px 0;
    cursor:           default;
}
```

Replace with the smaller-font, slightly-tighter-padding version. The transparent background is preserved (no pill on headers, per spec). Final state:

```rasi
/* Section headers — emitted with the existing dim-non-selectable
   format. rofi treats them as `urgent` rows; we make them small + dim
   and non-clickable visually. The smaller font lets the headers recede
   behind the pill labels. */
element normal.urgent {
    background-color: transparent;
    text-color:       @opt-text-dim;
    font:             "MesloLGS NF 11";
    padding:          4px 12px 0;
    cursor:           default;
}
```

The child `element normal.urgent element-text` rule below this block (sets text-color again on the inner text node) is unchanged.

- [ ] **Step 8: Run the three test suites — confirm zero regressions**

```bash
cd /etc/nixos/home && for t in tests/rofi-anchor-test.sh tests/notif-menu-format-test.sh tests/pill-geom-test.sh; do
  echo "=== $t ==="
  bash "$t" 2>&1 | tail -2
done
```

Expected:
- `rofi-anchor-test.sh` → `--- 25 pass, 0 fail ---`
- `notif-menu-format-test.sh` → `✓ all 17 tests passed`
- `pill-geom-test.sh` → `--- 13 pass, 0 fail ---`

None of these tests exercise rasi rendering — they validate anchor math, row formatting, and pill geometry — so rasi edits should be invisible to them. A red here means something else got touched accidentally; stop and investigate.

- [ ] **Step 9: Live-verify dark mode by screenshotting an open notif-menu**

```bash
echo dark > /tmp/glass-mode
( hyprctl dispatch movecursor 1340 12 >/dev/null
  sleep 0.05
  shot=/tmp/rofi-pill-dark.png
  rm -f "$shot"
  ( notif-menu </dev/null >/dev/null 2>&1 ) &
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.15
    [ -n "$(hyprctl layers -j 2>/dev/null | jq -c '.. | select(.namespace? == \"rofi\")' | head -1)" ] && break
  done
  sleep 0.1
  grim "$shot" 2>/dev/null
  echo "shot: $shot, $(stat -c '%s' "$shot") bytes"
  pkill -INT rofi 2>/dev/null
  wait 2>/dev/null || true
)
```

Then read the screenshot:

```
Read /tmp/rofi-pill-dark.png
```

Confirm visually:
- Window background is the lighter bar-veil tint, NOT the heavier parent-surface tint
- Notification rows are visible gray pills (not transparent text)
- The `▸ Dismiss all unread` row is a brighter pill (child surface)
- Section headers (`— Actions —`, `— Unread (N) —`, `— History —`) are small dim text, no pill
- Hovered row (cursor or selected) brightens to white-film film

If any of these fail, return to the appropriate step and fix.

- [ ] **Step 10: Live-verify light mode by flipping `/tmp/glass-mode` and re-screenshotting**

```bash
echo light > /tmp/glass-mode
( hyprctl dispatch movecursor 1340 12 >/dev/null
  sleep 0.05
  shot=/tmp/rofi-pill-light.png
  rm -f "$shot"
  ( notif-menu </dev/null >/dev/null 2>&1 ) &
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.15
    [ -n "$(hyprctl layers -j 2>/dev/null | jq -c '.. | select(.namespace? == \"rofi\")' | head -1)" ] && break
  done
  sleep 0.1
  grim "$shot" 2>/dev/null
  echo "shot: $shot, $(stat -c '%s' "$shot") bytes"
  pkill -INT rofi 2>/dev/null
  wait 2>/dev/null || true
)
```

Then read:

```
Read /tmp/rofi-pill-light.png
```

Confirm:
- Surfaces stay the same gray (theme-neutral per spec)
- Text reads dark (not the dark-mode white)
- Pills still visible

Restore dark glass after:

```bash
echo dark > /tmp/glass-mode
```

- [ ] **Step 11: Update `waybar/TODO.md` with a DONE entry**

Open `/etc/nixos/home/waybar/TODO.md`. At the top of the `## DONE` section, before the existing `2026-06-17` entries, insert:

```markdown
- **2026-06-17** — **rofi popup styled as OPTIONS pills.** Every row is
  now a parent-surface pill at rest; action rows keep the child-surface
  treatment; section headers stay dim small text with no pill. The
  window dropped from `@opt-surface-parent` to `@opt-bar-veil` so the
  pills inside become visible — previously the window was the same tint
  as the pills and they merged. Added one new token (`@opt-bar-veil`)
  to both rasi theme files, mirroring `waybar/style.css:50`. The five
  remaining rofi surfaces (apps launcher, window switcher,
  restore-minimized, reboot-prompt, notif-rofi legacy) inherit the
  treatment automatically — they import the same shared rasi.
  **Hint:** all changes in `rofi/options-{base,dark,light}.rasi`. No
  script, daemon, or Nix module touched. Edits are live via the
  `mkOutOfStoreSymlink` wiring in `modules/rofi.nix` — no
  `nixos-rebuild switch` needed.
  **Hint:** spec at `docs/superpowers/specs/2026-06-17-rofi-pill-styling-design.md`.
  Plan at `docs/superpowers/plans/2026-06-17-rofi-pill-styling.md`.
```

- [ ] **Step 12: Stage and commit**

```bash
cd /etc/nixos/home && git add \
  rofi/options-base.rasi \
  rofi/options-dark.rasi \
  rofi/options-light.rasi \
  waybar/TODO.md && \
git commit -m "$(cat <<'EOF'
rofi: style popup as OPTIONS pills (window→bar-veil, rows→parent surface)

Every row is now a visible parent-surface pill at rest, mirroring
.opt-pill. Action rows keep the child-surface treatment. Section
headers stay transparent + dim text but get a smaller font so they
recede behind the pill labels. Window background drops from
@opt-surface-parent to @opt-bar-veil so the pills inside become
visible — previously the window was the same tint as the pills and
the visual hierarchy collapsed.

One new token (@opt-bar-veil) added to both rasi theme files; rgba
literal mirrors waybar/style.css:50 byte-for-byte. Closed-budget
respected — no new colors, motions, or surfaces.

All in rasi; no script / daemon / Nix module touched. Edits are live
via the existing mkOutOfStoreSymlink wiring in modules/rofi.nix.

Spec: docs/superpowers/specs/2026-06-17-rofi-pill-styling-design.md
Plan: docs/superpowers/plans/2026-06-17-rofi-pill-styling.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" && git status -s
```

Expected: commit succeeds, `git status -s` prints nothing (clean tree).

- [ ] **Step 13: Clean up screenshot tmp files**

```bash
rm -f /tmp/rofi-pill-dark.png /tmp/rofi-pill-light.png
```

## Verification summary

- All three rasi files edited; no scripts, no Nix.
- Three test suites green (rofi-anchor 25/0, notif-menu-format 17/0, pill-geom 13/0).
- Dark mode: screenshot confirms pills, bar-veil window, dim headers, hover film.
- Light mode: screenshot confirms same shape, text flips to dark.
- TODO.md DONE entry written.
- Single commit landed, tree clean.
