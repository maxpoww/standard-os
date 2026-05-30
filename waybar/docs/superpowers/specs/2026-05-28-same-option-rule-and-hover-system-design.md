# Same-option rule + the bright/beat hover system

**Date:** 2026-05-28
**Status:** shipped

## Implementation deviation (noted post-build)

The spec below proposes `opt-beat opt-tone-blue` (text-glyph font-size + color beat) for the apps launcher and win-move-new, and `opt-swap-plus` (unchanged) for ws-current. During implementation we noticed that those two motion shapes — text font-size beat vs SVG background-size beat — are *visually distinct*, and Rule 6 requires "exactly the same look" across all three + pills.

**Final implementation:** unified on a single class `opt-plus` (SVG-based). All three + pills use `opt-plus`; ws-current additionally carries `opt-swap` (hide + at rest, reveal on hover behind the workspace number). Hover face is identical for all three: blue background + plus-{white,black}.svg + `opt-pulse-plus` animation (bg-size 14→10, blue color ladder).

**`opt-beat` is deferred** — not built. The infrastructure for text-glyph hover-beats is YAGNI today (no kill/shutdown/disable buttons exist in the bar yet). When such verbs arrive, we'll define `opt-beat` then (and likely choose between SVG icons + opt-plus-style implementation, or text + font-size animation, based on the actual icons available).

What the spec gets right that the implementation keeps:
- The same-option meta-rule (Rule 6) — codified verbatim.
- The hover system split — `opt-hover-bright` is the universal default; action pills get the beat.
- The CSS technique for `opt-hover-bright` — `box-shadow: inset 0 0 0 999px rgba(255,255,255,0.30)` layered over existing background-color, preserving identity.
- The pushed pills' two-stop box-shadow on hover (1 px border + 999 px brighten film).

What changed:
- "Action pill class" was specced as `opt-beat opt-tone-blue`; shipped as `opt-plus` (one class, not a base + tone modifier).
- `opt-tone-red` / `opt-tone-orange` for destructive / toggle-off verbs: deferred (no consumers exist).

---

## Why

Today the three `+` buttons on the bar carry three different visual treatments:

| Pill | Rest | Hover |
|---|---|---|
| `custom/new` (apps launcher) | persistent blue `+` (`opt-yes`) | uniform gray veil |
| `ws-current` (workspace +) | neutral parent w/ workspace number | swap to `+`, beats blue (`opt-pulse-plus`) |
| `custom/win-move-new` (move-to-new-WS) | persistent blue `+` (`opt-yes` on child) | uniform gray veil |

The user reads "+" as ONE option no matter where it appears in the bar. Three different treatments teach contradictory mental models. This spec fixes that and codifies the precedent so future "same options" (close, kill, shutdown, lock, etc.) get the same discipline.

It also redesigns hover globally — the current uniform gray veil muddies state colors and erases identity. We replace it with a brighten-the-rest-color rule, and reserve motion-on-hover for ACTION pills (`opt-beat`).

## The precedent (the meta-rule)

A new maintenance rule joining the existing five:

> **Rule 6 — Same option, same look.** When the same option (verb + glyph) appears in multiple places — every `+`, every "kill", every "open", every "lock" — it MUST share class composition across all instances. The user reads it as ONE option no matter where it appears; inconsistent treatment teaches contradictory mental models. New code adding a recurring option reuses the canonical class string; it does not reinvent one.

This rule is binding the same way the closed budget is binding — it's not a guideline.

## The hover system

Hover splits into two tiers. The pill's class composition picks which.

### Tier 1 — `opt-hover-bright` (the default, on every pill)

The pill's *rest color* gets brighter. Identity is preserved, not erased.

Implementation: a semi-transparent white film layered over the existing background.

```css
window#waybar .opt-pill:hover,
window#waybar .opt-pill-child:hover {
    box-shadow: inset 0 0 0 999px rgba(255, 255, 255, 0.30);
}
```

Why `box-shadow: inset` rather than touching `background`: GTK 3 `background:` REPLACES the value — we'd lose the pill's identity color underneath. A 999px-inset white shadow paints OVER the existing background, leaving it intact. Same technique as `opt-pushed`'s border, scaled up to fill the box. Composes cleanly with `opt-pushed`:

```css
window#waybar .opt-pill.opt-pushed:hover {
    box-shadow: inset 0 0 0 1px @opt-pushed-border,
                inset 0 0 0 999px rgba(255, 255, 255, 0.30);
}
```

