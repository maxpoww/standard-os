# TODO

The work map. Three sections, in flow order: **TODO** (active work, capped at
6 items), **NEXT** (ideas not yet started), **DONE** (history of what shipped
with a one-line hint about each implementation seam — useful when something
later regresses and you need to remember where the wires are).

Promotion is one-directional: an idea moves NEXT → TODO when work begins, and
TODO → DONE when it ships. **TODO cap = 6.** When TODO is full, nothing
promotes from NEXT until something completes. The cap keeps focus honest.

**Check this file at the start of every session that touches a Standard-OS
directory.** If work completes that was NOT on TODO, it goes straight to DONE
with a Hint line — do not retroactively add to TODO just to move it through.

See `CLAUDE.md` → "TODO.md (the work map)" and the global `standard-os` skill
for the maintenance contract.

---

## TODO

- [ ] **opt-pushed for dictate's recording state** — three of the four
      planned opt-pushed adoptions shipped 2026-05-28 (shader-paper,
      shader-newspaper, night-dimmer). Dictate remains: its `.recording`
      class is emitted by the `dictate-waybar` binary in
      `modules/voice-dictation.nix`, so the change is a Nix module + binary
      update, not a script edit. Refactor target: emit `opt-pill opt-pushed
      opt-breathe` directly instead of the legacy `.recording` class.
- [ ] **Tooltip coverage pass** — one-line tooltip decisions (on / off + text)
      for every existing pill per the README "Tooltips" rule. Tooltips name
      what the pill IS (`"Volume"`, `"Screen"`, `"Battery"`); current values
      live ON the pill. Self-evident pills get `"tooltip": false`. Pure-write
      sweep, no daemon work.
- [ ] **Audio module + context-daemon skeleton** — full pillar-6 proof.
      Permanent home (volume value on the pill, `opt-pushed` for mute), with
      `opt-flash` on `XF86AudioRaiseVolume` / `LowerVolume` / `Mute`. First
      real use of `context-daemon` (RTMIN+17). Validates the "permanent home
      IS transient home" architecture end-to-end before scaling it.
- [ ] **Screenshot module** — smallest pillar-6 proof: one key, no permanent
      state. Hardware-key OR mouse-path option click → daemon produces a
      transient "Saved" pill for 4 s. Click opens the image in the viewer.
      Hover reveals a screenshot-related cluster (open folder, copy path,
      delete, edit). Auto-collapses 4 s after last interaction.

---

## NEXT

- **Brightness module** — `XF86MonBrightnessUp/Down`, transient only (no
  permanent state). Tests the "transient with no permanent home" half of
  pillar 6.
- **Media player module (MPRIS)** — permanent when a player exists, lives in
  USER zone (bound to focused work). `XF86AudioPlay/Pause/Next/Prev` reflects
  on the existing pill. Implementation source: `/home/max/mpris-waybar/` rewrite.
- **Airplane / radios module** — `XF86RFKill` flips `opt-pushed` on the WiFi/BT
  cluster. Pairs naturally with network + bluetooth daemons.
- **Network daemon** (RTMIN+13) — WiFi state, scan, connect, saved profiles.
  Event-driven via `nmcli monitor`.
- **Bluetooth daemon** (RTMIN+13) — paired devices, scan, connect, device
  battery. Event-driven via `dbus-monitor`.
- **System daemon** (RTMIN+12) — CPU / GPU / memory / temp. Polled at 2 s.
- **Clipboard daemon** (RTMIN+15) — selection-aware text-operation options.
  `wl-paste --watch` for events.
- **Control panel row** — second waybar instance for control-panel-style depth.
  Destination for transient pills' "go away to" target after their 4 s expires.
- **`inactive` → `opt-dimmed` rename** — deferred until the workspace daemon
  migrates from `~/.config/waybar/scripts/` to a Nix module (cross-repo
  coupling would break dimming during the transition window otherwise).
- **Workspace-daemon migration to Nix** — moves the daemon into the OPTIONS
  module under `pkgs.writeShellScriptBin` with proper PATH curation.
- **Composite-module pattern** — inotify on `/tmp/waybar-cache/` for pills
  that subscribe to multiple upstream channels. Reference impl:
  `/home/max/mpris-waybar/`.
- **Per-window context surfacing** — focused-window class drives a silent
  swap of per-window options (e.g. text-app focused → format-text cluster
  appears in USER zone). Silent appearance per maintenance rule 4.

---

## DONE

