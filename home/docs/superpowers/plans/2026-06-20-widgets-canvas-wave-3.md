# Widgets Canvas — Wave 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every Wave 2 scaffold on the Dashboard canvas with real data sourced from purpose-built daemons (or, where the data already exists, a thin channel that exposes it). At the end of Wave 3 the canvas reads as the destination — no "ships in Wave 3" placeholder text anywhere — and the per-canvas CPU budget stays under 2 % with the canvas open.

**Architecture:** Six independent data streams, each owned by one daemon (or one Nix-managed extension of an existing daemon), all using the `/tmp/waybar-cache/` atomic-write + RTMIN-signal contract documented in `waybar/ARCHITECTURE.md`. The canvas (`widgets/eww/eww.yuck`) is the only consumer of these caches on the Dashboard surface; the bar consumes a subset for pillar 6 (notably `sys-*`). Each daemon is a long-running systemd-user unit with internal poll loops or event subscriptions — the canvas's `defpoll`s become cheap `cat` reads from disk, not shell-out chains. This buys us (a) suspended polls when the canvas is closed, paid once at daemon level rather than per-widget, and (b) shared truth between the bar and canvas for the streams that surface on both.

**Tech Stack:** bash + jq for the four shell daemons (`weather`, `pomodoro`, `notif-history-channel`, `system`); Rust extension to `notif-os-daemon` is OUT OF SCOPE for Wave 3 — `notif-os-daemon` already journals the history; Wave 3 only adds a shell channel that derives the canvas-facing cache from the existing JSONL. mpris-waybar truth is a wiring task on top of the in-progress `/home/max/mpris-waybar/` rewrite, not a rewrite itself. Eww 0.6.0 for canvas reads. Hyprland 0.52 signal infrastructure (`pkill -RTMIN+N waybar`) on the bar side. `inotifywait` (from `inotify-tools`) for the canvas's signal-aware reads of mpris and notif caches.

## Global Constraints

[Copied verbatim from `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md` §10, `2026-06-19-widgets-canvas-wave-2-design.md` §6 / §9, and `waybar/ARCHITECTURE.md` "Cache and signal table" / "Hazard checklist":]

- Every cache write is atomic: `tmp + mv -f` (waybar/CLAUDE.md hazard).
- Every RTMIN-signaled cache deduplicates at the writer — `pkill -RTMIN+N waybar` only fires when the new content differs from the previous bytes on disk.
- No `jq` / `awk` / `head` / `tr` fork-per-tick in hot loops. Bash builtins where possible.
- Class field, when emitted as JSON, is a JSON **array** (never a space-separated string).
- Every canvas-visible label inherits the dark veil → text is always white (`opt-text-on-dark` / `light` class). Glass-mode does NOT propagate to the canvas (shared spec §3, Rule 3).
- No new colors. No new motion verbs beyond the four already documented + the scoped `sun-pulse` admitted in Wave 2 §8.4.
- Canvas total CPU (with canvas open) stays under **2 %** on the reference laptop (i5-1235U) measured via `top -p $(pgrep eww)`.
- Daemon polls **continue when the canvas is closed** — the bar consumes `sys-*`, `mpris-*`, and `notif-history` even when the canvas isn't visible. The canvas-side polls suspend (Eww's `defpoll` does not run while the window is hidden), so the canvas pays nothing while closed.
- New daemons live under `/etc/nixos/home/scripts/` (existing daemons follow this pattern: `notif-daemon`, `hypr-context-daemon.sh`, `glass-text-daemon.sh`). Nix wiring lives in `/etc/nixos/home/modules/` as new `*.nix` files importable from `home/default.nix`.
- Every daemon registers in `waybar/ARCHITECTURE.md`'s "Daemon registry" table AND the "Cache and signal table" — same commit as the daemon ships.
- TODO.md cap is 6 (see `waybar/CLAUDE.md` → "TODO.md (the work map)"). When a Wave 3 task graduates a NEXT entry, it moves to DONE — not back through TODO.
- `nixos-rebuild switch`, NOT `test` (feedback memory: `test` activates in RAM only, reverts on reboot).
- `~/.config/eww/` is `mkOutOfStoreSymlink` → `/etc/nixos/home/widgets/eww/`. Eww yuck/scss edits are live; only `systemctl --user restart standardos-canvas.service` is needed.
- `~/.config/hypr/` modules are NOT live (frozen in /nix/store via home-manager). Hypr config edits need `nixos-rebuild switch` then `hyprctl reload`.
- StandardOS prose name. `OPTIONS` only as historical artifact in existing files / CSS classes.

---

## File Structure

[Decomposition lock: each daemon owns one or two files; each canvas integration touches eww.yuck data block + the widget def; no shared mutable state between daemon files.]

### Created

- `scripts/weather-daemon.sh` — long-running poll loop wrapping wttr.in (Open-Meteo as fallback). Writes `/tmp/waybar-cache/weather.json`. Signal: none — canvas re-reads on its own 60 s poll (weather doesn't move fast enough to justify push).
- `modules/weather-daemon.nix` — systemd-user wiring.
- `scripts/system-daemon.sh` — 2 s poll loop reading `/proc/loadavg`, `/proc/stat`, `/proc/meminfo`, `/sys/class/power_supply/BAT0/*`, `/sys/class/hwmon/*/temp1_input`, plus best-effort `nvidia-smi`/`radeontop`/`intel_gpu_top`. Writes `/tmp/waybar-cache/sys-{cpu,gpu,mem,battery,temp}`. Signal: RTMIN+18 on real-content change.
- `modules/system-daemon.nix` — systemd-user wiring.
- `scripts/notif-history-channel.sh` — inotify-driven derivation. Watches `~/.local/share/standard-os/notif-history.jsonl` (written by the existing Rust `notif-os-daemon`), tails the last N entries, writes `/tmp/waybar-cache/notif-history.json`. Signal: RTMIN+12 (shared with notif-daemon — Wave 2 §6 budget).
- `modules/notif-history-channel.nix` — systemd-user wiring.
- `scripts/pomodoro-daemon.sh` — state machine driven by a FIFO at `/run/user/$UID/standardos-pomodoro.fifo`. Writes `/tmp/waybar-cache/pomodoro.json`. Signal: RTMIN+19 (taken from the FREE pool in `waybar/ARCHITECTURE.md` — register in the same commit).
- `scripts/pomodoroctl` — thin CLI shim (`pomodoroctl {start|stop|skip|reset|status}`) writing into the FIFO. Lives next to `mprisctl` / `dictate-toggle` for muscle memory.
- `modules/pomodoro-daemon.nix` — systemd-user wiring.
- `scripts/cal-source-daemon.sh` — periodic ICS reader. Reads ICS files from `~/.config/standardos/calendars/*.ics` (any path globbed; user drops files here or symlinks remote-synced files). Writes `/tmp/waybar-cache/agenda.json` (next 8 events, today's count, next-upcoming offset minutes). Signal: RTMIN+20 (free pool).
- `modules/cal-source-daemon.nix` — systemd-user wiring.
- `scripts/lib/canvas-cache.sh` — shared cache primitives: `cache_write_atomic`, `cache_signal_if_changed`, `cache_read_or_default`. Pulled out so each Wave 3 daemon doesn't re-implement them. Pattern is identical to `waybar/scripts/lib/pill.sh`'s `pill_write`; this is the daemon-side variant (no waybar-class concerns).
- `tests/wave3/test_weather_daemon.sh` — TDD test for the weather daemon's parse-and-emit path (mocks `curl`).
- `tests/wave3/test_system_daemon.sh` — TDD test for the system daemon's read-and-emit path (fixture /proc files in $TMP).
- `tests/wave3/test_notif_history_channel.sh` — TDD test for the channel's JSONL → JSON derivation (fixture JSONL file).
- `tests/wave3/test_pomodoro_daemon.sh` — TDD test for the pomodoro state machine (driving via temp FIFO).
- `tests/wave3/test_cal_source_daemon.sh` — TDD test for the ICS reader (fixture .ics file).
- `tests/wave3/test_canvas_cache_lib.sh` — TDD test for the shared cache primitives.

### Modified

- `widgets/eww/eww.yuck` — replaces several `defpoll`s that shell out to scaffold scripts with `defpoll` reads of cache files (`cat /tmp/waybar-cache/<n> | jq -r '.<field>'`). Also adds new `defpoll`s for agenda, pomodoro, notif-history. Removes the "ships in Wave 3" placeholder labels from the four scaffold widgets; the widgets themselves stay; the conditional-empty paths now key on real data.
- `widgets/eww/eww.scss` — adds the few new classes needed (`field-agenda-event`, `field-notif-row`, `field-pom-running`, etc.) and removes the `.field-empty` styles that were only used by the four "ships in Wave 3" labels.
- `widgets/scripts/canvas-weather.sh` — DELETED (replaced by daemon + cache).
- `widgets/scripts/canvas-cpu.sh`, `canvas-gpu.sh`, `canvas-mem.sh`, `canvas-disk.sh` — DELETED (replaced by `system-daemon` + cache).
- `widgets/scripts/canvas-media.sh` — DELETED (replaced by mpris-waybar truth integration).
- `waybar/ARCHITECTURE.md` — Daemon-registry rows added for `weather-daemon`, `system-daemon` (already declared planned; mark shipped), `notif-history-channel`, `pomodoro-daemon`, `cal-source-daemon`. Signal table rows for RTMIN+18, +19, +20.
- `waybar/TODO.md` — Wave 3 graduation DONE entry; `system-daemon RTMIN+18` and `Network daemon` etc. on NEXT untouched unless explicitly graduated; `todonow.md` Wave 3 line moves from TODO to DONE.
- `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md` — §4 catalog notes that Wave 3 ships the listed daemons; §8 (Wave plan sketch) Wave 3 line strikes-through; §10 verification adds two new bullets for cache freshness + budget.
- `home/default.nix` (or wherever modules import) — imports the five new `modules/*.nix`.

### Untouched (explicit no-ops, to avoid scope creep)

- `notif-os-daemon` Rust source — Wave 3 only adds a shell channel reading the journal it already writes.
- The bar's existing per-pill behavior — `system-daemon` cache also feeds future bar pills, but Wave 3 does NOT add those pills. They're already on NEXT and graduate separately.
- mpris-waybar's internal architecture — Wave 3 consumes whatever cache the rewrite settles on. The integration task documents the cache filenames it expects; if those names drift during the rewrite, the integration commit picks them up.

---

## Task 1: Shared cache primitives library

A small bash library that every Wave 3 daemon sources. Ship this first so subsequent tasks can rely on `cache_write_atomic` and `cache_signal_if_changed` without re-deriving the pattern.

**Files:**
- Create: `scripts/lib/canvas-cache.sh`
- Test:   `tests/wave3/test_canvas_cache_lib.sh`

**Interfaces:**
- Consumes: nothing (pure bash + coreutils + procps for `pkill`).
- Produces:
  - `cache_write_atomic <abs-path> <content-string>` — writes to `<abs-path>.tmp.$$` then `mv -f` to `<abs-path>`. Returns 0 on success, non-zero on failure (which the daemon SHOULD log and continue).
  - `cache_signal_if_changed <abs-path> <new-content> <signal-num>` — writes `<new-content>` to `<abs-path>` atomically only if it differs from the existing file's bytes; if changed, `pkill -RTMIN+<signal-num> waybar` (silently, `2>/dev/null || true`). The dedup is the central anti-CPU-burn pattern (mpris regression at 130 % CPU prior to this; see `waybar/CLAUDE.md` "Known hazards").
  - `cache_read_or_default <abs-path> <default-string>` — `cat`s the file; if absent or unreadable, echoes the default. Always exits 0.

- [ ] **Step 1: Write the failing test (cache_write_atomic)**

Create `tests/wave3/test_canvas_cache_lib.sh`:

```bash
#!/usr/bin/env bash
# test_canvas_cache_lib — unit tests for scripts/lib/canvas-cache.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/lib/canvas-cache.sh"
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((pass++))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((fail++))
    fi
}

# --- cache_write_atomic ---
TARGET="$TMP/foo.json"
cache_write_atomic "$TARGET" '{"a":1}'
check "write_atomic creates file" "$(cat "$TARGET")" '{"a":1}'

cache_write_atomic "$TARGET" '{"a":2}'
check "write_atomic overwrites" "$(cat "$TARGET")" '{"a":2}'

# No partial .tmp file left over
check "write_atomic cleans tmp" \
    "$(ls "$TMP"/*.tmp.* 2>/dev/null | wc -l)" "0"

# --- cache_read_or_default ---
check "read existing" "$(cache_read_or_default "$TARGET" 'fallback')" '{"a":2}'
check "read missing → default" \
    "$(cache_read_or_default "$TMP/does-not-exist" 'fallback')" 'fallback'

# --- cache_signal_if_changed (no signal counted; just file behavior) ---
SIG_TARGET="$TMP/sig.json"
cache_write_atomic "$SIG_TARGET" 'A'
# Same content → no write side-effect we can observe other than mtime; mtime
# IS the observable: if cache_signal_if_changed skips on equal content, mtime
# stays. If it writes, mtime advances.
orig_mtime=$(stat -c %Y "$SIG_TARGET")
sleep 1.1  # advance clock past 1 s mtime granularity floor
cache_signal_if_changed "$SIG_TARGET" 'A' 99 >/dev/null 2>&1 || true
new_mtime=$(stat -c %Y "$SIG_TARGET")
check "signal_if_changed: equal content → no rewrite" \
    "$new_mtime" "$orig_mtime"

cache_signal_if_changed "$SIG_TARGET" 'B' 99 >/dev/null 2>&1 || true
check "signal_if_changed: new content → file updated" \
    "$(cat "$SIG_TARGET")" "B"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run the test, see it fail**

```
bash /etc/nixos/home/tests/wave3/test_canvas_cache_lib.sh
```

Expected: error from `source` because the library does not exist yet.

- [ ] **Step 3: Implement `scripts/lib/canvas-cache.sh`**

```bash
#!/usr/bin/env bash
# canvas-cache.sh — shared cache primitives for Wave 3 canvas daemons.
#
# Source from any daemon: `source /etc/nixos/home/scripts/lib/canvas-cache.sh`.
# Provides three functions:
#
#   cache_write_atomic <abs-path> <content>
#       Atomic write via tmp + mv -f. Avoids half-written-file races
#       (a waybar/eww reader picking up an empty file mid-write).
#
#   cache_signal_if_changed <abs-path> <new-content> <signal-num>
#       Writes only when <new-content> differs from on-disk bytes;
#       fires `pkill -RTMIN+<signal-num> waybar` on change. The dedup
#       is the central anti-CPU-burn pattern (see waybar/CLAUDE.md
#       "Known hazards" — the mpris 130 % CPU regression).
#
#   cache_read_or_default <abs-path> <default>
#       cat or default. Always exits 0 — never propagates a missing
#       file as a script failure (defpoll would emit empty otherwise).
#
# Hazards:
#   - The tmp file uses $$ + a per-call counter so concurrent writes
#     from the same daemon don't race each other (a single daemon
#     should not call this concurrently, but the safety is cheap).
#   - mv -f on the same filesystem is atomic on Linux ext4/btrfs/xfs;
#     /tmp/waybar-cache/ MUST be on the same filesystem as the tmp
#     write target. tmpfs on /tmp covers this on a standard NixOS box.

_CANVAS_CACHE_COUNTER=0

cache_write_atomic() {
    local target="$1"
    local content="$2"
    _CANVAS_CACHE_COUNTER=$((_CANVAS_CACHE_COUNTER + 1))
    local tmp="${target}.tmp.$$.${_CANVAS_CACHE_COUNTER}"
    printf '%s' "$content" > "$tmp" || return 1
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    return 0
}

cache_signal_if_changed() {
    local target="$1"
    local new="$2"
    local sig="$3"
    local existing=""
    if [[ -r "$target" ]]; then
        existing="$(cat "$target" 2>/dev/null || true)"
    fi
    if [[ "$existing" == "$new" ]]; then
        return 0
    fi
    cache_write_atomic "$target" "$new" || return 1
    pkill -RTMIN+"$sig" waybar 2>/dev/null || true
    return 0
}

cache_read_or_default() {
    local target="$1"
    local fallback="$2"
    if [[ -r "$target" ]]; then
        cat "$target" 2>/dev/null || printf '%s' "$fallback"
    else
        printf '%s' "$fallback"
    fi
}
```

- [ ] **Step 4: Run the test, see it pass**

```
bash /etc/nixos/home/tests/wave3/test_canvas_cache_lib.sh
```

Expected: `Results: 6 passed, 0 failed`. Exit 0.

- [ ] **Step 5: Commit**

```
cd /etc/nixos/home && git add scripts/lib/canvas-cache.sh tests/wave3/test_canvas_cache_lib.sh && git commit -m 'wave3: shared cache primitives for canvas daemons (Wave 3 Task 1)'
```

---

## Task 2: weather-daemon — replace canvas-weather.sh defpoll

Long-running daemon that polls wttr.in every 10 minutes (matching the existing defpoll interval) and writes `/tmp/waybar-cache/weather.json`. Canvas reads via cheap `cat` instead of curl-on-every-canvas-open.

The shape of the JSON is what eww's existing weather-cond / weather-temp / weather-hi / weather-lo / weather-hum reads expect. Today they parse a `|`-separated string; this task changes them to `jq` reads against the new JSON object so future fields are non-positional.

**Files:**
- Create: `scripts/weather-daemon.sh`, `modules/weather-daemon.nix`
- Modify: `widgets/eww/eww.yuck:44-52` (weather-raw defpoll), `home/default.nix` (import module), `widgets/scripts/canvas-weather.sh` (DELETE)
- Test:   `tests/wave3/test_weather_daemon.sh`

**Interfaces:**
- Consumes: `scripts/lib/canvas-cache.sh` from Task 1.
- Produces:
  - `/tmp/waybar-cache/weather.json` shape:
    ```json
    { "cond": "clear",
      "temp": "14°C",
      "hi": "18",
      "lo": "6",
      "hum": "32%",
      "city": "Mendoza",
      "fetched": 1718908234 }
    ```
  - `cond` ∈ `{ clear, partly-cloudy, cloudy, rain, snow, storm, clear-night }`.
  - `fetched` is unix epoch of the last successful fetch; canvas uses this to detect staleness (>1 h old → fall back to placeholder, don't paint misleading "current" data).

- [ ] **Step 1: Write the failing test**

Create `tests/wave3/test_weather_daemon.sh`:

```bash
#!/usr/bin/env bash
# test_weather_daemon — unit tests for weather-daemon.sh's parse + emit.
# Mocks `curl` via a function override; runs the daemon's one_fetch()
# function (sourced via WEATHER_DAEMON_LIB_ONLY=1) and inspects the
# JSON it would emit.
set -euo pipefail

DAEMON="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/weather-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Library-mode source: should define one_fetch + condition_canonicalize
# without entering the poll loop.
WEATHER_DAEMON_LIB_ONLY=1 source "$DAEMON"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((pass++))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((fail++))
    fi
}

# Override curl with a function that emits a fixture per URL.
curl() {
    case "$*" in
        *"format=%C"*) printf 'Partly cloudy|+18°C|45|Mendoza, AR\n' ;;
        *"format=j1"*) printf '{"weather":[{"maxtempC":"22","mintempC":"9"}]}\n' ;;
        *) return 7 ;;
    esac
}
export -f curl

