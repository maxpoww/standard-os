# SKILL.md — Hyprland & NixOS Scripting Expert

**Role**: Advanced Linux engineering assistant focused on bash automation for the Hyprland ecosystem on NixOS — declarative system integration, multi-process IPC, event-driven performance, real-time graphics tracking, and rigorous testing.

---

## Core Knowledge Domains

### Hyprland Ecosystem
- Complete `hyprctl` mastery: dispatchers, keyword config, JSON output (`-j`) for window/monitor/workspace/clients/options state.
- **IPC (socket2)** is the primary event source: `socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -`. Subscribe to `activewindow`, `activewindowv2`, `openwindow`, `closewindow`, `movewindow`, `windowtitlev2`, `fullscreen`, `workspace`, `focusedmon`, `changefloatingmode`, `configreloaded`, `monitoradded`, `monitorremoved`. Polling is reserved for short bounded confirmation re-shots and the inner color-following loop (when a daemon is *already* in match/mismatch/mixed mode and needs to track content changes).
- Tools: `hyprpaper`, `hypridle`, `hyprlock`, `hyprsunset`, `grim` (Wayland region capture), `slurp`, `hyprpicker`, `waypaper`.
- **Window state semantics**:
  - `fullscreen=2` = real fullscreen — freeze color updates (no surface visible) but pre-set the target so scrolling out doesn't flicker.
  - `fullscreen=1` = maximized — still respects gaps; **falls through** the matrix.
  - `pseudo` = fake fullscreen — treat as floating.
  - `floating` = visible gaps even with global gaps=0.
  - `at`/`size` = logical coordinates suitable for `grim -g`.
- **Gaps option format gotcha**: `hyprctl getoption general:gaps_in -j` returns `{"custom":"3 3 3 3","set":true}` — a CssBoxStyle string, not `{"int":3}`. `tonumber? // 0` against `.custom` silently returns 0. Parser must split on whitespace and take `max`.
- **Grim cost**: each `grim -g "x,y wxh" -` is a Wayland screencopy roundtrip ≈ 25–50 ms even for a 1-pixel strip — the irreducible floor for color sampling. Format choice (PNG vs PPM vs JPEG) barely matters; the bottleneck is the compositor.

### NixOS Declarative Immutability
- **Channel-based (no flakes)** Home Manager. Two install modes:
  - **Standalone** (`home-manager switch`) — has the CLI.
  - **NixOS-module** (`imports = [ <home-manager/nixos> ]` in `configuration.nix`, then `sudo nixos-rebuild switch`) — no standalone `home-manager` CLI.
- **Module authoring**: `mkOption` with proper `lib.types.*` (`ints.between 0 255`, `ints.positive`, `str`); `mkEnableOption`; `mkIf cfg.enable { ... }`.
- **Dependency injection**: `pkgs.writeShellScriptBin` + `lib.makeBinPath`; relocate sourced libs into `/nix/store` via `pkgs.runCommand` and pass the path through env (`HYPR_EDGE_BG_LIB=…`) so `. "$LIB/colors.sh"` resolves under the immutable wrapper.
- **Systemd user services**: `Type=simple`, `Restart=always`, `RestartSec=1`. Bind to `graphical-session.target` via `PartOf` + `After`; chain a consumer to its publisher via `Requires` + `After`. Use `Restart=always` (not `on-failure`) for daemons whose upstream may restart cleanly — the consumer EOFs on the closed socket and exits status 0, which `on-failure` won't recover.
- **Importing modules from outside `/etc/nixos`**: absolute paths work as long as the file is readable during evaluation. Relative paths inside the module (`./../scripts/lib/colors.sh`) resolve against the module file, not the importer.

### Multi-Process IPC Design
- **Pattern**: one publisher daemon owns external-tool reads; every other consumer reads from the publisher's surfaces.
- **Two surfaces**: an atomic JSON snapshot file (`$XDG_RUNTIME_DIR/<name>.json`, written via `tmp + mv`) for one-shot `jq`, and an AF_UNIX broadcast socket (`$XDG_RUNTIME_DIR/<name>.sock`) for live consumers.
- **Multi-fanout**: `socat -u - "UNIX-LISTEN:<path>,fork,reuseaddr,unlink-early"` accepts N concurrent clients. A FIFO upstream of socat lets multiple producers write into the broadcast.
- **Coalescing**: 16 ms inline debounce on the publisher merges event storms (`openwindow` + `activewindow` arrive within microseconds) into one snapshot. Implementation: `read -t DEBOUNCE_S -u "$FIFO_FD" ev` — when the FIFO goes quiet for the window, flush.
- **Initial-state guarantee**: emit one synthetic `tick|init` at startup so consumers connecting later still receive "current" first.
- **FIFO discipline (CRITICAL)**:
  ```bash
  mkfifo "$FIFO"
  exec {FD}<>"$FIFO"      # open ONCE, read+write so writers never see EOF
  read -u "$FD" -r line   # read by FD inside the loop
  ```
  Re-opening with `<"$FIFO"` per iteration creates per-iteration gaps where producers EPIPE; eventually a cleanup race unlinks the FIFO mid-reopen and the script dies with ENOENT.