- **2026-05-28** — Consistency pass: CSS dedup, opt-pushed adoption for
  shader-paper / shader-newspaper / night-dimmer, lock glyph unified
  (Material 󰍁 everywhere), stale ws-current comment fixed, battery
  exec extracted from a 400-char inline one-liner to a real
  `~/.config/waybar/scripts/battery.sh`.
  *Hint:* `.opt-pushed.opt-yes/middle/no` lost their redundant
  `box-shadow` declaration — they inherit from `.opt-pushed`'s parent
  rule. shader-toggle.sh / night-dimmer.sh now emit `opt-pushed`
  instead of `opt-yes` when engaged (textbook toggle-ON semantic).
  The lock alternative in `group/group-rofi` was using a Font Awesome
  arrow glyph U+F061 instead of the Material lock — both now use
  `󰍁` (U+F0341), matching `custom/lock` in the power group (Rule 6).
  The battery extraction also revealed two pre-existing bugs that the
  inline was silently carrying: (1) hard-coded `BAT0` while this
  hardware exposes `BAT1` (auto-detection via glob fixes it; the bar
  was showing "?% Unknown" indefinitely), and (2) empty icons for
  Charging/Full/Critical states (waybar hides empty-text modules, so
  the battery pill was invisible in three of four states). Bug (1) is
  fixed in this commit. Bug (2) is PRESERVED to keep the refactor
  free of design decisions — pick Nerd Font glyphs for those three
  states in a follow-up.

- **2026-05-28** — Hover system consolidation: one mechanism, one place.
  Window/clock/battery labels were vanishing on hover because a shared
  preemptive rule (`.opt-swap-switch:hover, .opt-swap-cal:hover,
  .opt-swap-pct:hover { color: transparent }`) hid labels for swap kinds
  whose SVG action-reveal isn't wired yet. Fix: deleted the shared rule
  entirely. Unwired swap kinds now inherit the universal brighten —
  surface lightens, text stays visible. Per-swap label-hide belongs
  INSIDE the per-swap :hover block (paired with the bg-image that
  replaces the label), as `opt-plus:hover` already does.
  Also deleted two more redundant blocks: state-pill hovers
  (`.opt-yes:hover, .opt-middle:hover, .opt-no:hover { box-shadow }`)
  and pin hovers (`.opt-pin-*:hover { box-shadow }`) — both duplicated
  the canonical `.opt-pill:hover` rule that already matches.
  *Hint:* hover behavior in OPTIONS now lives in exactly two CSS places:
  the canonical `.opt-pill:hover` (universal brighten) and per-pill
  `:hover` blocks (opt-pushed, opt-plus, future wired swaps). When
  adding a new pill, ask "does its hover have a SPECIFIC face?" If no,
  do not touch hover CSS — Rule A covers it. If yes, write ONE complete
  per-pill `:hover` block that includes color, bg-image, animation, and
  label transparency together. Never split hover behavior across shared
  blocks; that pattern is what made labels disappear into nothing.

