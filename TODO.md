# TODO

The work map. Three sections, in flow order: **TODO** (active work, capped at
6 items), **NEXT** (ideas not yet started), **DONE** (history of what shipped
with a one-line hint about each implementation seam — useful when something
later regresses and you need to remember where the wires are).

Promotion is one-directional: an idea moves NEXT → TODO when work begins, and
TODO → DONE when it ships. **TODO cap = 6.** When TODO is full, nothing
promotes from NEXT until something completes. The cap keeps focus honest.

See `CLAUDE.md` → "TODO.md (the work map)" for the maintenance contract.

---

## TODO

- [ ] **opt-pushed adoption pass** — apply `opt-pushed` to `custom/shader-paper`,
      `custom/shader-newspaper`, `custom/night-dimmer`, and `custom/dictate`'s
      recording state. Visible bar improvement, zero new daemon work, low risk.
      Confidence-building win that confirms the new CSS reads as intended live.
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