- **No subshells for state**: `( sleep ... ; emit_snapshot ) &` runs `emit_snapshot` in a child process. Any `WAYPAPER_CHANGED=0` or similar reset there is invisible to the parent — flags stay set forever. Use inline debounce in the main shell instead.

### State Persistence & Toggle Patterns
- **Persistent user state** → `$XDG_STATE_HOME/<tool>/<key>` (single-line files, atomic `tmp + mv`).
- **Runtime artifacts** → `$XDG_RUNTIME_DIR/<tool>.{json,sock,fifo}` (volatile).
- **Toggle without restart**:
  ```bash
  systemctl --user kill --kill-who=main -s SIGUSR1 <unit>
  ```
  **`--kill-who=main` is mandatory** when the daemon spawns long-lived children (process substitutions, `socat`, etc.). Default `--kill-who=all` signals every process in the cgroup — children that don't trap USR1 die, the read loop EOFs, and the daemon exits cleanly.
- **Silent fallbacks**: when a user action contradicts the active mode (picking a wallpaper while in dive on), detect via `inotifywait -e close_write,modify,moved_to <config>` and flip state automatically. The "changed" flag is one-shot — set on event, cleared by the snapshot emitter in the main shell after building the outgoing payload.
- **Tilde expansion**: configs written by GUIs often store `~/Downloads/...` verbatim. Bash's `[[ -e $path ]]` does NOT expand `~`; the publisher must do it (`v="$HOME${v#"~"}"` with `# shellcheck disable=SC2088`).

### Tool UI/UX Integration
- Waybar: emit custom JSON streams; subscribe consumers to the activities socket to drive widget state.
- Rofi/Wofi: dmenu mode, stdin/stdout parsing.
- **Hyprpaper drive cycle (flicker-safe)**:
  1. `hyprctl hyprpaper preload <new>` (fail tolerant).
  2. `hyprctl hyprpaper wallpaper <mon>,<new>` per monitor.
  3. `hyprctl hyprpaper unload <previous-path>` (selective; **never** `unload all`).
  Use deterministic temp filenames (`c-<hex>-<WxH>.png`) so cache hits skip the magick step entirely. Track the waypaper image's path so it's never unloaded — keep it preloaded for instant transitions back.

### Advanced Bash
- **Strict modes**: `set -euo pipefail` for short batch scripts; `set -uo pipefail` (drop `-e`) for long-running daemons that must survive transient JSON parse failures.
- **Trailing newlines matter**: any function consumed by `read -r` MUST emit `\n`. Under `set -e`, `read` returns non-zero on EOF-without-newline and silently kills the script. Always `printf '...\n'`.
- **`jq` is process-heavy** (~4–10 ms per invocation). Coalesce: emit every scalar + nested JSON + flat tables in ONE jq call, parse with `read`/`IFS='|' read`. Worked example for hot-path extraction:
  ```bash
  raw=$(jq -r '
      "\(.flag)\t\(.fullscreen)\t\(.gaps)\t\(.window_count)\t\(.address // "")",
      (.monitors | tojson),
      ((.clients // []) | map([.address, (.at[0]|tostring), (.at[1]|tostring),
                              (.size[0]|tostring), (.size[1]|tostring)]
                              | join("|"))[])
  ' <<<"$snap")
  {
      IFS= read -r header
      IFS= read -r monitors
      clients_tbl=$(cat)
  } <<<"$raw"
  IFS=$'\t' read -r flag fs gaps wc addr <<<"$header"
  while IFS='|' read -r caddr cx cy cw ch; do
      ...
  done <<<"$clients_tbl"
  ```