- **2026-05-28** — Rule 7 (no-op options collapse) + opt-plus visibility fix +
  opt-flash keyframe syntax fix. Three bugs surfaced during the post-Rule-6
  activation pass. (a) `opt-flash` keyframe used `0%, 100%` comma-separated
  selectors which waybar 0.14.0's CSS parser rejects — split into separate
  `0%` and `100%` blocks. Dormant bug from commit `bbd4b24` that only
  surfaced when `nixos-rebuild switch` activated the CSS for the first time.
  (b) `opt-plus` permanent-+ pills (apps launcher, win-move-new) emitted
  empty text — waybar hides any custom module with empty text. Fix: pass
  the FA plus glyph U+F067 as text content (`.opt-plus { color: transparent }`
  keeps it invisible so only the SVG renders). (c) `.opt-plus` carried
  `min-width: 14px` which made `ws-current` ~7 px wider than its child peers.
  Dropped — text content provides natural width now. Codified Rule 7: any
  pill whose click would be a no-op collapses to `.empty`. First wiring:
  workspace-daemon now emits the current WS as empty in the win-move list
  (you can't move a window to where it already is).
  *Hint:* the empty-text gotcha is a waybar contract, not a Standard-OS one
  — every opt-plus permanent-+ pill needs the FA glyph sentinel. The
  comma-selector hazard is a waybar 0.14.0 parser limit; if upstream fixes
  it, the keyframe can collapse back to `0%, 100%` syntax. Rule 7 is a
  design rule that outlives both.

- **2026-05-28** — Same-option rule (Rule 6) + bright/beat hover system. The
  three `+` buttons (apps launcher, ws-current's hover face, win-move-new) now
  all share `opt-plus` — same SVG, same blue beat, same `opt-pulse-plus`
  animation on hover. Universal hover changes from a flat gray veil
  (`@opt-hover-veil`) to a brighten-the-rest-color rule (`opt-hover-bright`
  = inset white film at 0.30 alpha, layered OVER the existing background).
  *Hint:* `opt-plus` is the canonical operationalisation of Rule 6 — the
  precedent that the same option SHARES a class string. ws-current uses
  `opt-plus opt-swap` (hide the + at rest, swap in on hover). Apps launcher
  and win-move-new use `opt-plus` alone (+ always visible). The CSS is
  symmetrical: `.opt-plus:hover` is the same for both. When a future
  recurring option arrives (kill, shutdown, lock), name ONE class for it and
  wire every instance to that single class — same discipline. Spec at
  `docs/superpowers/specs/2026-05-28-same-option-rule-and-hover-system-design.md`
  (deviation noted there: implementation unified on SVG-based `opt-plus`
  instead of the text-based `opt-beat opt-tone-blue` originally specced, for
  pixel-identical motion across all three + pills. `opt-beat` deferred until
  a future text-glyph action verb actually needs it — YAGNI).

- **2026-05-28** — Global `standard-os` skill + TODO.md contract refinements
  (session-start check, unplanned-→-DONE rule). Skill at
  `~/.claude/skills/standard-os/SKILL.md` (NOT in this git repo — lives in
  user-level Claude config so it ships with every session, including work on
  `hypr-edge-bg`, `mpris-waybar`, modules/, etc.).
  *Hint:* The skill is a NAVIGATOR not a duplicate of the docs — ~150 lines
  routing Claude to the right doc section, encoding named patterns, and
  enforcing the verification checklist. The only deliberate duplication is
  the five-sentence soul (kept inline so the philosophy loads with the skill).
  When adding a new named pattern, add it to the skill AND to a doc section
  it points to — never let a pattern live only in the skill.
- **2026-05-28** — Pillar 6 (Quiet invitation) + `opt-flash` motion + the
  input-acknowledged / context-silent rule. Commit `bbd4b24`.
  *Hint:* `opt-flash` CSS uses `box-shadow` only — no `background-color` or
  `background-image` touch — so it composes orthogonally with state colors
  AND with `opt-swap-plus`'s SVG icon. One-shot 250 ms, fill-mode default,
  so static styling re-applies after the flash settles (including
  `opt-pushed`'s 1 px border). For rapid same-key repeats the daemon must
  alternate the class between `opt-flash` and `opt-flash-r` to re-trigger.
- **2026-05-28** — Color budget closure: parents naturally uncolored at rest,
  `opt-pin-*` post-animation persistence, `opt-pushed` (sole border carrier),
  dimmed rule formalised, tooltip rules. Commit `8dfb24a`.
  *Hint:* `opt-pushed` uses `box-shadow: inset 0 0 0 1px` — NOT a real CSS
  `border:` — because a real border grows the box by 2 px and breaks the
  22 px bar-height pin. The dimmed CSS class stays as `.inactive` (not
  `.opt-dimmed`) until the workspace daemon migrates to Nix.
- **2026-05-28** — OS architecture migration: first implementation pass of
  the Standard-OS layer over Hyprland. Commit `df391ef`.
- **2026-05-28** — Zone semantics fixed: USER = where the user is, TASK =
  task tools, SYSTEM unchanged. Commit `4b54e63`.
- **2026-05-28** — Foundation pass: three-zone layout, color tokens
  (`opt-surface-parent` / `opt-surface-child`), daemon registry in
  ARCHITECTURE.md. Commit `b6bc3c9`.
  *Hint:* The cool / warm surface differentiation is alpha-matched (both
  0.30) so it reads as "same lightness, different hue" — quiet boundary
  marker, not announcement.
- **2026-05-28** — CLAUDE.md added as the operating manual. Commit `cfc2952`.
- **2026-05-28** — Bar layout zones + parent/child surface colors initial
  draft. Commit `767b993`.
- **(earlier)** — Pre-OPTIONS infra still in use: pill primitive, hover veil,
  30 px border-radius, group drawer + expansion-direction zoning, glass-text
  adaptive text (`/tmp/glass-mode`), cache-file + RTMIN+10/11 signal pattern,
  workspace-daemon publishing window / workspace / win-move state.
  *Hint:* The daemons (`workspace-daemon.sh`, `glass-text-daemon.sh`) live
  in `~/.config/waybar/scripts/`, NOT in this git repo — they're managed
  via `modules/waybar.nix`'s systemd-user units but the script files themselves
  are not yet nix-packaged. Touch them via `Edit` in `$HOME`, not via the
  repo.
