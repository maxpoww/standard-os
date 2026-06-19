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
- **System daemon** (RTMIN+18) — CPU / GPU / memory / temp. Polled at 2 s.
  (RTMIN+12 went to notif-daemon 2026-06-06; see ARCHITECTURE.md.)
- **Clipboard daemon** (RTMIN+15) — selection-aware text-operation options.
  `wl-paste --watch` for events.
- **Control panel row** — second waybar instance for control-panel-style depth.
  Destination for transient pills' "go away to" target after their 4 s expires.
- **`inactive` → `opt-dimmed` rename** — now safe; the workspace daemon is
  Nix-managed (via the hypr-context unification 2026-06-13). Single-pass
  CSS + emitter rename.
- **Per-window context surfacing** — focused-window class drives a silent
  swap of per-window options (e.g. text-app focused → format-text cluster
  appears in USER zone). Silent appearance per maintenance rule 4.
  Hypr-context-daemon already publishes `focused.class` in
  `/tmp/waybar-cache/hypr-context.json`; consumer is the missing piece.

---

## DONE

- **2026-06-19** — **widgets-canvas Wave 0: dashboard substrate + clock.**
  New surface class shipped: the canvas, Eww-rendered, full-screen
  translucent overlay opened on Super+RETURN and dismissed on Esc
  (persistent — not hold-to-peek, not toggle, decision reversed mid-
  flight after physical test). CROWN / HERO / FIELD zone layout drawn
  as placeholders; HERO holds a 96pt clock polling `date(1)` every
  second. Eww daemon runs as a systemd-user unit
  `standardos-canvas.service` bound to graphical-session.target.
  **Hint:** new module `modules/widgets-canvas.nix` mirrors the waybar.nix
  out-of-store-symlink pattern — edit `/etc/nixos/home/widgets/eww/*` and
  `systemctl --user restart standardos-canvas.service` to iterate without
  a rebuild.
  **Hint:** Hyprland binds at `hypr/modules/Binds.conf` use a `submap`
  pattern: default-submap `bind` on $mainMod+RETURN dispatches both
  `exec eww open dashboard` AND `submap canvas-open`; inside the
  canvas-open submap, `bind` on ESCAPE dispatches `exec eww close
  dashboard` AND `submap reset`. The daemon must be up before press;
  graphical-session binding handles that.
  **Hint:** spec at `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`.
  Wave 0 plan at `docs/superpowers/plans/2026-06-19-widgets-canvas-wave-0.md`.
  Waves 1–5 (catalog widgets, lock, greeter) are separate plans.
  **Hint:** palette tokens at `/etc/nixos/home/widgets/palette.css`
  mirror waybar/style.css §50-126 — future hyprlock + regreet work
  reads from the same file.
  **Hint:** home.nix at `/etc/nixos/home.nix` is OUTSIDE the
  `/etc/nixos/home` git worktree; its `services.standardosCanvas.enable
  = true;` line lives on disk but is not tracked. Existing repo
  pattern.

- **2026-06-17** — **rofi pill metrics: copy-verbatim from waybar.** Follow-up
  to the pill-styling commit (cd276fa). User: *"pills are huge and the
  corners are not the same round of the waybar ones."* Extracted exact
  values from `waybar/style.css:200-207` and copied verbatim to
  `rofi/options-base.rasi`:
  padding `6px 12px` → `3px 8px 3px 7px`, border-radius `18px` → `30px`,
  listview spacing `4px` → `2px` (matches waybar's `margin: 1px 0px`
  between-pill rhythm). Action rows inherit padding from `element`;
  border-radius bumped to 30 too. Headers stay at 11pt (no waybar
  analogue). Pills now read as compact fully-rounded chips identical to
  bar pills.

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