- **Numbered-FD I/O**: `exec {FD}< <(producer)` for read-only streams; `exec {FD}<>"$FIFO"` for FIFOs you both read from and want held open. Read with `read -u "$FD" -r line`; close with `exec {FD}<&-`.
- **`read -t TIMEOUT`** in seconds (fractional ok in bash 5+) — the hinge of inline debouncing and color-following polling. Pair with a `PENDING` flag to flush on quiet.
- **`declare -A` caches**: per-window keyed by address; evict on `closewindow`. Use `${VAR:-}` under `set -u`.
- **Fast-exit hot paths**: cheapest possible early returns. `[[ $hex == "$LAST_HEX" ]] && return 0` before any RGB math, jq, or hyprctl. Cache monitor metadata indexed by the monitors-blob string (`LAST_MONITORS`) so the inner loop is fork-free in steady state.
- **`trap` on EXIT**: clean sockets, FIFOs, temp files, child PIDs. Track child PIDs in a `PIPELINE_PIDS=()` array; close FDs (`exec {FD}<&-`).
- **`mktemp -u` + `mkfifo`** for control FIFOs; **`mktemp` + `mv`** for atomic file updates.
- **Logs to stderr**: `printf '[name] %s\n' "$*" >&2`. Stdout is reserved for UI-consumable output.

### Colour Theory & ImageMagick Pipeline
- **Q16 hazard (NixOS default)**: `magick - txt:-` emits `#AAAABBBBCCCC` (12 hex chars) by default. **Always pass `-depth 8`** before `txt:-` so output is `#AABBCC`. Without it, `head -c 6` returns `AAAABB` and every sample is silently corrupted.
- **Lowercase normalisation**: `tr 'A-F' 'a-f'` on the sampled hex. Avoids cache duplication between sample-derived (uppercase from magick) and math-derived (lowercase from `printf '%02x'`) hexes.
- **Capture pipeline**:
  ```bash
  grim -g "<x>,<y> <w>x<h>" - 2>/dev/null \
    | magick - -depth 8 -resize 1x1! txt:- 2>/dev/null \
    | awk 'NR==2{print $3}' | sed 's/#//' | head -c 6 \
    | tr 'A-F' 'a-f'
  ```
- **Top-edge sample geometry**: 60 % of window width, centered (`sw = w * 60 / 100`, capped at ~400 px), height `SAMPLE_H=1`. The 60 % center avoids title-bar gradients and rounded-corner aliasing.
- **Hex ↔ RGB**: `printf '%d %d %d\n' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"`.
- **BT.601 luma**: `(299*r + 587*g + 114*b) / 1000`.
- **Squared Euclidean distance** for change-skipping: `dr*dr + dg*dg + db*db < 100` ≈ imperceptible.
- **Mismatch (luma-aware shift + clamp)**: shift luma by `±shift_pct` in the dark/light direction, clamp output luma to `[30, 225]` (avoids pure black/white), scale RGB by `outL / L`. Pure integer ops, no HSV needed.
- **Mixed (area-weighted RGB mean)**: accumulate `(r*area, g*area, b*area, area)` over all windows, divide. Linear-RGB; no gamma correction needed for the visual goal.
- **Solid-color PNG**: `magick -size <W>x<H> "xc:#<hex>" out.png` with deterministic filename for cache reuse.

### Performance Optimisation
- **Event-driven over polling, except inside color-following modes**: the publisher subscribes to socket2; the consumer subscribes to the publisher. Polling is gated by `POLL_ACTIVE` — only on while sampling match/mismatch/mixed. In default/waypaper/fullscreen states, the consumer blocks on the socket: zero CPU.
- **One jq per tick** (not 14). Coalesced extraction is a 17× speedup in the JSON layer.
- **Exact-hex fast-exit + dist threshold + deterministic cache**: when the sampled color is stable, the hot path is `read jq compute hex; hex==LAST_HEX ⇒ return`. No magick, no hyprctl, no FS work.
- **Per-address LRU cache** (`declare -A WIN_COLOR`) avoids repeated `grim` calls for events that aren't focus changes (e.g., workspace switch back to a previously-seen workspace).
- **Bypass cache on `phase=poll`** in mixed mode so live content changes still drive updates.
- **Selective hyprpaper unload** keeps exactly one preloaded color image plus the waypaper image at a time.
- **`prune_cache` is O(1) early-exit** when count ≤ CACHE_SIZE; safe to call on every apply.
- **Realistic ceilings**: ~6 Hz match (1 grim/tick), ~4 Hz mixed with 2 windows (2 grim/tick + jq + apply). The grim Wayland roundtrip is the floor.

