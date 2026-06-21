# Canvas media-MEGA — mpris truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the canvas media-MEGA card's 8 playerctl-forking defpolls with a single inotify-driven deflisten that reads a new composite JSON written by `mpris-publisher` (now systemd-supervised), and wire cover art + progress-bar width in the same swap.

**Architecture:** Publisher gains one new output channel (`/tmp/waybar-cache/mpris-snapshot.json`) computed from existing internal state plus a 1 s position ticker; new pure helpers (`derive_composite_json`, `derive_pos_text`, `derive_pct`, the existing `json_str`) move into `lib/mpris.sh` for testability. A new Nix module ships the publisher as a systemd user unit. Eww swaps 8 defpolls → 1 deflisten subscribed via `inotifywait -m /tmp/waybar-cache --format '%f'` filtered by basename (composite-module pattern). The 8 widget label/text bindings rewire to `mpris-snapshot.<field>` accessors; `mm-bar-fill` width interpolates via `:style "min-width: ${pct}%"`; cover art renders via `image :path={mpris-snapshot.art_path ?: ""}` over the existing stable `/tmp/mpris/current` symlink the publisher already maintains.

**Tech Stack:** Bash 5.x (`set -uo pipefail`), jq, playerctl, inotify-tools, Eww 0.5+ with `deflisten`, NixOS Home Manager systemd-user units. No new runtime deps.

## Global Constraints

- **Composite-module pattern (hard):** every consumer that watches `/tmp/waybar-cache/<name>` for atomic-rewrite events MUST `inotifywait -m --format '%f'` on the parent dir and filter by basename. Per-file watches die after the first `tmp+mv` because the inode is unlinked. Documented in `waybar/ARCHITECTURE.md` and the standard-os skill hazard list.
- **Atomic writes only:** every cache write goes via `printf > tmp` then `mv -f tmp final`. Never write directly to the final path.
- **No error pills:** all failures log to journalctl (`log()` helper for the publisher; nothing at all for the listener — eww deflisten respawns on script exit). No `notify-send`, no red pill, no toast.
- **`nixos-rebuild switch`, not `test`:** Nix module activation requires `switch` per the `feedback_nixos_rebuild_switch_not_test.md` memory. `test` activates in RAM only and reboot reverts the unit.
- **StandardOS naming in prose:** new docs/spec/TODO entries use "StandardOS" (not "OPTIONS") per the `feedback_use_standardos_not_options.md` memory. Existing files are not retroactively renamed.
- **`.empty` collapse requires `font-size: 0`:** any label-bearing widget that collapses via `.empty` MUST set `font-size: 0` alongside `padding: 0; margin: 0; opacity: 0`, or label glyphs keep their natural width. Standard-os skill hazard list.
- **`set -u` + associative arrays:** any new `declare -A FOO` must use `declare -A FOO=()` (explicit empty assignment) so `${#FOO[@]}` / `${!FOO[@]}` don't trip unbound-variable under `set -u`. Pattern enforced by existing code at `mpris-publisher:53`.
- **One commit per task,** small and behavior-framed in the imperative — matches Wave 3 commit style (`wave3: <what changed>` prefix where Wave 3 work continues).
- **mpris-waybar repo is not git-tracked.** Edits there are uncommitted; the commit boundary is the StandardOS repo (`/etc/nixos/home/`). Mention publisher edits in the commit message body as "Modified (no-git): /home/max/mpris-waybar/…".

---

### Task 1: Publisher — composite JSON output + library-mode helpers + TDD

**Files:**
- Modify: `/home/max/mpris-waybar/scripts/lib/mpris.sh` (gain `json_str`, `derive_pos_text`, `derive_pct`, `derive_composite_json`)
- Modify: `/home/max/mpris-waybar/scripts/mpris-publisher:43` (extend `declare -A` with `P_POS_SEC P_LEN_SEC`)
- Modify: `/home/max/mpris-waybar/scripts/mpris-publisher:297-341` (remove `json_str` body; now sourced from lib)
- Modify: `/home/max/mpris-waybar/scripts/mpris-publisher:237-269` (extend `apply_metadata` to populate `P_LEN_SEC[bus]` from `mpris:length`)
- Modify: `/home/max/mpris-waybar/scripts/mpris-publisher:638-760` (add `write_snapshot_composite()` definition; call it from `write_snapshot` tail)
- Modify: `/home/max/mpris-waybar/scripts/mpris-publisher:893-906` (add `position_ticker_loop()` definition; start it `&` after `info_marquee_loop &`)
- Create: `/home/max/mpris-waybar/tests/test_mpris_publisher_composite.sh`

**Interfaces:**
- Produces: cache file `/tmp/waybar-cache/mpris-snapshot.json` with shape documented in the spec § Cache.
- Produces (for later tasks): `derive_composite_json` pure function in `lib/mpris.sh` accepting `active player source_label title artist album status status_glyph pos_sec len_sec pos_text len_text pct art_path` (14 positional args, all strings; ints accepted as strings); returns JSON on stdout.

- [ ] **Step 1: Write the failing test**

Create `/home/max/mpris-waybar/tests/test_mpris_publisher_composite.sh`:

```bash
#!/usr/bin/env bash
# Tests for derive_composite_json, derive_pos_text, derive_pct + json_str
# (post-move). Pure functions in lib/mpris.sh, sourced library-style.
set -uo pipefail

HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=/dev/null
. "$HERE/../scripts/lib/mpris.sh"

pass=0
fail=0
assert_eq() {
    local name=$1 want=$2 got=$3
    if [[ $want == "$got" ]]; then
        printf '  ok   %s\n' "$name"
        ((pass++))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got"
        ((fail++))
    fi
}

# ── derive_pos_text ──────────────────────────────────────────────────────────
assert_eq "pos_text 0"       "—:—" "$(derive_pos_text 0)"
assert_eq "pos_text 73"      "1:13" "$(derive_pos_text 73)"
assert_eq "pos_text 5"       "0:05" "$(derive_pos_text 5)"
assert_eq "pos_text 3661"    "61:01" "$(derive_pos_text 3661)"

# ── derive_pct ───────────────────────────────────────────────────────────────
assert_eq "pct 0 over 0"     "0"   "$(derive_pct 0 0)"
assert_eq "pct 0 over 100"   "0"   "$(derive_pct 0 100)"
assert_eq "pct 50 over 200"  "25"  "$(derive_pct 50 200)"
assert_eq "pct 200 over 200" "100" "$(derive_pct 200 200)"
assert_eq "pct 250 over 200" "100" "$(derive_pct 250 200)" # clamp

# ── json_str (moved from publisher) ──────────────────────────────────────────
assert_eq "json_str empty"      '""'              "$(json_str '')"
assert_eq "json_str ascii"      '"hello"'         "$(json_str 'hello')"
assert_eq "json_str quote"      '"a\"b"'          "$(json_str 'a"b')"
assert_eq "json_str backslash"  '"a\\b"'          "$(json_str 'a\b')"

# ── derive_composite_json: active player ─────────────────────────────────────
active_json=$(derive_composite_json \
    "true" "spotify" "SPOTIFY · NOW PLAYING" \
    "Strobe" "deadmau5" "For Lack of a Better Name" \
    "Playing" "⏸" \
    "73" "633" "1:13" "10:33" "11" \
    "/tmp/mpris/current")

# Field-by-field via jq for stable comparison
assert_eq "active true"     "true"                          "$(jq -r .active        <<<"$active_json")"
assert_eq "player"          "spotify"                       "$(jq -r .player        <<<"$active_json")"
assert_eq "source_label"    "SPOTIFY · NOW PLAYING"         "$(jq -r .source_label  <<<"$active_json")"
assert_eq "title"           "Strobe"                        "$(jq -r .title         <<<"$active_json")"
assert_eq "artist"          "deadmau5"                      "$(jq -r .artist        <<<"$active_json")"
assert_eq "album"           "For Lack of a Better Name"     "$(jq -r .album         <<<"$active_json")"
assert_eq "status"          "Playing"                       "$(jq -r .status        <<<"$active_json")"
assert_eq "status_glyph"    "⏸"                             "$(jq -r .status_glyph  <<<"$active_json")"
assert_eq "pos_sec"         "73"                            "$(jq -r .pos_sec       <<<"$active_json")"
assert_eq "len_sec"         "633"                           "$(jq -r .len_sec       <<<"$active_json")"
assert_eq "pct"             "11"                            "$(jq -r .pct           <<<"$active_json")"
assert_eq "pos_text"        "1:13"                          "$(jq -r .pos_text      <<<"$active_json")"
assert_eq "len_text"        "10:33"                         "$(jq -r .len_text      <<<"$active_json")"
assert_eq "art_path"        "/tmp/mpris/current"            "$(jq -r .art_path      <<<"$active_json")"
assert_eq "updated is int"  "number"                        "$(jq -r '.updated | type' <<<"$active_json")"

# ── derive_composite_json: no player (empty sentinel) ────────────────────────
empty_json=$(derive_composite_json "false" "" "" "" "" "" "" "⏵" "0" "0" "—:—" "—:—" "0" "")
assert_eq "empty active false"  "false"   "$(jq -r .active        <<<"$empty_json")"
assert_eq "empty title"         ""        "$(jq -r .title         <<<"$empty_json")"
assert_eq "empty pos_sec"       "0"       "$(jq -r .pos_sec       <<<"$empty_json")"
assert_eq "empty pct"           "0"       "$(jq -r .pct           <<<"$empty_json")"
assert_eq "empty art_path"      ""        "$(jq -r .art_path      <<<"$empty_json")"
assert_eq "empty status_glyph"  "⏵"       "$(jq -r .status_glyph  <<<"$empty_json")"

# ── Quote/backslash safety in title ──────────────────────────────────────────
quote_json=$(derive_composite_json "true" "p" "" 'a"b\c' "" "" "Playing" "⏸" "0" "0" "0:00" "0:00" "0" "")
assert_eq "title with quote+bs preserved" 'a"b\c' "$(jq -r .title <<<"$quote_json")"

echo
echo "pass: $pass / fail: $fail"
[[ $fail -eq 0 ]] || exit 1
```

Make executable: `chmod +x /home/max/mpris-waybar/tests/test_mpris_publisher_composite.sh`

- [ ] **Step 2: Run test to verify it fails**

```
bash /home/max/mpris-waybar/tests/test_mpris_publisher_composite.sh
```

Expected: FAIL with `derive_pos_text: command not found` (or similar — none of the helpers exist in lib yet).

- [ ] **Step 3: Move `json_str` from publisher to lib + add the three new pure helpers**

Add to the bottom of `/home/max/mpris-waybar/scripts/lib/mpris.sh`:

```bash
# json_str <s>: emit a JSON-safe string literal. Pure-bash, no forks for the
# fast path (printable ASCII without quote/backslash). Moved here from
# mpris-publisher so derive_composite_json and tests can reuse it.
json_str() {
    local s=$1
    if [[ $s != *[!\ -\!\#-\[\]-~]* ]]; then
        printf '"%s"' "$s"
        return
    fi
    local r='"' i c hex
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in
        '"') r+='\"' ;;
        '\') r+='\\' ;;
        $'\n') r+='\n' ;;
        $'\r') r+='\r' ;;
        $'\t') r+='\t' ;;
        $'\b') r+='\b' ;;
        $'\f') r+='\f' ;;
        *)
            printf -v hex '%d' "'$c"
            if ((hex < 32)); then
                printf -v r '%s\\u%04x' "$r" "$hex"
            else
                r+=$c
            fi
            ;;
        esac
    done
    printf '%s"' "$r"
}

# derive_pos_text <seconds> → "M:SS" (e.g. "1:13", "61:01"). 0 or negative → "—:—".
derive_pos_text() {
    local s=${1:-0}
    if (( s <= 0 )); then
        printf '—:—'
        return
    fi
    printf '%d:%02d' $((s / 60)) $((s % 60))
}

# derive_pct <pos_sec> <len_sec> → integer 0..100, clamped.
# Returns 0 when len_sec <= 0.
derive_pct() {
    local pos=${1:-0} len=${2:-0}
    if (( len <= 0 )); then
        printf '0'
        return
    fi
    local pct=$(( (pos * 100) / len ))
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    printf '%d' "$pct"
}

# derive_composite_json <active> <player> <source_label> <title> <artist> <album>
#                       <status> <status_glyph> <pos_sec> <len_sec>
#                       <pos_text> <len_text> <pct> <art_path>
# → one-line JSON to stdout, ready for atomic write. Uses EPOCHSECONDS for
# the `updated` field (no fork).
derive_composite_json() {
    local active=$1 player=$2 source_label=$3 \
          title=$4 artist=$5 album=$6 \
          status=$7 status_glyph=$8 \
          pos_sec=$9 len_sec=${10} \
          pos_text=${11} len_text=${12} pct=${13} \
          art_path=${14}
    printf '{"active":%s,"player":%s,"source_label":%s,"title":%s,"artist":%s,"album":%s,"status":%s,"status_glyph":%s,"pos_sec":%d,"len_sec":%d,"pct":%d,"pos_text":%s,"len_text":%s,"art_path":%s,"updated":%d}' \
        "$active" \
        "$(json_str "$player")" \
        "$(json_str "$source_label")" \
        "$(json_str "$title")" \
        "$(json_str "$artist")" \
        "$(json_str "$album")" \
        "$(json_str "$status")" \
        "$(json_str "$status_glyph")" \
        "${pos_sec:-0}" "${len_sec:-0}" "${pct:-0}" \
        "$(json_str "$pos_text")" \
        "$(json_str "$len_text")" \
        "$(json_str "$art_path")" \
        "${EPOCHSECONDS:-0}"
}
```

Note: `active` is the literal string `true` or `false` (interpolated as JSON without `json_str` quoting). `pos_sec` / `len_sec` / `pct` use `%d` so any non-numeric input would explode loud — that's intentional (callers must pass ints).

Then remove the `json_str` function body from `mpris-publisher` (lines 297-341), replacing it with a single-line note pointing at the lib:

```bash
# json_str moved to lib/mpris.sh — same byte-for-byte impl, sourced via $MPRIS_LIB.
```

- [ ] **Step 4: Run test to verify it passes**

```
bash /home/max/mpris-waybar/tests/test_mpris_publisher_composite.sh
```

Expected: `pass: 28 / fail: 0` (or whatever exact count of `assert_eq` calls — count from Step 1). All green.

- [ ] **Step 5: Wire `P_LEN_SEC` into `apply_metadata`**

Modify `/home/max/mpris-waybar/scripts/mpris-publisher`. The `apply_metadata` function currently extracts 6 fields. Extend to 7 (length), and store in `P_LEN_SEC` (microseconds → seconds).

At line 43 (the `declare -A` line), append:

```bash
declare -A P_STATUS P_TITLE P_ARTIST P_ALBUM P_ART_URL P_ART_LOCAL P_VOLUME P_VOLSUPPORTED P_POS_SEC=() P_LEN_SEC=()
```

(The `=()` on the two new arrays is mandatory per Global Constraints.)

At lines 230-233 (the `playerctl -p ... metadata` line in `refresh_metadata`), extend the JSON format to include length:

```bash
    line=$(playerctl -p "$bus" metadata --format \
        '{"status":"{{status}}","title":"{{markup_escape(title)}}","artist":"{{markup_escape(artist)}}","album":"{{markup_escape(album)}}","art":"{{mpris:artUrl}}","volume":"{{volume}}","length":"{{mpris:length}}"}' \
        2>/dev/null) || return 0
```

Similarly at line 112-114 in `start_producer_followctl`:

```bash
    playerctl --all-players --follow metadata --format \
        '{"src":"follow","player":"{{playerInstance}}","status":"{{status}}","title":"{{markup_escape(title)}}","artist":"{{markup_escape(artist)}}","album":"{{markup_escape(album)}}","art":"{{mpris:artUrl}}","volume":"{{volume}}","length":"{{mpris:length}}"}' \
        >&9 2>/dev/null &
```

At lines 238-243 (the `apply_metadata` jq extraction), add `length`:

```bash
    local bus=$1 line=$2 status title artist album art volume length
    IFS='|' read -r status title artist album art volume length < <(
        printf '%s' "$line" |
            jq -r '[.status // "", .title // "", .artist // "", .album // "", .art // "", .volume // "", .length // ""] | join("|")'
    ) || return 0
```