- **2026-06-17** — **notif-menu: anchor under cursor at click time + universal
  screen-edge clamp.** The notif-menu popup was landing 220px off-screen on
  the hi-DPI laptop panel because the pill-geom width registry undercounted
  the SYSTEM zone (icon-only pills had width=8, non-pill_write modules had
  no entry at all). Replaced the width-estimator anchor source with
  cursor-at-click on the universal entry point `rofi_anchor_at_cursor` —
  cursor IS on the trigger pill at the moment the click handler fires
  (notif-menu is exec'd from notif-click), so centering the popup on
  cursor.x places it consistently under the parent on any monitor /
  resolution / scale without any per-pill geometry. Belt-and-suspenders:
  every anchor path now passes through `_rofi_clamp_x_offset` which clamps
  to `[mon_x + margin, mon_x + mon_w - W - margin]` against the focused
  monitor's LOGICAL bounds — the popup can never overflow the screen
  regardless of how the anchor was computed.
  **Hint:** new functions in `scripts/lib/rofi-anchor.sh`:
  `_rofi_clamp_x_offset`, `_rofi_cursor_xy` (with `ROFI_CURSORPOS_FILE` test
  hook), `_rofi_scale_pct`, `_rofi_monitor_logical_xy`,
  `_rofi_monitor_containing` (resolves which monitor a logical x sits on —
  used by anchor_at so multi-monitor clamping picks the monitor where
  the click happened, not the focused-window monitor), `rofi_anchor_at
  <logical_x>`, `rofi_anchor_at_cursor`. `rofi_anchor_for` (zone-walker
  fallback) now also clamps. `rofi_launch` defaults to the cursor anchor.
  **Hint:** fixed regression from this morning's hi-DPI patch: only
  `monitor.width` is RAW-px (divide by scale), `monitor.x` is LOGICAL
  (pass through). Symptom was harmless on the single-monitor x=0 case but
  would have placed popups against the wrong screen on multi-monitor.
  Regression test: `[multi-monitor scale=2 right: mon.x logical 3200 ...]`.
  **Hint:** retired stale entries from `ROFI_ZONE_SYSTEM`
  (`waybar-self-test`, `power-resume`) — both removed from the bar this
  morning.
  **Hint:** `notif-menu::run_rofi` calls `rofi_anchor_at_cursor` instead
  of `rofi_anchor_for notif-bell`. Future click-triggered popups (apps
  launcher, restore-minimized, etc.) follow the same pattern; only
  keyboard-triggered popups need the `rofi_anchor_for` zone walker.

- **2026-06-17** — **rofi-anchor: divide by monitor scale (hi-DPI fix).**
  notif-menu rofi popup was landing too far right on the hi-DPI eDP-1 panel
  because hypr-context.json publishes RAW pixel dimensions while rofi
  positions in LOGICAL pixels. `_rofi_focused_monitor` now parses
  `"scale":N.NN` from the monitor blob as integer percent (no fork to bc),
  divides x and w by it, returns logical-pixel anchor inputs. Test grid
  extended: scale 1.0 / 1.5 / 2.0 all produce the same `x-offset:1346px`
  for the bell-anchored notif-menu (12/12 pass).
  **Hint:** scale parser uses BASH_REMATCH on `"scale":[0-9]+(\.[0-9]+)?`
  and pads/truncates the decimal to two digits → `sx100` integer percent.
  No `bc`, no `awk` — bash builtin arithmetic only (hot path on every
  rofi popup).
  **Hint:** previous bellwether commit (f692e13) tested on scale=1 (no
  divide), regressed on scale=2. Now all three scales covered in
  `tests/rofi-anchor-test.sh`.

- **2026-06-17** — **error pills erased from OPTIONS — failures are silent.**
  Three red error pills removed entirely from the bar: `custom/power-resume`
  ("Resume: bt" and friends), `custom/waybar-self-test` ("⚠ N"), and the
  opt-no error state of `custom/update-pending`. The in-progress update pill
  (opt-pin-orange + opt-breathe) and the "System updated" success notify-send
  are preserved. Failures go to the existing logs only — no notify-send, no
  pill. User decision: "the error on options are not atractive, erase them
  complitly. silent — log only."
  **Hint:** `custom/waybar-self-test` and `custom/power-resume` deleted from
  `config.jsonc` (both the modules-right list and their definitions);
  matching CSS rules pulled from `style.css`. `custom/update-pending` kept
  for the working pill.
  **Hint:** `standard-os-update::pill_state_error` now writes an empty pill
  (collapses the module) — the function signature is preserved so call sites
  don't change, but no opt-no class is ever emitted. All four error-state
  `notify-send` calls in the script were removed; the success one in
  `phase_signal` is untouched.
  **Hint:** `standard-os-resume-user.nix` and `/etc/nixos/modules/power-sleep.nix`
  no longer write `/tmp/waybar-cache/power-resume`; both still probe and
  remediate, both log failures to journalctl. `standard-os-resume-crashed`
  service + its `onFailure` reference deleted.
  **Hint:** `waybar-self-test.sh` no longer writes the `waybar-self-test`
  pill cache. Exit-code contract (0 healthy / 1 broken) is preserved so the
  update pipeline's pre-flight and post-switch verify phases still work.
  `emit_reboot_pending` is unchanged (separate cache feeding the power-pill).
  **Hint:** click handler `standard-os-update-pill-ack` left as-is — the
  `opt-no` branch is now unreachable but harmless; the working-state no-op
  is still wired through.

- **2026-06-16** — **rofi unified with OPTIONS — bellwether ships on notif-menu.**
  Three new shared artefacts: pill-geom registry in pill.sh (per-pill
  files at /tmp/waybar-cache/pill-geom/), rofi-anchor.sh library
  (rofi_anchor_for, rofi_theme_for_mode, rofi_launch), and
  options-{base,light,dark}.rasi mirroring the waybar @opt-* palette.
  notif-menu's inline `-no-config -theme-str` deleted; the bell popup
  now opens under the bell pill, with light/dark following glass-mode.
  Five remaining rofi surfaces (apps launcher, window switcher,
  restore-minimized, reboot-prompt, notif-rofi legacy) follow as
  separate streams.
  **Hint:** spec at `docs/superpowers/specs/2026-06-16-waybar-rofi-integration-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-16-waybar-rofi-integration.md`.
  **Hint:** pill-geom is written by pill.sh::pill_write on every emit;
  one JSON file per pill avoids jq merge in the hot loop.
  **Hint:** rofi-anchor.sh's zone layout list is currently SYSTEM-only
  (encodes notif-widepill → notif-dnd → notif-bell). Other zones will
  be added as their pills need rofi popups.
  **Hint:** action-row marker is `fmt_l1_action` in
  notif-menu-format.sh: emits `<b>▸ LABEL</b>` (Pango-bold + chevron);
  rofi rendered with `-markup-rows`.

- **2026-06-16** — **View focuses Chrome PWAs correctly via desktop-entry hint.**
  Chrome PWAs (WhatsApp Web, YouTube Music, etc.) declare a distinct
  Hyprland window class per app (`chrome-<hash>-Default`). The same
  string appears in the notification's freedesktop `desktop-entry`
  hint. Previously View used the notif's `app_name` ("WhatsApp Web")
  as the class needle, which substring-matched the wrong Chromium
  window on another workspace. Now: notif-os-daemon extracts the
  `desktop-entry` hint at Notify time, stores it in NotifRecord +
  ListNotifications JSON + the JSONL journal; notif-menu uses it as
  the hyprctl class needle in do_view, falling back to `app_name`
  ONLY when the hint is absent (intentional — falling back when the
  hint is set but unmatched would defeat the PWA disambiguation).
  **Hint:** spec at `docs/superpowers/specs/2026-06-16-notif-desktop-entry-pwa-focus-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-16-notif-desktop-entry-pwa-focus.md`.
  **Hint:** simulate from CLI with
  `notify-send --hint=string:desktop-entry:chrome-XXX-Default "title" "body"`.

- **2026-06-16** — **bell ↔ DND pill swap + Dismiss(X) child.**
  Parent identity = DND state. DND off → bell is parent (`opt-pill`,
  `opt-yes` if unread), DND is hover-revealed child. DND on → DND is parent
  (`opt-pill` + `opt-breathe` always + `opt-yes` compose if unread),
  bell becomes child-styled (`opt-pill-child` + "Resume notifications"
  tooltip). The swap is a side effect of the DND toggle — no separate
  state file.
  Bell-click while DND is on routes to the DND toggle via a runner-level
  action rewrite (`$action=bell → dnd`), not a new decision branch. The
  pure decision function stays filesystem-free.
  New third pill: Dismiss(X). Joined `group/notif` between DND and bell.
  Visible when bell is parent AND unread > 0. Click fires
  `mako_dismiss_all`. Collapses to `["empty"]` via the no-op-options rule
  whenever DND is on OR unread == 0.
  **Hint:** spec at `docs/superpowers/specs/2026-06-16-pill-swap-and-dismiss-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-16-pill-swap-and-dismiss.md`.
  **Hint:** waybar's `group/notif` makes `modules[0]` (bell) the always-
  visible anchor — the bell cannot literally hide when DND is on. Visual
  asymmetry is intentional: bell stays anchored with child styling
  (smaller, child-surface color), DND becomes a forced-visible breathing
  pill in the drawer position. Functional swap (state, click target,
  color) works; physical-anchor identity stays with bell per waybar's
  architecture.
  **Hint:** the daemon must be restarted (not just SIGUSR1'd) to pick
  up new render-function code — `nixos-rebuild switch` updates the
  store binary but doesn't restart the systemd-user notif-daemon.service.
  Use `systemctl --user restart notif-daemon` after switch when
  iterating on the daemon source.

- **2026-06-16** — **profile machinery purged → single DND toggle pill.**
  Replaced six profiles (off/dnd/sleep/work/gaming/media), the
  notif-rofi-profiles picker, lib/notif-profile-format.sh, lib/notif-schedule.sh,
  the profiles JSON materialization, and ~150 lines of profile-resolution
  logic in the bash daemon with a single state file
  ~/.local/share/standard-os/notif-dnd (presence ↔ ON).
  Click `notif-click dnd` (bell-child pill) toggles + SIGUSR1s the daemon.
  When ON: wide-pill suppressed, sound suppressed, journal + pin keep working.
  Visible from the moment of toggle via `opt-breathe` on the DND child pill.
  Single left-click commits everywhere (rofi `-me-accept-entry MousePrimary`).
  **Hint:** spec at `docs/superpowers/specs/2026-06-15-profile-purge-dnd-toggle-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-15-profile-purge-dnd-toggle.md`.
  **Hint:** notif-rofi-profiles is gone from PATH; any hyprland keybinding
  that called it should now call `notif-click dnd` directly.
  **Hint:** the daemon's per-arrival `kind` (transient_kind_for_state) was
  also fixed mid-task — it was returning "beat" for urg=2 which rendered
  the silenced-ack face instead of the pulsing critical wide-pill. Now
  returns "critical" / "normal" which match `render_bell_for_state`'s
  case statement. Critical urgency notifs now correctly pulse-orange.

- **2026-06-15** — **wide-pill click now runs View (was: default-action + dismiss).**
  The transient bell pill (the wide `App · Title` face that appears for
  5 s after a notif arrives) used to fire `mako_invoke <id> default` +
  `mako_dismiss`. For apps that don't react to `ActionInvoked` (notify-send
  CLI, Claude Code, etc.) that was a silent dismiss with no visible effect.
  Switched to the same View semantics notif-menu's L2 menu uses:
   1. Invoke default action if declared.
   2. `hypr_focus_by_class` on the captured `source_window`.
   3. Dismiss when either fired.
   4. Honest fallback notify-send when neither did.
  Implementation: new `view-latest` subcommand on notif-menu (`notif-menu
  view-latest`) — headless, no rofi UI. Queries the daemon for the highest
  live id, hydrates the `L2_*` globals `do_view` reads, dispatches.
  `notif-click invoke-and-dismiss` now just `exec notif-menu view-latest`.
  **Hint:** the decision string in notif_click_decide is still
  `"invoke-and-dismiss"` to avoid churning `tests/notif-click-test.sh`'s
  oracle values. Rename to `"view-latest"` in a future sweep.
  **Hint:** silent no-op when the store is empty — the wide-pill is
  still showing but the notif may have been closed by its app between
  arrival and click (race window ≤ 5 s).

- **2026-06-15** — **notif-menu: bell-click open 3.5s → ~180ms + single-click accept.**
  Two perf bugs in `populate_l1`, plus a rofi mouse-binding tweak. Both
  surfaced once the bell pointed at notif-menu instead of notif-rofi.
  **Speed** (timing on 4 unread + 127 history):
   - Per-line `jq <<<"$line"` fork in the History loop: 127 jq forks × ~20 ms
     on NixOS = ~2.5 s by itself. Replaced with one `jq -nR | fromjson?`
     stream pass over the whole journal — same pattern lib/notif-journal.sh
     uses correctly.
   - Per-row `grep -qF` against live_map to skip live ids: 127 grep forks
     × ~10 ms = ~1.2 s. Replaced with a bash assoc-array set built once
     from live_map; the lookup is now a pure builtin string check.
   Result: 3493 ms → ~180 ms (≈ 20× faster). Measured via populate_l1
   in isolation across three runs.
  **Single-click**: rofi 2.0.0's default `-me-accept-entry` requires
  double-click (first click selects, second accepts). Added
  `-me-select-entry MousePrimary -me-accept-entry MousePrimary` to
  run_rofi so a single click both selects AND accepts. Both flags
  required — accept alone fires only when a row is already hovered.
  **Hint:** the same per-line-jq + per-row-grep pattern lives in
  `scripts/notif-rofi` build_rows and handle_pick. notif-rofi is no
  longer the bell target so the perf doesn't surface, but the dead
  binary will be dropped in the mako-demolition session anyway.

- **2026-06-15** — **bell click switched from notif-rofi → notif-menu.**
  The whole point of the Rust daemon was capturing `source_window` so the
  View action could focus where a notif came from. notif-menu has had View
  + the L1/L2 two-level UX since the 2026-06-14 do_view compose fix, but
  the bell still launched the older notif-rofi. Swapped the `open-rofi`
  decision in notif-click to `exec notif-menu`. Click flow:
   1. Bell click → L1 (Actions block / Unread / History).
   2. Click a Unread row → L2: View / [app actions] / Dismiss / Back.
   3. Click View → hyprctl focuses the captured source_window.
   4. History rows get: View / Copy summary / Copy body / Remove / Back.
  All clicks are single-click (rofi `-dmenu` default). notif-rofi binary
  stays in `home.packages` for one more session — will be dropped in the
  mako-demolition pass along with the other dead surface (mako package,
  mako/config xdg.configFile, ARCHITECTURE.md "notif-rofi" docs).

- **2026-06-15** — **notif-rofi: fix latent `fromjson?` bug (clicks were no-op).**
  Three jq pipelines in notif-rofi used `fromjson? // empty | select(.id == $id)`
  against bare jq stdin. Bare jq already parses each input line as JSON,
  so `fromjson` (which expects a JSON-encoded STRING) raised a type error
  on every line; the `?` swallowed it; `// empty` made every entry vanish.
  Net: per-id journal lookups silently returned nothing.
  Symptoms (latent since 2026-06-10 commit 771e2e25, only surfaced now
  because the mako cutover removed the masking error):
   1. Unread rows used `date -Iseconds` fallback timestamps (current time)
      instead of the actual arrival ts because the journal lookup failed
      and we fell through to the live-fetch branch.
   2. History section was empty — every line dropped by the same broken
      jq when iterating the journal for "non-live" entries.
   3. **Click did nothing** — handle_pick couldn't resolve picked rows
      back to live ids, so neither InvokeAction nor CloseNotification fired.
  Fix: drop `fromjson? // empty |` from all three sites. `notif-menu`
  (the modern replacement) already gets this right with plain
  `select(.id == $id)`.
  **Hint:** `lib/notif-journal.sh` uses `fromjson?` CORRECTLY because
  it invokes `jq -nR` (null-input, raw-input), making `inputs` produce
  raw strings that DO need `fromjson` to parse. The June 10 commit
  copy-pasted the pattern from journal.sh into notif-rofi without
  carrying the `-nR` flag — and `?` made the type error silent.

- **2026-06-15** — **notif-os-daemon cutover: click stack migration (followup).**
  The initial cutover migrated `notif-daemon` (the spine), but the click-
  handler stack still hardcoded the dead mako interface. Symptom: bell
  click opened a rofi list with NO "Unread" section — all freshly-arrived
  notifications got bucketed into "History (N)" at the top, easy to miss
  because there was no Unread header above them and they looked like old
  entries. Same root cause hit `notif-click action N` (the per-action pill
  click): five busctl-to-`fr.emersion.Mako` blocks + makoctl invoke/dismiss
  all silently no-op'd.
  Migrated both `notif-rofi` and `notif-click` to source `lib/notif-os.sh`
  and route through `org.standardos.NotifOS` via the existing adapter
  (`mako_list_live`, `mako_invoke`, `mako_dismiss`, `mako_dismiss_all`).
  `notif-click` gained a `_latest_id` helper to centralize the "max id in
  store" pattern previously inlined in four places.
  **Hint:** the adapter helpers kept the `mako_` prefix on purpose (per
  notif-os.sh's own header) to avoid touching every call site this pass.
  Rename to `notif_*` in the same future sweep that touches
  `query_mako_state` in the daemon.
  **Hint:** `notif-click-test.sh` and `notif-rofi-test.sh` both exercise
  only the pure libraries (decision function / row formatter) — neither
  touches busctl. Migration needed no test changes.

- **2026-06-15** — **notif-os-daemon: live cutover, mako inert.**
  notif-os-daemon (Rust) is now the live `org.freedesktop.Notifications`
  owner. New `systemd.user.services.notif-os-daemon` unit starts it at
  graphical-session; `notif-daemon.service` (bash) now declares
  `After`/`Requires` on it. `query_mako_state` in the bash daemon was
  rewritten to call `org.standardos.NotifOS.ListNotifications` and parse
  the flat shape `[{id, app, summary, body, urgency, actions:[[k,l],...]}]`
  — no more mako `.data[0][]` / `.id.data` wrap. `dbus-monitor` no longer
  filters on `fr.emersion.mako`. Journal writes deduplicated: the Rust
  daemon writes on Notify, so the bash `journal_append`+`journal_prune`+
  `src_win` block in `on_dbus_event` was removed; `journal_mark_dismissed`
  stays in bash because the Rust daemon doesn't currently write
  `dismissed_at`. The OTP-copied dismiss path was switched from
  `makoctl dismiss -n` to a direct `busctl ... CloseNotification` call.
  Live-verified: normal + critical + actions all render the correct pill
  state; InvokeAction returns `b true` and removes the notif. mako stays
  installed but inert (Rust grabs the bus name first).
  **Hint:** `notif-os.sh` adapter already routed every notif-menu call to
  `org.standardos.NotifOS` — only the bash daemon's `query_mako_state`
  was the holdout. That made the cutover a single file + one nix block.
  **Hint:** the `query_mako_state` function name was kept (per the same
  precedent in `notif-os.sh`'s `mako_*` helpers) to avoid touching every
  call site this session. Rename in a future sweep.
  **Hint:** mako removal — drop from `home.packages`, delete the
  `xdg.configFile."mako/config"` block (lines ~206–260 of
  `notif-center.nix`), and rewrite the `silencedApps` mkOption discovery
  example — is the next session's work. The package is currently dead
  weight in PATH; the writeable mako config never gets read because mako
  doesn't run.

- **2026-06-15** — **notif-menu: do_view composes step 1 + step 3.**
  Original investigation: after notif-os-daemon shipped, View on a LIVE
  notif with an app-declared `default` action appeared to no-op (notif
  vanished, no visible focus change) while View on the same notif moved
  to history worked correctly. Root cause: the old `do_view` early-
  returned after firing the app's default action (`mako_invoke ... default`),
  trusting the app to focus its own window via the `ActionInvoked`
  signal. Many apps (notify-send CLI, Claude Code, etc.) don't react to
  ActionInvoked at all, so the notif was dismissed silently with no
  focus change. New flow: step 1 fires the action if declared, step 3
  ALWAYS runs (`hypr_focus_by_class`), and dismissal is gated on
  `action_fired OR focused`. Step 4 fallback only fires when neither
  produced an effect.
  Also ships a gated `_dbg` logger triggered by `NOTIF_MENU_DEBUG=1`
  that writes to `/tmp/notif-menu-debug.log` — paid for itself
  diagnosing this bug, zero cost when unset, kept as permanent infra.
  Tests grew from 18 to 21 (t3 updated to assert the compose, t5b added
  for the "step 1 fired, step 3 missed" case).
  **Hint:** the compose is harmless when the app DOES focus itself via
  ActionInvoked — step 3's focuswindow on the same window is a visual
  no-op. Slack/Firefox style apps that switch to the right channel/tab
  on `default` get both behaviors: their app-specific action fires AND
  hypr_focus_by_class focuses their window.
  **Hint:** the original report described history-View as no-op and
  live-View as working. Diagnostic logging revealed the opposite — live-
  View was firing only step 1 (silently dismissing) while history-View
  was firing step 3 (visibly focusing). The fix unified them.

- **2026-06-15** — **notif-os-daemon (Rust): Standard-OS native notification daemon.**
  Replaces mako as the `org.freedesktop.Notifications` D-Bus owner. Pure Rust
  binary built with zbus 5 + tokio; no Python runtime, no library quirks.
  Implements the freedesktop spec (Notify, CloseNotification, GetCapabilities,
  GetServerInformation, NotificationClosed, ActionInvoked) plus our
  `org.standardos.NotifOS` extension (ListNotifications returning full JSON,
  InvokeAction working for ANY id, Count). Every Notify captures the active
  Hyprland window address — notif-menu's View action focuses the exact source
  window for interactively-fired notify-send. Same on-disk JSONL journal as
  notif-journal.sh, so notif-menu's populate_l1 reads the new daemon's writes
  without any adapter change. Live-verified end-to-end: notify-send → journal
  entry with source_window → notif-menu View focuses the kitty.
  **Hint:** the daemon owns BOTH bus names — org.freedesktop.Notifications
  (so apps' notify-send goes through it) AND org.standardos.NotifOS (so
  notif-menu can call our richer API). Both registered in the connection
  builder's serve_at chain in src/main.rs.
  **Hint:** notif-menu's notif-os.sh adapter is unchanged from the Python
  POC iteration — same function names, same busctl call shapes, same JSON
  parsing. The daemon's interface contract was preserved on purpose.
  **Hint:** sender_pid is captured as 0 in v0 (the Notify method body doesn't
  yet plumb the D-Bus MessageHeader's sender field through). source_window
  is the load-bearing field; sender_pid is a future iteration.
  **Hint:** park mechanism is `tokio::select!` on SIGINT + SIGTERM, not
  `pending::<()>().await`. systemd-user sends SIGTERM on `systemctl --user
  stop`; SIGINT-only would leave the daemon ignoring systemd shutdown.
  **Hint:** to clean-restart during dev, BOTH the systemd-user `notif-daemon`
  unit AND the transient `dbus-:1.2-org.freedesktop.Notifications@N.service`
  must be stopped, otherwise mako auto-reactivates via D-Bus session
  activation the moment our daemon exits. The transient unit's number (`N`)
  shifts each session; find it with `systemctl --user list-units 'dbus-*Notifications*'`.
  **Hint:** ts format uses `%:z` (colon-tz) to match bash `date -Iseconds`;
  `%z` would give `-0300` and visually diverge from the bash-written entries.
  **Hint:** `invoke_action` removes from the store BEFORE emitting
  ActionInvoked + NotificationClosed, so a concurrent CloseNotification
  can't race it into emitting NotificationClosed twice for the same id.
  `close_notification` already used the same pattern.

- **2026-06-14** — **notif-menu: View action + tight L2 menu.**
  Replaced the v1 Copy/Snooze L2 with `View / Dismiss / Back`. `View`
  takes the user to the source of the notification: invokes mako's
  default action when the app declared one (Firefox focuses the tab,
  Telegram focuses the chat, Slack focuses the channel), falls back to
  `hyprctl dispatch focuswindow address:<addr>` when there's no default,
  and surfaces an honest `notify-send` fallback when nothing matches.
  New lib `scripts/lib/notif-hypr.sh` encapsulates every `hyprctl`
  call so tests can mock it. `notif-mako.sh` gains
  `mako_has_default_action` (anchored-grep on `mako_list_actions`).
  Reply ruled out (universal `wtype`-into-focused-window approach was
  too fragile). Mute deferred to a follow-up. Vanished-fallback and
  true-history L2 menus are unchanged (Copy / Remove / Back).
  **Hint:** The `default` action key is HIDDEN from the L2 row list
  when View is shown — View invokes it. Apps that declared
  non-default actions (e.g. `archive\tArchive`) still surface those
  rows below View.
  **Hint:** `do_view`'s step 2 (recursion guard) short-circuits when
  `app == "notif-menu"`. The step 4 fallback fires notify-send with
  `-a notif-menu` so picking View on a fallback notif hits step 2
  and just dismisses — no cascading loop.
  **Hint:** Hyprland class matching is case-insensitive substring
  (lowercase needle, lowercase haystack class, `contains`). Covers
  Firefox → firefox / firefox-developer-edition. Misses
  "Telegram Desktop" → org.telegram.desktop — but Telegram declares
  a default action so step 1 catches it. Per-app override map can
  be added later if real-world misses accumulate.
  **Hint:** `focuswindow address:<addr>` follows the target's
  workspace automatically (per Hyprland docs). Cross-workspace
  navigation is intentional.
  **Hint:** Cold-launching the app when no window matches is OUT of
  scope for v2. If a notif arrived from an app, the app was running
  at notif time. If the app exited between the notif and the user's
  View pick, step 4's fallback honestly says nothing's there.

- **2026-06-14** — **notif-menu: rofi selector with per-notif action surfacing.**
  New alternative to `notif-rofi` shipped as `/etc/nixos/home/scripts/notif-menu`.
  Two-level rofi flow: L1 lists Actions block + Unread + History sections; picking
  a notif opens L2 with app-declared actions (default hoisted), Copy summary,
  Copy body (suppressed when empty), Snooze 10m/1h (via `systemd-run --user
  --on-active=… --collect notify-send`), Dismiss, ← Back. History L2: Copy +
  Remove-from-history + Back. Stale-id (notif vanished between L1 and L2)
  falls back to history actions with a no-op header. New libs:
  `scripts/lib/notif-mako.sh` (busctl/makoctl adapter, handles both mako 1.10's
  object actions payload and legacy array form), `scripts/lib/notif-menu-format.sh`
  (pure plain-text formatters — no NUL/icon metadata, simpler than the old
  notif-rofi-format). `notif-journal.sh` gained `journal_remove` (id+ts keyed).
  Bar untouched: `custom/notif-bell` keeps calling the old `notif-rofi`; the
  new menu is launched manually for now.
  **Hint:** rofi pick→metadata uses `-format i` (index) plus parallel bash
  associative arrays keyed by row index (`kind_at`, `id_at`, `ts_at`, etc.)
  populated during `populate_l1` / `populate_l2_*`. Avoids the text-parse-back
  fragility the old `notif-rofi` paid for in `handle_pick`.
  **Hint:** `mako_list_actions` defensively type-switches on `actions.data`
  (object vs array) to handle mako 1.10's `a{ss}` rendering quirk that was
  documented in TODO.md line 826.
  **Hint:** `Back` is implemented as `exec "$(readlink -f "$0")"` — full
  re-launch is the cheapest correct re-render and resets all index arrays
  for free. Symlink-safe via `readlink -f`.
  **Hint:** Tests mock `rofi` / `mako_*` / `wl-copy` / `systemd-run` via
  bash function overrides. No live daemons required to run any of the four
  test scripts.
  **Hint:** Row staging uses `populate_l1 > "$NOTIF_MENU_TMP/l1"` redirection
  (NOT `$()` capture) so the parallel index arrays mutated inside populate_*
  persist into the parent shell where the dispatchers read them. Same pattern
  for L2 staging.
  **Hint:** `main()` registers `trap RETURN` unconditionally but only registers
  `trap EXIT` when `${BASH_SOURCE[0]} == $0` (direct invocation). This stops
  main from clobbering test sandboxes when called as a sourced function.

- **Empty-ws caches: TASK window pill + ws-current decoupled** — 2026-06-14
  Switching to an empty workspace painted the TASK center pill with the
  CSV of occupied ws IDs (e.g. "3,9" — the *ws-list-in-use*, exactly
  what the user reported) and the ws-current pill with literal `"0"`.
  Root cause was bash `read` behavior, not jq: `hypr-context-daemon.sh`
  packed five values into a tab-separated string and parsed back with
  `IFS=$'\t' read -r class title addr ws_current ws_list_csv`, but
  bash strips leading IFS-whitespace runs even when IFS is set
  explicitly — and tab is in the whitespace set. On an empty ws the
  first three fields (`$active.class`/`title`/`address`) all fall
  through to "" because `j/activewindow` returns `{}`, producing a
  `\t\t\t9\t3,9` payload that bash parsed as
  `class=9, title=3,9, addr=, ws_current=, ws_list_csv=`. The
  `${ws_current:-0}` fallback then surfaced the "0" symptom; the title
  shift surfaced the "shows ws in use" symptom. Switched the
  separator to Unit Separator `\x1F` (non-whitespace in bash IFS),
  emitted by jq via `[...] | join("")` instead of `@tsv`.
  Hint: any future packed-fields parse in a daemon must use a
  non-whitespace delimiter (\x1f is the standard pick) when ANY field
  can be empty. The `@tsv` form is fine ONLY when every field is
  guaranteed non-empty.

- **Bg-painter trigger: float-tolerant + fullscreen-aware + actually fires** — 2026-06-14
  Two flaws in the 2026-06-13 unification surfaced together. (1) The
  4-state rule missed real cases: a `w[tv1]` workspace with a floating
  window on top focused the float, sampling its top edge mismatched the
  tile; `f[1]` workspaces with multiple siblings beneath the fullscreen
  window were excluded by `tiled_count==1` / `floating_count==0`.
  (2) The `gaps_out == 0` guard read the GLOBAL config via
  `hyprctl getoption` (always `"2 6 6 6"`), NOT the per-workspace
  effective value the `w[tv1]`/`f[1]` selectors apply at render-time —
  so the guard was always false in practice and the painter had not
  fired at all since 2026-06-13 (the post-reboot "verification" only
  checked daemon health, not paint behavior). Replaced with a
  `bg_window` field computed by `hypr-context-daemon` (the workspace's
  fullscreen window if any, else the lone non-floating non-pseudo tile,
  else null) and a single topology trigger: fire iff `bg_window != null`,
  sample `bg_window`'s top — never the focused window. Matches legacy
  `hypr-edge-bg`'s inference rule ("a single tiled non-floating non-pseudo
  window owns the screen → no visible gaps regardless of Hyprland's
  gaps_in/gaps_out setting") without re-introducing its dive/poll
  scaffold.
  Hint: snapshot schema gained `bg_window: {address,x,y,w,h} | null`;
  bg-daemon's `evaluate_and_apply` dropped from 6 state checks to 1.
  CLAUDE.md hazard added: never re-introduce a `gaps_out`
  check thinking it reflects per-workspace effective gaps.

- **Hypr-context unification** — 2026-06-13
  Replaced the two-daemon Hyprland-state duplication (workspace-daemon +
  hypr-activities) with one publisher (`hypr-context-daemon`, socket2
  event-driven, bundled into the `waybar-scripts` derivation) feeding
  both the waybar pill caches and a `/tmp/waybar-cache/hypr-context.json`
  snapshot for inotify consumers. Folded the bg system into a single
  `hypr-bg-daemon` with a 4-state-check rule (paint solid color when
  workspace has zero gaps and a single tiled non-floating non-pseudo
  window; otherwise restore the waypaper image). Folded glass-text-daemon
  into hypr-bg-daemon — it now owns `/tmp/glass-mode` because it is the
  only party that knows when the visible color changes. Dropped: hypr-dive,
  the 4-mode color matrix, the dark_theme gsettings pipeline, and the
  glib runtime dep. Absorbed the previously-NEXT "workspace-daemon
  migration to Nix" and "composite-module pattern" items.
  Hint: spec at `docs/superpowers/specs/2026-06-13-hypr-context-unification-design.md`,
  plan at `docs/superpowers/plans/2026-06-13-hypr-context-unification.md`.
  **Verified 2026-06-14 post-reboot:** all three new daemons (`waybar`,
  `waybar-hypr-context-daemon`, `waybar-hypr-bg-daemon`) active; no legacy
  units (`hypr-dive` / `hypr-edge-bg` / `hypr-activities` / `glass-text` /
  `workspace-daemon`) present; `/tmp/waybar-cache/hypr-context.json` valid
  (`monitor_focused = "eDP-1"`); `/tmp/glass-mode = dark`.

- **Rebuild-pending orphan cleanup** — 2026-06-13
  Today's retirement (commits `3f59b70` + `05ea9a9` + `6ed260b`) left four
  loose threads after the UPDATE pipeline absorbed the user-facing rebuild
  state. Cleared in one pass:
  (1) Orphan cache file `/tmp/waybar-cache/rebuild-pending` (stale from
  13:50, no module read it anymore).
  (2) Dead CSS selector `window#waybar #custom-rebuild-pending.light` in
  `waybar/style.css`.
  (3) Stale runtime-dep comments in `modules/waybar.nix:61-62` (`git` is
  now only for UPDATE scheduler L1; `rofi` is now only for reboot-prompt).
  (4) `waybar/scripts/standard-os-shutdown-guard.sh` collapsed to a thin
  dispatcher — the `check_rebuild_pending` function and rofi modal are
  gone. Sleep/hibernate/poweroff now pass through immediately, same as
  reboot did after `05ea9a9`. UPDATE pipeline handles rebuilds in the
  background; no user-facing gate is needed before a power transition.
  **Hint:** the script's behavior contract is unchanged from a caller's
  POV — `standard-os-shutdown-guard <action>` still maps to `systemctl
  <action>`. DRY_RUN=1 preserved for tests. Callers untouched
  (`power-pill.sh`, `config.jsonc` x3, `standard-os-reboot-prompt`).

- **Rebuild-pending is eliminated as a user-facing concept** — 2026-06-13
  Two changes combine to make "pending" the briefest possible window:
  (1) The UPDATE scheduler's three idle gates (fullscreen, input-idle,
  DND) are gone for L1 source-ahead detection. The scheduler now just
  checks detection + lock-file and fires the pipeline. Pkexec is
  passwordless via `modules/standard-os-update-polkit.nix`, so the
  whole pipeline runs silently in the background.
  (2) A new post-commit git hook at `/etc/nixos/home/.git/hooks/post-commit`
  fires the scheduler the moment any commit lands at HEAD. The
  scheduler's lock-file check coalesces rapid commits during an
  in-progress build — the next eligible tick (hook or 5-min timer)
  picks up whatever HEAD became.
  Surfaces the user sees: only the passive updating-pill while the
  pipeline runs, then the power-pill's reboot face once activation
  succeeds. Click the reboot face → boots into the new gen (the
  guard rofi for reboot is gone as of this morning's earlier commit).
  Failure modes preserved: the pipeline already had dry-build → switch
  → verify-and-rollback, so a broken commit reverts itself before it
  can wedge the system.
  **Hint:** if the hook ever needs editing, change `postCommitHook` in
  `modules/standard-os-update-scheduler.nix` — the activation
  `install`-copies it from `/nix/store` into `.git/hooks/post-commit`
  on every nixos-rebuild. The 5-min timer remains as the safety-net
  trigger; `gate_*` functions in the scheduler script are deleted.
  The race window (commit B lands while pipeline-for-A is running) is
  closed by the next 5-min tick; if that's too slow in practice, a
  follow-up could have the pipeline re-detect at end-of-run and
  self-fire.

- **Reboot click bypasses the rebuild-pending rofi** — 2026-06-13
  The power-parent spec's "direct reboot, no prompt" claim
  (`2026-06-13-power-parent-reboot-pending-design.md` line 70-76) assumed
  reboot-pending and rebuild-pending only ever co-occurred at the moment of
  reboot — i.e., after a rebuild, HEAD == activated-commit so
  `check_rebuild_pending` returned false and the guard exec'd `systemctl
  reboot` directly. That assumption breaks the second the user makes a new
  commit AFTER the rebuild (e.g., the power-pill theme fix earlier today):
  rebuild-pending is now true again, the guard's existing logic fires the
  rofi with "Rebuild + reboot / Reboot anyway / Cancel," and the power-pill
  — which was already visibly advertising reboot urgency — feels like it's
  second-guessing the click. New policy: when `action=reboot`, the guard
  never prompts. Click intent is authoritative; rebuild handling belongs to
  the background UPDATE pipeline (per `2026-06-13-update-pill-design.md`),
  not the click path. Uncompiled commits past activated-commit ride the
  next rebuild cycle. Other actions (sleep / hibernate / poweroff) keep the
  existing guard rofi — they're not the path the power-pill visually
  commits to.
  **Hint:** the bypass lives at the top of
  `waybar/scripts/standard-os-shutdown-guard.sh`'s decision block, before
  `check_rebuild_pending` is consulted. Spec
  `2026-06-13-power-parent-reboot-pending-design.md` line 76 ("we only get
  a prompt in the legitimately-ambiguous case") is now stale — the dual-
  state case also bypasses.

- **Fix: power-pill emits the dark|light theme token** — 2026-06-13
  Follow-up to the power-parent ship earlier today. The new `power-pill.sh`
  helper went straight to raw `printf '{"text":"…","class":["opt-pill","…"]}'`
  for its six face branches instead of going through `lib/pill.sh::pill_emit`.
  Every other emitter in the corpus uses `pill_emit`, which is the ONLY place
  the `dark|light` glass-mode token gets injected into the class array. So the
  three power-cluster modules (`custom/power`, `custom/reboot`, `custom/hibernate`)
  rendered with class arrays that never carried a theme token, the canonical
  `window#waybar .opt-pill.light` / `.opt-pill-child.light` rules in style.css
  never matched, and the label color stayed at the dark-mode default regardless
  of wallpaper. Rule violated: every text-bearing pill MUST emit `dark|light`
  as a class (see `lib/pill.sh` header + `Known hazards`). Fix: source
  `lib/pill.sh`, cache `theme="$(pill_theme)"` once per invocation, replace
  each `printf` face with `pill_emit "$glyph" "$(pill_class opt-pill "$theme"
  <state>)" "<tooltip>"`. Empty branches unchanged (`emit_empty` — text=""
  hides the module; theme irrelevant). No CSS change needed; the adaptive
  rules already cover these pills once the class is present.
  **Hint:** the `pill_emit` theme-substitution loop (`case "$c" in dark|light)
  c="$theme"`) means future face additions just need to pass the cached
  `$theme` through `pill_class`. Verified: installed wrapper emits
  `["opt-pill","dark",…]` with `glass-mode=dark` and `["opt-pill","light",…]`
  with `glass-mode=light`. Nix install rewrites the `. "$SELF_DIR/lib/pill.sh"`
  line to the absolute store path; same mechanism as `pill` / `pill-child`.

- **Power parent absorbs reboot-pending state** — 2026-06-13
  Retired the standalone `custom/reboot-pending` pill. The existing power
  group's parent now swaps face when `current-system != booted-system`:
  normal mode shows the FA power glyph + `opt-hover-red` and clicks
  hibernate; reboot-pending mode shows the reboot glyph + `opt-pin-yellow`
  (new pin variant — saturated yellow, same hue family as @opt-yellow /
  @opt-yellow-state, 0.70 alpha to match the other pins;
  opt-pin-orange read too peach-toned for the "reboot recommended" signal)
  and clicks reboot. On hover the cluster's third slot swaps identity too
  — reboot child in normal mode, hibernate child (red, `opt-no`) in
  reboot-pending mode — so the sleep + escape-hatch hover affordance is
  always present. Rule 6 (same option, same look) wins: reboot urgency
  rides on the existing reboot affordance instead of growing a new pill.
  New `power-pill.sh` helper does the state branch via direct readlink
  on `/run/current-system` vs `/run/booted-system` (no cache dependency,
  sidestepping the `text=empty hides module` hazard that left the old
  standalone pill invisible anyway).
  **Hint:** state predicate lives in `waybar/scripts/power-pill.sh`'s
  `is_reboot_pending()` (mirrors `waybar-self-test.sh`'s
  `check_reboot_pending`). Click on the parent goes through
  `power-pill click power` so the same module slot dispatches to
  reboot or hibernate based on state. Spec at
  `docs/superpowers/specs/2026-06-13-power-parent-reboot-pending-design.md`.

- **Fix: post-reboot OPTIONS module loss + reboot-pill no-op** — 2026-06-13
  User rebooted and OPTIONS came back stripped (night-dimmer / battery / clock
  exec via $WAYBAR_SCRIPTS_LIB / standard-os-reboot-prompt all silently
  failing). Three causes layered:
  (1) Booted generation predated the Environment= block + waybar-scripts
      derivation in waybar.nix — i.e. a `test` / never-`switch` regression of
      the same pattern as 2026-06-12. Resolved by `sudo nixos-rebuild switch`.
  (2) After switch, two extensionless scripts added during UPDATE pill L1
      (`standard-os-reboot-prompt`, `standard-os-update-pill-ack`) were still
      missing from the shellcheck + install loop in `modules/waybar.nix`.
      Added to both lists.
  (3) Curated `Environment=PATH` (previously inherited from systemctl --user)
      dropped `/etc/profiles/per-user/max/bin` — sibling HM-module binaries
      (`dictate-waybar`) became unreachable. Added the user profile to PATH.
  **Hint:** the `*.sh` glob in waybar-scripts' shellcheck + install loop
  silently swallows new extensionless scripts. Every new bare-name script
  under `waybar/scripts/` MUST also be enumerated in both lines of
  `modules/waybar.nix` (search `for f in *.sh`). Pair with: when curating
  `Environment=PATH` for a waybar-like service, include
  `/etc/profiles/per-user/max/bin` so sibling HM-module binaries still
  resolve.

- **UPDATE pill — L1 foundation (auto-pipeline + verify-rollback)** — 2026-06-13
  Replaced the manual rebuild workflow with an automatic 5-min-cadence
  pipeline gated on idle (fullscreen/IdleHint/DND). Pipeline phases:
  pre-flight self-test → dry-build → switch → verify → signal. Verify
  failure triggers immediate `nixos-rebuild switch --rollback`.
  Two new SYSTEM pills: `custom/update-pending` (Hidden / Working /
  Error states) and `custom/reboot-pending` (lights when current ≠
  booted; click → rofi reboot/dismiss). Polkit rule scoped to four
  nix binaries.
  Bugs caught during implementation: (1) waybar.nix script-glob missing
  extensionless scripts (fixed up-front); (2) waybar-scripts binPath
  missing flock/pkexec/systemd-run (added); (3) systemd ExecStart needs
  absolute path (Env=PATH doesn't help); (4) pkexec via makeWrapper PATH
  resolved to non-setuid store binary (hardcoded /run/wrappers/bin/pkexec);
  (5) waybar-self-test.sh always exited 0 — auto-rollback was non-functional
  before this — now exits 1 on failure.
  **Hint:** spec at `docs/superpowers/specs/2026-06-13-update-pill-design.md`,
  plan at `docs/superpowers/plans/2026-06-13-update-pill-l1.md`.
  L2–L5 (channels, GC, optimise, CVE) are separate plans.

- **2026-06-12 (bulletproof)** — **OPTIONS bar moves into /nix/store: scripts derivation, self-test pill, rebuild-pending pill, shutdown gate.**
  Closes the architectural follow-up flagged in the incident DONE entry
  below. A single `pkgs.stdenv.mkDerivation` wraps every script under
  `/etc/nixos/home/waybar/scripts/` (plus three new ones —
  `waybar-self-test`, `standard-os-shutdown-guard`,
  `standard-os-rebuild-prompt`) as `${waybar-scripts}/bin/<name>`.
  `lib/pill.sh` lives at `share/waybar-scripts/lib/pill.sh` and is
  sourced via absolute path through `substituteInPlace`. The daemon
  `ExecStart`s and `config.jsonc` exec sites move off
  `~/.config/waybar/scripts/`; the `xdg.configFile."waybar/scripts"`
  declaration is deleted. `~/.config/waybar/scripts` ceases to exist.
  Restart-burst tuning (20 attempts / 5 min, expo backoff plateauing
  at 30 s) replaces the 5-shots-in-12 ms failure mode the incident
  exposed. `waybar-self-test.service` + 60 s timer drive a SYSTEM-zone
  pill that surfaces broken daemons or missing caches in red (`⚠ N`),
  invisible when healthy. `modules/standard-os-commit-tracking.nix`
  writes `/run/standard-os/activated-commit` at every activation;
  the same `waybar-self-test` script emits a second pill
  (`rebuild-pending`, FA sync glyph + `opt-pin-orange`) whenever the
  working tree at `/etc/nixos/home` is ahead. Power-cluster `on-click`
  handlers route through `standard-os-shutdown-guard <action>` — clean
  tree forwards immediately, pending tree opens a rofi modal (rebuild+
  action / action-anyway / cancel).
  Verified via end-to-end acceptance suite (16 commits across 15 tasks,
  every AC PASS): 18 wrapped binaries in `${waybar-scripts}/bin/`,
  `~/.config/waybar/{scripts,scripts.hm-bak}` both absent, services
  active with clean journal, `rm -rf /tmp/waybar-cache /tmp/glass-mode`
  + restart-of-all-daemons → every required cache present within 2 s,
  self-test surface on daemon-down + clear on recovery, rebuild-pending
  pill activates on `git commit --allow-empty` + clears on reset,
  shutdown-guard DRY_RUN forwards directly on clean tree.
  Spec: `waybar/docs/superpowers/specs/2026-06-12-waybar-bulletproof-design.md`.
  Plan: `waybar/docs/superpowers/plans/2026-06-12-waybar-bulletproof.md`.
  **Hint:** `lib/pill.sh` substitution covers only one form —
  `. "$SELF_DIR/lib/pill.sh"`. If a future script uses any other form
  (e.g. `source "$(dirname "$0")/lib/pill.sh"` or
  `LIB=$(dirname "$0")/lib; source $LIB/pill.sh`), append the
  `--replace-quiet` pair in `modules/waybar.nix` installPhase or the
  wrapped binary will runtime-fail with "lib/pill.sh: No such file or
  directory" on first call. The original spec template anticipated two
  forms (`source "$(dirname...)" /` and `. "$(dirname...)"/`) — neither
  appears in the codebase; the implementer's pre-flight grep caught
  the discrepancy.
  **Hint:** `shellcheck -S error` (not full severity) gates the build.
  The corpus carries legitimate informational/warning findings
  (SC1090/SC1091 non-const lib source, SC2154 false-positive jq vars,
  SC2034 unused INTERVAL in glass-text-daemon) — the gate's job is
  catching new errors, not enforcing a style pass. Adding a new
  script: `nix-shell -p shellcheck --run 'shellcheck -S error -s bash
  <name>.sh'` locally before committing. Explicit `pill pill-child`
  added to the invocation so the no-extension launchers don't slip
  through the `*.sh` glob.
  **Hint:** self-seeding contract — `glass-text-daemon.sh` calls
  `self_seed` (which uses `hex_luminance` + `set_mode` from the same
  daemon, falling back to "dark") and `workspace-daemon.sh` calls
  `emit_snapshot` before entering its event loop. New long-lived
  daemons must do the same; the AC3 regression gate (`rm -rf
  /tmp/waybar-cache /tmp/glass-mode && restart-all-daemons →
  every required cache present within 2 s`) catches violations.
  Caveat: only the two long-lived waybar daemons self-seed today;
  `notif-daemon` was NOT touched in this migration. On a fresh tmpfs
  `/tmp` boot, `notif-bell` cache will be missing until the first
  notification arrives — the self-test pill correctly surfaces this
  ("⚠ 1, cache/notif-bell: missing-or-empty") for ≤60s after boot.
  Adding `self_seed` to notif-daemon is queued in NEXT.
  **Hint:** `StartLimitBurst` / `StartLimitIntervalSec` belong in the
  `[Unit]` section, NOT `[Service]`. systemd silently ignores
  `StartLimitIntervalSec` when placed in `[Service]` (reverts to 10 s
  default), making the burst math wrong on the exact failure mode
  the tuning was designed to prevent (today's incident: 5 instant
  restarts in 12 ms each). Both daemon definitions place the StartLimit*
  fields under `Unit`, while `Restart` / `RestartSec` / `RestartSteps`
  / `RestartMaxDelaySec` stay in `Service`. Verify with `systemctl
  --user show <unit> -p StartLimitIntervalUSec` — should report `5min`,
  not `10s`.
  **Hint:** `/run/standard-os/activated-commit` is the rebuild-pending
  ground truth. The activation script uses `${pkgs.git}/bin/git -c
  safe.directory=/etc/nixos/home -C /etc/nixos/home rev-parse HEAD` —
  the `-c safe.directory=...` is required because activation runs as
  root while `/etc/nixos/home` is owned by user max, and git 2.35+
  refuses cross-user repo operations by default. Without the override,
  the activation script silently truncates `activated-commit` to zero
  bytes (`> file` is non-atomic; the redirect fires before git can
  produce output) and the rebuild-pending check fails open (correct
  behavior, wrong reason). `modules/standard-os-commit-tracking.nix`
  lives in `/etc/nixos/modules/` which is NOT a git repo on this host —
  the file is part of the host config but untracked. If `/etc/nixos`
  ever becomes git-versioned, retroactively commit it.
  **Hint:** `standard-os-shutdown-guard` covers OPTIONS power-cluster
  (`custom/lock`, `custom/power`, `custom/reboot`) and is the
  authoritative path for user-initiated shutdown. Emergency hibernate
  (lid close, low battery via UPower) intentionally bypasses the gate
  (time-sensitive). Shell-typed `systemctl poweroff` intentionally
  bypasses (expert escape hatch). If a user-initiated power path is
  ever added (e.g., a new rofi power menu, SUPER+ESC binding), route
  it through the guard or it'll skip the rebuild-pending modal.
  **Hint:** the `waybar-self-test` REQUIRED lists (`REQUIRED_UNITS`,
  `REQUIRED_CACHES`, `REQUIRED_FILES`) grow over time. When adding a
  new daemon to the bar, add its unit name to `REQUIRED_UNITS` AND
  add its canonical cache file to `REQUIRED_CACHES` if it's a reliable
  presence-indicator. Current lists: `waybar`,
  `waybar-glass-text-daemon`, `waybar-workspace-daemon` (units) +
  `ws-current`, `window`, `notif-bell` (caches) + `/tmp/glass-mode`
  (files).
  **Hint:** the clock pill's exec inline-sources `lib/pill.sh` to call
  `pill_emit` + `pill_theme` as shell functions (not binaries). The
  `WAYBAR_SCRIPTS_LIB` env var set on waybar.service's `Environment`
  list points to `${waybar-scripts}/share/waybar-scripts/lib` so the
  inline source path `$WAYBAR_SCRIPTS_LIB/pill.sh` resolves without
  `$HOME`. Any future custom module wanting to call lib functions
  directly should use the same pattern.
  **Hint:** `--replace` in `substituteInPlace` is deprecated; the
  installPhase uses `--replace-quiet` (no warnings on no-match files,
  modern API). If a future script doesn't source `lib/pill.sh`, the
  silent no-match is correct — no false alarms in build output.
  **Hint:** `restore-minimized.sh` (the alt-tab-style launcher)
  sources `~/.config/rofi/window-helper.sh` (a user-managed rofi
  helper, NOT under `/etc/nixos/home/waybar/scripts/`). This
  reference was preserved as-is because (a) restore-minimized is
  invoked via `on-click`, not from a daemon, so it runs in the
  user's shell context with `$HOME` resolved; (b) the rofi helper
  itself isn't yet nix-packaged. If the user reorganizes their
  rofi setup, this script needs updating.
  **Hint:** the 5-minute Argentinian-clock pill format ("HH:MM"
  with "YYYY MMM" tooltip) is preserved in the inline exec at
  `custom/clock`. If the format ever changes, the file to edit is
  `config.jsonc` (still mkOutOfStoreSymlink'd; live iteration).

- **2026-06-12 (incident)** — **Post-reboot blank bar: scripts/ migration committed without `nixos-rebuild switch`.**
  After the sleep/hibernate work (2026-06-11) the user rebooted to validate
  kernel-param changes. Bar came back missing "a lot of modules" — visually
  the entire interactive layer was gone. Root cause: commit `a8d720a`
  ("scripts/ tracked in repo + HM symlink") added
  `xdg.configFile."waybar/scripts" = mkOutOfStoreSymlink …` to
  `modules/waybar.nix` at 16:32, but no rebuild ran between the commit and
  the reboot. At boot the activated HM generation was the pre-migration
  one: `/nix/store/zvacrbqx…-home-manager-files/.config/waybar/` contained
  only `config.jsonc`, `style.css`, `offers/` — no `scripts` entry — so
  `~/.config/waybar/scripts/` was never materialised. Cascade:
  `waybar-glass-text-daemon.service` and `waybar-workspace-daemon.service`
  both exited 127 (`bash: glass-text-daemon.sh / workspace-daemon.sh: No
  such file or directory`); waybar's per-module execs of `night-dimmer.sh`,
  `battery.sh`, `lib/pill.sh`, `pill`, `pill-child` all failed the same
  way; modules went empty or stayed on stale pre-reboot /tmp caches.
  Fix: `sudo nixos-rebuild switch` (activated the new HM, materialised
  the scripts symlink → `/etc/nixos/home/waybar/scripts/`) + restart
  `waybar`, `waybar-glass-text-daemon`, `waybar-workspace-daemon`.
  Verified: zero `No such file or directory` errors in waybar journal
  since 17:00:15 restart, both daemons `active`, fresh writes landing in
  `/tmp/waybar-cache/` (window pill ticked 17:01:29).
  **Hint:** the deeper issue is unchanged — `scriptsDir =
  "${config.home.homeDirectory}/.config/waybar/scripts"` makes the bar
  fragile by design. Any missed activation, partial HM run, `rm -rf
  ~/.config`, or fresh-install-before-user-activation breaks the entire
  interactive layer. Real bulletproofing requires moving every script
  into `pkgs.writeShellScriptBin` with curated PATH so daemons and
  per-module execs reference `/nix/store/…/bin/<name>` directly and
  $HOME stops being a runtime dep. Queued as the next major work item
  (see NEXT entries "Workspace-daemon migration to Nix" and the broader
  scripts-tree wave the 2026-06-12 audit entry below already flagged).
  **Hint:** `/tmp` on this host is NOT tmpfs — `findmnt /tmp` returns
  empty exit-1, meaning /tmp lives on the root filesystem and persists
  across reboots. That's why some `/tmp/waybar-cache/*` files carry
  pre-reboot mtimes (00:22 jun 12). It's not a daemon bug; workspace-
  daemon's content-dedup correctly suppresses re-emits when the value
  hasn't changed since last write, and the surviving file content is
  current. The persistence is environmental and benign here, but worth
  noting: a fresh distro install onto tmpfs-`/tmp` will have an empty
  cache dir at every boot, and any module whose owning daemon doesn't
  self-seed on startup will render empty until its first event. Audit
  recipe before sealing the distro: each daemon must write its initial
  cache file BEFORE entering its event loop.
  **Hint:** rebuild-before-reboot is not yet a hook. Future safety net
  candidate: a `nixos-rebuild-since-commit` check in shell rc or a
  pre-poweroff hook that warns if the working tree has commits ahead
  of the activated generation. Lower priority than the writeShellScriptBin
  migration but cheap to add later.

- **2026-06-12 (audit)** — **Waybar `scripts/` dir migrated into repo + HM symlink.**
  Deep-debug audit after the b/w switcher fix found that 1,444 lines of bash
  driving the entire bar UX — glass-text-daemon.sh (with today's RTMIN+11/+12
  signal fanout), lib/pill.sh (with the Layer 2A pill_emit theme re-read fix
  from 36abfe1), workspace-daemon.sh, the static pill / pill-child wrappers,
  and every per-module script (battery, screen-type, warm-cycle, shader-*,
  night-dimmer, win-action, win-icon, restore-minimized, swap-smart,
  shader-stack) — lived ONLY in `~/.config/waybar/scripts/` as un-tracked
  real files. A `rm -rf ~/.config` (or fresh-machine reinstall from the
  git repo) would have erased the entire interactive layer plus today's
  hard-won bugfixes. The bar would have come back wallpaper-broken on the
  first install of a fresh distro image.
  Migration: byte-identical snapshot of every script committed under
  `/etc/nixos/home/waybar/scripts/` (mirrors `style.css` + `config.jsonc`
  living next to them). `waybar.nix` gains a `scriptsSource` option +
  `xdg.configFile."waybar/scripts"` declaration with
  `mkOutOfStoreSymlink` — same out-of-store pattern as style.css.
  Chain after activation:
    ~/.config/waybar/scripts
      → /nix/store/<hm-files>/.config/waybar/scripts (HM-managed)
        → /nix/store/<hm_scripts> (mkOutOfStoreSymlink wrapper)
          → /etc/nixos/home/waybar/scripts/ (the source of truth)
  Edits to either end are immediately live (no rebuild for behavior
  changes), and a fresh distro install gets every script materialised
  on first `nixos-rebuild switch`.
  Verified: byte-identical snapshot (cmp passes for every file),
  daemons restart cleanly through the new symlink, real luminance
  flip via touched bg file produces correct mode + cache + visual
  flip across all pills.
  **Hint:** the *full* nix migration (wrap each daemon in
  `pkgs.writeShellScriptBin` with curated PATH so they survive without
  `~/.config/waybar/scripts/` even existing) is still pending — that's
  the "Workspace-daemon migration to Nix" entry in NEXT, expanded to
  cover the whole `scripts/` tree. The current state already protects
  against data-loss + makes fresh installs work; the writeShellScriptBin
  wrap removes the last `$HOME` runtime dependency.
  **Hint:** if HM activation reports `Existing file ... is in the way`
  for a path under `waybar/scripts/`, look for a `.hm-bak` next to it
  — HM backed up an old version. After confirming the symlink works,
  it's safe to `rm` the `.hm-bak`.

- **2026-06-12 (late)** — **Glass-mode actually works: the missing fourth layer was CSS.**
  Commit 36abfe1's "bulletproof" three-layer fix landed cache content correctly
  (`["opt-pill","light","opt-no",...]` everywhere) but the user reported the
  visual symptom unchanged: only the `+` launcher and `ws-current` pill flipped
  on a light wallpaper. Everything else (ws-1..9 drawer, window title, clock,
  battery, win-close/minimize/move-trigger, notif-bell, notif-profile, dictate)
  stayed in dark-mode white text.
  Root cause: the canonical adaptive-text rule in `style.css` was
  `window#waybar .opt-pill.light label { color: @opt-text-on-light; ... }` —
  a descendant selector on `label`. In waybar 0.14.0 / GTK 3 this silently
  no-op'd for every text-bearing custom module. The only pills that visibly
  flipped were the opt-plus pair, because their own light-mode rules
  (`.opt-plus.light` for SVG-swap, `.opt-plus.opt-swap.light` for text)
  happen to set `color:` directly on the pill, not via a label descendant.
  Fix: rewrite the canonical rule (and its `:hover` sibling) without the
  `label` descendant, so color cascades into the GtkLabel via GTK CSS
  inheritance — same mechanism the working opt-plus.opt-swap rule used all
  along. The label-direct override at line 437
  (`.opt-pill.opt-plus.opt-swap.light:hover label { color: transparent }`)
  still wins by specificity (4 compound classes > 2), so swap-pill label
  hiding on hover is preserved.
  Verified end-to-end: stopped glass-text-daemon, forced /tmp/glass-mode=light,
  jq-rewrote all caches, sent RTMIN+10/+11/+12 to waybar; user confirmed
  visually "everything flips dark now" (vs. the previous "only + and
  ws-current"). Restarted glass-text-daemon afterward; daemon auto-reverted
  /tmp/glass-mode to dark per the current dark-wallpaper luminance, and
  text returned to white correctly.
  **Hint:** new hazard added to waybar/CLAUDE.md: GTK 3 CSS descendant `label`
  selector doesn't reliably match GtkLabel inside a waybar custom module —
  always set color on the pill, not on `label` descendant. Reserve label-direct
  rules for specificity overrides (the opt-plus-swap hover transparent-label
  trick). Sanity grep: `grep -n '\.light label' style.css` — every hit should
  be a deliberate override of a pill-direct rule, not a primary adaptive-text
  rule.
  **Hint:** this is the *fourth* layer of the glass-mode flip, missed entirely
  by the 2026-06-12 morning audit which verified cache content but not CSS
  application. Verification recipe must include a human-eye visual check
  ("does the bar actually look different on a light wallpaper?"), not just
  cache-content asserts — because the cache can be perfect and the bar still
  wrong if the consuming CSS rule doesn't match.
  **Hint:** notif-bell / notif-profile / notif-action-1/2/3 use `signal: 12`
  and dictate uses `signal: 11` (their owning daemons drive them independently
  of theme). Glass-text-daemon's `set_mode` now signals all three of RTMIN+10,
  +11, +12 after rewriting caches, so those modules re-cat their (already
  jq-rewritten) cache file immediately on theme flip. Without this, the cache
  was correct but waybar wouldn't read it until the owning daemon's next
  natural emission — meaning a notif-bell or dictate pill could carry stale
  theme tokens across a wallpaper change. Adding the extra two signals is
  free (signal delivery is microseconds). If a new module starts using a
  signal other than 10/11/12 AND wants to re-render on theme flip, extend
  `set_mode` to also send that signal. Reference: `glass-text-daemon.sh`
  bottom of `set_mode()`. **Heads-up:** that script lives at
  `~/.config/waybar/scripts/glass-text-daemon.sh` — NOT in this repo, so the
  RTMIN+11/+12 fanout edit is NOT in the git commit. When this daemon migrates
  to a Nix module (queued in NEXT as "Workspace-daemon migration to Nix"; the
  glass-text-daemon belongs in the same wave), copy the edited `set_mode` body
  into the new Nix-managed version verbatim.
  **Hint:** battery is currently invisible when Status = Charging/Full or
  capacity ≤ 15 % — `battery.sh` emits `text=""` for those three states (per
  the script header KNOWN PRE-EXISTING BUG, inherited from the pre-refactor
  inline exec). Waybar hides custom modules with empty text, so on a charging
  laptop the pill is gone regardless of theme. This is queued as a separate
  decision (which Nerd Font glyphs to use for charging/full/critical) and is
  NOT a glass-mode regression — when the icon glyph lands, the theme flip
  already works correctly because battery.sh re-reads `pill_theme()` on every
  exec and waybar signal:10 re-execs it on every flip.

- **2026-06-12** — **Glass-mode (b/w font switcher) rebuilt bulletproof.**
  Three independent bugs were keeping the b/w font switcher silently broken
  since the 2026-05-28 JSON array migration; user-visible symptom was that
  only the apps-launcher `+` and (apparently) the workspace pills ever
  flipped text color on a light wallpaper.
  (1) `glass-text-daemon.sh::update_cache_mode` — the central "rewrite all
  caches when /tmp/glass-mode flips" path — used a sed regex targeting the
  obsolete string-form `"class":"…dark…"` while every cache file is array
  form `"class":[…,"dark",…]` since 2026-05-28. Net effect: silent no-op for
  ~2 weeks. Replaced with jq array surgery (`map(if . == "dark" or . ==
  "light" then $m else . end)`) + atomic tmp+mv per file + dedup against
  previous content. Layer 1.
  (2) `lib/pill.sh::pill_emit` — added a fresh `pill_theme()` read at emit
  time that auto-substitutes any "dark"/"light" token the caller passed
  with the current value, then deduplicates so we never emit two theme
  tokens. This collapses the workspace-daemon race: workspace-daemon caches
  `m=$(pill_theme)` at top of its 1 s loop and reuses for ~20 pill_writes;
  if glass-text-daemon flipped /tmp/glass-mode mid-iteration the cached `m`
  would land in the cache and overwrite the central rewrite. Now pill_emit
  re-reads, so the race window is microseconds, not seconds. Layer 2A.
  (3) `notif-daemon` (4 emit sites), `voice-dictation.nix` (3 sites),
  `power-sleep.nix` (2 sites), `standard-os-resume-user.nix` (1 site) all
  hardcoded the literal string `"dark"` in class arrays. notif-daemon's
  own comment explicitly said "for now we hardcode dark and rely on the
  glass-text rule to swap when implemented in a follow-up" — the follow-up
  never happened and the rule was broken anyway. Replaced each with a
  fresh /tmp/glass-mode read (notif-daemon: new `glass_theme()` helper;
  Nix-embedded printfs: inline `theme=$(cat /tmp/glass-mode 2>/dev/null) ||
  theme=dark` with `case` validation). Layer 2B.
  Verified with `/tmp/glass-mode-stress.sh` — toggles light↔dark via touch
  on cached bg files, audits every /tmp/waybar-cache/*.json for the wrong
  theme token. Before: 9 stale per iteration (notif-bell, notif-profile +
  workspace race). After: 10/10 PASS at SETTLE=1 (1-second window). Smoke
  tested fresh notif arrival under forced light → cache emits "light".
  **Hint:** the three layers are independent and overlap deliberately. Layer
  1 catches stale caches centrally on mode flip. Layer 2A catches any pill
  going through pill_emit even if the daemon's cached `m` is stale (so it
  protects bypass paths). Layer 2B catches event-driven daemons whose printfs
  bypass pill_emit. Lose any one layer and there's a failure mode that
  reappears (notif on light wallpaper, workspace-daemon race, dictate
  recording on light, power-resume after suspend with light wallpaper).
  **Hint:** new hazard added to waybar/CLAUDE.md "Known hazards": hardcoded
  `"dark"` / `"light"` literal in any class-array emit site → pill never
  adapts. Grep recipe: `grep -rn '"dark"\|"light"' /etc/nixos/home/scripts/
  /etc/nixos/home/modules/ /etc/nixos/modules/ | grep -E '(class|opt-pill)'`
  should return only comments after this commit.
  **Hint:** stress test script at `/tmp/glass-mode-stress.sh` is one-shot,
  not committed. If a regression reappears, recreate it (touches two
  /tmp/hypr-edge-bg/bg_*.png files alternately, audits caches after each).
  **Hint:** workspace-daemon and notif-daemon both need a restart after a
  pill.sh edit (they source it once at process start). The systemctl --user
  restart of waybar-glass-text-daemon, waybar-workspace-daemon, and
  notif-daemon services is part of the post-change verification.

- **2026-06-11** — **Sleep/resume display polish (blackout choreography).**
  After the first-round sleep fixes landed (see next entry), the
  remaining UX complaint was the visible "freeze → off → comes back
  → off again" sequence on suspend and the symmetric "wake frozen →
  off → live" sequence on resume — three subsystems (Hyprland, i915,
  NVIDIA VRAM save) each touching the display during the handoff,
  every transition visible. Two changes mask it as one clean fade:
  (1) `power-sleep.nix`'s existing system-scope `standard-os-presleep`
  service now blacks the panel before the kernel suspend kicks off
  by walking `/run/user/*/hypr/*/.socket.sock`, deriving uid /
  username / HYPRLAND_INSTANCE_SIGNATURE from the path, and invoking
  `hyprctl dispatch dpms off` via `runuser -u <user> -- env …` (the
  root→user bridge). 200 ms settle ensures the off-frame is fully
  rendered before the kernel begins the suspend sequence. The
  matching `standard-os-resume` service spawns a backgrounded
  `restore_display` loop (1 s cadence, `timeout 1` per hyprctl
  attempt, capped by `displayRestoreTimeoutSec`, default 5 s) that
  dpms-on as soon as the compositor is reachable — typically iter
  1–2 on a healthy resume, so the panel restores within ~1 s with
  fresh-rendered content (not the stale framebuffer flash).
  (2) `NVreg_PreserveVideoMemoryAllocations` flipped 1 → 2 — mode 2
  saves VRAM into the kernel suspend image instead of mode 1's
  sysfs-trigger that briefly re-activates the display. Eliminates
  the "comes back, off again" sub-flash. While here, fixed a latent
  bug in `standard-os-presleep`: its `path` was `[ coreutils bluez ]`
  with no gawk, so `bluetoothctl … | awk '{print $2}'` silently
  failed on every suspend (the `|| :` masked it) — the bt-connected-
  presleep file was always empty and post-resume BT reconnect logic
  was a no-op. Added gawk + hyprland + util-linux to the path.
  *Hint #1:* The NVreg flip required `lib.mkAfter` plumbing because
  nixpkgs's `hardware.nvidia.powerManagement.enable=true` silently
  auto-appends `NVreg_PreserveVideoMemoryAllocations=1`. Kernel takes
  the LAST occurrence of a module param when listed multiple times
  on the cmdline. The override lives in `power-sleep.nix`'s
  `boot.kernelParams = lib.mkMerge [ [...] (lib.mkAfter [...]) ]`
  block — declaring it in `boot.nix` (default-priority list) was
  silently overridden because nixpkgs's contribution landed after.
  Validation: `cat /run/current-system/kernel-params | grep -oP
  "Preserve[^ ]*" | tail -1` should print `…=2`.
  *Hint #2 (the trap of the day):* user-scope `sleep.target` /
  `suspend.target` do NOT exist on NixOS+systemd by default.
  `systemctl --user list-unit-files | grep sleep` is empty. Any
  Home-Manager `systemd.user.services.<x>.Install.WantedBy = [
  "sleep.target" ]` is a dead letter — the existing
  `standard-os-resume-user.service` has *never* fired since
  2026-06-05 install (`ExecMainStartTimestamp=` empty, journal
  has no entries across all boots). For Standard-OS purposes, any
  user-touching work tied to sleep/resume must live in a system-
  scope service with a root→user bridge (the pattern is now in
  `standard-os-presleep` and `standard-os-resume` — copy from
  there). Future fix candidate: a system-sleep hook that activates
  user-scope sleep.target.wants/ via `runuser systemctl --user
  start …`; not done in this round because the system-scope path
  is sufficient and simpler.

- **2026-06-11** — **Sleep/hibernate/lid resume hardening.**
  Fixed three live sleep-system regressions after 3 days of suspend
  cycles between Jun 8 reboot and now. (1) WiFi-after-resume: TLP
  `DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE = "bluetooth wifi"` raced
  NetworkManager on every resume — radio saw "no active connection"
  on battery and was soft-blocked via rfkill until user manually
  ran `rfkill unblock all`. Dropped wifi from the list (kept BT per
  user pref), added `RESTORE_DEVICE_STATE_ON_STARTUP=1`. (2) Display
  freeze on lid-open: i915 `adlp_tc_phy_connect` PHY-ready timeout
  WARN on every resume (Lenovo Slim Pro 9i 83C0 / Alder Lake-P
  USB-C DP-alt bug). Added `i915.enable_psr=0 i915.enable_fbc=0`
  kernel params to `power-sleep.nix`. (3) NVIDIA wake glitches:
  running kernel still on `NVreg_DynamicPowerManagement=0x02` (D3
  cold) — boot.nix already had 0x01 (D3 hot) since 2026-06-05 but
  kernel params only take effect on reboot. Hardened the post-resume
  health-check with two-layer net probe (rfkill state + NM state)
  and explicit `rfkill unblock wifi` in `remediate_net()`.
  *Hint:* The i915 params are hardware-agnostic — kernel ignores
  them on AMD GPUs and on `xe`-driven newer Intel iGPUs, so safe
  for the distro. They live in `power-sleep.nix`'s `boot.kernelParams`
  next to `resume=UUID=...`, gated by `standardOs.power.sleep.enable`.
  Trade-off is ~0.5–1 W extra idle iGPU draw on battery for Intel
  systems — worth it for resume stability. New kernel params require
  a reboot to validate; TLP and resume-health changes took effect
  live via `nixos-rebuild switch`. Future debugging seam: if a wifi
  "block on resume" regression appears, check `journalctl -b 0 -u
  tlp.service` for "Disabling radios" near suspend exit time, and
  the resume pill (`/tmp/waybar-cache/power-resume`) for "net" in
  the failure list — both will name the layer responsible.

- **2026-06-11** — **Notification center P3: focus profiles + sound.**
  Replaces P1's binary DND toggle with 6 named profiles (Off, DND,
  Sleep, Work, Gaming, Media), each declaring a `silenceMode`
  (none / transient / all-but-critical-silent / non-allowed / all),
  `criticalPulse`, `criticalSound`, optional `allowedApps`, and
  optional `schedule` ("HH:MM-HH:MM Day-Day" with cross-midnight
  wraparound). The bell glyph swaps between FA bell (`\xef\x83\xb3`,
  Off only) and FA solid bell-slash (`\xef\x87\xb7`, every other
  profile); pin colors continue to reflect unread state. `opt-pushed`
  is gone — the glyph carries the engaged signal. A new
  `custom/notif-profile` child pill (replacing `custom/notif-dnd`)
  shows the active profile name; click opens a new `notif-rofi-profiles`
  picker that writes an override file with `valid_until` = next
  schedule boundary, then signals SIGUSR1 to the daemon.
  Sound subsystem uses `canberra-gtk-play` with the freedesktop sound
  theme: `message-new-instant` for normal arrivals, `dialog-warning`
  for critical (when the profile allows). Rate-limited at 1 sound /
  500ms via `LAST_SOUND_AT`.
  **Hint:** `render_bell_for_state`'s 3rd arg renamed `DND_ON` (0/1)
  → `SILENCE_MODE` (string). Callers must update — the daemon's
  emit() does this, but any future unit tests that pass the old 0/1
  form need conversion to "none"/"transient" or similar.
  **Hint:** Profiles JSON path is
  `~/.local/share/standard-os/notif-profiles.json` (materialized via
  `home.file`), NOT `/etc/notif-profiles.json` as the spec originally
  proposed. The env var `NOTIF_PROFILES_JSON` overrides per process.
  **Hint:** Schedule resolution polls every 60s via a tick check in
  `on_arrival`. SIGUSR1 (from notif-rofi-profiles) wakes the daemon
  for an immediate re-resolve; the capped `read -t` cadence inherited
  from P2 (≤0.5s during transient) ensures the override file is
  picked up promptly.
  **Hint:** The `dnd` subcommand of notif-click is GONE. Any user
  keybindings or scripts calling it must migrate to
  `notif-click profile` (opens the rofi picker).
  **Hint:** Acceptance gate: profile-change propagation after SIGUSR1
  takes up to ~1.5s in the worst case because of the same bash
  signal-vs-subshell bug P1/P2 hit. The daemon has BOTH a SIGUSR1
  trap (immediate when delivered to the main shell) AND a 1s idle-tick
  `resolve_and_load_profile + emit` fallback that catches missed
  signals. Manual rofi-picker UX feels instant; programmatic tests
  should sleep ≥1.5s after writing the override file + signaling.

- **2026-06-10** — **Notification center P2: actions + app icons + 2FA extraction.**
  Composes onto the live P1 architecture: three child action pills
  (`custom/notif-action-{1,2,3}`) join `group/notif` and surface
  mako's `actions` array on hover-revealed wide pills. Wide-pill text
  gains Pango bold for the app name (`<b>App</b> · Title`) with
  `pango_escape` applied to app/title BEFORE the markup wrap so raw
  D-Bus strings can't inject styling. Rofi rows gain icons via the
  native `\0icon\x1f<app_name>` row metadata + `-show-icons` flag —
  no new icon-resolution code. 2FA / OTP extraction runs a keyword-
  anchored regex (`code|OTP|PIN|verification|auth|login|token|MFA|
  2FA|one-time|cód|código|codice` + 40-char window + 4-8 digit code)
  over summary+body on every arrival; matches embed an `otp_code`
  field in the bell cache and add `opt-glow-green` to the class array.
  Click the OTP wide pill → `wl-copy` the code, rendezvous via
  `/tmp/notif-otp-clicked` + SIGUSR2 to notif-daemon, daemon transitions
  to `otp_copied` kind for 500ms (wide-pill text becomes
  `<b>App</b> · Title · copied`), then dismisses cleanly.
  **Hint:** `render_bell_for_state` gained 2 args (OTP_CODE, OTP_COPIED).
  Bell output always emits `otp_code` (empty string when no code) so the
  JSON schema stays stable; waybar ignores the field, notif-click reads it.
  **Hint:** action children embed the mako action key in a non-standard
  `key` field on the action-N cache. The field name is the project-internal
  contract between notif-daemon (writer) and notif-click (reader); if it
  ever changes both files need synchronised updates.
  **Hint:** P2 added SIGUSR2 alongside the P1 SIGUSR1. USR1 = DND mode
  changed, USR2 = OTP-copied transition. Both traps set a *_PENDING
  flag that the main loop drains; both use the 1-second polling
  fallback for delivery races.
  **Hint:** rofi icon hints (`\0icon\x1f<app_name>`) contain literal NUL
  bytes that bash `$()` command substitution silently strips. notif-rofi
  bypasses `$()` capture: format_rofi_entry is called directly (output
  goes to build_rows' stdout), and build_rows is piped directly into
  rofi (`build_rows | rofi -dmenu …`). The history section uses a
  two-pass approach: first collect tab-separated field strings (no NULs)
  into a bash array, then emit rows with direct printf calls.
  **Hint:** bash signal traps fire in whatever subshell happens to be
  active at signal-delivery time, and trap-body assignments are silently
  lost when a `$()` subshell exits. P1 first hit this with SIGUSR1 (DND
  toggle wake); P2 re-hits it with SIGUSR2 (OTP-click hold). The pattern
  to defeat it: a file-existence rendezvous (`/tmp/notif-otp-clicked`)
  PLUS a capped `read -t` timeout (≤0.5s during transient, ≤0.1s during
  OTP-copied hold) so the top-of-loop file-poll runs frequently. The
  trap itself stays — when delivered to the main shell it wakes `read`
  early; when delivered to a subshell, the next iteration's poll catches
  the file.
  **Hint:** mako 1.10 returns the actions array as a D-Bus dict (type
  `a{ss}`) which busctl --json=short renders as a JSON object, NOT the
  alternating-strings array the freedesktop spec suggests. query_mako_state
  type-switches with jq: object → `to_entries | map([.key, .value]) |
  flatten` to get an alternating array; array → pass through; else → [].
  Dict iteration order is mako-internal (currently insertion-reverse) so
  the slot assignment to action-1/2/3 isn't argv-stable.

- **2026-06-10** — **Notification center P1: drawer + DND + per-app rules.**
  Extends the spine (same-day spine commit) with a hover-revealed DND
  toggle, a persistent journal of all arrivals, and a rofi-based history
  browser. Layout: `custom/notif` (single pill) becomes `group/notif` with
  two children — `custom/notif-bell` (always visible, carries pin / pushed
  state + transient wide-pill face for 5 s) and `custom/notif-dnd`
  (hover-revealed bell-slash glyph, opt-pushed when DND on, click toggles
  via `makoctl mode -t dnd`). Click bell at rest → opens
  `notif-rofi` listing live unread + journal history; click bell during
  the 5 s wide-pill → invokes the notification's default action AND
  dismisses (same dual-action pattern as the spine's transient click).
  Persistent journal at `~/.local/share/standard-os/notif-history.jsonl`,
  ring-bounded to `services.notifCenter.journalLimit` (default 200) entries,
  pruned per-arrival. Per-app silencing via the new
  `services.notifCenter.silencedApps` Nix option emits mako
  `[app-name=...]` blocks with `history=0` — empty default.
  **Hint:** the bell pill carries ALL state at rest (pin color, opt-pushed,
  composes orthogonally). Normal-urgency arrivals are silent context
  shifts (NO opt-flash, Rule 4 deviation from the spine); only critical
  retains opt-pulse-orange. The bell click handler distinguishes rest from
  transient by the literal ` · ` separator in the cache `text` field.
  **Hint:** journal entries include a `dismissed_at` field that the
  rofi script reads to distinguish unread from historical entries.
  Daemon also marks entries as dismissed when it sees the
  `fr.emersion.mako.Dismissed` D-Bus signal, so the journal stays in
  sync with mako's live state even across daemon restarts.
  **Hint:** the lib dir (`scripts/lib/notif-journal.sh`,
  `scripts/lib/notif-rofi-format.sh`) is wired via `NOTIF_LIB_DIR` env
  var (set by the Nix wrapper) so both `notif-daemon` and `notif-rofi`
  can source from the same canonical location regardless of whether
  they're invoked from the Nix store or the source tree (dev).
  **Hint:** mako 1.10 does NOT emit a ModeChanged D-Bus signal — the
  P1 design assumed one and learned otherwise during acceptance. The
  workaround is two-layered: (1) `notif-click toggle-dnd` sends
  SIGUSR1 to notif-daemon.service via `systemctl --user kill
  --kill-who=main`; the daemon's USR1 trap sets a flag the main loop
  drains (with a 50 ms settle to let `makoctl mode -t dnd` commit before
  query_dnd reads it); (2) the main loop's idle `read -t 1` polls
  `query_dnd` every second as a fallback for any USR1 delivery race —
  `emit`'s dedup means the fallback is a no-op when DND state is stable.
  Worst-case toggle latency is ~1 s; SIGUSR1 hits faster most of the time.

- **2026-06-10** — **Notification center SPINE — live.**
  mako (popups OFF via `invisible=1`, history ON, default-timeout 0) is the
  capture/persistence/DND backbone; OPTIONS owns 100 % of the visible
  surface via a single `custom/notif` pill in SYSTEM zone (leftmost), bell
  glyph at rest, `opt-pin-{green,orange}` for unread/critical, `opt-flash`
  on normal arrival, `opt-no opt-pulse-orange opt-flash` for critical
  arrival, transitioning to `opt-no opt-pin-orange` (motion stopped) at the
  4-s calm threshold and to bell rest at 8 s. Architecture: `notif-daemon`
  (bash, RTMIN+12, `/tmp/waybar-cache/notif`) subscribes to `dbus-monitor`
  on `org.freedesktop.Notifications` AND `fr.emersion.mako`, queries mako
  via `busctl --json=short … fr.emersion.Mako ListNotifications` (mako 1.10
  `makoctl list` is plain text, not JSON). Click handler `notif-click`:
  transient → `makoctl invoke -n <id>` + `makoctl dismiss -n <id>`; rest →
  `makoctl dismiss --all` (interim until the drawer spec ships); right-click
  → noop placeholder. 19/19 state unit tests + 12/12 click unit tests pass;
  all 8 spec acceptance criteria + 5 hazard audits pass live. Spec:
  `waybar/docs/superpowers/specs/2026-06-06-notification-center-spine-design.md`.
  Spine-only — drawer, DND toggle, focus modes, per-app rules, action
  buttons, 2FA, sound, app-icon rendering are all deferred follow-up specs.
  **Hint:** mako 1.10 dropped `makoctl dismiss-all` as a top-level command
  (it's `dismiss --all` now), and `makoctl invoke -n <id>` only fires
  ActionInvoked when the notification carries a "default" action — it does
  NOT auto-dismiss notifications without actions. The click handler invokes
  AND dismisses explicitly to satisfy "click clears the pill" regardless.
  **Hint:** the daemon tracks `TRANSIENT_ID` (the mako id the current
  transient represents) and clears the transient face the moment that id
  disappears from `UNREAD_IDS` (per-event invariant in `on_dbus_event`).
  Without this, click-dismissing the underlying notification left the
  transient sticky in the cache. **Hint:** spec deviation — critical
  transient is time-bounded (4 s pulse → 4 s acked → collapse), not
  hover-driven; waybar doesn't broadcast pill-hover to the daemon. The
  user-visible "stays until acknowledged" guarantee is preserved by the
  underlying `opt-pin-orange` rest face, which persists until the user
  clicks. Hover-driven critical advancement is queued for a follow-up when
  a generic pill-hover IPC channel exists. **Hint:** mako's config file is
  installed via `xdg.configFile."mako/config"`, NOT
  `services.mako.enable = true` — the latter conflicts with D-Bus
  auto-activation (mako ships its own `org.freedesktop.Notifications`
  .service file in `/run/current-system/sw/share/dbus-1/services/`).

- **2026-06-06** — **Font-family resolution fix + icon-pill size restored.**
  The deeper cause of the "right-of-window pills look small" complaint was
  that `style.css` `*` declared `font-family: font-awesome, meslo-lg,
  meslo-lgs-nf` — three nixpkgs PACKAGE names, none of which fontconfig
  recognises as font FAMILY names. `fc-match` returned DejaVu Sans for all
  three, then fontconfig substituted per-glyph to whatever Nerd Font
  contained each private-use codepoint; the result was DejaVu Sans-metric
  text vs Nerd-Font-metric icons, so glyph pills looked smaller than the
  clock at the same 13px. The regression became loud when `font-awesome`
  bumped 6→7 in nixpkgs (`"Font Awesome 7 Free"` family name). Fix:
  rewrote `font-family` to the canonical names
  `"MesloLGS NF", "Font Awesome 7 Free", "Symbols Nerd Font Mono", monospace`
  and moved `nerd-fonts.symbols-only` into `/etc/nixos/modules/desktop.nix`
  `fonts.packages` so the chain is guaranteed on a fresh install without
  depending on the optional `web-design.nix`. Per-pill exception:
  `#custom-window label` overrides back to `sans-serif` because the title
  text reads better proportional. Hazard entry added to CLAUDE.md.
  **Hint:** when a font package bumps major version, re-run
  `fc-match "<exact CSS name>" family` on every entry in the chain — if
  it returns anything OTHER than that family, the chain is silently
  broken and the bar will look "off" without errors in logs.

- **2026-06-06** — **Pill font-size regression fix (`#custom-dictate`,
  `#custom-power-resume`).** Both pills carried standalone `#custom-X { ... }`
  blocks re-implementing `.opt-pill` geometry with `font-size: 12px`, which
  outranked the canonical 13px via ID specificity. Power-resume shipped
  2026-06-05 and the user noticed "smaller font to the right of the window
  module" the next day. Fix: deleted the standalone geometry from `style.css`,
  kept only the state-paint rules (`.recording`/`.transcribing` backgrounds
  and animations; `.empty` collapse). Dictate writers in
  `modules/voice-dictation.nix` (`write_state` and `dictate-waybar` exec)
  updated to emit `class` as a JSON array including `opt-pill` + `dark` —
  same form power-resume's writers already used. New hazard entry in
  CLAUDE.md "Known hazards" plus a `grep -nE '#custom-[a-z-]+ \{' style.css`
  audit recipe so future modules don't reintroduce the pattern.
  **Hint:** every text-bearing custom pill MUST carry `opt-pill` in its
  class array, and `#custom-X` CSS blocks must only carry STATE deltas
  (`.recording`, `.empty`, …) — never geometry.

- **2026-06-05** — **Sleep + Hibernate system + OPTIONS power-cluster remap.**
  Two NixOS modules: `modules/power-sleep.nix` (runtime, default-on, build-time
  assertions for swap presence + UUID derivability) and `modules/disko-layout.nix`
  (install-time partition scheme via disko pinned to v1.12.0, default-off, gated
  by `iAmInstallingAFreshSystem`). Post-resume health-check is split: system
  service `standard-os-resume.service` covers NetworkManager / NVIDIA / time /
  Bluetooth; user service `standard-os-resume-user.service` (in
  `home/modules/standard-os-resume-user.nix`) covers pipewire / hyprland /
  OPTIONS daemons. Two-pass probe at +1s and +3s with per-subsystem remediate
  between passes; pass 2 is source of truth. Pre-sleep service `sync`s + writes
  ISO timestamp to `/run/standard-os/last-sleep` + snapshots currently-connected
  Bluetooth MACs to `/run/standard-os/bt-connected-presleep`. Failure surfaces
  via `/tmp/waybar-cache/power-resume` consumed by new `custom/power-resume`
  pill in SYSTEM zone (between `group-power` and `custom/clock`); empty cache
  → invisible pill (`.empty` collapse). Click pill → re-runs system service.
  OPTIONS group-power remapped: `custom/lock` is Sleep (suspend), `custom/power`
  is Hibernate, `custom/reboot` unchanged. All 5 remaining `swaylock` callsites
  stripped from `config.jsonc` — screen-lock eliminated as a concept. SUPER+ESC
  remains bound to Hibernate. `services.logind.settings.Login`: lid=ignore,
  power-key=poweroff. UPower: critical@5% → Hibernate (safety net only). NVIDIA
  pm services enabled via `hardware.nvidia.powerManagement`. `boot.nix`
  `nvidia.NVreg_DynamicPowerManagement` lowered from 0x02 to 0x01 (D3 hot vs
  cold) to reduce screen-flash count on resume; costs ~0.5–1W idle. Kernel
  change requires reboot to take effect.
  **Hint:** the bluetooth probe is comparison-based, not threshold-based — it
  reads `/run/standard-os/bt-connected-presleep` and only fails if a device
  that WAS connected pre-sleep is NOT connected now. Trusted-but-not-active
  devices (headphones in a drawer) never trigger the failure pill. The v1
  threshold-based probe (any trusted-must-be-connected) false-positived on
  this host immediately. **Hint:** the system service's bash script lives
  inside a Nix `''...''` string — `${VAR}` bash expansions must be escaped
  as `''${VAR}` or Nix interpolates them at eval time. Same for the user
  service via `pkgs.writeShellScript`. **Hint:** `run_pass` must guard the
  `printf '%s\n' "''${failures[@]}"` with `[ "''${#failures[@]}" -gt 0 ]`;
  without the guard, an empty array still emits one empty line and `mapfile`
  records `("")` length 1, producing a spurious "Resume: " pill on every
  healthy resume. **Hint:** disko module imports the disko tarball
  UNCONDITIONALLY at file-top-level; gating `imports` on `cfg.enable` causes
  infinite recursion (Nix needs imports to compute config, needs config to
  compute imports). The destructive logic is gated by `mkIf cfg.enable` in
  the `config` block. **Follow-up noted:** 5 click-inert placeholder pills
  from the swaylock cleanup should collapse to `.empty` per Rule 7 (separate
  spec). Spec: `docs/superpowers/specs/2026-06-05-suspend-hibernate-design.md`.
  Plan: `docs/superpowers/plans/2026-06-05-suspend-hibernate.md`.

- **2026-05-30** — Dark text on colored pills, including through animations,
  AND the deployment-path fix that made the CSS change actually visible.
  Two threads:
  (a) **Text color:** icon glyphs on `win-close` (opt-no red), `win-minimize`
  (opt-middle yellow), and any pin pill (opt-pin-violet/green/orange) were
  showing white during their hover beats / pin animations — the pastels are
  too bright for white text to read. `style.css` now: state-pill rules
  (`.opt-yes/.opt-middle/.opt-no`) set `color: @opt-text-on-light` +
  `text-shadow: none` directly on the box (was label-only — the previous
  rule didn't cascade reliably to custom-module glyphs); keyframes
  `opt-pulse-orange/red/blue`, `opt-glow-green`, `opt-breathe-violet/blue`
  hold text at `@opt-text-on-light` at peak (was `#ffffff`; only
  `opt-glow-yellow` was already right); `opt-pin-violet/green/orange`
  children switched from `color: #ffffff` to `color: @opt-text-on-light`.
  Rule: if the pill is colored — state, pin, or hover-borrowed during an
  animation peak — text reads as dark.
  (b) **Deploy path:** while debugging (a) I edited style.css and restarted
  waybar twice with no visible change. Cause: `~/.config/waybar/style.css`
  was a symlink to a copy in `/nix/store/*-hm_style.css`, not to the source.
  `xdg.configFile.<>.source = cfg.styleSource` in `modules/waybar.nix` was
  COPYING the source into the store at activation, so `nixos-rebuild switch`
  was a hidden prerequisite for any CSS edit. Fixed declaratively: wrapped
  both `xdg.configFile."waybar/config.jsonc".source` and `…/style.css.source`
  in `config.lib.file.mkOutOfStoreSymlink`. Now the symlinks resolve
  DIRECTLY to `/etc/nixos/home/waybar/*` and edit-then-restart is enough.
  *Hint:* `readlink -f ~/.config/waybar/style.css` should print
  `/etc/nixos/home/waybar/style.css`. If it ever prints a `/nix/store/*`
  path again, `mkOutOfStoreSymlink` got removed from waybar.nix — restore
  it before iterating, or every CSS edit silently no-ops until rebuild.
  Module header has a long "IMPORTANT — out-of-store symlinks" note;
  `CLAUDE.md` → "Build / activate / verify" warns about the symlink check.
  No new tokens; closed budget intact for the visual change.

- **2026-05-28** — opt-pushed redesign: no hard border, soft inset shadow
  on the rest face. The earlier "darker surface + 1 px sharp inset border"
  combo painted a black stamp over each pushed pill's identity (state
  colors muddied behind it, ws-current and shader pills looked framed
  rather than pressed). Replaced with `box-shadow: inset 0 2px 5px
  rgba(0,0,0,0.35)` only — pill keeps rest face, gains a gentle pressed-in
  shadow. State colors (opt-pushed.opt-yes/middle/no) now show their blue/
  yellow/red while still reading as pressed. Hover composes cleanly via a
  two-stop box-shadow (soft shadow + bright overlay).
  *Hint:* dropped `@opt-pushed-surface` and `@opt-pushed-border` tokens
  (no longer referenced); added `@opt-pushed-shadow` (the rgba used in
  rest + hover composition). The closed budget shrinks from
  "6 colors + 4 motions + 2 surfaces + 1 border" to
  "6 colors + 4 motions + 2 surfaces" — no hard borders anywhere in
  OPTIONS now. Rule 3 phrasing updated across README / CLAUDE.md /
  ARCHITECTURE.md / standard-os skill.

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