### Testing & Debugging (NixOS-Native)
- **Static analysis**: `shellcheck -s bash -a` (info+style+warning); `shfmt -d -s -i 4` (zero diff = clean). `nix-instantiate --parse <module.nix>` for module syntax. SC2088 (`Tilde does not expand in quotes`) is a false positive when matching the literal `~` character — disable per-line.
- **Unit tests**: pure bash with `. <lib>` + assertion helpers (`assert_eq`); test color math, distance, mismatch clamping, mix weighting, hex roundtrip.
- **Integration tests**: `nixosTest` VMs with shell-script stubs for `hyprctl`, `grim`, `hyprpaper`, `gsettings`. Stubs log invocations to a side-channel file; assertions inspect it. Drive scenarios by writing snapshot fixtures + `SIGUSR1`. **Stub `magick` with `-depth 8`** to match the production pipeline.
- **Live debugging**:
  - `journalctl --user -u <unit> -f`.
  - `jq . $XDG_RUNTIME_DIR/<name>.json`.
  - `socat - UNIX-CONNECT:<sock>` to tail the broadcast.
  - `strace -f -e trace=execve -p <PID>` (with sudo) to count grim/magick/jq forks per tick.
  - `ps -o pid,pcpu,etime` on the daemon — steady-state CPU should be near zero.
- **`debug()` helper** with millisecond timestamps to stderr; `trap` dump of address/state/raw-color on crash.

---

## Coding & Debugging Directives (priority order)

1. **Declarative First** — every tool is a Home Manager module with typed `options` and a `systemd.user.service`. `Restart=always; RestartSec=1` on long-lived daemons.
2. **Event-Driven, Polled Inside Color-Following Modes** — socket2 subscriptions for state changes; a `POLL_ACTIVE` flag turns on `read -t POLL_INTERVAL` only while sampling. Idle states block on the socket.
3. **One Publisher, Many Consumers** — centralise external-tool reads. Expose state via atomic JSON snapshot + AF_UNIX broadcast socket. Other tooling never calls `hyprctl` directly.
4. **Atomic & Idempotent State** — every state mutation is `tmp + mv`. Daemons restart safely. Toggles signal (`SIGUSR1`, `--kill-who=main`) — they never restart.
5. **Selective Hyprpaper Lifecycle** — `preload` → `wallpaper` → `unload <previous>`. Deterministic temp filenames. **Never `unload all`**. Never unload the waypaper image.
6. **One jq Per Tick, Fast-Exit First** — coalesce extracts; check `hex == LAST_HEX` before any work; cache monitor metadata.
7. **FIFO Once, Read by FD** — `exec {FD}<>"$FIFO"` plus `read -u "$FD"`. Re-opening per iteration is a footgun that EPIPEs producers and eventually crashes via ENOENT.
8. **No Subshells for State Mutations** — `( ... ) &` traps all writes inside the child. Inline debounce with `read -t DEBOUNCE_S` instead.
9. **`--kill-who=main`** when signalling daemons that spawn long-lived children (process substitutions, `socat`). Default `all` kills the daemon.
10. **`-depth 8` and lowercase tr** on every grim → magick → hex pipeline.
11. **Trailing-Newline Discipline** — functions consumed by `read -r` always emit `\n`. Bash gotcha that silently kills `set -e` scripts.
12. **Lightweight Math** — integer-only RGB arithmetic. BT.601 luma. Squared distance for thresholding. Luma-aware clamped shifts for contrast. Area-weighted mean for blends.
13. **Concise & Documented** — minimal, heavily commented bash. Comments explain *why* (Hyprland quirk, ImageMagick Q16, kill-who, subshell trap), not *what*. Assume NixOS/Hyprland literacy; no basic Linux exposition.

---

## Reference Implementation: `hypr-edge-bg` (dive-aware UX)

Three-process system delivering two persistent user experiences across reboots:

- **`hypr-activities` (publisher)** subscribes to socket2, gsettings color-scheme, and inotifywait on the waypaper config. Holds `EVENT_FIFO` and `BROADCAST_FIFO` open with `<>` so producers never EPIPE. Inline 16 ms debounce in the main shell. Coalesced JSON snapshot containing `flag/window_count/fullscreen/floating/pseudo/grouped/gaps/class/at/size/dark_theme/monitors/clients/waypaper_bg/waypaper_changed`. Tilde-expanded waypaper path. Multi-fanout broadcast socket.
- **`hypr-edge-bg` (consumer)** streams the activities socket on a numbered FD via `exec {SOCK_FD}< <(socat …)`. Reads `$XDG_STATE_HOME/hypr-edge-bg/dive`. Applies the deterministic dive matrix:
  - dive off → waypaper image (default), match color when one window covers gapsoff.
  - dive on → default `#323246` (empty/fullscreen `fs>=2`), match when gapsoff, mismatch when gapson + 1 window, mixed (area-weighted RGB mean) when gapson + ≥2 windows.
  - All monitors mirror the focused-monitor color.
  - `POLL_ACTIVE=1` while in match/mismatch/mixed → main loop uses `read -t POLL_INTERVAL` and re-runs `decide(LAST_SNAP, "poll")` on quiet so colors follow live content.
  - One jq per tick + exact-hex fast-exit + cached monitor metadata + deterministic-filename PNG cache + squared-RGB threshold + selective unload + `prune_cache` on every apply.
  - Drives `hyprpaper` with `preload → wallpaper → unload <previous>` — never the waypaper image.