# --- canonicalize ---
check "canonicalize clear"          "$(condition_canonicalize 'Clear')"               "clear"
check "canonicalize partly cloudy"  "$(condition_canonicalize 'Partly cloudy')"       "partly-cloudy"
check "canonicalize rain"           "$(condition_canonicalize 'Light rain shower')"   "rain"
check "canonicalize snow"           "$(condition_canonicalize 'Light snow')"          "snow"
check "canonicalize storm"          "$(condition_canonicalize 'Thunderstorm')"        "storm"
check "canonicalize unknown→clear"  "$(condition_canonicalize 'Volcanic ash plume')"  "clear"

# --- one_fetch (full integration with mocked curl) ---
out="$(STANDARDOS_WEATHER_CITY=Mendoza one_fetch)"
check "one_fetch returns JSON cond"  "$(printf '%s' "$out" | jq -r .cond)"  "partly-cloudy"
check "one_fetch returns JSON temp"  "$(printf '%s' "$out" | jq -r .temp)"  "+18°C"
check "one_fetch returns JSON hi"    "$(printf '%s' "$out" | jq -r .hi)"    "22"
check "one_fetch returns JSON lo"    "$(printf '%s' "$out" | jq -r .lo)"    "9"
check "one_fetch returns JSON hum"   "$(printf '%s' "$out" | jq -r .hum)"   "45%"
check "one_fetch returns JSON city"  "$(printf '%s' "$out" | jq -r .city)"  "Mendoza"

# --- one_fetch failure (curl exit 7) ---
curl() { return 7; }
export -f curl
out="$(one_fetch || true)"
check "fetch failure returns empty"  "$out"  ""

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run the test, see it fail**

```
bash /etc/nixos/home/tests/wave3/test_weather_daemon.sh
```

Expected: `source` failure (daemon script does not exist).

- [ ] **Step 3: Implement `scripts/weather-daemon.sh`**

```bash
#!/usr/bin/env bash
# weather-daemon — fetch current weather from wttr.in, cache as JSON.
#
# Replaces widgets/scripts/canvas-weather.sh, which was an eww defpoll
# shell-out. Wave 3 moves the poll into a long-running systemd-user
# service so the cache is fresh whether or not the canvas is open
# (the bar may surface weather as a pillar-6 pill in a future wave),
# and so the canvas's defpoll becomes a cheap `cat | jq -r`.
#
# Cache:  /tmp/waybar-cache/weather.json
# Signal: none (the canvas re-reads on its own 60 s defpoll; weather
#         doesn't move fast enough to justify pushing to waybar).
#
# Library mode: `WEATHER_DAEMON_LIB_ONLY=1 source weather-daemon.sh`
# defines one_fetch + condition_canonicalize without entering the
# loop, so tests can drive them with a mocked curl.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CACHE=/tmp/waybar-cache/weather.json
mkdir -p "$(dirname "$CACHE")"

POLL_INTERVAL="${WEATHER_POLL_INTERVAL:-600}"
CITY="${STANDARDOS_WEATHER_CITY:-Mendoza}"

condition_canonicalize() {
    # wttr.in condition strings → canonical codes for the canvas's
    # illustration set. Order matters: "Light snow" must match snow
    # before any "cloudy"-substring rule.
    local raw="${1,,}"  # lowercase
    case "$raw" in
        *thunder*|*storm*)   echo storm ;;
        *snow*|*sleet*)      echo snow ;;
        *rain*|*shower*|*drizzle*) echo rain ;;
        *partly*cloudy*)     echo partly-cloudy ;;
        *overcast*|*cloudy*) echo cloudy ;;
        *clear*|*sunny*)
            # Day vs night: check current hour. wttr.in doesn't tell us
            # directly; rely on local clock as good-enough.
            local h
            h=$(date +%-H)
            if (( h < 7 || h >= 20 )); then echo clear-night
            else echo clear
            fi
            ;;
        *) echo clear ;;  # unknown — safe default
    esac
}

one_fetch() {
    # Two endpoints: %C|%t|%h|%l for the current observation, ?format=j1
    # for the day's hi/lo. Both have --max-time guards to keep the
    # daemon responsive on flaky networks.
    local raw
    raw=$(curl -fsS --max-time 10 \
          "https://wttr.in/${CITY}?format=%C|%t|%h|%l" 2>/dev/null) || return 1

    local cond_text temp hum loc
    IFS='|' read -r cond_text temp hum loc <<<"$raw"

    local forecast hi lo
    forecast=$(curl -fsS --max-time 6 \
               "https://wttr.in/${CITY}?format=j1" 2>/dev/null) || forecast=""
    hi=$(printf '%s' "$forecast" | jq -r '.weather[0].maxtempC // "—"' 2>/dev/null || echo "—")
    lo=$(printf '%s' "$forecast" | jq -r '.weather[0].mintempC // "—"' 2>/dev/null || echo "—")

    local cond
    cond=$(condition_canonicalize "$cond_text")

    jq -n \
       --arg cond "$cond" \
       --arg temp "$temp" \
       --arg hi   "$hi" \
       --arg lo   "$lo" \
       --arg hum  "${hum}%" \
       --arg city "${loc%%,*}" \
       --argjson fetched "$(date +%s)" \
       '{cond:$cond, temp:$temp, hi:$hi, lo:$lo, hum:$hum, city:$city, fetched:$fetched}'
}

[[ -n "${WEATHER_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ───────────────────────────────────────────────────────
while true; do
    out=$(one_fetch) || out=""
    if [[ -n "$out" ]]; then
        # No signal — canvas defpoll re-reads on its own cadence.
        cache_write_atomic "$CACHE" "$out"
    fi
    sleep "$POLL_INTERVAL"
done
```

`chmod +x` the file.

- [ ] **Step 4: Run the test, see it pass**

```
chmod +x /etc/nixos/home/scripts/weather-daemon.sh
bash /etc/nixos/home/tests/wave3/test_weather_daemon.sh
```

Expected: all PASS, exit 0.

- [ ] **Step 5: Write the Nix module**

Create `modules/weather-daemon.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.weatherDaemon;
in
{
  options.services.weatherDaemon = {
    enable = lib.mkEnableOption "StandardOS weather daemon (canvas weather.json)";

    city = lib.mkOption {
      type = lib.types.str;
      default = "Mendoza";
      description = "City passed to wttr.in.";
    };

    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Seconds between fetches.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.weather-daemon = {
      Unit = {
        Description = "StandardOS weather daemon (canvas weather.json)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "STANDARDOS_WEATHER_CITY=${cfg.city}"
          "WEATHER_POLL_INTERVAL=${toString cfg.pollInterval}"
          "PATH=${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.bash}/bin:${pkgs.coreutils}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/weather-daemon.sh";
        Restart = "always";
        RestartSec = "10";
      };
    };
  };
}
```

- [ ] **Step 6: Wire the module + enable it**

Find the home.nix that imports `widgets-canvas.nix` (the canvas module). Add `./modules/weather-daemon.nix` to the imports list, and add `services.weatherDaemon.enable = true;` to the config block.

```
grep -rln 'widgets-canvas.nix\|services.standardosCanvas' /etc/nixos/home/*.nix /etc/nixos/home/modules/*.nix 2>/dev/null
```

Identify the consumer. Most likely `/etc/nixos/home/home.nix` or similar. Add the import + enable next to the canvas-enable line.

- [ ] **Step 7: Update canvas yuck to read the cache**

Edit `widgets/eww/eww.yuck` — replace the existing weather-raw defpoll block:

```yuck
;; Weather — wttr.in defpoll, pipe-separated output. 10 minutes is plenty.
(defpoll weather-raw
  :interval "600s"
  :initial "clear|—°|—|—|—%"
  `/etc/nixos/home/widgets/scripts/canvas-weather.sh`)

;; Parse the pipe-separated values via Eww's string ops.
(defvar weather-cond-default "clear")
;; index 0..4 = COND, TEMP, HI, LO, HUM
```

With the new cache-driven block:

```yuck
;; Weather — daemon writes /tmp/waybar-cache/weather.json; canvas reads
;; the parsed fields via jq on a 60 s cadence. Daemon: services.weatherDaemon
;; (modules/weather-daemon.nix). Wave 3 Task 2.
(defpoll weather-cond :interval "60s" :initial "clear"
  `jq -r '.cond  // "clear"' /tmp/waybar-cache/weather.json 2>/dev/null || echo clear`)
(defpoll weather-temp :interval "60s" :initial "—°"
  `jq -r '.temp  // "—°"' /tmp/waybar-cache/weather.json 2>/dev/null || echo "—°"`)
(defpoll weather-hi   :interval "60s" :initial "—"
  `jq -r '.hi    // "—"' /tmp/waybar-cache/weather.json 2>/dev/null || echo —`)
(defpoll weather-lo   :interval "60s" :initial "—"
  `jq -r '.lo    // "—"' /tmp/waybar-cache/weather.json 2>/dev/null || echo —`)
(defpoll weather-hum  :interval "60s" :initial "—%"
  `jq -r '.hum   // "—%"' /tmp/waybar-cache/weather.json 2>/dev/null || echo "—%"`)
(defpoll weather-city :interval "300s" :initial "—"
  `jq -r '.city  // "—"' /tmp/waybar-cache/weather.json 2>/dev/null || echo —`)
```

Find the existing weather-using widget (the clock+weather merged frame, HERO left) and update its references from `(arraydec weather-raw '|' 0)` style (or whatever the current parse is) to the named polls. Search:

```
grep -n 'weather-raw\|weather-cond' /etc/nixos/home/widgets/eww/eww.yuck
```

Replace each `(arraydec weather-raw '|' N)` with `weather-{cond,temp,hi,lo,hum}` accordingly.

- [ ] **Step 8: Delete the scaffold script**

```
rm /etc/nixos/home/widgets/scripts/canvas-weather.sh
```

- [ ] **Step 9: Rebuild + start the daemon + restart canvas**

```
cd /etc/nixos && sudo nixos-rebuild switch
systemctl --user start weather-daemon.service
systemctl --user restart standardos-canvas.service
```

- [ ] **Step 10: Verify the cache file appears with real data**

```
sleep 12 && cat /tmp/waybar-cache/weather.json | jq .
```

Expected: a JSON object with cond, temp, hi, lo, hum, city, fetched. Cond is one of the canonical 7 values.

- [ ] **Step 11: Visual verify (canvas opens with real weather)**

Press Super+RETURN. The HERO-left clock+weather frame paints the city, temperature, hi/lo, and the canonical illustration matches the cond value. Press Esc.

- [ ] **Step 12: Update ARCHITECTURE.md**

`waybar/ARCHITECTURE.md` — in the daemon registry table, add a row:

```
| **weather-daemon** | `weather-daemon.service` (via `home/modules/weather-daemon.nix`) | `home/scripts/weather-daemon.sh` | `/tmp/waybar-cache/weather.json` | — (canvas re-reads on 60 s defpoll; weather doesn't need signal push) |
```

- [ ] **Step 13: Commit**

```
cd /etc/nixos/home && git add scripts/weather-daemon.sh scripts/lib/canvas-cache.sh modules/weather-daemon.nix widgets/eww/eww.yuck waybar/ARCHITECTURE.md tests/wave3/test_weather_daemon.sh && git rm widgets/scripts/canvas-weather.sh && git add <path-to-home.nix>  && git commit -m 'wave3: weather-daemon — canvas reads cache, scaffold script retired (Wave 3 Task 2)'
```

(Adjust file paths if your home.nix imports module from a different location.)

---

## Task 3: system-daemon — RTMIN+18, replaces canvas-{cpu,gpu,mem,disk}.sh

A 2 s poll loop reading `/proc` + `/sys` + best-effort GPU tools. Writes five cache files (`sys-cpu`, `sys-gpu`, `sys-mem`, `sys-battery`, `sys-temp`) and signals RTMIN+18 on real-content change per cache. Canvas reads these via cheap `cat`; the existing `canvas-{cpu,gpu,mem,disk}.sh` scaffold scripts are deleted.

Also graduates the NEXT entry in TODO.md (system-daemon was already on NEXT).

**Files:**
- Create: `scripts/system-daemon.sh`, `modules/system-daemon.nix`
- Modify: `widgets/eww/eww.yuck:64-75` (ring-* defpolls), `widgets/scripts/canvas-{cpu,gpu,mem,disk}.sh` (DELETE all four), `waybar/ARCHITECTURE.md` (mark system-daemon shipped), `waybar/TODO.md` (NEXT → DONE), `home/default.nix` (import module)
- Test:   `tests/wave3/test_system_daemon.sh`

**Interfaces:**
- Consumes: `scripts/lib/canvas-cache.sh` from Task 1.
- Produces:
  - `/tmp/waybar-cache/sys-cpu` — `{"pct":17,"temp":"52°","load_1":"0.42"}`
  - `/tmp/waybar-cache/sys-gpu` — `{"pct":3,"temp":"45°","kind":"intel"}` (kind ∈ `intel | nvidia | amd | none`)
  - `/tmp/waybar-cache/sys-mem` — `{"pct":48,"used":"7.6G","total":"16G"}`
  - `/tmp/waybar-cache/sys-battery` — `{"pct":82,"state":"discharging","time_remaining":"4h12m"}` (state ∈ `charging | discharging | full | unknown`)
  - `/tmp/waybar-cache/sys-temp` — `{"cpu":"52°","gpu":"45°","fan_rpm":1840}`
  - `/tmp/waybar-cache/sys-disk-root` — `{"pct":34,"used":"82G","total":"240G"}` (kept under the sys-* umbrella so the disk caches don't fragment)
  - `/tmp/waybar-cache/sys-disk-home` — same shape
  - All cache files emit RTMIN+18 on real-content change (dedup at writer per the global constraint).

- [ ] **Step 1: Write the failing test**

Create `tests/wave3/test_system_daemon.sh`:

```bash
#!/usr/bin/env bash
# test_system_daemon — unit tests for system-daemon.sh's read+emit path.
# Each emit_* function reads from $SYS_PROC and $SYS_SYS roots so tests
# can supply fixture trees and verify the JSON output.
set -euo pipefail

DAEMON="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/system-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Library-mode: define emit_* without entering the poll loop.
SYSTEM_DAEMON_LIB_ONLY=1 source "$DAEMON"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((pass++))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((fail++))
    fi
}

# ─── Fixture: /proc ─────────────────────────────────────────
PROC="$TMP/proc"
mkdir -p "$PROC"
cat > "$PROC/loadavg" <<'EOF'
0.42 0.38 0.31 2/812 12345
EOF
cat > "$PROC/meminfo" <<'EOF'
MemTotal:       16384000 kB
MemFree:         2048000 kB
MemAvailable:    8200000 kB
Buffers:          512000 kB
Cached:          2048000 kB
EOF
cat > "$PROC/stat" <<'EOF'
cpu  10000 0 5000 90000 0 0 100 0 0 0
EOF

# ─── Fixture: /sys for battery ──────────────────────────────
SYS="$TMP/sys"
mkdir -p "$SYS/class/power_supply/BAT0"
echo 82                  > "$SYS/class/power_supply/BAT0/capacity"
echo Discharging         > "$SYS/class/power_supply/BAT0/status"
echo 14400000000         > "$SYS/class/power_supply/BAT0/energy_full"
echo 11808000000         > "$SYS/class/power_supply/BAT0/energy_now"
echo 2500000000          > "$SYS/class/power_supply/BAT0/power_now"

# ─── Fixture: /sys for thermals ─────────────────────────────
mkdir -p "$SYS/class/hwmon/hwmon0"
echo 'coretemp'          > "$SYS/class/hwmon/hwmon0/name"
echo '52000'             > "$SYS/class/hwmon/hwmon0/temp1_input"

SYS_PROC="$PROC" SYS_SYS="$SYS" out=$(emit_cpu)
check "cpu pct present"   "$(printf '%s' "$out" | jq -r 'has("pct") | tostring')" "true"
check "cpu temp present"  "$(printf '%s' "$out" | jq -r '.temp')" "52°"

SYS_PROC="$PROC" SYS_SYS="$SYS" out=$(emit_mem)
# 1 - 8200000/16384000 = 49.94 → 50 (rounded)
check "mem pct close to 50"  "$(printf '%s' "$out" | jq -r '.pct')" "50"

SYS_PROC="$PROC" SYS_SYS="$SYS" out=$(emit_battery)
check "battery pct"          "$(printf '%s' "$out" | jq -r '.pct')" "82"
check "battery state"        "$(printf '%s' "$out" | jq -r '.state')" "discharging"

# Disk uses df; mock via PATH override
DF_DIR="$TMP/bin"
mkdir -p "$DF_DIR"
cat > "$DF_DIR/df" <<'EOF'
#!/usr/bin/env bash
# Fixture: emulate `df -B1 --output=size,used,pcent <path>`
# Outputs header + one row.
echo "  1B-blocks       Used Use%"
echo "250000000000 80000000000 32%"
EOF
chmod +x "$DF_DIR/df"
PATH="$DF_DIR:$PATH" out=$(emit_disk /)
check "disk pct"            "$(printf '%s' "$out" | jq -r '.pct')" "32"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run the test, see it fail (script not present)**

```
bash /etc/nixos/home/tests/wave3/test_system_daemon.sh
```

Expected: source failure.

- [ ] **Step 3: Implement `scripts/system-daemon.sh`**

```bash
#!/usr/bin/env bash
# system-daemon — CPU / GPU / memory / battery / thermal cache writer.
#
# Replaces widgets/scripts/canvas-{cpu,gpu,mem,disk}.sh (each was an
# eww defpoll shell-out). Wave 3 moves the polls into a single
# long-running systemd-user service so:
#   - Caches stay fresh for future bar pillar-6 surfaces
#     (audio / brightness / battery existing pills will read sys-battery
#     for true %).
#   - Canvas defpolls become `cat | jq -r`, removing the per-tick
#     `nvidia-smi` / `radeontop` invocations that briefly spike GPU
#     polling when the canvas is open.
#
# Cache files:    /tmp/waybar-cache/sys-{cpu, gpu, mem, battery, temp,
#                                       disk-root, disk-home}
# Signal:         RTMIN+18 (reserved in waybar/ARCHITECTURE.md;
#                 dedup at writer per the global anti-CPU-burn pattern)
#
# Library mode: SYSTEM_DAEMON_LIB_ONLY=1 source system-daemon.sh
# defines emit_* without entering the loop.
#
# Fixture roots: SYS_PROC and SYS_SYS env vars override /proc and /sys
# for tests. Default: SYS_PROC=/proc, SYS_SYS=/sys.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CACHE_DIR=/tmp/waybar-cache
mkdir -p "$CACHE_DIR"

POLL_INTERVAL="${SYSTEM_POLL_INTERVAL:-2}"
SIG=18

: "${SYS_PROC:=/proc}"
: "${SYS_SYS:=/sys}"

# ─── CPU ─────────────────────────────────────────────────────
_PREV_CPU_IDLE=0
_PREV_CPU_TOTAL=0
emit_cpu() {
    local line idle total diff_idle diff_total pct temp load_1
    read -r _ user nice sys idle iowait irq softirq steal _ < "$SYS_PROC/stat"
    total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
    diff_total=$((total - _PREV_CPU_TOTAL))
    diff_idle=$((idle - _PREV_CPU_IDLE))
    if (( diff_total > 0 )); then
        pct=$(( 100 * (diff_total - diff_idle) / diff_total ))
    else
        pct=0
    fi
    _PREV_CPU_IDLE=$idle
    _PREV_CPU_TOTAL=$total

    # Temperature from coretemp hwmon node, if present.
    temp="—"
    local hw
    for hw in "$SYS_SYS"/class/hwmon/hwmon*; do
        [[ -r "$hw/name" ]] || continue
        local n; n=$(<"$hw/name")
        case "$n" in
            coretemp|k10temp|zenpower)
                local t; t=$(<"$hw/temp1_input" 2>/dev/null || echo "")
                if [[ -n "$t" ]]; then
                    temp="$((t / 1000))°"
                fi
                break
                ;;
        esac
    done

    read -r load_1 _ < "$SYS_PROC/loadavg"
    jq -nc --argjson pct "$pct" --arg temp "$temp" --arg load_1 "$load_1" \
       '{pct:$pct, temp:$temp, load_1:$load_1}'
}

# ─── Memory ──────────────────────────────────────────────────
emit_mem() {
    local total avail used pct used_h total_h
    total=$(awk '/^MemTotal:/  {print $2}' "$SYS_PROC/meminfo")
    avail=$(awk '/^MemAvailable:/ {print $2}' "$SYS_PROC/meminfo")
    used=$(( total - avail ))
    pct=$(( 100 * used / total ))
    used_h=$(awk -v k=$used 'BEGIN{printf "%.1fG", k/1024/1024}')
    total_h=$(awk -v k=$total 'BEGIN{printf "%.0fG", k/1024/1024}')
    jq -nc --argjson pct "$pct" --arg used "$used_h" --arg total "$total_h" \
       '{pct:$pct, used:$used, total:$total}'
}