After line 250 (`P_ART_URL[$bus]=$art`), add:

```bash
    # length is microseconds. Empty/zero → 0 (unknown).
    if [[ -n $length && $length != "0" ]]; then
        P_LEN_SEC[$bus]=$(( length / 1000000 ))
    else
        P_LEN_SEC[$bus]=0
    fi
```

- [ ] **Step 6: Add `write_snapshot_composite()` and call it from `write_snapshot` tail**

Insert this function definition just before the `# ── Main loop ──` comment (around line 893 in the unmodified file, after `info_marquee_loop`):

```bash
# ── Composite snapshot (dashboard truth) ─────────────────────────────────────
# Sole writer of /tmp/waybar-cache/mpris-snapshot.json. Subscribed by the
# canvas dashboard's media-MEGA card via `inotifywait` on /tmp/waybar-cache
# (composite-module pattern). Position field comes from position_ticker_loop
# (separate writer; both go through this same function with byte-equal dedup).
_LAST_COMPOSITE=""
write_snapshot_composite() {
    local active_str player_disp source_label \
          title artist album status status_glyph \
          pos_sec len_sec pos_text len_text pct \
          art_path snap

    if [[ -n ${ACTIVE:-} ]]; then
        active_str="true"
        player_disp=$(player_display_name "$ACTIVE")
        local upper
        upper=$(printf '%s' "$player_disp" | tr '[:lower:]' '[:upper:]')
        source_label="${upper} · NOW PLAYING"
        title=${P_TITLE[$ACTIVE]:-}
        artist=${P_ARTIST[$ACTIVE]:-}
        album=${P_ALBUM[$ACTIVE]:-}
        status=${P_STATUS[$ACTIVE]:-}
        case "$status" in
            Playing) status_glyph="⏸" ;;
            *)       status_glyph="⏵" ;;
        esac
        pos_sec=${P_POS_SEC[$ACTIVE]:-0}
        len_sec=${P_LEN_SEC[$ACTIVE]:-0}
        # /tmp/mpris/current already maintained atomically by update_art_symlink.
        # Existence check: only expose the path when the symlink resolves.
        if [[ -e $ART_DIR/current ]]; then
            art_path="$ART_DIR/current"
        else
            art_path=""
        fi
    else
        active_str="false"
        player_disp=""
        source_label=""
        title=""; artist=""; album=""
        status=""; status_glyph="⏵"
        pos_sec=0; len_sec=0
        art_path=""
    fi

    pos_text=$(derive_pos_text "$pos_sec")
    len_text=$(derive_pos_text "$len_sec")
    pct=$(derive_pct "$pos_sec" "$len_sec")

    snap=$(derive_composite_json \
        "$active_str" "$player_disp" "$source_label" \
        "$title" "$artist" "$album" \
        "$status" "$status_glyph" \
        "$pos_sec" "$len_sec" \
        "$pos_text" "$len_text" "$pct" \
        "$art_path")

    # In-memory dedup. Position ticker calls this every 1s when Playing —
    # without dedup, idle Paused state would still rewrite every tick.
    [[ $snap == "$_LAST_COMPOSITE" ]] && return
    _LAST_COMPOSITE=$snap

    printf '%s\n' "$snap" >"$CACHE_DIR/mpris-snapshot.json.tmp" \
        && mv -f "$CACHE_DIR/mpris-snapshot.json.tmp" "$CACHE_DIR/mpris-snapshot.json"
}
```

In `write_snapshot()`, append `write_snapshot_composite` after `write_cava_target_inline` at line 759 (the existing last line of the function before the closing `}`):

```bash
    write_cava_target_inline
    write_snapshot_composite   # NEW: dashboard truth, dedup'd in-memory
}
```

- [ ] **Step 7: Add `position_ticker_loop()` and start it in init**

Insert this function just below `write_snapshot_composite`:

```bash
# ── Position ticker ──────────────────────────────────────────────────────────
# Every 1s, when an active player is Playing, poll its position with playerctl
# and re-emit the composite. When not Playing (or no ACTIVE), sleep without
# forking playerctl. Zero idle cost when nothing is playing.
position_ticker_loop() {
    local pos_str pos_int
    while true; do
        if [[ -n ${ACTIVE:-} && ${P_STATUS[$ACTIVE]:-} == "Playing" ]]; then
            # playerctl returns float seconds. Truncate to int.
            pos_str=$(playerctl --player="$ACTIVE" position 2>/dev/null || echo "")
            if [[ -n $pos_str ]]; then
                pos_int=${pos_str%.*}
                P_POS_SEC[$ACTIVE]=${pos_int:-0}
                write_snapshot_composite
            fi
        fi
        sleep 1
    done
}
```

In the init block, just after `info_marquee_loop &` at line 906, add:

```bash
info_marquee_loop &
position_ticker_loop &
```

- [ ] **Step 8: Re-run the test and smoke-test the live publisher**

```
bash /home/max/mpris-waybar/tests/test_mpris_publisher_composite.sh
```