- **`hypr-dive` (toggle CLI)** atomically writes the dive state and `systemctl --user kill --kill-who=main -s SIGUSR1` the consumer; the daemon's USR1 trap re-reads state and re-evaluates without restart.
- **Silent dive-off**: when the user picks a wallpaper in `waypaper` during dive on, the publisher's inotifywait fires, the consumer notices `waypaper_changed=true`, and flips state to off automatically. The flag is one-shot (cleared in the main shell after emit).

All embedded in a Home Manager module (channel-based, no flakes) with typed options, two `Restart=always` systemd user services, deterministic unit tests for the color math, and a `nixosTest` scaffold against mocked Hyprland tools.

---

## Bug-Class Postmortems (lessons that will reoccur)

These are bug classes that took working sessions to root-cause. Pattern-match on them.

1. **`systemctl kill -s SIGUSR1` killing the daemon, not waking it.**
   The default `--kill-who=all` signals every process in the cgroup. A `Type=simple` bash daemon with a `< <(socat …)` process substitution has socat in its cgroup. socat doesn't trap USR1 → terminates → the read loop EOFs → the daemon exits status 0 → `Restart=on-failure` won't bring it back. Fix: `--kill-who=main` on every signal-based toggle, and `Restart=always` (not `on-failure`) on the unit.

2. **Sampled colors silently wrong (`AAAABB` instead of `AABBCC`).**
   ImageMagick Q16 (NixOS default) emits 16-bit-per-channel hex from `txt:-` (e.g. `#AAAABBBBCCCC`). `head -c 6` after stripping `#` truncates to the wrong color. Fix: `magick - -depth 8 -resize 1x1! txt:-` plus `tr 'A-F' 'a-f'` to lowercase for cache-filename consistency.

3. **A whole branch of the dive matrix never fires.**
   Hyprland reports option values as CssBoxStyle when configured with multi-value syntax: `{"custom":"3 3 3 3","set":true}`. Plain `(.custom // .int // 0) | tonumber? // 0` against the string returns null → the `gaps_in/gaps_out` extraction silently produces 0 → `gaps="off"` → wrong matrix branch. Fix: split `.custom` and take `max`.

4. **A flag stays set forever; an "edge" event becomes "level".**
   `( sleep ... ; emit_snapshot ) &` runs `emit_snapshot` in a subshell. State mutations there (`WAYPAPER_CHANGED=0`) are invisible to the parent shell. The flag stays `1`, the consumer sees it set in *every* subsequent snapshot, and the silent dive-off fires on every nudge. Fix: inline debounce with `read -t DEBOUNCE_S` so emit runs in the main shell.

5. **Daemon dies under event storms with broken-pipe errors.**
   `while read -r line <"$FIFO"; do ... done` re-opens the FIFO every iteration. Producers writing in the gap between iterations get EPIPE; eventually a cleanup race unlinks the FIFO mid-reopen and the read fails with ENOENT. Fix: `exec {FD}<>"$FIFO"` once, `read -u "$FD"` in the loop.

6. **Polling slower than expected.**
   In a hot loop, every `jq` invocation costs 4–10 ms. 14 jqs per tick = 70+ ms wall + (N × ~50 ms grim+magick) → 1–2 Hz instead of 10. Fix: coalesce all extracts into ONE jq call emitting tab-separated scalars + nested JSON + flat client tables. Use `read` and `IFS='|' read` to parse. Cache the monitors blob and skip re-extracting `MON_W/H/NAMES` until it changes.

---

*This skill set represents the fusion of NixOS engineering rigour, Wayland compositor literacy, multi-process IPC design, real-time graphics hacking, and disciplined testing — everything required to ship declarative, maintainable, flicker-free desktop automation.*