# ─── Battery ─────────────────────────────────────────────────
emit_battery() {
    local bat="$SYS_SYS/class/power_supply/BAT0"
    if [[ ! -d "$bat" ]]; then
        # Desktop / no battery: emit a stable "absent" payload.
        echo '{"pct":-1,"state":"absent","time_remaining":"—"}'
        return
    fi
    local pct state energy_now power_now state_lc time_remaining
    pct=$(<"$bat/capacity")
    state=$(<"$bat/status")
    state_lc="${state,,}"  # Discharging → discharging
    [[ "$state_lc" =~ ^(charging|discharging|full|unknown)$ ]] || state_lc=unknown

    # time_remaining: only meaningful while charging/discharging.
    time_remaining="—"
    if [[ "$state_lc" == discharging || "$state_lc" == charging ]]; then
        energy_now=$(<"$bat/energy_now" 2>/dev/null || echo 0)
        power_now=$(<"$bat/power_now" 2>/dev/null || echo 0)
        if (( power_now > 0 )); then
            local hours=$(( energy_now / power_now ))
            local mins=$(( (energy_now * 60 / power_now) % 60 ))
            time_remaining="${hours}h${mins}m"
        fi
    fi
    jq -nc --argjson pct "$pct" --arg state "$state_lc" --arg tr "$time_remaining" \
       '{pct:$pct, state:$state, time_remaining:$tr}'
}

# ─── GPU (best-effort, kind detected once) ────────────────────
_GPU_KIND=""
detect_gpu_kind() {
    if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia
    elif command -v radeontop  >/dev/null 2>&1; then echo amd
    elif command -v intel_gpu_top >/dev/null 2>&1; then echo intel
    else echo none
    fi
}
emit_gpu() {
    [[ -z "$_GPU_KIND" ]] && _GPU_KIND=$(detect_gpu_kind)
    local pct=0 temp="—"
    case "$_GPU_KIND" in
        nvidia)
            local raw; raw=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu \
                              --format=csv,noheader,nounits 2>/dev/null | head -1) || raw=""
            if [[ -n "$raw" ]]; then
                IFS=',' read -r pct temp <<<"$raw"
                pct=$(printf '%s' "$pct" | tr -d ' ')
                temp="$(printf '%s' "$temp" | tr -d ' ')°"
            fi
            ;;
        intel|amd|none) : ;; # Wave 3 ships nvidia-only metrics; intel/amd
                              # land in a follow-up. pct stays 0, temp "—".
    esac
    jq -nc --argjson pct "$pct" --arg temp "$temp" --arg kind "$_GPU_KIND" \
       '{pct:$pct, temp:$temp, kind:$kind}'
}

# ─── Thermals (cpu + gpu + fan, aggregated for SYSTEM·TEMPS card) ──
emit_temp() {
    local cpu_temp gpu_temp fan_rpm
    cpu_temp=$(printf '%s' "$(emit_cpu)" | jq -r .temp)
    gpu_temp=$(printf '%s' "$(emit_gpu)" | jq -r .temp)
    fan_rpm="—"
    local hw
    for hw in "$SYS_SYS"/class/hwmon/hwmon*; do
        [[ -r "$hw/fan1_input" ]] || continue
        fan_rpm=$(<"$hw/fan1_input")
        break
    done
    jq -nc --arg cpu "$cpu_temp" --arg gpu "$gpu_temp" --argjson fan "${fan_rpm//—/0}" \
       '{cpu:$cpu, gpu:$gpu, fan_rpm:$fan}'
}

# ─── Disk (per mountpoint, called per cache file) ────────────
emit_disk() {
    local mp="$1"
    local line
    line=$(df -B1 --output=size,used,pcent "$mp" 2>/dev/null | tail -1) || {
        echo '{"pct":0,"used":"—","total":"—"}'
        return
    }
    local size used pct
    read -r size used pct <<<"$line"
    pct="${pct%\%}"
    local used_h total_h
    used_h=$(awk -v k=$used 'BEGIN{ printf "%.0fG", k/1024/1024/1024}')
    total_h=$(awk -v k=$size 'BEGIN{ printf "%.0fG", k/1024/1024/1024}')
    jq -nc --argjson pct "$pct" --arg used "$used_h" --arg total "$total_h" \
       '{pct:$pct, used:$used, total:$total}'
}

