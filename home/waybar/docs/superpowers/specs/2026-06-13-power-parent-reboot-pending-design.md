# Power-parent reboot-pending — design

**Goal.** Fold the standalone `custom/reboot-pending` pill into the existing
power group so reboot-urgency rides on the same affordance the user already
reaches for to reboot. The bar gains no new pill, no new color outside the
existing budget, no new motion.

**Rule 6 motivation.** "Same option, same look" — the power group is already
where you reach for reboot. Surfacing reboot-urgency as a *separate* pill
elsewhere on the bar splits the user's mental model. The fix is to colour the
existing reboot affordance, not to grow a new one.

## State source

Direct comparison of `/run/current-system` vs `/run/booted-system`,
modulo the `/run/standard-os/reboot-dismissed` marker (same predicate
`waybar-self-test` already implements as `check_reboot_pending`). Two
`readlink`s + one string compare — no cache parsing, no JSON
extraction, no dependency on `waybar-self-test`'s timer.

The three subscribing modules use `interval: 5, signal: 10` — 5 s is
fast enough to feel responsive after a `nixos-rebuild switch` and
slow enough not to be noise; signal 10 lets `waybar-self-test` or a
future signaler force an immediate repaint.

**Why not the existing cache file:** `/tmp/waybar-cache/reboot-pending`
emits `"text":""` in both branches today (`waybar-self-test` writes
the FA-power glyph only when pending, empty otherwise) — but the
standard-os hazard "text=empty hides the module entirely" means the
class swap never reaches the DOM in the normal branch, and the
"current" branch's cache hasn't been observed updating in practice
(the cache file's mtime lags the actual state). Direct source-of-
truth comparison sidesteps both problems.

## Cluster layout

The power group keeps 3 slots in both modes. Only Slot 1 (parent) and
Slot 3 (the swappable child) change identity between modes; Slot 2 (sleep)
is stable.

| Slot | Normal mode | Reboot-pending mode |
|---|---|---|
| 1 — parent `custom/power` | `` (moon) · `opt-pill opt-hover-red` · tooltip "Hibernate" · click → `shutdown-guard hibernate` | `󰜉` (reboot) · `opt-pill opt-pin-yellow` · tooltip "Reboot to finalize updates" · click → `shutdown-guard reboot` |
| 2 — sleep `custom/lock` | `󰍁` · `opt-pill-child opt-yes` · click → `shutdown-guard sleep` | *(unchanged — always visible)* |
| 3 — state-driven | `custom/reboot` — `󰜉` · `opt-pill-child opt-middle` · click → `shutdown-guard reboot` | `custom/hibernate` (new) — `` · `opt-pill-child opt-no` · click → `shutdown-guard hibernate` |

Children are implemented as two distinct modules with `.empty` collapse —
exactly one is visible at a time. Cluster slot count stays at 3, no layout
twitch on state flip.

## Color tier rationale

- `opt-yes` (blue) — sleep, the lightest action, "do this softly."
- `opt-middle` (yellow) — reboot, the warning-tier action.
- `opt-no` (red) — hibernate, the most-drastic action (matches the parent's
  current `opt-hover-red` rest-face semantic; when hibernate moves to a
  child, the tier follows).
- `opt-pin-yellow` — parent attention color in reboot-pending mode.
  Added to the pin family alongside violet / green / orange. Defined as
  `@opt-yellow-pin` at 0.70 alpha — same hue as the existing `@opt-yellow`
  / `@opt-yellow-state` (no new hue, stays inside the 6-hue closed
  budget), saturation lifted to match the other pin colors. The original
  reboot-pending pill used `opt-pin-orange` (peach-toned at this
  saturation), which read too red for "reboot recommended"; yellow lands
  the urgency without sliding into the red/danger family.

## Click behavior

All three modules' on-click routes through
`standard-os-shutdown-guard <action>`. The guard fires its rofi prompt
only when there's an *unactivated* git change at `/etc/nixos/home`
(`check_rebuild_pending` returns true). In reboot-pending mode the
activated commit equals git HEAD — the only thing pending is the *boot*,
not a rebuild — so the guard immediately runs `systemctl reboot`. The
"direct reboot, no prompt" behavior comes for free; we only get a prompt
in the legitimately-ambiguous case (rebuild AND reboot pending).

## Attention motion

None. Per Rule 4 (system-driven context shifts are silent), the parent
just changes color + glyph when the state flips. No pulse, no breathe.
The user notices via ambient color, not performance.

## What gets retired

- `custom/reboot-pending` pill is removed from `modules-right` in
  `config.jsonc` and its module definition deleted.
- `/tmp/waybar-cache/reboot-pending` is **kept** as the state channel —
  three new readers replace the one old reader.
- `waybar-self-test` keeps writing the cache file unchanged.

## Implementation surfaces

- `waybar/scripts/power-pill.sh` (new) — single helper that takes one
  argument (`power | reboot | hibernate`) and emits the JSON for that
  cluster slot based on the direct state predicate. The `*.sh` glob in
  `modules/waybar.nix`'s `waybar-scripts` install loop picks it up with
  no nix-side change. Ships at `${waybar-scripts}/bin/power-pill`.
- `waybar/config.jsonc`:
  - Drop `custom/reboot-pending` from `modules-right`.
  - Rewrite `custom/power` to `exec: power-pill power`,
    `interval: 5, signal: 10`. on-click: `standard-os-shutdown-guard
    $( [ "$(readlink /run/current-system)" = "$(readlink
    /run/booted-system)" ] && echo hibernate || echo reboot )` —
    branched the same way (single shell line; alternatively
    `power-pill click power` if cleaner).
  - Rewrite `custom/reboot` to `exec: power-pill reboot`, same
    interval/signal. on-click unchanged (`shutdown-guard reboot`) —
    it's only visible in normal mode.
  - Add `custom/hibernate` (new) — `exec: power-pill hibernate`,
    on-click `shutdown-guard hibernate`. Only visible in reboot-
    pending mode.
  - Delete `custom/reboot-pending` definition block.
- `waybar/style.css`: adds one new pin variant. New `@opt-yellow-pin`
  color token (`rgba(255, 230, 179, 0.70)`) + selector
  `.opt-pill.opt-pin-yellow / .opt-pill-child.opt-pin-yellow` mapping to
  it. Comment header's Pin enumeration updated. Other classes used
  (`opt-no`, `opt-middle`, `opt-yes`, `opt-pill`, `opt-pill-child`,
  `empty`) already exist.
- `waybar/scripts/waybar-self-test.sh`: no changes (still writes the
  same cache file — it stays a debugging aid even though
  `custom/reboot-pending` is gone).

## Verification

1. **Normal mode rest face.** With current-system = booted-system,
   the bar shows: moon-glyph parent (uncolored), sleep child (blue,
   on hover), reboot child (yellow, on hover). No standalone
   `custom/reboot-pending` pill anywhere on the bar.
2. **State flip via cache injection.** Force the state without an
   actual rebuild:
   ```
   printf '{"text":"!","class":["opt-pill","opt-pin-yellow"],"tooltip":"test"}\n' \
     > /tmp/waybar-cache/reboot-pending
   pkill -RTMIN+10 waybar
   ```
   Within ~2s, the parent face must swap to `󰜉` + `opt-pin-yellow`;
   on hover Slot 3 must now show the hibernate glyph `` (red),
   and the reboot child must be gone.
3. **Click in reboot-pending mode.** Confirmed by `DRY_RUN=1
   standard-os-shutdown-guard reboot` printing `would-exec: systemctl
   reboot` directly (no rofi) when `/run/standard-os/activated-commit
   == git rev-parse HEAD`. If both are stale, the guard's rofi
   should still surface — that's the intentionally-ambiguous case.
4. **State clears.** Restore normal mode by clearing the cache:
   ```
   printf '{"text":""}\n' > /tmp/waybar-cache/reboot-pending
   pkill -RTMIN+10 waybar
   ```
   The cluster returns to normal-mode faces within ~2s. In real
   use the `waybar-self-test` timer does this automatically once
   `current-system == booted-system`.

## Out of scope

- Renaming `custom/lock` to `custom/sleep` (functionally it's sleep but
  the glyph is a lock — historical mismatch, deferred to a separate
  cleanup commit).
- Per-state dismiss flow. Reboot-pending stays "ambient" — no
  user-controlled dismiss; the only way to clear it is to actually
  reboot. (Confirmed in brainstorming.)
- Animation on state flip. (Confirmed: silent.)