The 1px border draws as the innermost layer; the 999px fills the rest. Pressed-affordance survives the hover lift.

The `@opt-hover-veil` color token is **removed** — no longer the source of truth for hover.

### Tier 2 — `opt-beat` (reserved for ACTION pills)

The pill beats on hover — font-size pulses AND color cycles between rest tone and a brighter same-tone. This is the existing `opt-pulse-plus` keyframe semantics, generalised for permanent-+ pills (text glyph) in addition to swap-+ pills (SVG glyph).

Motion vocabulary impact: **`opt-beat` is NOT a 5th motion.** It is `opt-pulse` semantics triggered by `:hover` instead of continuously. Same motion shape, new trigger scope. The closed 4-motion budget holds.

When to apply: **pills whose click changes the world.** Verbs with consequence.

| Tone | Use for | Color |
|---|---|---|
| `opt-tone-blue` (default) | Forward/creative actions: `+`, open, show, launch, new, restore | blue ladder |
| `opt-tone-red` | Destructive actions: kill, close, shutdown, disconnect | red ladder |
| `opt-tone-orange` | Toggle/disable actions: turn off, mute, disable | orange ladder |

`opt-tone-*` mirrors the existing modifier vocabulary already used by `opt-pulse`, `opt-glow`, `opt-breathe`.

Implementation sketch (CSS):

```css
@keyframes opt-beat-blue-fg {
    from { font-size: 14px; color: #cbd5ff; }
    to   { font-size: 18px; color: #2563eb; }
}
@keyframes opt-beat-red-fg {
    from { font-size: 14px; color: #ffd0d0; }
    to   { font-size: 18px; color: @opt-red; }
}
@keyframes opt-beat-orange-fg {
    from { font-size: 14px; color: #ffdcba; }
    to   { font-size: 18px; color: @opt-orange; }
}

/* Default tone = blue when only opt-beat is present */
window#waybar .opt-beat:hover label {
    animation: opt-beat-blue-fg 1s ease-in-out infinite alternate;
}
window#waybar .opt-beat.opt-tone-red:hover label {
    animation: opt-beat-red-fg 1s ease-in-out infinite alternate;
}
window#waybar .opt-beat.opt-tone-orange:hover label {
    animation: opt-beat-orange-fg 1s ease-in-out infinite alternate;
}
```

`opt-pulse-plus` (the SVG-+ beat used by `opt-swap-plus`) **stays as-is** — it's a specialised "rest-swap + beat" combo for hover-revealed `+` glyphs. `opt-beat` is the text-glyph counterpart.

### Rule of thumb (which tier does a pill get?)

```
Is the click consequential (verb with real impact)?
├─ Yes → opt-beat (with appropriate opt-tone-*)
└─ No  → default opt-hover-bright (every other pill)
```

Most pills are information surfaces (workspace number, clock, battery) — they brighten. Action pills (+, kill, shutdown) beat.

## How the three `+` buttons resolve

| Pill | Class composition after |
|---|---|
| `ws-current` | `opt-pill opt-swap-plus` (unchanged — reference impl) |
| `custom/new` (apps launcher) | `opt-pill opt-beat opt-tone-blue` (was: `opt-pill opt-yes`) |
| `custom/win-move-new` | `opt-pill-child opt-beat opt-tone-blue` (was: `opt-pill-child opt-yes`) |

All three resolve to "+ glyph beats blue on hover". The two non-swap pills also drop their persistent blue rest face — the + at rest now lives on the neutral parent/child surface, matching ws-current's rest convention (neutral parents, color only via action-reveal / pin / pushed / animation).

## Implementation map

1. **`/etc/nixos/home/waybar/style.css`**
   - Remove `@opt-hover-veil` rules (lines 142-143, 154-160, 177-184, 209-215).
   - Add `opt-hover-bright` rule on `.opt-pill:hover, .opt-pill-child:hover` using `box-shadow: inset 0 0 0 999px rgba(255,255,255,0.30)`.
   - Update `.opt-pill.opt-pushed:hover` to keep the 1px inset border AND add the brighten layer (two-stop shadow).
   - Add `opt-beat` rules + 3 keyframes (`opt-beat-blue-fg`, `opt-beat-red-fg`, `opt-beat-orange-fg`).
   - Add light-text override for `opt-beat` (parallel to the existing `.opt-swap-*.light:hover label` block) so the beat color reads on light wallpapers.
   - Keep `@define-color opt-hover-veil` for the comment-block historical reference but the color is no longer referenced by any rule — actually, remove it entirely; one less zombie token.