[[ -n "${SYSTEM_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# Prime CPU counters with one read so the next iteration produces a
# meaningful diff. Without this, the first emit_cpu returns 100 %.
emit_cpu >/dev/null

while true; do
    cache_signal_if_changed "$CACHE_DIR/sys-cpu"        "$(emit_cpu)"     "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-mem"        "$(emit_mem)"     "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-battery"    "$(emit_battery)" "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-gpu"        "$(emit_gpu)"     "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-temp"       "$(emit_temp)"    "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-disk-root"  "$(emit_disk /)"  "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-disk-home"  "$(emit_disk /home)" "$SIG"
    sleep "$POLL_INTERVAL"
done
```

`chmod +x` the file.

- [ ] **Step 4: Run the test, see it pass**

```
chmod +x /etc/nixos/home/scripts/system-daemon.sh
bash /etc/nixos/home/tests/wave3/test_system_daemon.sh
```

Expected: all PASS.

- [ ] **Step 5: Write the Nix module**

Create `modules/system-daemon.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.systemDaemon;
in
{
  options.services.systemDaemon = {
    enable = lib.mkEnableOption "StandardOS system daemon (RTMIN+18; sys-* caches)";
    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Seconds between poll iterations.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.system-daemon = {
      Unit.Description = "StandardOS system daemon (CPU/GPU/mem/battery/temp)";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "SYSTEM_POLL_INTERVAL=${toString cfg.pollInterval}"
          "PATH=${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.gawk}/bin:${pkgs.bash}/bin:/run/current-system/sw/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/system-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
```

- [ ] **Step 6: Wire + enable, then update canvas yuck**

Same pattern as Task 2 Step 6 — find the home.nix consumer and add `./modules/system-daemon.nix` to imports + `services.systemDaemon.enable = true;` to config.

Then edit `widgets/eww/eww.yuck` — replace the ring-* defpoll block (lines ~64–75):

```yuck
;; Ring stats — 6 polls, varying cadences.
(defpoll ring-disk-root  :interval "60s" :initial "0" `/etc/nixos/home/widgets/scripts/canvas-disk.sh /`)
(defpoll ring-disk-home  :interval "60s" :initial "0" `/etc/nixos/home/widgets/scripts/canvas-disk.sh /home`)
;; Battery reuses the existing waybar battery script (parses % from its JSON-ish output).
(defpoll ring-battery    :interval "15s" :initial "0"
  `/etc/nixos/home/waybar/scripts/battery.sh 2>/dev/null | sed -E 's/.*"tooltip":"([0-9]+)%.*/\1/' || echo 0`)
(defpoll ring-wifi-bars  :interval "10s" :initial "▯▯▯▯" `/etc/nixos/home/widgets/scripts/canvas-wifi.sh bars`)
(defpoll ring-wifi-pct   :interval "10s" :initial "0"   `/etc/nixos/home/widgets/scripts/canvas-wifi.sh pct`)
(defpoll ring-gpu        :interval "5s"  :initial "0" `/etc/nixos/home/widgets/scripts/canvas-gpu.sh pct`)
(defpoll ring-gpu-temp   :interval "10s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-gpu.sh temp`)
(defpoll ring-mem        :interval "5s"  :initial "0" `/etc/nixos/home/widgets/scripts/canvas-mem.sh pct`)
(defpoll ring-mem-used   :interval "10s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-mem.sh used`)
```

With:

```yuck
;; Ring stats — read from system-daemon's sys-* caches.
;; The daemon polls every 2 s; canvas defpolls at 2 s match so we never
;; lag the daemon. /tmp/waybar-cache/sys-disk-root etc. are written by
;; system-daemon (modules/system-daemon.nix, Wave 3 Task 3).
(defpoll ring-disk-root :interval "60s" :initial "0"
  `jq -r '.pct // 0' /tmp/waybar-cache/sys-disk-root 2>/dev/null || echo 0`)
(defpoll ring-disk-home :interval "60s" :initial "0"
  `jq -r '.pct // 0' /tmp/waybar-cache/sys-disk-home 2>/dev/null || echo 0`)
(defpoll ring-battery :interval "15s" :initial "0"
  `jq -r '.pct // 0' /tmp/waybar-cache/sys-battery 2>/dev/null || echo 0`)
(defpoll ring-wifi-bars :interval "10s" :initial "▯▯▯▯"
  `/etc/nixos/home/widgets/scripts/canvas-wifi.sh bars`)   ;; wifi stays
(defpoll ring-wifi-pct  :interval "10s" :initial "0"
  `/etc/nixos/home/widgets/scripts/canvas-wifi.sh pct`)    ;; (network daemon = Wave 4)
(defpoll ring-gpu       :interval "5s" :initial "0"
  `jq -r '.pct // 0' /tmp/waybar-cache/sys-gpu 2>/dev/null || echo 0`)
(defpoll ring-gpu-temp  :interval "10s" :initial "—"
  `jq -r '.temp // "—"' /tmp/waybar-cache/sys-gpu 2>/dev/null || echo —`)
(defpoll ring-mem       :interval "5s" :initial "0"
  `jq -r '.pct // 0' /tmp/waybar-cache/sys-mem 2>/dev/null || echo 0`)
(defpoll ring-mem-used  :interval "10s" :initial "—"
  `jq -r '.used // "—"' /tmp/waybar-cache/sys-mem 2>/dev/null || echo —`)
```

- [ ] **Step 7: Replace the SYSTEM·TEMPS sys-pill polls**

Find the `sp-cpu`, `sp-cpu-temp`, `sp-fan` defpolls (they currently call `canvas-cpu.sh`). Replace with:

```yuck
(defpoll sp-cpu      :interval "2s"  :initial "—"
  `jq -r '.pct // "—"' /tmp/waybar-cache/sys-cpu 2>/dev/null || echo —`)
(defpoll sp-cpu-temp :interval "5s"  :initial "—"
  `jq -r '.temp // "—"' /tmp/waybar-cache/sys-cpu 2>/dev/null || echo —`)
(defpoll sp-fan      :interval "5s"  :initial "—"
  `jq -r '.fan_rpm // "—"' /tmp/waybar-cache/sys-temp 2>/dev/null || echo —`)
```

- [ ] **Step 8: Delete the scaffold scripts**

```
rm /etc/nixos/home/widgets/scripts/canvas-cpu.sh \
   /etc/nixos/home/widgets/scripts/canvas-gpu.sh \
   /etc/nixos/home/widgets/scripts/canvas-mem.sh \
   /etc/nixos/home/widgets/scripts/canvas-disk.sh
```

- [ ] **Step 9: Rebuild + start + restart canvas**

```
cd /etc/nixos && sudo nixos-rebuild switch
systemctl --user start system-daemon.service
systemctl --user restart standardos-canvas.service
```

- [ ] **Step 10: Verify caches appear with real data**

```
sleep 3
for f in sys-cpu sys-gpu sys-mem sys-battery sys-temp sys-disk-root sys-disk-home; do
    echo "--- $f ---"
    cat "/tmp/waybar-cache/$f" | jq . || echo "(missing)"
done
```

Expected: every file present, parseable JSON, values look sane (pct ∈ 0..100; temps look like room-temp + load; battery state matches `acpi -b`).

- [ ] **Step 11: Verify dedup is working**

```
# Watch the cache mtime for 10 seconds. mtime should NOT advance every 2s;
# it advances only on real-content change.
stat -c '%y %n' /tmp/waybar-cache/sys-disk-root
sleep 10
stat -c '%y %n' /tmp/waybar-cache/sys-disk-root
```

Expected: same mtime (disk usage didn't change in 10 s). If mtime ticked every 2 s, the dedup is broken — fix `cache_signal_if_changed` and re-run.

- [ ] **Step 12: Visual verify (canvas paints rings + sys-pills)**

Press Super+RETURN. The HERO-right rings frame paints real %s; the FIELD row 2 SYSTEM·TEMPS card shows CPU%, CPU temp, fan RPM. Press Esc.

- [ ] **Step 13: Update ARCHITECTURE.md (mark system-daemon shipped)**

In `waybar/ARCHITECTURE.md`, change the system-daemon row from a planned daemon to a shipped one — move it from the "Planned daemons" table into the "Shipped daemons" table, with the same cache + signal columns. Reference: `home/scripts/system-daemon.sh` (script) + `home/modules/system-daemon.nix` (unit).

- [ ] **Step 14: Update TODO.md (graduate NEXT entry)**

`waybar/TODO.md` — remove the `**System daemon** (RTMIN+18)` line from NEXT. Add a DONE entry (under the Wave 3 daemons collective entry, OR as a standalone entry depending on whether Tasks 1–7 are committed as one Wave 3 graduation at Task 8 — write here as a standalone DONE for now; the Task 8 graduation entry will absorb it):

```
- **2026-06-XX** — **system-daemon shipped (RTMIN+18).** Replaces the
  Wave 2 scaffolds canvas-{cpu,gpu,mem,disk}.sh with a single 2-s poll
  daemon writing /tmp/waybar-cache/sys-{cpu,gpu,mem,battery,temp,disk-*}.
  Canvas rings + SYSTEM·TEMPS sys-pills now read these caches via cheap
  cat | jq -r. Future bar pillar-6 pills consume the same caches.
  **Hint:** GPU detection is one-shot at daemon start (nvidia-smi probe);
  if the user replaces a GPU at runtime the daemon needs a restart.
  Wave 3 ships nvidia metrics only; intel/amd land in a follow-up
  (the `kind` field reports the detection so the canvas can choose).
```

- [ ] **Step 15: Commit**

```
cd /etc/nixos/home && git add scripts/system-daemon.sh modules/system-daemon.nix widgets/eww/eww.yuck waybar/ARCHITECTURE.md waybar/TODO.md tests/wave3/test_system_daemon.sh && git rm widgets/scripts/canvas-cpu.sh widgets/scripts/canvas-gpu.sh widgets/scripts/canvas-mem.sh widgets/scripts/canvas-disk.sh && git add <home.nix> && git commit -m 'wave3: system-daemon (RTMIN+18) — canvas rings read sys-* caches (Wave 3 Task 3)'
```

---

## Task 4: notif-history channel — surface the existing JSONL to the canvas

`notif-os-daemon` (Rust, already shipped) journals every notification to `~/.local/share/standard-os/notif-history.jsonl`. This task adds a thin shell channel that watches the journal and writes a canvas-shaped JSON cache. The canvas's empty-state placeholder is removed; the notifications card reads real entries.

This task has no Rust changes — the existing JSONL is the input.

**Files:**
- Create: `scripts/notif-history-channel.sh`, `modules/notif-history-channel.nix`
- Modify: `widgets/eww/eww.yuck` (field-notif-card def), `home/default.nix`, `waybar/ARCHITECTURE.md`
- Test:   `tests/wave3/test_notif_history_channel.sh`

**Interfaces:**
- Consumes: `~/.local/share/standard-os/notif-history.jsonl` (one JSON object per line, written by notif-os-daemon).
- Produces:
  - `/tmp/waybar-cache/notif-history.json` shape:
    ```json
    { "count": 12,
      "entries": [
        { "app": "Slack",  "title": "Maria",  "body": "lunch?", "ts": 1718908100, "urgency": "normal" },
        { "app": "Firefox", "title": "Build passed", "body": "main 1234", "ts": 1718908000, "urgency": "low" }
      ],
      "updated": 1718908234 }
    ```
  - Top 10 entries (most recent first). `count` is total journal length, NOT entries.length, so the canvas can show "12 total · top 10 shown."
- Signal: RTMIN+12 (shared with notif-daemon — see waybar/ARCHITECTURE.md).

- [ ] **Step 1: Write the failing test**

Create `tests/wave3/test_notif_history_channel.sh`:

```bash
#!/usr/bin/env bash
# test_notif_history_channel — TDD for the derivation that turns the
# JSONL journal into a canvas-shaped JSON cache.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/notif-history-channel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NOTIF_HISTORY_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((pass++))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((fail++))
    fi
}

# Fixture: 12 lines, top 10 should appear in entries.
JOURNAL="$TMP/journal.jsonl"
for i in $(seq 1 12); do
    jq -nc --arg app "App$i" --arg title "T$i" --arg body "B$i" \
       --argjson ts $((1718908000 + i)) \
       --arg urgency normal \
       '{app:$app, title:$title, body:$body, ts:$ts, urgency:$urgency}' >> "$JOURNAL"
done

out=$(derive_history_json "$JOURNAL")

check "count = total lines"        "$(printf '%s' "$out" | jq -r .count)"      "12"
check "entries length = 10"        "$(printf '%s' "$out" | jq -r '.entries | length')" "10"
check "first entry is newest (T12)" "$(printf '%s' "$out" | jq -r '.entries[0].title')" "T12"
check "last entry is T3"           "$(printf '%s' "$out" | jq -r '.entries[9].title')"  "T3"

# Empty journal → empty entries, count 0.
echo -n "" > "$JOURNAL"
out=$(derive_history_json "$JOURNAL")
check "empty: count 0"     "$(printf '%s' "$out" | jq -r .count)"               "0"
check "empty: entries []"  "$(printf '%s' "$out" | jq -r '.entries | length')"  "0"

# Missing journal → empty.
out=$(derive_history_json "$TMP/does-not-exist.jsonl")
check "missing: count 0"   "$(printf '%s' "$out" | jq -r .count)"               "0"
check "missing: entries []""$(printf '%s' "$out" | jq -r '.entries | length')"  "0"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run the test, see it fail**

```
bash /etc/nixos/home/tests/wave3/test_notif_history_channel.sh
```

Expected: source failure (script not present).

- [ ] **Step 3: Implement `scripts/notif-history-channel.sh`**

```bash
#!/usr/bin/env bash
# notif-history-channel — derive a canvas-shaped JSON cache from the
# notif-os-daemon journal at ~/.local/share/standard-os/notif-history.jsonl.
#
# notif-os-daemon (Rust) already journals every notification. Wave 3
# adds this thin shell channel so the canvas's notifications card
# has a stable, atomically-written input (JSONL is append-only and
# can be tailed mid-write, which is not friendly to a defpoll).
#
# Cache:  /tmp/waybar-cache/notif-history.json
# Signal: RTMIN+12 (shared with notif-daemon — connectivity-style sharing
#                   per ARCHITECTURE.md; one signal refreshes every
#                   notif-related consumer).
#
# Triggers: inotify on the journal directory (the file inode may
# rotate when notif-os-daemon truncates; watch the parent dir with
# --format '%f' filtered by basename, per the hazard in waybar/CLAUDE.md).
#
# Library mode: NOTIF_HISTORY_LIB_ONLY=1 source defines derive_history_json
# without entering the loop.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

JOURNAL="${HOME}/.local/share/standard-os/notif-history.jsonl"
CACHE=/tmp/waybar-cache/notif-history.json
SIG=12
mkdir -p "$(dirname "$CACHE")" "$(dirname "$JOURNAL")"
touch "$JOURNAL"  # so inotifywait doesn't bail when journal hasn't been written yet

derive_history_json() {
    local journal="$1"
    if [[ ! -r "$journal" ]]; then
        echo '{"count":0,"entries":[],"updated":'"$(date +%s)"'}'
        return
    fi
    # tac to get newest first, take top 10. Use a jq slurp so we get a
    # single array; count uses wc -l for cheapness.
    local count entries
    count=$(wc -l < "$journal" 2>/dev/null || echo 0)
    if (( count == 0 )); then
        echo '{"count":0,"entries":[],"updated":'"$(date +%s)"'}'
        return
    fi
    entries=$(tac "$journal" 2>/dev/null | head -10 | jq -s '.')
    jq -nc --argjson count "$count" --argjson entries "$entries" \
       --argjson updated "$(date +%s)" \
       '{count:$count, entries:$entries, updated:$updated}'
}

[[ -n "${NOTIF_HISTORY_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# Initial write.
cache_signal_if_changed "$CACHE" "$(derive_history_json "$JOURNAL")" "$SIG"

# Watch the parent dir for changes to the journal basename. The
# notif-os-daemon writes via append; inotify CLOSE_WRITE + MODIFY
# both fire. We coalesce: any event → re-derive.
JOURNAL_NAME=$(basename "$JOURNAL")
JOURNAL_DIR=$(dirname "$JOURNAL")

inotifywait -m -e modify -e close_write -e moved_to --format '%f' "$JOURNAL_DIR" 2>/dev/null \
| while read -r fname; do
    [[ "$fname" == "$JOURNAL_NAME" ]] || continue
    cache_signal_if_changed "$CACHE" "$(derive_history_json "$JOURNAL")" "$SIG"
done
```

`chmod +x`.

- [ ] **Step 4: Run the test, see it pass**

```
chmod +x /etc/nixos/home/scripts/notif-history-channel.sh
bash /etc/nixos/home/tests/wave3/test_notif_history_channel.sh
```

Expected: 8 PASS.

- [ ] **Step 5: Nix module**

Create `modules/notif-history-channel.nix`:

```nix
{ config, lib, pkgs, ... }:

let cfg = config.services.notifHistoryChannel; in
{
  options.services.notifHistoryChannel.enable =
    lib.mkEnableOption "StandardOS notif-history canvas channel";

  config = lib.mkIf cfg.enable {
    systemd.user.services.notif-history-channel = {
      Unit = {
        Description = "StandardOS notif-history canvas channel";
        After = [ "notif-os-daemon.service" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.jq}/bin:${pkgs.inotify-tools}/bin:${pkgs.coreutils}/bin:${pkgs.procps}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/notif-history-channel.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
```

- [ ] **Step 6: Wire + enable + update canvas yuck**

Same import / enable pattern.

Add to `widgets/eww/eww.yuck` data block:

```yuck
;; Notif-history — derived from notif-os-daemon's JSONL journal by
;; notif-history-channel. Wave 3 Task 4.
(defpoll notif-count :interval "5s" :initial "0"
  `jq -r '.count // 0' /tmp/waybar-cache/notif-history.json 2>/dev/null || echo 0`)
(defpoll notif-entries :interval "5s" :initial "[]"
  `jq -c '.entries // []' /tmp/waybar-cache/notif-history.json 2>/dev/null || echo "[]"`)
```

Replace `field-notif-card` (around line 313). Find:

```yuck
(defwidget field-notif-card []
  (box :class "field-card field-notif" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (box :class "field-notif-top" :orientation "horizontal" :space-evenly false
      (label :class "field-lk" :text "NOTIFICATIONS · 0" :halign "start" :hexpand true)
      (label :class "field-notif-clear" :text "CLEAR" :halign "end"))
    (label :class "field-empty" :text "No notifications.\nHistory ships with the notif-daemon channel (Wave 3)."
           :wrap true :limit-width 32 :halign "start")))
```

Replace with:

```yuck
(defwidget field-notif-row [app title body]
  (box :class "field-notif-row" :orientation "vertical" :space-evenly false :spacing 0
    (box :orientation "horizontal" :space-evenly false :spacing 6
      (label :class "field-notif-app"   :text app   :halign "start")
      (label :class "field-notif-title" :text title :halign "start" :hexpand true))
    (label :class "field-notif-body"    :text body  :halign "start" :wrap true :limit-width 32)))

(defwidget field-notif-card []
  (box :class "field-card field-notif" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (box :class "field-notif-top" :orientation "horizontal" :space-evenly false
      (label :class "field-lk" :text {"NOTIFICATIONS · " + notif-count} :halign "start" :hexpand true)
      (button :class "field-notif-clear" :onclick "echo '' > ~/.local/share/standard-os/notif-history.jsonl" "CLEAR"))
    (box :class "field-notif-list" :orientation "vertical" :space-evenly false :spacing 4
      (for entry in {notif-entries}
        (field-notif-row :app   {entry.app}
                         :title {entry.title}
                         :body  {entry.body})))))
```

(Eww `for` works over array literals — see existing examples in the yuck file.)

- [ ] **Step 7: Add the matching SCSS**

In `widgets/eww/eww.scss`, near the existing `.field-notif` block, add:

```scss
.field-notif-list { padding-top: 2px; }
.field-notif-row {
  padding: 4px 6px;
  border-radius: 8px;
}
.field-notif-row:hover { background-color: rgba(255,255,255,0.04); }
.field-notif-app    { color: rgba(255,255,255,0.55); font-size: 8pt; }
.field-notif-title  { color: rgba(255,255,255,0.90); font-size: 10pt; font-weight: 500; }
.field-notif-body   { color: rgba(255,255,255,0.65); font-size: 9pt; }
.field-notif-clear  {
  background-color: transparent;
  color: rgba(255,255,255,0.55);
  font-size: 8pt;
  padding: 2px 8px;
  border-radius: 8px;
}
.field-notif-clear:hover { background-color: rgba(255,255,255,0.10); color: rgba(255,255,255,0.95); }
```

Remove the `.field-empty` rules used only by the four "ships in Wave 3" placeholder labels (search them out — they'll be retired by Tasks 4/5/6/7 progressively; for now just remove the notif one if it's separately defined).

- [ ] **Step 8: Rebuild, start, restart canvas**

```
cd /etc/nixos && sudo nixos-rebuild switch
systemctl --user start notif-history-channel.service
systemctl --user restart standardos-canvas.service
```

- [ ] **Step 9: Verify cache + canvas paints history**

```
cat /tmp/waybar-cache/notif-history.json | jq .
```

Expected: count + entries reflect the current JSONL.

Trigger a test notification:

```
notify-send "Wave 3 Test" "If this appears on the canvas, the channel works"
sleep 1
cat /tmp/waybar-cache/notif-history.json | jq '.entries[0]'
```

Expected: the new entry is the first in `.entries[]`. Open canvas; the notifications card shows the entry.

- [ ] **Step 10: Update ARCHITECTURE.md + commit**

Add a daemon-registry row for notif-history-channel. Note that RTMIN+12 is now shared with notif-daemon AND notif-history-channel (per the connectivity-style shared-signal pattern).

```
cd /etc/nixos/home && git add scripts/notif-history-channel.sh modules/notif-history-channel.nix widgets/eww/eww.yuck widgets/eww/eww.scss tests/wave3/test_notif_history_channel.sh waybar/ARCHITECTURE.md && git add <home.nix> && git commit -m 'wave3: notif-history channel — canvas notifications card reads journal (Wave 3 Task 4)'
```

---

## Task 5: pomodoro-daemon + pomodoroctl + canvas integration

A state-machine daemon driving a focus-block timer. Reads commands from a FIFO; writes state JSON to a cache; the canvas's focus card reads the cache and paints `opt-breathe` during an active block.

**Files:**
- Create: `scripts/pomodoro-daemon.sh`, `scripts/pomodoroctl`, `modules/pomodoro-daemon.nix`
- Modify: `widgets/eww/eww.yuck` (field-focus-card), `home/default.nix`, `waybar/ARCHITECTURE.md`
- Test:   `tests/wave3/test_pomodoro_daemon.sh`

**Interfaces:**
- Consumes: `/run/user/$UID/standardos-pomodoro.fifo` — accepts commands one per line: `start [seconds]` (default 25*60), `stop`, `skip`, `reset`.
- Produces:
  - `/tmp/waybar-cache/pomodoro.json` shape:
    ```json
    { "state": "running",
      "remaining_seconds": 1140,
      "remaining_text": "19:00",
      "block_kind": "focus",
      "blocks_completed_today": 3,
      "blocks_target": 4 }
    ```
  - `state` ∈ `{ idle, running, paused, break }`.
  - `block_kind` ∈ `{ focus, short_break, long_break }`. During `idle`, both `remaining_seconds` and `remaining_text` are `0` and `"—:—"`.
- Signal: RTMIN+19 (free pool — register in `ARCHITECTURE.md`).

- [ ] **Step 1: Write the failing test**

Create `tests/wave3/test_pomodoro_daemon.sh`:

```bash
#!/usr/bin/env bash
# test_pomodoro_daemon — TDD for the state machine and tick logic.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/pomodoro-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

POMODORO_DAEMON_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((pass++))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((fail++))
    fi
}

# Initial state = idle.
state_reset
check "initial state idle"      "$STATE"            "idle"
check "initial blocks_today 0"  "$BLOCKS_TODAY"     "0"

# Start a focus block.
cmd_start 1500
check "after start state=running" "$STATE"          "running"
check "after start kind=focus"    "$BLOCK_KIND"     "focus"
check "after start remaining=1500" "$REMAINING_S"   "1500"

# Tick 30 seconds.
tick 30
check "after tick remaining=1470" "$REMAINING_S"    "1470"

# Skip to break (block completed).
cmd_skip
check "after skip kind=short_break" "$BLOCK_KIND"   "short_break"
check "after skip blocks_today=1"   "$BLOCKS_TODAY" "1"

# Stop.
cmd_stop
check "after stop state=idle"      "$STATE"         "idle"

# emit_json
state_reset
cmd_start 1500
tick 60
out=$(emit_json)
check "emit_json state"     "$(printf '%s' "$out" | jq -r .state)"             "running"
check "emit_json remaining" "$(printf '%s' "$out" | jq -r .remaining_seconds)" "1440"
check "emit_json text"      "$(printf '%s' "$out" | jq -r .remaining_text)"    "24:00"

# After 4 focus blocks, next break should be long_break.
state_reset
for i in 1 2 3 4; do
    cmd_start 1500
    cmd_skip
done
check "4 focus → long break"  "$BLOCK_KIND"  "long_break"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run, see it fail**

```
bash /etc/nixos/home/tests/wave3/test_pomodoro_daemon.sh
```

Expected: source failure.

- [ ] **Step 3: Implement `scripts/pomodoro-daemon.sh`**

```bash
#!/usr/bin/env bash
# pomodoro-daemon — focus-block state machine.
#
# Reads commands from a FIFO at /run/user/$UID/standardos-pomodoro.fifo
# and writes state JSON to /tmp/waybar-cache/pomodoro.json on every
# state change AND every tick during an active block. Signal: RTMIN+19
# (dedup at writer; ticks that don't change the rendered text don't
# fire the signal — that's what cache_signal_if_changed already does).
#
# State machine:
#   idle ──(start [N])──→ running (focus)
#   running ──(time elapses)──→ break (short or long)
#   running ──(skip)──→ break
#   running ──(stop)──→ idle
#   break ──(skip)──→ running (focus)
#   break ──(stop)──→ idle
#   any ──(reset)──→ idle, BLOCKS_TODAY = 0
#
# Long break after every 4th focus block (Pomodoro classic).
# Block kinds:
#   focus       — 25 min default (caller overridable via `start N`)
#   short_break — 5 min
#   long_break  — 15 min
#
# Library mode: POMODORO_DAEMON_LIB_ONLY=1 source defines state +
# cmd_* + tick + emit_json without entering the loop.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CACHE=/tmp/waybar-cache/pomodoro.json
SIG=19
FIFO="/run/user/${UID:-$(id -u)}/standardos-pomodoro.fifo"
mkdir -p "$(dirname "$CACHE")"

FOCUS_DEFAULT=$((25 * 60))
SHORT_BREAK=$((5 * 60))
LONG_BREAK=$((15 * 60))
BLOCKS_TARGET=4

STATE=idle
BLOCK_KIND=focus
REMAINING_S=0
BLOCKS_TODAY=0

state_reset() {
    STATE=idle
    BLOCK_KIND=focus
    REMAINING_S=0
    BLOCKS_TODAY=0
}

cmd_start() {
    local seconds="${1:-$FOCUS_DEFAULT}"
    STATE=running
    BLOCK_KIND=focus
    REMAINING_S=$seconds
}

cmd_stop() {
    STATE=idle
    REMAINING_S=0
}

cmd_skip() {
    # If we were in focus → completed → next is break (short or long).
    # If we were in break → next is focus.
    if [[ "$BLOCK_KIND" == focus && "$STATE" == running ]]; then
        BLOCKS_TODAY=$((BLOCKS_TODAY + 1))
        if (( BLOCKS_TODAY % BLOCKS_TARGET == 0 )); then
            BLOCK_KIND=long_break
            REMAINING_S=$LONG_BREAK
        else
            BLOCK_KIND=short_break
            REMAINING_S=$SHORT_BREAK
        fi
        STATE=break
    elif [[ "$BLOCK_KIND" == short_break || "$BLOCK_KIND" == long_break ]]; then
        BLOCK_KIND=focus
        REMAINING_S=$FOCUS_DEFAULT
        STATE=running
    fi
}

cmd_reset() {
    state_reset
}

tick() {
    local dt="${1:-1}"
    if [[ "$STATE" == running || "$STATE" == break ]]; then
        REMAINING_S=$((REMAINING_S - dt))
        if (( REMAINING_S <= 0 )); then
            cmd_skip
        fi
    fi
}

emit_json() {
    local text
    if (( REMAINING_S > 0 )); then
        text=$(printf '%d:%02d' $((REMAINING_S / 60)) $((REMAINING_S % 60)))
    else
        text="—:—"
    fi
    jq -nc --arg state "$STATE" \
       --argjson rs "$REMAINING_S" \
       --arg rt "$text" \
       --arg kind "$BLOCK_KIND" \
       --argjson bt "$BLOCKS_TODAY" \
       --argjson tg "$BLOCKS_TARGET" \
       '{state:$state, remaining_seconds:$rs, remaining_text:$rt,
         block_kind:$kind, blocks_completed_today:$bt, blocks_target:$tg}'
}

[[ -n "${POMODORO_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# Make the FIFO if it doesn't exist. Open it for read+write on the same
# FD so the open call doesn't block waiting for a writer.
[[ -p "$FIFO" ]] || mkfifo -m 600 "$FIFO"
exec {FIFO_FD}<>"$FIFO"

cache_signal_if_changed "$CACHE" "$(emit_json)" "$SIG"

while true; do
    # Non-blocking read with 1 s timeout — drives the tick.
    if read -r -t 1 -u "$FIFO_FD" cmd args; then
        case "$cmd" in
            start)  cmd_start "${args:-}" ;;
            stop)   cmd_stop ;;
            skip)   cmd_skip ;;
            reset)  cmd_reset ;;
            status) : ;; # falls through to emit
            *) ;;
        esac
    else
        tick 1
    fi
    cache_signal_if_changed "$CACHE" "$(emit_json)" "$SIG"
done
```

- [ ] **Step 4: Implement `scripts/pomodoroctl`**

```bash
#!/usr/bin/env bash
# pomodoroctl — CLI shim over the pomodoro-daemon FIFO. Provides the
# same one-line ergonomics as mprisctl / dictate-toggle.
#
# Usage:
#   pomodoroctl start [seconds]   # default 25*60
#   pomodoroctl stop
#   pomodoroctl skip
#   pomodoroctl reset
#   pomodoroctl status            # prints the current cache JSON
set -euo pipefail
FIFO="/run/user/${UID:-$(id -u)}/standardos-pomodoro.fifo"
CACHE=/tmp/waybar-cache/pomodoro.json

case "${1:-}" in
    status)
        cat "$CACHE" 2>/dev/null || echo '{"state":"idle"}'
        ;;
    start|stop|skip|reset)
        if [[ ! -p "$FIFO" ]]; then
            echo "pomodoroctl: daemon FIFO missing ($FIFO). Is pomodoro-daemon.service running?" >&2
            exit 1
        fi
        echo "$@" > "$FIFO"
        ;;
    *)
        echo "usage: pomodoroctl {start [seconds]|stop|skip|reset|status}" >&2
        exit 2
        ;;