Expected: still all green (we didn't touch lib semantics, only added consumers).

Then smoke-test the live script:

```
# Kill any stale instance first
pkill -f mpris-publisher 2>/dev/null
sleep 1

# Start in foreground for visibility
bash /home/max/mpris-waybar/scripts/mpris-publisher &
PUB_PID=$!
sleep 2

# Inspect the new composite cache. Start a player (or have one running) first.
cat /tmp/waybar-cache/mpris-snapshot.json | jq .

# When nothing is playing → expect "active": false, empty strings, status_glyph "⏵".
# Start playing → expect "active": true, title/artist filled, status "Playing",
#                  status_glyph "⏸", pos_sec advancing per second, art_path
#                  pointing at /tmp/mpris/current (which itself resolves to an art file).

# Sanity: verify position advances every second while Playing
for i in 1 2 3; do
    jq -r '.pos_sec' /tmp/waybar-cache/mpris-snapshot.json
    sleep 1
done
# Expected: 3 monotonically increasing integers.

# Cleanup
kill $PUB_PID 2>/dev/null
```

Expected: all four behaviors hold. If `art_path` is empty even with art on screen, check `/tmp/mpris/current` exists (it's the publisher's own symlink; absence is a separate bug — out of this task's scope but flag if seen).

- [ ] **Step 9: Commit (StandardOS repo only — mpris-waybar is not git-tracked)**

```bash
cd /etc/nixos/home
git add docs/superpowers/specs/2026-06-21-canvas-media-mpris-truth-design.md \
        docs/superpowers/plans/2026-06-21-canvas-media-mpris-truth.md
git commit -m "$(cat <<'EOF'
spec+plan: canvas media-MEGA reads mpris-publisher composite truth

Wave 3 Task 6 (deferred) resumes: publisher exposes a new composite JSON
channel at /tmp/waybar-cache/mpris-snapshot.json with title/artist/album/
status/pos/len/pct/art_path; dashboard rewires off 8 playerctl-shelling
defpolls to a single inotify deflisten. Publisher additions (P_LEN_SEC,
position ticker, write_snapshot_composite) implemented and unit-tested
in /home/max/mpris-waybar (not git-tracked; edits documented in the plan).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

(The publisher edits + new lib helpers + new test live in `/home/max/mpris-waybar/`, which is not a git repo — they're durable on disk but won't appear in this commit. The spec and plan ARE checked in to the StandardOS repo.)

---

### Task 2: Systemd user unit for mpris-publisher

**Files:**
- Create: `/etc/nixos/home/modules/mpris-publisher.nix`
- Modify: `/etc/nixos/home/home.nix` (import the new module)

**Interfaces:**
- Consumes: working publisher from Task 1 (writes `/tmp/waybar-cache/mpris-snapshot.json` on demand).
- Produces: a systemd user unit `mpris-publisher.service` that auto-starts with `graphical-session.target` and auto-restarts on failure. The publisher runs continuously thereafter, owning `/tmp/waybar-cache/mpris-snapshot.json`.

- [ ] **Step 1: Create the Nix module**

`/etc/nixos/home/modules/mpris-publisher.nix`:

```nix
{ pkgs, ... }:

{
  systemd.user.services.mpris-publisher = {
    Unit = {
      Description = "MPRIS publisher (StandardOS — owns /tmp/waybar-cache/mpris-* and /tmp/mpris/current)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" "pipewire.service" "dbus.socket" ];
      Wants = [ "pipewire.service" ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${pkgs.bash}/bin/bash /home/max/mpris-waybar/scripts/mpris-publisher";
      Restart = "on-failure";
      RestartSec = "2s";
      # Publisher relies on PATH for playerctl, jq, dbus-monitor, inotifywait,
      # pw-dump, pw-mon, wpctl, curl. Inherit the user session PATH explicitly.
      PassEnvironment = "PATH XDG_RUNTIME_DIR XDG_STATE_HOME WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS";
    };

    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # Runtime deps the publisher script forks. Listed here so they're guaranteed
  # in the user session even if home.nix's general installs change.
  home.packages = with pkgs; [
    playerctl
    jq
    dbus           # dbus-monitor
    inotify-tools  # inotifywait
    pipewire       # pw-dump, pw-mon
    wireplumber    # wpctl
    curl
  ];
}
```

Note: `home.packages` is additive — if any of these are already declared elsewhere in `home.nix`, Nix de-dups. Safe to repeat.

- [ ] **Step 2: Import the module from `home.nix`**

Read `/etc/nixos/home/home.nix` and locate the `imports = [` list. Add `./modules/mpris-publisher.nix` to that list. Example (the surrounding imports will already exist; add this line in alphabetical position):

```nix
  imports = [
    ./modules/brightness-daemon.nix
    ./modules/cal-source-daemon.nix
    # ...
    ./modules/mpris-publisher.nix      # NEW
    # ...
    ./modules/system-daemon.nix
  ];
```

If `home.nix` is structured differently (e.g. imports inlined), match the established pattern. Do NOT duplicate; if `mpris-publisher.nix` is already imported somehow, skip this step.

- [ ] **Step 3: Verify the module evaluates and rebuild**

```
sudo nixos-rebuild switch
```

Use `switch`, not `test` — `test` does not survive reboot (memory: `feedback_nixos_rebuild_switch_not_test.md`).

Expected: rebuild succeeds, switch activates new generation.

- [ ] **Step 4: Verify the unit is active and the publisher is running**

```
systemctl --user status mpris-publisher.service
```

Expected: `Active: active (running)`. PID > 0. If `inactive (dead)`, check `journalctl --user -u mpris-publisher.service -n 50` for the failure.

```
pgrep -af mpris-publisher
```

Expected: at least one matching line for `/home/max/mpris-waybar/scripts/mpris-publisher`.

```
ls -la /tmp/waybar-cache/mpris-snapshot.json
jq . /tmp/waybar-cache/mpris-snapshot.json
```

Expected: file exists, mtime within the last few seconds, valid JSON matching the documented shape.

- [ ] **Step 5: Verify auto-restart works**

```
PUB_PID=$(pgrep -f /home/max/mpris-waybar/scripts/mpris-publisher | head -1)
kill -9 $PUB_PID
sleep 3
systemctl --user status mpris-publisher.service
```

Expected: a NEW pid running, `Active: active (running)`, journal shows the `Restart=on-failure` did its job within ~2s.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add modules/mpris-publisher.nix home.nix
git commit -m "$(cat <<'EOF'
mpris-publisher: systemd user unit (auto-start with graphical-session)

Publisher now supervised; cache file mpris-snapshot.json populates within
~2s of session start and survives publisher crash via Restart=on-failure.
Script path is out-of-Nix-store (/home/max/mpris-waybar/scripts/) per the
established live-edit pattern for ~/.config/waybar/scripts daemons.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Eww rewire — listener + deflisten + media-MEGA widget + scss + delete scaffold

**Files:**
- Create: `/etc/nixos/home/widgets/scripts/canvas-mpris-listen` (executable)
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (delete defpolls, add deflisten, rewire `media-mega-frame`)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (add `.mm-art` + `.empty` cascade with `font-size: 0`)
- Delete: `/etc/nixos/home/widgets/scripts/canvas-media.sh`

**Interfaces:**
- Consumes: `/tmp/waybar-cache/mpris-snapshot.json` (from Task 1+2).
- Produces (visual): the media-MEGA card on the dashboard renders title/artist/album/source label + cover art + progress bar reflecting real-time MPRIS state, collapses to `.empty` when no player.

This task swaps a coupled set of file edits atomically — partial state would leave eww unable to parse `eww.yuck`. All edits go in one commit.

- [ ] **Step 1: Write the listener script**

Create `/etc/nixos/home/widgets/scripts/canvas-mpris-listen`:

```bash
#!/usr/bin/env bash
# Eww deflisten source for /tmp/waybar-cache/mpris-snapshot.json. Emits the
# current cache once at startup, then re-emits whenever the publisher swaps
# the file via tmp+mv. Watches the parent dir + filters by basename because
# per-file inotify watches die after the inode is unlinked (composite-module
# hazard, waybar/ARCHITECTURE.md).
set -u
CACHE_DIR=/tmp/waybar-cache
SNAP=mpris-snapshot.json
EMPTY='{"active":false,"player":"","source_label":"","title":"","artist":"","album":"","status":"","status_glyph":"⏵","pos_sec":0,"len_sec":0,"pct":0,"pos_text":"—:—","len_text":"—:—","art_path":"","updated":0}'

emit_once() {
    if [[ -r $CACHE_DIR/$SNAP ]]; then
        cat "$CACHE_DIR/$SNAP"
    else
        printf '%s\n' "$EMPTY"
    fi
}

emit_once

# inotifywait blocks; eww kills the script when it tears down the deflisten.
exec inotifywait -m -q --format '%f' -e close_write,moved_to "$CACHE_DIR" \
    | while IFS= read -r f; do
        [[ $f == "$SNAP" ]] && emit_once
    done
```

Make executable:
```
chmod +x /etc/nixos/home/widgets/scripts/canvas-mpris-listen
```

- [ ] **Step 2: Smoke-test the listener standalone**

```
# Confirm the publisher is running and the cache is populated
ls -la /tmp/waybar-cache/mpris-snapshot.json

# Run the listener; expect one immediate JSON line, then nothing until the publisher rewrites
/etc/nixos/home/widgets/scripts/canvas-mpris-listen &
LISTEN_PID=$!
sleep 1
# Provoke an update by pausing/unpausing a player (or seeking) — the listener should emit a new line.
# Then kill it:
kill $LISTEN_PID
```

Expected: one JSON line per state change, no spurious lines.

- [ ] **Step 3: Rewrite the eww.yuck section (defpolls → deflisten + widget body)**

In `/etc/nixos/home/widgets/eww/eww.yuck`, delete lines 65-72 (the eight `media-*` defpolls). Replace with one deflisten:

```
;; mpris-snapshot: composite JSON owned by mpris-publisher. One subscription
;; replaces the previous 8 defpolls (source/title/artist/album/status/pos/len/pct).
;; See: docs/superpowers/specs/2026-06-21-canvas-media-mpris-truth-design.md
(deflisten mpris-snapshot
  :initial `{"active":false,"player":"","source_label":"","title":"","artist":"","album":"","status":"","status_glyph":"⏵","pos_sec":0,"len_sec":0,"pct":0,"pos_text":"—:—","len_text":"—:—","art_path":"","updated":0}`
  `/etc/nixos/home/widgets/scripts/canvas-mpris-listen`)
```

In the `media-mega-frame` definition (line 229 onward), rewire field bindings. The current shape (lines 229-260 approx) references `media-source`, `media-title`, `media-artist`, `media-album`, `media-status`, `media-pos`, `media-len`, `media-pct`. Replace EACH such reference with `{mpris-snapshot.<field>}`. New body:

```
(defwidget media-mega-frame []
  (box :class {mpris-snapshot.active == "true" ? "media-mega" : "media-mega empty"}
       :orientation "vertical" :space-evenly false :spacing 7
    (box :orientation "horizontal" :space-evenly false :spacing 10
      (image :class "mm-art"
             :path {mpris-snapshot.art_path ?: ""}
             :image-width 92 :image-height 92)
      (box :orientation "vertical" :space-evenly false :spacing 2 :hexpand true
        (label :class "mm-source" :text {mpris-snapshot.source_label} :halign "start")
        (label :class "mm-title"  :text {mpris-snapshot.title}        :halign "start")
        (label :class "mm-artist" :text {mpris-snapshot.artist}       :halign "start")
        (label :class "mm-album"  :text {mpris-snapshot.album}        :halign "start")))
    (box :orientation "horizontal" :space-evenly false :spacing 8
      (label :class "mm-status" :text {mpris-snapshot.status_glyph})
      (label :class "mm-pos"    :text {mpris-snapshot.pos_text})
      (box :class "mm-bar" :hexpand true
        (box :class "mm-bar-fill" :hexpand false
             :style "min-width: ${mpris-snapshot.pct}%;"))
      (label :class "mm-len" :text {mpris-snapshot.len_text}))))
```

(Adjust child structure to match the existing widget's layout if it differs — the field names and `:style` interpolation are the substantive changes. The image block + `:style` line on `mm-bar-fill` are NEW; everything else is a 1:1 rewire.)

- [ ] **Step 4: Update eww.scss — `.mm-art` rule + `.empty` cascade with font-size:0**

In `/etc/nixos/home/widgets/eww/eww.scss`, add:

```scss
.mm-art {
    border-radius: 6px;
    background-color: rgba(0, 0, 0, 0.18); // placeholder tint when art_path empty
    min-width: 92px; min-height: 92px;
}

.media-mega.empty {
    // Collapse the whole card when no active player. font-size: 0 is mandatory
    // (StandardOS hazard) — label glyphs reserve natural width without it.
    padding: 0; margin: 0;
    opacity: 0;
    font-size: 0;
}
.media-mega.empty .mm-art {
    min-width: 0; min-height: 0;
    background-color: transparent;
}
```

- [ ] **Step 5: Delete the scaffold**

```
rm /etc/nixos/home/widgets/scripts/canvas-media.sh
```

- [ ] **Step 6: Reload eww and visually verify**

```
# Reload (eww watches its config but a manual reload forces a clean re-parse)
eww reload

# Open the canvas
hyprctl dispatch exec eww open dashboard
# (Or press Super+RETURN — same canvas-open script.)
```

Acceptance checklist (visual):
- [ ] No player active → media-MEGA collapses (no visible card).
- [ ] Start playing music → card appears, title/artist/album/source_label populated.
- [ ] Cover art renders in the 92×92 box (publisher's symlink resolves).
- [ ] Progress bar fills to roughly the right fraction; seeking updates within ~1s.
- [ ] Status glyph shows `⏸` while Playing; pause → flips to `⏵`.
- [ ] Swap to a different player (e.g. Firefox tab vs. Spotify) → source_label updates.
- [ ] Esc closes the canvas; reopen → still working.

If anything fails: check `journalctl --user -u eww-dashboard.service -n 50` (or wherever eww logs land) and `/tmp/waybar-cache/mpris-snapshot.json | jq .`.

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home
git add widgets/scripts/canvas-mpris-listen \
        widgets/eww/eww.yuck \
        widgets/eww/eww.scss
git rm widgets/scripts/canvas-media.sh
git commit -m "$(cat <<'EOF'
wave3: canvas media-MEGA reads mpris-publisher composite truth (Task 6)

Eight playerctl-forking defpolls collapse into one inotify deflisten.
Cover art renders via the publisher's stable /tmp/mpris/current symlink;
mm-bar-fill width interpolates via :style min-width (Wave 2 follow-up
folded in). Scaffold widgets/scripts/canvas-media.sh deleted — replaced
verbatim.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: ARCHITECTURE.md row + TODO.md graduation + split off bar-pill NEXT entry

**Files:**
- Modify: `/etc/nixos/home/waybar/ARCHITECTURE.md` (add mpris-publisher daemon-registry row)
- Modify: `/etc/nixos/home/waybar/TODO.md` (move the deferred Wave 3 Task 6 to DONE; split the original NEXT entry into a smaller bar-pill-only follow-up)

**Interfaces:**
- No code interfaces — pure docs.

- [ ] **Step 1: Add daemon-registry row to ARCHITECTURE.md**

In `/etc/nixos/home/waybar/ARCHITECTURE.md`, find the daemon-registry table (the section that lists Wave 3 daemons like `weather-daemon`, `system-daemon`, `pomodoro-daemon`, `cal-source-daemon`, `brightness-daemon`). Add a new row matching the established format. Example (adjust columns to match the actual table header):

```
| `mpris-publisher` | n/a (canvas-only) | `/tmp/waybar-cache/mpris-snapshot.json` (composite for dashboard) + 7 existing pill caches | `/home/max/mpris-waybar/scripts/mpris-publisher` | Out-of-Nix-store (live-edit pattern). Composite consumed by widgets/scripts/canvas-mpris-listen → eww deflisten. |
```

Note: no RTMIN signal entry needed — the composite is canvas-only (subscribed via inotifywait); waybar doesn't read it. The 7 existing pill caches still use `WAYBAR_SIGNAL=12` (RTMIN+12) — already documented.

- [ ] **Step 2: Update TODO.md — DONE entry + split-off NEXT**

In `/etc/nixos/home/waybar/TODO.md`, find the NEXT entry under "Media player module (MPRIS)" (lines 50-61 in the unmodified file). Replace it with TWO entries:

(a) A NEW shorter NEXT entry covering ONLY the bar-pill half (the dashboard half is done):

```
- **Media player module (MPRIS) — bar pill** — permanent when a player exists,
  lives in USER zone (bound to focused work). `XF86AudioPlay/Pause/Next/Prev`
  reflects on the existing pill. Source state: mpris-publisher (now running
  via systemd; see DONE entry for 2026-06-21). The 7 existing pill caches
  (`mpris-playpause`, `mpris-volume`, `mpris-selector`, `mpris-prev`,
  `mpris-next`, `mpris-output`, `mpris-info`) already populate; what's
  missing is the waybar custom-module wiring + opt-pill class composition +
  XF86 reflection.
```

(b) Add to DONE (above the most recent entry):

```
- **2026-06-21** — **canvas media-MEGA reads mpris-publisher composite truth
  (Wave 3 Task 6 closes).** Publisher now ships as systemd user unit
  (`modules/mpris-publisher.nix`). New composite channel
  `/tmp/waybar-cache/mpris-snapshot.json` exposes title/artist/album/status/
  pos/len/pct/source_label/art_path; canvas dashboard subscribes via
  `widgets/scripts/canvas-mpris-listen` (inotifywait on parent dir,
  filtered by basename — composite-module pattern). Eight playerctl-shelling
  defpolls collapsed to one deflisten; cover art renders via the existing
  `/tmp/mpris/current` symlink; mm-bar-fill width wired via `:style
  min-width: ${pct}%` (Wave 2 follow-up folded in). Scaffold
  `widgets/scripts/canvas-media.sh` deleted.
  **Hint:** Publisher script lives out-of-Nix-store at
  `/home/max/mpris-waybar/scripts/mpris-publisher` — that repo is not git-
  tracked, so the new pure helpers (`json_str`, `derive_pos_text`,
  `derive_pct`, `derive_composite_json`) in `lib/mpris.sh` and the
  test_mpris_publisher_composite.sh test exist only on disk. A
  follow-up to git-init mpris-waybar is recorded under NEXT.
  **Hint:** spec at
  `docs/superpowers/specs/2026-06-21-canvas-media-mpris-truth-design.md`;
  plan at `docs/superpowers/plans/2026-06-21-canvas-media-mpris-truth.md`.
  **Hint:** Position ticker runs at 1 Hz only while ACTIVE is Playing —
  zero CPU when paused or no player. write_snapshot_composite dedup'd
  via in-memory _LAST_COMPOSITE byte-compare.
```

(c) Add a third NEXT entry tracking the mpris-waybar git-init follow-up (so it doesn't get forgotten):

```
- **Git-init the mpris-waybar repo** — `/home/max/mpris-waybar/` is currently
  not a git repo; publisher edits (composite JSON wiring, position ticker,
  lib helpers) live on disk only. Initialize the repo, commit the current
  state, and add it as a flake input or pin its path in `modules/mpris-
  publisher.nix` so the script becomes reproducible. Pure cleanup — no
  behavior change.
```

- [ ] **Step 3: Verify TODO cap still ≤ 6**

```
grep -c '^- \[ \]' /etc/nixos/home/waybar/TODO.md
```

Expected: `≤ 6`. (The cap rule is about active TODO items — NEXT items are uncapped.) Verify with:

```
awk '/^## TODO/{flag=1; next} /^## /{flag=0} flag && /^- \[ \]/{n++} END{print n}' /etc/nixos/home/waybar/TODO.md
```

Expected: 4 (the existing dictate / tooltip / audio / screenshot — unchanged by this task).

- [ ] **Step 4: Final visual smoke**

Reboot the machine (per the memory: nixos-rebuild switch survives reboot; this verifies end-to-end including session-start auto-launch of the publisher).

After login:
- Start any media player (Spotify, Firefox tab, mpv).
- Press Super+RETURN to open the canvas.
- Confirm media-MEGA card renders with live data, art, advancing progress.
- Close all players; confirm card collapses to empty.
- Reopen and confirm collapse persists, then start a player and confirm card reappears within ~1s.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add waybar/ARCHITECTURE.md waybar/TODO.md
git commit -m "$(cat <<'EOF'
wave3: graduate canvas media-MEGA → DONE; split bar-pill into its own NEXT

ARCHITECTURE.md gains mpris-publisher daemon-registry row. TODO.md moves
the dashboard half of the old NEXT entry to DONE; the bar-pill +
XF86AudioPlay/Pause/Next/Prev reflection half stays NEXT as a smaller,
focused entry. Adds NEXT entry for git-init'ing mpris-waybar so the
out-of-Nix-store publisher state doesn't drift unnoticed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review (post-write check)

**1. Spec coverage:** every interface (composite JSON cache, listener script, publisher additions, systemd unit, eww widget rewire, cover art via `/tmp/mpris/current`, mm-bar-fill width, ARCHITECTURE row, TODO graduation, NEXT split) has a task. Hazards section in spec (inotify-on-dir, dedup at write, position ticker storms, deflisten respawn, art eviction race, systemd ordering, `.empty` font-size:0, no-error-pill) all surface in code or tests.

**2. Placeholders:** none. Every code block is complete and copy-pasteable.

**3. Type consistency:** `derive_composite_json` accepts 14 args in fixed order; the call site in `write_snapshot_composite` passes them in the same order. `mpris-snapshot.<field>` access in eww uses the documented field names (active/player/source_label/title/artist/album/status/status_glyph/pos_sec/len_sec/pct/pos_text/len_text/art_path/updated). Listener `EMPTY` sentinel and lib `derive_composite_json` produce the same shape (manually verified field-by-field).
