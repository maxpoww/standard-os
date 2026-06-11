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