esac
```

`chmod +x` both scripts.

- [ ] **Step 5: Run the test, see it pass**

```
chmod +x /etc/nixos/home/scripts/pomodoro-daemon.sh /etc/nixos/home/scripts/pomodoroctl
bash /etc/nixos/home/tests/wave3/test_pomodoro_daemon.sh
```

Expected: all PASS.

- [ ] **Step 6: Nix module**

Create `modules/pomodoro-daemon.nix`:

```nix
{ config, lib, pkgs, ... }:
let cfg = config.services.pomodoroDaemon; in
{
  options.services.pomodoroDaemon.enable =
    lib.mkEnableOption "StandardOS pomodoro daemon";

  config = lib.mkIf cfg.enable {
    home.packages = [ ];  # pomodoroctl is in /etc/nixos/home/scripts — already on PATH if user adds it; otherwise add a wrapper here.
    systemd.user.services.pomodoro-daemon = {
      Unit.Description = "StandardOS pomodoro daemon (FIFO + state cache)";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.jq}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/pomodoro-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
```

If `pomodoroctl` is not yet on PATH, add a symlink in your home `home.file."./.local/bin/pomodoroctl".source = ...;` block or add `/etc/nixos/home/scripts/` to PATH — either is fine; pick what matches your existing pattern for `mprisctl`.

- [ ] **Step 7: Wire + enable + canvas yuck**

Find + replace `field-focus-card` (around line 355):

```yuck
(defwidget field-focus-card []
  (box :class "field-card field-focus" :orientation "vertical" :space-evenly false :spacing 4 :halign "fill" :hexpand true
    (label :class "field-lk" :text "FOCUS · POM —/—" :halign "center")
    (label :class "field-focus-big" :text "—:—" :halign "center")
    (label :class "field-empty" :text "Pomodoro daemon ships in Wave 3."
           :wrap true :limit-width 22 :halign "center")))
```

Replace with:

```yuck
;; Pomodoro — driven by pomodoro-daemon (Wave 3 Task 5).
;; Cache /tmp/waybar-cache/pomodoro.json; commands via pomodoroctl.
(defpoll pom-state    :interval "1s" :initial "idle"
  `jq -r '.state // "idle"' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo idle`)
(defpoll pom-text     :interval "1s" :initial "—:—"
  `jq -r '.remaining_text // "—:—"' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo "—:—"`)
(defpoll pom-done     :interval "5s" :initial "0"
  `jq -r '.blocks_completed_today // 0' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo 0`)
(defpoll pom-target   :interval "60s" :initial "4"
  `jq -r '.blocks_target // 4' /tmp/waybar-cache/pomodoro.json 2>/dev/null || echo 4`)

(defwidget field-focus-card []
  (box :class {"field-card field-focus field-focus-" + pom-state} :orientation "vertical" :space-evenly false :spacing 4 :halign "fill" :hexpand true
    (label :class "field-lk"
           :text {"FOCUS · POM " + pom-done + "/" + pom-target} :halign "center")
    (label :class "field-focus-big" :text pom-text :halign "center")
    (box :class "field-focus-ctrls" :orientation "horizontal" :space-evenly true :halign "center"
      (button :class "opt-pill" :onclick "/etc/nixos/home/scripts/pomodoroctl start" "Start")
      (button :class "opt-pill" :onclick "/etc/nixos/home/scripts/pomodoroctl skip"  "Skip")
      (button :class "opt-pill" :onclick "/etc/nixos/home/scripts/pomodoroctl stop"  "Stop"))))
```

- [ ] **Step 8: Add breathe motion in SCSS**

Per Wave 2 design §5 motion table, pomodoro breathes during an active focus block. Add to `widgets/eww/eww.scss`:

```scss
@keyframes pom-breathe {
  0%   { opacity: 1.0; }
  50%  { opacity: 0.78; }
  100% { opacity: 1.0; }
}
.field-focus-running .field-focus-big {
  animation: pom-breathe 3.2s ease-in-out infinite;
}
.field-focus-ctrls { padding-top: 4px; }
```

- [ ] **Step 9: Rebuild + start + restart canvas + smoke-test**

```
cd /etc/nixos && sudo nixos-rebuild switch
systemctl --user start pomodoro-daemon.service
systemctl --user restart standardos-canvas.service
sleep 1
/etc/nixos/home/scripts/pomodoroctl status | jq .
/etc/nixos/home/scripts/pomodoroctl start 30
sleep 2
/etc/nixos/home/scripts/pomodoroctl status | jq .
/etc/nixos/home/scripts/pomodoroctl stop
```

Expected: initial state idle; after start, remaining_seconds counts down (~28 after 2 s); after stop, idle again.

- [ ] **Step 10: Visual verify**

Open canvas. Click Start. The focus card text counts down 25:00 → 24:59 → … and the big text breathes (opacity oscillation). Click Stop. Card returns to idle face.

- [ ] **Step 11: Update ARCHITECTURE.md + commit**

Add daemon registry + signal table rows for pomodoro-daemon / RTMIN+19. Mark RTMIN+19 as taken.

```
cd /etc/nixos/home && git add scripts/pomodoro-daemon.sh scripts/pomodoroctl modules/pomodoro-daemon.nix widgets/eww/eww.yuck widgets/eww/eww.scss tests/wave3/test_pomodoro_daemon.sh waybar/ARCHITECTURE.md && git add <home.nix> && git commit -m 'wave3: pomodoro-daemon (RTMIN+19) + pomodoroctl — focus card live (Wave 3 Task 5)'
```

---

## Task 6: mpris-waybar truth — canvas reads `/tmp/waybar-cache/mpris-*` instead of polling playerctl

`/home/max/mpris-waybar/` is a separate concern being rewritten. The Wave 3 task is the canvas-side wiring: stop polling `playerctl` from `canvas-media.sh`, start reading whatever cache(s) mpris-waybar writes.

**Precondition:** mpris-waybar's daemon must already be writing to `/tmp/waybar-cache/mpris-*` files. If the rewrite hasn't reached that milestone, this task BLOCKS — defer until then, and document the block in TODO.md.

**Files:**
- Modify: `widgets/eww/eww.yuck:54-62` (media-* defpolls), `widgets/scripts/canvas-media.sh` (DELETE)
- No new daemon (consume what mpris-waybar already writes)
- No new test (the mpris-waybar daemon owns its own tests)

**Interfaces:**
- Consumes: `/tmp/waybar-cache/mpris-*` — exact filenames depend on what mpris-waybar settles on. Probable shape (verify in mpris-waybar/docs/ at execution time):
  - `mpris-title`, `mpris-artist`, `mpris-album`, `mpris-source`, `mpris-status`, `mpris-pos`, `mpris-len`, `mpris-pct`.
- If mpris-waybar writes a single composite JSON file at e.g. `/tmp/waybar-cache/mpris.json`, the canvas defpolls become single-source `jq -r` reads instead of 8 separate cat reads. Decide at execution time per what the daemon actually writes.

- [ ] **Step 1: Verify mpris-waybar is writing caches**

```
ls /tmp/waybar-cache/mpris-* 2>/dev/null
# If empty:
ls /tmp/waybar-cache/ | grep -i mpris
```

Expected: at least one file. If empty AND mpris-waybar daemon is running:

```
ls /home/max/mpris-waybar/
cat /home/max/mpris-waybar/docs/superpowers/specs/*.md 2>/dev/null | grep -iE 'cache|tmp|waybar-cache' | head
```

— check the mpris-waybar spec for cache filenames. If the rewrite hasn't reached cache-writing yet, **STOP THIS TASK**, move it to NEXT in TODO.md with a "blocks on mpris-waybar reaching cache milestone" note, and skip ahead to Task 7.

- [ ] **Step 2: Replace canvas yuck defpolls**

Edit `widgets/eww/eww.yuck` — find the media-* block (lines 54–62):

```yuck
;; Media — playerctl best-effort.
(defpoll media-source :interval "5s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh source`)
(defpoll media-title  :interval "2s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh title`)
(defpoll media-artist :interval "2s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh artist`)
(defpoll media-album  :interval "5s" :initial "—" `/etc/nixos/home/widgets/scripts/canvas-media.sh album`)
(defpoll media-status :interval "1s" :initial "⏵" `/etc/nixos/home/widgets/scripts/canvas-media.sh status`)
(defpoll media-pos    :interval "1s" :initial "—:—" `/etc/nixos/home/widgets/scripts/canvas-media.sh pos`)
(defpoll media-len    :interval "5s" :initial "—:—" `/etc/nixos/home/widgets/scripts/canvas-media.sh len`)
(defpoll media-pct    :interval "1s" :initial "0"   `/etc/nixos/home/widgets/scripts/canvas-media.sh pct`)
```

Replace with cache reads. Substitute the EXACT filenames you verified in Step 1 (this example assumes per-field files; if composite JSON, collapse to `jq -r .title <single-file>`):

```yuck
;; Media — mpris-waybar daemon owns truth. Wave 3 Task 6.
;; Files written by /home/max/mpris-waybar/scripts/mpris-publisher.
(defpoll media-source :interval "5s"
  :initial "—" `cat /tmp/waybar-cache/mpris-source 2>/dev/null || echo —`)
(defpoll media-title  :interval "2s"
  :initial "—" `cat /tmp/waybar-cache/mpris-title 2>/dev/null || echo —`)
(defpoll media-artist :interval "2s"
  :initial "—" `cat /tmp/waybar-cache/mpris-artist 2>/dev/null || echo —`)
(defpoll media-album  :interval "5s"
  :initial "—" `cat /tmp/waybar-cache/mpris-album 2>/dev/null || echo —`)
(defpoll media-status :interval "1s"
  :initial "⏵" `cat /tmp/waybar-cache/mpris-status 2>/dev/null || echo ⏵`)
(defpoll media-pos    :interval "1s"
  :initial "—:—" `cat /tmp/waybar-cache/mpris-pos 2>/dev/null || echo "—:—"`)
(defpoll media-len    :interval "5s"
  :initial "—:—" `cat /tmp/waybar-cache/mpris-len 2>/dev/null || echo "—:—"`)
(defpoll media-pct    :interval "1s"
  :initial "0"   `cat /tmp/waybar-cache/mpris-pct 2>/dev/null || echo 0`)
```

- [ ] **Step 3: Delete the scaffold script**

```
rm /etc/nixos/home/widgets/scripts/canvas-media.sh
```

- [ ] **Step 4: Restart canvas + smoke-test**

```
systemctl --user restart standardos-canvas.service
```

Open a media player (Spotify / Firefox YouTube / whatever's normal). Open the canvas. The media-MEGA frame paints title, artist, source, position/length, percent. Click play/pause/next/prev — they fire to the player via `mprisctl` (the canvas's existing on-click handlers, untouched in this task).

- [ ] **Step 5: Commit**

```
cd /etc/nixos/home && git add widgets/eww/eww.yuck && git rm widgets/scripts/canvas-media.sh && git commit -m 'wave3: canvas media reads mpris-waybar cache truth (Wave 3 Task 6)'
```

---

## Task 7: cal-source-daemon — local ICS files → agenda cache

A periodic ICS reader. v0 source: `~/.config/standardos/calendars/*.ics`. The user drops .ics files in that directory (manually exported from Google Calendar, Apple Calendar, Outlook, or a CalDAV sync tool of their choice). The daemon parses next 8 events across all files, writes `agenda.json` for the canvas.

CalDAV / Google Calendar direct sync are explicit non-goals for Wave 3 — they're a Wave 4+ follow-up after the canvas pattern proves out.

**Files:**
- Create: `scripts/cal-source-daemon.sh`, `modules/cal-source-daemon.nix`
- Modify: `widgets/eww/eww.yuck` (field-agenda-card), `home/default.nix`, `waybar/ARCHITECTURE.md`
- Test:   `tests/wave3/test_cal_source_daemon.sh`

**Interfaces:**
- Consumes: `~/.config/standardos/calendars/*.ics` (any path globbed; user drops files here).
- Produces:
  - `/tmp/waybar-cache/agenda.json` shape:
    ```json
    { "events": [
        { "summary": "Dentist", "start": 1718911800, "start_text": "14:30", "minutes_until": 47 },
        { "summary": "Standup", "start": 1718998200, "start_text": "Tomorrow 09:30", "minutes_until": 1487 }
      ],
      "today_count": 1,
      "next_minutes_until": 47,
      "updated": 1718908234 }
    ```
  - `events` capped at 8, ordered by start ascending. `start_text` is a human-friendly time stamp (today → `HH:MM`, future days → `WeekdayName HH:MM` or `MMM D HH:MM` past 6 days).
- Signal: RTMIN+20 (free pool).

- [ ] **Step 1: Write the failing test**

Create `tests/wave3/test_cal_source_daemon.sh`:

```bash
#!/usr/bin/env bash
# test_cal_source_daemon — TDD for the ICS parse and emit path.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/cal-source-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CAL_SOURCE_LIB_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; ((pass++))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; ((fail++))
    fi
}

# Fixture: a single ICS file with 3 events, one in the past, one today,
# one tomorrow. Tests use a fixed reference now so the time math is
# deterministic.

NOW_FIXED=1718908234  # 2024-06-20 (fixture date)
FIXTURE_DIR="$TMP/calendars"
mkdir -p "$FIXTURE_DIR"
cat > "$FIXTURE_DIR/test.ics" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
SUMMARY:Past event
DTSTART:20240601T100000Z
DTEND:20240601T110000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:Today event
DTSTART:20240620T140000Z
DTEND:20240620T150000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:Tomorrow event
DTSTART:20240621T090000Z
DTEND:20240621T100000Z
END:VEVENT
END:VCALENDAR
EOF

out=$(CAL_NOW="$NOW_FIXED" derive_agenda_json "$FIXTURE_DIR")

# Past event should be dropped; future 2 should remain.
check "events.length = 2"           "$(printf '%s' "$out" | jq -r '.events | length')"  "2"
check "first event = Today event"    "$(printf '%s' "$out" | jq -r '.events[0].summary')" "Today event"
check "second event = Tomorrow"      "$(printf '%s' "$out" | jq -r '.events[1].summary')" "Tomorrow event"
check "today_count = 1"              "$(printf '%s' "$out" | jq -r .today_count)"        "1"

# Empty directory.
EMPTY_DIR="$TMP/empty"
mkdir -p "$EMPTY_DIR"
out=$(CAL_NOW="$NOW_FIXED" derive_agenda_json "$EMPTY_DIR")
check "empty dir → 0 events"        "$(printf '%s' "$out" | jq -r '.events | length')"  "0"
check "empty dir → today_count 0"   "$(printf '%s' "$out" | jq -r .today_count)"        "0"

# Missing directory.
out=$(CAL_NOW="$NOW_FIXED" derive_agenda_json "$TMP/does-not-exist")
check "missing dir → 0 events"      "$(printf '%s' "$out" | jq -r '.events | length')"  "0"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run, see it fail**

```
bash /etc/nixos/home/tests/wave3/test_cal_source_daemon.sh
```

Expected: source failure.

- [ ] **Step 3: Implement `scripts/cal-source-daemon.sh`**

```bash
#!/usr/bin/env bash
# cal-source-daemon — local ICS files → agenda cache for the canvas.
#
# v0 source: ~/.config/standardos/calendars/*.ics (manually exported
# from Google/Apple/Outlook, or symlinked from a CalDAV sync tool
# the user runs separately). CalDAV/Google direct sync = Wave 4+
# follow-up.
#
# Cache:  /tmp/waybar-cache/agenda.json
# Signal: RTMIN+20 (free pool — register in waybar/ARCHITECTURE.md).
#
# Library mode: CAL_SOURCE_LIB_ONLY=1 source defines derive_agenda_json
# without entering the loop. CAL_NOW env var overrides "now" for tests.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CAL_DIR="${HOME}/.config/standardos/calendars"
CACHE=/tmp/waybar-cache/agenda.json
SIG=20
POLL_INTERVAL="${CAL_POLL_INTERVAL:-300}"  # 5 min
mkdir -p "$(dirname "$CACHE")" "$CAL_DIR"

# parse_one_ics <file> — emit lines of "<unix_ts>\t<summary>" for each
# VEVENT with a valid DTSTART. Only handles UTC + local timestamp forms.
parse_one_ics() {
    local f="$1"
    [[ -r "$f" ]] || return 0
    awk '
        BEGIN { in_event = 0; sum = ""; start = "" }
        /^BEGIN:VEVENT/  { in_event = 1; sum = ""; start = ""; next }
        /^END:VEVENT/    {
            if (in_event && start != "") {
                # Convert DTSTART to unix ts. Forms we accept:
                #   20240620T140000Z          (UTC)
                #   20240620T140000           (floating local)
                #   20240620                  (all-day)
                # We rely on `date -d` for parsing.
                cmd = "date -d \"" start "\" +%s 2>/dev/null"
                cmd | getline ts
                close(cmd)
                if (ts ~ /^[0-9]+$/) {
                    print ts "\t" sum
                }
            }
            in_event = 0; sum = ""; start = ""
            next
        }
        in_event && /^SUMMARY[:;]/  { sub(/^SUMMARY[^:]*:/, ""); sum = $0; next }
        in_event && /^DTSTART[:;]/  {
            sub(/^DTSTART[^:]*:/, "")
            if (length($0) == 8) {
                # All-day: 20240620 → 2024-06-20
                start = substr($0,1,4) "-" substr($0,5,2) "-" substr($0,7,2)
            } else if (length($0) >= 15) {
                # 20240620T140000(Z?) → 2024-06-20T14:00:00(Z?)
                start = substr($0,1,4) "-" substr($0,5,2) "-" substr($0,7,2) \
                        "T" substr($0,10,2) ":" substr($0,12,2) ":" substr($0,14,2) \
                        (substr($0,16,1) == "Z" ? "Z" : "")
            }
            next
        }
    ' "$f"
}

derive_agenda_json() {
    local dir="$1"
    local now="${CAL_NOW:-$(date +%s)}"
    local today_start
    today_start=$(date -d "@$now" +%Y-%m-%d)
    today_start=$(date -d "${today_start}T00:00:00" +%s)
    local today_end=$((today_start + 86400))

    if [[ ! -d "$dir" ]]; then
        jq -nc --argjson updated "$now" \
           '{events:[], today_count:0, next_minutes_until:null, updated:$updated}'
        return
    fi

    # Aggregate all events across all *.ics files, filter to future, sort,
    # take top 8.
    local tmp; tmp=$(mktemp)
    trap "rm -f $tmp" RETURN
    local f
    for f in "$dir"/*.ics; do
        [[ -e "$f" ]] || continue
        parse_one_ics "$f" >> "$tmp"
    done

    # tmp: "<ts>\t<summary>" lines, possibly empty. Filter, sort, top 8,
    # then emit as JSON via jq.
    local events_json today_count next_minutes
    events_json=$(awk -F'\t' -v now="$now" -v today_end="$today_end" '
        $1 >= now { print $0 }
    ' "$tmp" | sort -n | head -8 | awk -F'\t' -v now="$now" -v today_end="$today_end" '
        {
            ts=$1; sum=$2
            mins = int((ts - now) / 60)
            cmd = "date -d \"@" ts "\" +%H:%M"; cmd | getline hm; close(cmd)
            if (ts < today_end) {
                start_text = hm
            } else {
                cmd2 = "date -d \"@" ts "\" \"+%a %H:%M\""; cmd2 | getline st; close(cmd2)
                start_text = st
            }
            printf "{\"summary\":\"%s\",\"start\":%d,\"start_text\":\"%s\",\"minutes_until\":%d}\n",
                   sum, ts, start_text, mins
        }
    ' | jq -s '.')

    today_count=$(awk -F'\t' -v now="$now" -v today_end="$today_end" '
        $1 >= now && $1 < today_end { c++ } END { print c+0 }
    ' "$tmp")

    next_minutes=$(printf '%s' "$events_json" | jq -r '.[0].minutes_until // null')

    jq -nc --argjson events "$events_json" \
       --argjson today_count "$today_count" \
       --argjson next "${next_minutes:-null}" \
       --argjson updated "$now" \
       '{events:$events, today_count:$today_count, next_minutes_until:$next, updated:$updated}'
}

[[ -n "${CAL_SOURCE_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
while true; do
    cache_signal_if_changed "$CACHE" "$(derive_agenda_json "$CAL_DIR")" "$SIG"
    sleep "$POLL_INTERVAL"
done
```

- [ ] **Step 4: Run the test, see it pass**

```
chmod +x /etc/nixos/home/scripts/cal-source-daemon.sh
bash /etc/nixos/home/tests/wave3/test_cal_source_daemon.sh
```

Expected: all PASS.

- [ ] **Step 5: Nix module + wire + canvas yuck**

`modules/cal-source-daemon.nix`:

```nix
{ config, lib, pkgs, ... }:
let cfg = config.services.calSourceDaemon; in
{
  options.services.calSourceDaemon = {
    enable = lib.mkEnableOption "StandardOS calendar source daemon (ICS → agenda)";
    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds between ICS re-reads.";
    };
  };
  config = lib.mkIf cfg.enable {
    systemd.user.services.cal-source-daemon = {
      Unit.Description = "StandardOS calendar source (ICS → agenda.json)";
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "CAL_POLL_INTERVAL=${toString cfg.pollInterval}"
          "PATH=${pkgs.jq}/bin:${pkgs.gawk}/bin:${pkgs.coreutils}/bin:${pkgs.procps}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/cal-source-daemon.sh";
        Restart = "always";
        RestartSec = "10";
      };
    };
  };
}
```

Same wire + enable + canvas yuck pattern.

Replace `field-agenda-card` (around line 300):

```yuck
(defwidget field-agenda-card []
  (box :class "field-card field-agenda" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (label :class "field-lk" :text "TODAY · NO EVENTS" :halign "start")
    (label :class "field-empty" :text "Agenda will populate once cal-source lands (Wave 3)."
           :wrap true :limit-width 28 :halign "start")))
```

With:

```yuck
(defpoll agenda-events :interval "30s" :initial "[]"
  `jq -c '.events // []' /tmp/waybar-cache/agenda.json 2>/dev/null || echo "[]"`)
(defpoll agenda-today-count :interval "30s" :initial "0"
  `jq -r '.today_count // 0' /tmp/waybar-cache/agenda.json 2>/dev/null || echo 0`)

(defwidget field-agenda-event [summary start-text minutes-until]
  (box :class {minutes-until < 30 ? "field-agenda-row field-agenda-imminent" : "field-agenda-row"}
       :orientation "horizontal" :space-evenly false :spacing 6
    (label :class "field-agenda-when"    :text start-text :halign "start")
    (label :class "field-agenda-summary" :text summary    :halign "start" :hexpand true)))

(defwidget field-agenda-card []
  (box :class "field-card field-agenda" :orientation "vertical" :space-evenly false :spacing 4 :hexpand true
    (label :class "field-lk"
           :text {agenda-today-count == "0" ? "TODAY · NO EVENTS" : ("TODAY · " + agenda-today-count + " EVENT" + (agenda-today-count == "1" ? "" : "S"))}
           :halign "start")
    (box :class "field-agenda-list" :orientation "vertical" :space-evenly false :spacing 4
      (for e in {agenda-events}
        (field-agenda-event :summary {e.summary} :start-text {e.start_text} :minutes-until {e.minutes_until})))))
```

Add SCSS:

```scss
.field-agenda-list { padding-top: 2px; }
.field-agenda-row {
  padding: 3px 6px;
  border-radius: 8px;
}
.field-agenda-when    { color: rgba(255,255,255,0.65); font-size: 9pt; min-width: 56px; }
.field-agenda-summary { color: rgba(255,255,255,0.95); font-size: 10pt; }
@keyframes agenda-glow {
  0%, 100% { box-shadow: inset 0 0 0 1px rgba(150, 130, 255, 0.0); }
  50%      { box-shadow: inset 0 0 0 1px rgba(150, 130, 255, 0.55); }
}
.field-agenda-imminent {
  animation: agenda-glow 2.6s ease-in-out infinite;
}
```

- [ ] **Step 6: Rebuild + start + smoke-test with a fixture ICS**

```
cd /etc/nixos && sudo nixos-rebuild switch
systemctl --user start cal-source-daemon.service
mkdir -p ~/.config/standardos/calendars
cat > ~/.config/standardos/calendars/test.ics <<EOF
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
SUMMARY:Wave 3 verify event
DTSTART:$(date -u -d '+1 hour' +%Y%m%dT%H%M%SZ)
DTEND:$(date -u -d '+2 hour' +%Y%m%dT%H%M%SZ)
END:VEVENT
END:VCALENDAR
EOF
systemctl --user restart cal-source-daemon.service
sleep 2
cat /tmp/waybar-cache/agenda.json | jq .
systemctl --user restart standardos-canvas.service
```

Expected: agenda.json has one event. Open canvas; FIELD row 1 agenda card shows it.

- [ ] **Step 7: Update ARCHITECTURE.md + commit**

Add daemon registry + signal table rows. Mark RTMIN+20 as taken.

```
cd /etc/nixos/home && git add scripts/cal-source-daemon.sh modules/cal-source-daemon.nix widgets/eww/eww.yuck widgets/eww/eww.scss tests/wave3/test_cal_source_daemon.sh waybar/ARCHITECTURE.md && git add <home.nix> && git commit -m 'wave3: cal-source-daemon (RTMIN+20) — agenda card reads local ICS (Wave 3 Task 7)'
```

---

## Task 8: Wave 3 graduation — TODO.md + todonow.md + design spec deltas

Wraps up the wave. Single commit consolidating documentation.

**Files:**
- Modify: `waybar/TODO.md`, `waybar/todonow.md`, `docs/superpowers/specs/2026-06-19-widgets-canvas-design.md`

- [ ] **Step 1: Move the Wave 3 entry from todonow.md TODO → DONE-equivalent**

In `waybar/todonow.md`, the Wave 3 line under item 7 (Widgets) reads:

```
   - Wave 3 (new daemons: weather-fetch · cal-source · pomodoro-state ·
     notif-history channel · system-daemon RTMIN+18 · mpris-waybar truth) — TODO
```

Change `— TODO` to `— DONE 2026-06-XX` (use today's date).

- [ ] **Step 2: Add a Wave 3 graduation entry to waybar/TODO.md DONE**

Above the existing Wave 2 DONE entry, add:

```
- **2026-06-XX** — **widgets-canvas Wave 3 shipped: all 6 scaffolds
  replaced by real daemons.** weather-daemon (wttr.in cache),
  system-daemon (RTMIN+18, sys-{cpu,gpu,mem,battery,temp,disk-*}),
  notif-history-channel (existing notif-os-daemon JSONL → canvas
  cache), pomodoro-daemon + pomodoroctl (RTMIN+19, FIFO-driven),
  mpris-waybar truth (canvas reads /tmp/waybar-cache/mpris-*),
  cal-source-daemon (RTMIN+20, ~/.config/standardos/calendars/*.ics
  → agenda.json). Canvas now has zero "ships in Wave 3" placeholders.
  Per-canvas CPU stays under 2 % with canvas open (Wave 2 §9.12
  budget).
  **Hint:** All five new daemons share scripts/lib/canvas-cache.sh
  for atomic write + dedup-signal — same pattern as waybar's pill.sh
  but writer-side, no waybar-class concerns. New daemons reuse this
  primitive instead of re-deriving it.
  **Hint:** RTMIN+18 was already reserved for system-daemon in
  ARCHITECTURE.md (planned, since 2026-06-06). +19 (pomodoro) and
  +20 (cal-source) are newly claimed from the FREE pool.
  **Hint:** cal-source-daemon v0 reads local ICS only; CalDAV /
  Google Calendar direct sync is explicit Wave 4+ follow-up. Users
  on those services run a separate sync tool that drops .ics into
  ~/.config/standardos/calendars/.
```

- [ ] **Step 3: Strike-through the design spec's Wave 3 sketch**

`docs/superpowers/specs/2026-06-19-widgets-canvas-design.md` §8 — Wave 3 paragraph:

Before:
```
### Wave 3 — Dashboard widgets requiring new daemons

- `weather` (new daemon), `agenda` (new daemon), `pomodoro` (new daemon),
  `notifications-list` (notif-daemon extension), `system-stats` (depends on
  NEXT system daemon).
```

After:
```
### Wave 3 — Dashboard widgets requiring new daemons ✓ SHIPPED 2026-06-XX

- `weather` (new daemon: weather-daemon), `agenda` (new daemon:
  cal-source-daemon, v0 reads local ICS), `pomodoro` (new daemon:
  pomodoro-daemon + pomodoroctl), `notifications-list` (notif-daemon
  shell channel over the existing JSONL journal), `system-stats`
  (system-daemon shipped at RTMIN+18), `media-player` truth
  (canvas reads mpris-waybar caches; rewrite continues in
  /home/max/mpris-waybar/). See
  `docs/superpowers/plans/2026-06-20-widgets-canvas-wave-3.md` for
  the implementation plan.
```

- [ ] **Step 4: Verify Wave 3 success — full canvas walk**

Open the canvas. Walk:

1. CROWN — all 9 toggles + workspaces strip — should be unchanged from Wave 2.
2. HERO left (clock+weather) — illustration matches actual weather; temp + hi/lo are real.
3. HERO middle (media-MEGA) — if a player is up, real title/artist/cover-via-mpris-truth (depending on what mpris-waybar exposes); if no player, "—" everywhere — no playerctl shell-out spike.
4. HERO right (rings) — all 6 rings paint real %s (vitals: /, /home, Battery; perf: Wi-Fi, GPU, MEM).
5. 5 sliders — unchanged from Wave 2.
6. FIELD row 1 calendar / agenda / notes / notifications — calendar unchanged, **agenda paints next 8 events from local ICS**, notes unchanged, **notifications paints the JSONL journal**.
7. FIELD row 2 NETWORK / SYSTEM·TEMPS / FOCUS — NETWORK unchanged (network daemon = Wave 4), **SYSTEM·TEMPS reads sys-cpu/sys-temp**, **FOCUS has start/skip/stop buttons + breathes during running**.
8. CPU when canvas open: `top -p $(pgrep eww)` should stay under ~2 %.
9. Esc closes the canvas.

- [ ] **Step 5: Verify daemons stay healthy after the canvas closes**

After dismissing the canvas:

```
systemctl --user status weather-daemon system-daemon notif-history-channel pomodoro-daemon cal-source-daemon
```

Expected: all `active (running)`. No restart-loop chatter in journal.

- [ ] **Step 6: Commit the graduation**

```
cd /etc/nixos/home && git add waybar/TODO.md waybar/todonow.md docs/superpowers/specs/2026-06-19-widgets-canvas-design.md && git commit -m 'wave3: graduation — all 6 scaffolds replaced (Wave 3 Task 8)'
```

---

## Self-review (run after writing, before handing off)

**1. Spec coverage:** Each of the 6 daemons named in `todonow.md` Wave 3 has a dedicated task: weather-fetch → Task 2; cal-source → Task 7; pomodoro-state → Task 5; notif-history channel → Task 4; system-daemon RTMIN+18 → Task 3; mpris-waybar truth → Task 6. Tasks 1 (shared lib) and 8 (graduation) are the necessary scaffolding around them.

**2. Placeholder scan:** Two intentional "<home.nix>" placeholders in commit commands — the user's home.nix path is repo-shape-specific and the executor must `grep -rln widgets-canvas` to find it first; I name the grep in Task 2 Step 6. One "<path-to-home.nix>" same kind. One "DONE 2026-06-XX" placeholder for today's date — `date +%Y-%m-%d` substitutes at execution time. No "TBD," no "add appropriate error handling," no "similar to Task N."

**3. Type consistency:** The Task 1 library functions are called consistently by name in Tasks 2/3/4/5/7 (`cache_write_atomic`, `cache_signal_if_changed`, `cache_read_or_default`). The cache file naming (`/tmp/waybar-cache/<name>.json`) is consistent. Signal numbers: 12 (notif), 18 (system), 19 (pomodoro), 20 (cal-source) — no collisions.

**4. Granularity check:** Tasks 1, 4, 6 are small (1 daemon or 1 wiring); Tasks 2, 3, 5, 7 are medium (daemon + Nix module + canvas integration + tests); Task 8 is pure docs. Each ends with an independently-testable deliverable + a commit.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-20-widgets-canvas-wave-3.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task with two-stage review between tasks. Best for this plan because tasks 1–7 are largely independent (Task 1 is the only true upstream dependency for the rest) and reviewing each daemon in isolation catches the dedup hazard cleanly.

2. **Inline Execution** — execute the tasks in this session using `superpowers:executing-plans`. Faster if you want to watch the changes live and the session has the bandwidth; risks rolling the user's CPU budget out of canvas-spec compliance without an explicit budget check.

Which approach?