2. **`/etc/nixos/home/waybar/config.jsonc`**
   - `custom/new` exec: `pill '' opt-yes` → `pill '' "opt-beat opt-tone-blue"`.
   - Update the comment above `group/group-rofi` (line 241): launcher is no longer "the primary go action" via persistent blue — it's now "the canonical + action: neutral at rest, beats blue on hover".

3. **`/home/max/.config/waybar/scripts/workspace-daemon.sh`** (NOT in the waybar repo, lives in `$HOME` per project convention)
   - Line 80: `pill_write "win-move-new" "+" "opt-pill-child $m opt-yes"` → `pill_write "win-move-new" "+" "opt-pill-child $m opt-beat opt-tone-blue"`.

4. **`/etc/nixos/home/waybar/README.md`**
   - Rewrite `### Hover` section (lines 144-152): replace uniform-veil description with the two-tier bright/beat system.
   - Add Rule 6 to `## Maintenance rules` (after current Rule 5 at line 282).
   - Optional: short reference to the bright/beat split inside `### Motion vocabulary` — clarify opt-beat reuses pulse semantics, not a 5th motion.

5. **`/etc/nixos/home/waybar/CLAUDE.md`**
   - Add named pattern entry: "Action pill (`opt-beat`)" describing tone modifiers + the same-option rule's binding force.
   - Add a hazard note: "Don't add `opt-yes` for 'persistent blue' on action pills — use `opt-beat opt-tone-blue` so the bar's same-option discipline holds. Persistent blue is for state, not for verbs."

6. **`/etc/nixos/home/waybar/ARCHITECTURE.md`**
   - One-line note: `opt-beat` added to motion vocabulary as hover-scoped reuse of pulse.

7. **`/etc/nixos/home/waybar/TODO.md`**
   - Move to DONE with a Hint line describing the same-option rule + the hover-system replacement of `@opt-hover-veil` + the three + buttons wired.

8. **`~/.claude/skills/standard-os/SKILL.md`**
   - Add to "Named patterns" section: action pill (`opt-beat`) pattern.
   - Update "The five rules I cannot break" → "The six rules I cannot break" (rule 6 = same-option rule).

## Risks / tradeoffs

1. **Hover behaviour changes for every pill on the bar.** Most pills look very similar (they were neutral; light-gray brighten is close to today's gray veil). State pills (`opt-yes`, `opt-no`, `opt-middle`) get meaningfully different — blue brightens to light-blue instead of veiling to gray-white. This is the intended outcome but warrants a visual gut-check after deploy.

2. **`opt-beat` + already-running state pulse.** If a pill carries both a state animation (`opt-pulse` for low battery) AND opt-beat (hypothetical: "kill" button on a critical-state pill), and the user hovers it — CSS allows only one `animation` per element. The `:hover` declaration overrides. State pulse pauses while hovered, resumes on hover-out. Acceptable for now; revisit if a real conflicting case arises.

3. **`opt-tone-red` and `opt-tone-orange` for opt-beat are forward-looking infra.** No pills use them today (no kill / shutdown / disable buttons exist in the bar yet). Defined now to set the pattern; only `opt-tone-blue` is wired in this change.

4. **The two `+` pills lose their persistent-blue rest face.** This is intentional (Rule 2 — parents naturally uncolored), but it's a visible bar change. Worth confirming with the user post-deploy that the new "+ glyph on neutral surface" reads cleanly without the blue background.

## Verification checklist

- [ ] CSS validates (no GTK 3 parse errors in waybar journal).
- [ ] All three `+` buttons render with the same hover beat.
- [ ] State pills (battery, weather, anything carrying `opt-yes/middle/no`) brighten on hover instead of going to flat gray.
- [ ] `opt-pushed` pills keep their 1px border on hover and ALSO brighten (two-stop box-shadow composes correctly).
- [ ] Light-mode pills (`.light`) brighten correctly — black-text pills on light backgrounds don't go invisible.
- [ ] No regression on existing `opt-swap-*` pills (ws-current, swap-cal, swap-pct, swap-switch) — they continue running their reveal animations and don't accidentally inherit `opt-hover-bright`.
- [ ] TODO.md updated with the DONE entry.
