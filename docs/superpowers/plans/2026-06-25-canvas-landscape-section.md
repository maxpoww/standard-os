# Canvas Landscape section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 16th `Landscape` section to the StandardOS canvas — a 3×3 grid of workspace screenshots (rows 1-2-3, 4-5-6, 7-8-9), click-to-jump-and-close.

**Architecture:** A dedicated systemd-user daemon (`landscape-snap`) listens to Hyprland IPC, debounced-grims the currently-focused workspace on window events, and writes atomic PNGs into `/tmp/standardos/landscape/`. An eww `deflisten` watches a manifest file and emits cache-buster paths so `(image :path …)` re-renders. Click handler dispatches `hyprctl workspace N` then `exec`s the existing `canvas-close` script.

**Tech Stack:** bash + socat + inotify-tools + grim + jq + hyprctl (daemon side); eww (yuck + scss) + GTK 3 (canvas side); Home Manager + systemd-user (nix wiring).

## Global Constraints

Copied verbatim from the standard-os skill and the spec — every task inherits these.

- `eww.scss` and every other CSS-adjacent file MUST be strictly ASCII (no em-dash, no glyphs, no UTF-8 anywhere). Grep `[^\x00-\x7f]` before saving any `.scss` edit.
- Cache writes MUST be atomic — write to `<path>.tmp`, then `mv -f` to final path. No partial-PNG flicker.
- Inotify on a directory with `tmp + mv` writers MUST use `inotifywait -m -e close_write,moved_to --format '%f' "$dir"` and filter by basename. A per-file watch dies the first time `mv -f` unlinks the inode.
- No `jq` / `awk` / `head` in tight hot loops. Hyprland's event socket emits 100+ lines/min; the per-event branch must use bash builtins only. `jq` is fine inside the debounced snapshot path (one call per ~300ms at most).
- Light-mode adaptation: Landscape carries no text, so no `light` / `dark` class is required on its cells. If you add text labels later, you MUST emit `light` / `dark` AND update the `style.css` light-text selector blocks per the standing rule.
- No new error pill on OPTIONS. `grim` failures, daemon crashes, missing outputs — all silent. Logs only.
- After any `*.nix` change: `sudo nixos-rebuild switch` (NOT `test`). `test` activates in RAM only and the new systemd unit vanishes after reboot.
- After any `eww.yuck` / `eww.scss` change: `eww reload`. After any `home.nix` / `landscape-snap.nix` change: `sudo nixos-rebuild switch` first.
- Cache root for this feature: `/etc/nixos/home/widgets/eww/.superpowers/` was created by the visual-companion server; ignore — not relevant to this work. Real cache root for this feature is `/tmp/standardos/landscape/`.
- Commit discipline (`/etc/nixos/home` IS a git repo): commit each task's deliverable before starting the next. **Pre-existing dirty stream (canvas-prefs polish) must be resolved before Task 1** — see Task 0.

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `/etc/nixos/home/scripts/landscape-snap-daemon.sh` | Create | Subscribe to Hyprland IPC, debounce-grim the current workspace on window events, write `ws-N.png` + `manifest.json`. Inotify-watch `open-trigger` for the canvas-open refresh path. |
| `/etc/nixos/home/modules/landscape-snap.nix` | Create | Home Manager module exposing `services.landscapeSnap.enable`; wires the daemon as a systemd-user unit with PATH (`grim` + `socat` + `inotify-tools` + `jq` + `hyprland` + `coreutils`). |
| `/etc/nixos/home/widgets/scripts/canvas-jump-ws` | Create | One-arg click handler: `hyprctl dispatch workspace $1` then `exec /etc/nixos/home/scripts/canvas-close`. |
| `/etc/nixos/home/widgets/scripts/canvas-landscape-listen` | Create | Eww `deflisten` source. Watches `manifest.json` via `inotifywait`, emits JSON `{ws1:"<path>?t=<mtime>", …, ws9:"…"}` so eww re-renders the 9 image widgets. |
| `/etc/nixos/home/widgets/eww/eww.yuck` | Modify (5 spots) | (1) append `landscape` to `section-nav`; (2) append landscape branch to `canvas` section-body; (3) add `(deflisten ws-paths …)`; (4) add `(defpoll focused-ws …)`; (5) add `(defwidget landscape-section …)`. |
| `/etc/nixos/home/widgets/eww/eww.scss` | Modify | Append `.ls-grid`, `.ls-cell`, `.ls-cell-current`, `.ls-empty`, `.ls-shot` rules. Strictly ASCII. |
| `/etc/nixos/home/scripts/canvas-open` | Modify | Append `mkdir -p /tmp/standardos/landscape && touch /tmp/standardos/landscape/open-trigger` so the daemon refreshes the current cell on canvas open. |
| `/etc/nixos/home.nix` (outside the repo, edited in place) | Modify | Add `imports = [ ./home/modules/landscape-snap.nix ];` to the imports list AND `services.landscapeSnap.enable = true;` next to the existing `services.brightnessDaemon.enable = true;` (line 62 area). |
| `/etc/nixos/home/waybar/TODO.md` | Modify (post-ship) | Append a DONE entry with a Hint line per the TODO.md contract. Unplanned work — never on TODO, goes straight to DONE. |

Eight created or modified files. One downstream consumer (the canvas) gains a new section. Zero existing surface lost.

---

## Task 0: Pre-flight — resolve dirty tree

Per the commit-discipline rule in the `standard-os` skill: if `git status -s` in `/etc/nixos/home` shows >1 work stream dirty, STOP. The tree currently shows the canvas-prefs polish stream (pref-* scripts, eww.yuck, sidecar-render.sh) plus an unrelated `hypr/modules/Window_Rules.conf` change. Both predate this work.

**Files:**
- Inspect: `/etc/nixos/home/.` (git status)

**Interfaces:**
- Consumes: nothing
- Produces: clean working tree (or explicit user direction to proceed anyway)

- [ ] **Step 1: Audit the tree**

```bash
cd /etc/nixos/home && git status -s
```

Expected: a list of modified files belonging to identifiable streams.

- [ ] **Step 2: Group by stream and present to user**

Show the user each dirty file grouped by likely stream (canvas-prefs polish, Window_Rules tweak, etc.). Ask which stream(s) to commit before Task 1 begins. Do NOT auto-commit on user's behalf — wait for explicit instruction.

- [ ] **Step 3: Commit the resolution the user chose**

Per their instruction, stage and commit each stream with its own message. Phrase as behavior changes ("canvas-prefs: <what>"), not file changes. Example:

```bash
cd /etc/nixos/home
git add scripts/pref-apply scripts/pref-choose-groups scripts/pref-choose-shell scripts/lib/sidecar-render.sh widgets/eww/eww.yuck
git commit -m "canvas-prefs: <user-described change>"
```

- [ ] **Step 4: Confirm tree is clean (or carries only landscape work)**

```bash
cd /etc/nixos/home && git status -s
```

Expected: empty, OR contains only the spec file added by brainstorming (`docs/superpowers/specs/2026-06-25-canvas-landscape-section-design.md`). That spec file gets committed as part of Task 1 below.

---

## Task 1: Click handler + cache dir scaffolding

The smallest standalone piece — a 4-line script and a tmpfs directory. No daemon, no eww, no nix. Verifiable in isolation by invoking it from a shell on a populated workspace.

**Files:**
- Create: `/etc/nixos/home/widgets/scripts/canvas-jump-ws`
- Test: manual invocation in shell

**Interfaces:**
- Consumes: `hyprctl` (in `PATH`); `/etc/nixos/home/scripts/canvas-close` (existing)
- Produces: an executable that takes one arg in `[1-9]` and performs jump + close

- [ ] **Step 1: Write the script**

```bash
cat > /etc/nixos/home/widgets/scripts/canvas-jump-ws <<'EOF'
#!/usr/bin/env bash
# Usage: canvas-jump-ws <N> - jump to workspace N then close the canvas.
# Invoked from eww eventbox onclick in the Landscape section.
n=$1
[[ "$n" =~ ^[1-9]$ ]] || exit 1
hyprctl dispatch workspace "$n" >/dev/null
exec /etc/nixos/home/scripts/canvas-close
EOF
chmod +x /etc/nixos/home/widgets/scripts/canvas-jump-ws
```

(In implementation, use the `Write` tool for the file body and a separate `chmod` Bash call. The heredoc above is for the engineer reading the plan.)

- [ ] **Step 2: Verify it dispatches**

Open a second workspace via the bar pill first so there's somewhere to jump to. Then run:

```bash
/etc/nixos/home/widgets/scripts/canvas-jump-ws 2
```

Expected: you're now on workspace 2. (The `canvas-close` exec will fail-silent because the canvas isn't open, which is fine; the test is whether the dispatch fired.)

- [ ] **Step 3: Verify the guard rejects bad input**

```bash
/etc/nixos/home/widgets/scripts/canvas-jump-ws foo; echo $?
/etc/nixos/home/widgets/scripts/canvas-jump-ws 99; echo $?
/etc/nixos/home/widgets/scripts/canvas-jump-ws ; echo $?
```

Expected: `1`, `1`, `1` — no `hyprctl` dispatch fires (you're still on whatever workspace you started on).

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home
git add widgets/scripts/canvas-jump-ws docs/superpowers/specs/2026-06-25-canvas-landscape-section-design.md docs/superpowers/plans/2026-06-25-canvas-landscape-section.md
git commit -m "landscape: canvas-jump-ws click handler + design+plan docs"
```

---

## Task 2: Snapshot daemon — capture function (single-shot)

Build the daemon script in two passes: first the snapshot function only (testable by running once), then the event loop (Task 3). Splitting protects against debugging "is it the capture or the loop?" later.

**Files:**
- Create: `/etc/nixos/home/scripts/landscape-snap-daemon.sh`
- Test: run with `LANDSCAPE_ONESHOT=1` env var

**Interfaces:**
- Consumes: `hyprctl monitors -j`, `grim`, `jq`, `stat`, `mv -f`
- Produces: `/tmp/standardos/landscape/ws-N.png` (where N is current focused workspace) + `/tmp/standardos/landscape/manifest.json`

- [ ] **Step 1: Write the daemon script with capture function + oneshot hook**

```bash
#!/usr/bin/env bash
# StandardOS landscape snapshot daemon.
# Captures the currently-focused workspace on window events (debounced)
# and on canvas-open trigger. Output: /tmp/standardos/landscape/ws-N.png.

set -u

CACHE=/tmp/standardos/landscape
mkdir -p "$CACHE"

# --- capture ----------------------------------------------------------------

snapshot_current() {
    # Returns silently on any failure (no error pill on OPTIONS).
    local mon ws tmp
    mon=$(hyprctl monitors -j 2>/dev/null \
          | jq -r '.[] | select(.focused) | .name' 2>/dev/null) || return 0
    ws=$(hyprctl monitors -j 2>/dev/null \
          | jq -r '.[] | select(.focused) | .activeWorkspace.id' 2>/dev/null) || return 0
    [[ "$ws" =~ ^[1-9]$ ]] || return 0
    [ -n "$mon" ] || return 0

    tmp="$CACHE/ws-$ws.png.tmp"
    if grim -o "$mon" -s 0.4 "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CACHE/ws-$ws.png"
        write_manifest
    else
        rm -f "$tmp"
    fi
}

write_manifest() {
    local tmp="$CACHE/manifest.json.tmp"
    {
        printf '{'
        local first=1 f m n
        for n in 1 2 3 4 5 6 7 8 9; do
            f="$CACHE/ws-$n.png"
            if [ -r "$f" ]; then
                m=$(stat -c %Y "$f")
                [ $first -eq 0 ] && printf ','
                printf '"ws%d_mtime":%d' "$n" "$m"
                first=0
            fi
        done
        printf '}\n'
    } > "$tmp"
    mv -f "$tmp" "$CACHE/manifest.json"
}

# --- entry ------------------------------------------------------------------

if [ "${LANDSCAPE_ONESHOT:-0}" = "1" ]; then
    snapshot_current
    exit 0
fi

# Event loop comes in Task 3.
echo "landscape-snap: event loop not implemented yet (Task 3)" >&2
exit 1
```

(Use `Write` to create the file; `chmod +x` separately.)

- [ ] **Step 2: Run the oneshot capture**

```bash
chmod +x /etc/nixos/home/scripts/landscape-snap-daemon.sh
LANDSCAPE_ONESHOT=1 /etc/nixos/home/scripts/landscape-snap-daemon.sh
ls -l /tmp/standardos/landscape/
```

Expected: `ws-N.png` (where N = your current workspace) exists, ~50-300 KB. `manifest.json` exists, contains `{"wsN_mtime":<epoch>}`. No stderr.

- [ ] **Step 3: Verify the PNG is readable**

```bash
file /tmp/standardos/landscape/ws-*.png
```

Expected: each line ends with `PNG image data, NNNN x NNNN, 8-bit/color RGBA, non-interlaced`. If width × height looks too big (e.g. native 2560×1600 instead of ~1024×640), the `-s 0.4` scaling didn't apply — re-check.

- [ ] **Step 4: Verify the manifest grows correctly**

Switch to workspace 2 (or another that has at least one window). Re-run oneshot:

```bash
hyprctl dispatch workspace 2
LANDSCAPE_ONESHOT=1 /etc/nixos/home/scripts/landscape-snap-daemon.sh
cat /tmp/standardos/landscape/manifest.json
```

Expected: manifest now contains both `ws1_mtime` and `ws2_mtime` (assuming you started on ws1). JSON well-formed (`jq . /tmp/standardos/landscape/manifest.json` returns without error).

- [ ] **Step 5: Verify atomic-write hazard mitigation**

There should never be a `ws-N.png.tmp` left over after a successful run:

```bash
ls /tmp/standardos/landscape/*.tmp 2>/dev/null; echo "exit=$?"
```

Expected: `exit=2` (no matches). If a `.tmp` lingers, the `mv -f` failed or grim's exit code was misread.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add scripts/landscape-snap-daemon.sh
git commit -m "landscape: snapshot daemon - capture function (oneshot)"
```

---

## Task 3: Snapshot daemon — event loop + debounce + open-trigger

Replace the Task 2 stub (`echo "...Task 3"; exit 1`) with the real event loop. Subscribes to Hyprland's `.socket2.sock`, debounces window events 300 ms, and inotify-watches `open-trigger` for canvas-open refreshes.

**Files:**
- Modify: `/etc/nixos/home/scripts/landscape-snap-daemon.sh` (replace bottom block)
- Test: run the daemon in the foreground, generate events, observe cache updates

**Interfaces:**
- Consumes: `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` via `socat`; `inotifywait`
- Produces: same as Task 2, but driven by events instead of one-shot

- [ ] **Step 1: Replace the entry-point block**

Replace the `LANDSCAPE_ONESHOT` block + the placeholder `echo`/`exit 1` with:

```bash
# --- entry ------------------------------------------------------------------

if [ "${LANDSCAPE_ONESHOT:-0}" = "1" ]; then
    snapshot_current
    exit 0
fi

# Debounced capture: any event posts to a fifo; a reader coalesces bursts.
FIFO=$(mktemp -u /tmp/standardos/landscape-snap.fifo.XXXXXX)
mkfifo "$FIFO"
trap 'rm -f "$FIFO"' EXIT

# Debounce loop: read events from FIFO, sleep 0.3s, drain remaining, snapshot.
(
    while :; do
        if read -r _; then
            # Coalesce: drain any further events that arrive in the next 0.3s.
            sleep 0.3
            while IFS= read -r -t 0.01 _; do :; done
            snapshot_current
        fi
    done
) < "$FIFO" &
DEBOUNCE_PID=$!
trap 'rm -f "$FIFO"; kill "$DEBOUNCE_PID" 2>/dev/null' EXIT

# Source 1: Hyprland event socket.
HYPR_SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
if [ -S "$HYPR_SOCK" ]; then
    (
        socat -U - "UNIX-CONNECT:$HYPR_SOCK" | while IFS= read -r line; do
            case "$line" in
                openwindow*|closewindow*|movewindow*|fullscreen*|workspace*|workspacev2*)
                    printf '1\n' > "$FIFO"
                    ;;
                # windowtitle fires on every background tab title change; skip
                # to keep grim out of hot loops.
            esac
        done
    ) &
fi

# Source 2: canvas-open trigger (inotify on the parent dir, filtered).
(
    inotifywait -m -e close_write,create,attrib --format '%f' "$CACHE" 2>/dev/null \
    | while read -r name; do
        [ "$name" = "open-trigger" ] && printf '1\n' > "$FIFO"
    done
) &

wait
```

- [ ] **Step 2: Start the daemon in the foreground for testing**

```bash
/etc/nixos/home/scripts/landscape-snap-daemon.sh &
DAEMON_PID=$!
sleep 1
```

- [ ] **Step 3: Trigger via window event**

Open a fresh terminal in your current workspace (e.g. `kitty &` or whatever your launcher does). Within ~1s:

```bash
stat -c '%y %n' /tmp/standardos/landscape/ws-*.png
```

Expected: the ws-N.png for your current workspace has a fresh mtime (within the last few seconds). Old cells unchanged.

- [ ] **Step 4: Trigger via canvas-open path**

```bash
mtime_before=$(stat -c %Y /tmp/standardos/landscape/ws-$(hyprctl activeworkspace -j | jq -r .id).png)
touch /tmp/standardos/landscape/open-trigger
sleep 1
mtime_after=$(stat -c %Y /tmp/standardos/landscape/ws-$(hyprctl activeworkspace -j | jq -r .id).png)
[ "$mtime_after" -gt "$mtime_before" ] && echo OK || echo FAIL
```

Expected: `OK`.

- [ ] **Step 5: Verify debounce coalesces bursts**

Generate a 5-event burst (rapid title changes, focus changes, whatever). Expect exactly one grim call to result. To confirm:

```bash
mtime_before=$(stat -c %Y /tmp/standardos/landscape/ws-$(hyprctl activeworkspace -j | jq -r .id).png)
# Synthesize a burst: open+close 3 windows fast.
for i in 1 2 3; do hyprctl dispatch exec "kitty -e bash -c 'sleep 0.05; exit'"; done
sleep 1.5
mtime_after=$(stat -c %Y /tmp/standardos/landscape/ws-$(hyprctl activeworkspace -j | jq -r .id).png)
[ "$mtime_after" -gt "$mtime_before" ] && echo OK || echo FAIL
```

Expected: `OK`, AND only one capture happened (verify by tailing `journalctl -f` if you wired it later; for now, eyeball that mtime advanced exactly once, not five times — re-run with `inotifywait` if uncertain).

- [ ] **Step 6: Kill the foreground daemon**

```bash
kill $DAEMON_PID 2>/dev/null
```

- [ ] **Step 7: Commit**

```bash
cd /etc/nixos/home
git add scripts/landscape-snap-daemon.sh
git commit -m "landscape: snapshot daemon event loop (socat + inotify + debounce)"
```

---

## Task 4: Home Manager module + enable + nixos-rebuild switch

Wire the daemon as a systemd-user service. After this task, the daemon survives logout/login and reboots, and `systemctl --user` reflects its state.

**Files:**
- Create: `/etc/nixos/home/modules/landscape-snap.nix`
- Modify: `/etc/nixos/home.nix` (add import + `services.landscapeSnap.enable = true;`)
- Test: `systemctl --user status landscape-snap`

**Interfaces:**
- Consumes: NixOS module system, Home Manager `services.*` namespace
- Produces: systemd user unit `landscape-snap.service` running on `default.target`

- [ ] **Step 1: Create the HM module**

Write `/etc/nixos/home/modules/landscape-snap.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.landscapeSnap;
in
{
  options.services.landscapeSnap.enable =
    lib.mkEnableOption "StandardOS landscape snapshot daemon (3x3 workspace exposé)";

  config = lib.mkIf cfg.enable {
    systemd.user.services.landscape-snap = {
      Unit = {
        Description = "StandardOS landscape snapshot daemon (3x3 workspace exposé)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        Environment = [
          "PATH=${pkgs.grim}/bin:${pkgs.jq}/bin:${pkgs.socat}/bin:${pkgs.inotify-tools}/bin:${pkgs.hyprland}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin"
        ];
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/home/scripts/landscape-snap-daemon.sh";
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
```

- [ ] **Step 2: Wire the module into home.nix**

Edit `/etc/nixos/home.nix`. Find the existing `imports = [ ... ];` block and the existing `services.brightnessDaemon.enable = true;` (line 62 area). Add two lines:

```nix
imports = [
  # ... existing entries ...
  ./home/modules/landscape-snap.nix    # NEW
];

# ... and beside services.brightnessDaemon.enable:
services.brightnessDaemon.enable = true;
services.landscapeSnap.enable    = true;   # NEW
```

- [ ] **Step 3: Rebuild and switch (NOT test)**

```bash
sudo nixos-rebuild switch
```

Expected: exits 0. If activation fails on the new module, the most likely cause is a typo in the option path (`services.landscapeSnap.enable` must match between module and `home.nix`).

- [ ] **Step 4: Confirm the systemd unit started**

```bash
systemctl --user status landscape-snap --no-pager
```

Expected: `Active: active (running)`. `Loaded: loaded ( ... landscape-snap.service ...)`.

- [ ] **Step 5: Verify it's snapshotting**

Switch to a workspace with at least one window, then:

```bash
sleep 1
ls -lt /tmp/standardos/landscape/ws-*.png 2>/dev/null | head
```

Expected: at least one PNG with mtime in the last few seconds. If the directory is empty, check `journalctl --user -u landscape-snap -n 50` for grim errors.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add modules/landscape-snap.nix
git commit -m "landscape: HM module + systemd-user unit"
```

(`/etc/nixos/home.nix` is outside this repo and not committed — its edit is permanent on disk but not tracked.)

---

## Task 5: Eww listener `canvas-landscape-listen`

The deflisten source. Reads the current state of all 9 ws-N.png files on startup, emits a JSON map, then inotify-loops on the cache dir filtered to `manifest.json` changes.

**Files:**
- Create: `/etc/nixos/home/widgets/scripts/canvas-landscape-listen`
- Test: invoke in foreground; touch `manifest.json` from another shell; observe new JSON line

**Interfaces:**
- Consumes: `/tmp/standardos/landscape/ws-*.png` + `manifest.json`; `inotifywait`; `stat`
- Produces: stdout stream of JSON lines, one per change, like `{"ws1":"/tmp/standardos/landscape/ws-1.png?t=1782420000","ws2":"…","ws3":"","ws4":"",…}`

- [ ] **Step 1: Write the listener**

```bash
#!/usr/bin/env bash
# Eww deflisten source for the Landscape section.
# Emits a JSON map of {wsN: "path?t=mtime" or ""} on every manifest change.

set -u

CACHE=/tmp/standardos/landscape
mkdir -p "$CACHE"

emit() {
    local out='{'
    local first=1 f m n
    for n in 1 2 3 4 5 6 7 8 9; do
        f="$CACHE/ws-$n.png"
        [ $first -eq 0 ] && out+=','
        if [ -r "$f" ]; then
            m=$(stat -c %Y "$f")
            out+="\"ws$n\":\"$f?t=$m\""
        else
            out+="\"ws$n\":\"\""
        fi
        first=0
    done
    echo "${out}}"
}

# Emit initial state immediately so eww has data on launch.
emit

# Watch the cache dir; only re-emit when manifest.json changes (the daemon
# rewrites it atomically after every successful capture).
inotifywait -m -e close_write,moved_to --format '%f' "$CACHE" 2>/dev/null \
| while read -r name; do
    [ "$name" = "manifest.json" ] && emit
done
```

`chmod +x` it after writing.

- [ ] **Step 2: Run it in the foreground**

```bash
/etc/nixos/home/widgets/scripts/canvas-landscape-listen
```

Expected: prints one JSON line immediately like `{"ws1":"/tmp/standardos/landscape/ws-1.png?t=1782420000","ws2":"",…,"ws9":""}`. Process hangs (it's now in the inotify loop).

- [ ] **Step 3: From a second terminal, trigger a manifest change**

```bash
touch /tmp/standardos/landscape/manifest.json
```

Expected: in the first terminal, a second JSON line appears. The mtime suffix on populated cells advanced.

- [ ] **Step 4: Kill the listener (Ctrl-C in first terminal)**

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add widgets/scripts/canvas-landscape-listen
git commit -m "landscape: eww deflisten source (cache-buster path map)"
```

---

## Task 6: Eww section pill + widget + scss + canvas-open trigger

The user-facing surface. Five touch points in `eww.yuck`, one block in `eww.scss`, one append to `canvas-open`. After this task, the canvas's Landscape section renders the live grid.

**Files:**
- Modify: `/etc/nixos/home/widgets/eww/eww.yuck` (5 spots)
- Modify: `/etc/nixos/home/widgets/eww/eww.scss` (append one block)
- Modify: `/etc/nixos/home/scripts/canvas-open` (one line append)
- Test: `eww reload`, open canvas, click Landscape pill

**Interfaces:**
- Consumes: `canvas-landscape-listen` output (Task 5); `canvas-jump-ws` (Task 1); `focused-ws` defpoll value
- Produces: a `(landscape-section)` widget; a `landscape` route entry in `section-nav` and in the canvas body switch

- [ ] **Step 1: Append the section pill in `section-nav`**

In `eww.yuck`, find line 165 (the last `(section-pill :id "location" :label "Location")` in `defwidget section-nav`). Append after it:

```yuck
    (section-pill :id "landscape" :label "Landscape")))
```

(Move the closing `)))` to wrap the new pill. The existing line ends with `)))` — convert it to `)` and put the closing brackets after the new line.)

Concrete edit: change line 165
```yuck
    (section-pill :id "location" :label "Location")))
```
to
```yuck
    (section-pill :id "location"  :label "Location")
    (section-pill :id "landscape" :label "Landscape")))
```

- [ ] **Step 2: Add the data sources near the existing defpolls (top of file)**

After the `notif-entries` defpoll (around line 45) — or wherever the other workspace-related defpolls live — add:

```yuck
;; Landscape section — current focused workspace id (1..9) and per-cell
;; cache-buster paths emitted by canvas-landscape-listen.
(defpoll focused-ws :interval "1s" :initial "0"
  `hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // 0'`)

(deflisten ws-paths
  :initial "{\"ws1\":\"\",\"ws2\":\"\",\"ws3\":\"\",\"ws4\":\"\",\"ws5\":\"\",\"ws6\":\"\",\"ws7\":\"\",\"ws8\":\"\",\"ws9\":\"\"}"
  `/etc/nixos/home/widgets/scripts/canvas-landscape-listen`)
```

- [ ] **Step 3: Add the `landscape-section` widget definition**

After the existing `section-max` widget definition (around line 433, before `section-placeholder`), add:

```yuck
;; ── Landscape section ──
;;
;; 3x3 grid of workspace thumbnails (1..9, row-major). Click a cell to
;; jump to that workspace and close the canvas. The current workspace
;; gets a soft top-inset shadow (opt-pushed visual language). Cells
;; with no cached snapshot render as a flat empty surface.

(defwidget ls-cell [n]
  (eventbox :class {focused-ws == n ? "ls-cell ls-cell-current" : "ls-cell"}
            :onclick "/etc/nixos/home/widgets/scripts/canvas-jump-ws ${n}"
    (box :hexpand true :vexpand true
      (overlay
        (box :class "ls-empty" :hexpand true :vexpand true)
        (image :class "ls-shot"
               :path {jq(ws-paths, "[.ws${n}] | .[0]")}
               :image-width 320 :image-height 200)))))

(defwidget landscape-section []
  (box :class "ls-grid" :orientation "vertical" :space-evenly true :spacing 14
       :hexpand true :vexpand true :halign "fill" :valign "fill"
    (box :orientation "horizontal" :space-evenly true :spacing 14
      (ls-cell :n "1") (ls-cell :n "2") (ls-cell :n "3"))
    (box :orientation "horizontal" :space-evenly true :spacing 14
      (ls-cell :n "4") (ls-cell :n "5") (ls-cell :n "6"))
    (box :orientation "horizontal" :space-evenly true :spacing 14
      (ls-cell :n "7") (ls-cell :n "8") (ls-cell :n "9"))))
```

Note: the `(image :path ...)` will gracefully no-op (render nothing) when the path is empty, letting the `.ls-empty` box show through the overlay.

- [ ] **Step 4: Add the canvas body branch**

In `eww.yuck`'s `(defwidget canvas ...)` around line 483 (just before the final `(section-slot :id "location" ...)` line), add the landscape branch in the same inline-widget style as `section-max`:

Change the bottom of the `canvas` widget from:
```yuck
        (section-slot :id "security" :name "Security and privacy")
        (section-slot :id "location" :name "Location")))
```
to:
```yuck
        (section-slot :id "security" :name "Security and privacy")
        (section-slot :id "location" :name "Location")
        (box :visible {current-section == "landscape"} :orientation "vertical"
             :hexpand true :vexpand true :halign "fill" :valign "fill"
          (landscape-section))))
```

- [ ] **Step 5: Add SCSS rules (strictly ASCII)**

Append to `/etc/nixos/home/widgets/eww/eww.scss`:

```scss
/* Landscape section -- 3x3 workspace exposé grid. */
window#dashboard .ls-grid {
    padding: 22px;
}

window#dashboard .ls-cell {
    background-color: @opt-surface-parent;
    border-radius: 12px;
    min-width: 240px;
    min-height: 150px;
}

window#dashboard .ls-cell-current {
    /* opt-pushed visual: soft top-inset shadow on existing surface. */
    box-shadow: inset 0 6px 18px -4px @opt-pushed-shadow;
}

window#dashboard .ls-shot {
    border-radius: 12px;
}

window#dashboard .ls-empty {
    background-color: @opt-surface-child;
    border-radius: 12px;
}
```

Then verify ASCII:

```bash
grep -P '[^\x00-\x7f]' /etc/nixos/home/widgets/eww/eww.scss && echo "FAIL: non-ASCII found" || echo "OK: ASCII clean"
```

Expected: `OK: ASCII clean`. If `FAIL`, the css comment or anything else slipped in a curly quote / em-dash — fix and re-grep.

- [ ] **Step 6: Wire canvas-open trigger**

Append to `/etc/nixos/home/scripts/canvas-open` (before any final `exec` if present; at end otherwise):

```bash
mkdir -p /tmp/standardos/landscape && touch /tmp/standardos/landscape/open-trigger
```

- [ ] **Step 7: Reload eww**

```bash
eww reload
```

Expected: silent exit 0. If it errors, the most likely cause is unbalanced parens in `eww.yuck` (count `(` vs `)` in the changed regions).

- [ ] **Step 8: Open canvas → Landscape**

Press Super+RETURN. Click the `Landscape` pill at the right of `section-nav`.

Expected: a 3×3 grid renders. Cells whose workspace you have visited show their PNG. The current cell has the soft top-inset shadow. Other cells show the empty-surface fallback.

- [ ] **Step 9: Click a populated cell**

Click any cell whose workspace has windows (and isn't the current one).

Expected: canvas closes, you land on that workspace.

- [ ] **Step 10: Commit**

```bash
cd /etc/nixos/home
git add widgets/eww/eww.yuck widgets/eww/eww.scss scripts/canvas-open
git commit -m "landscape: canvas section pill + 3x3 grid widget + opt-pushed current"
```

---

## Task 7: Acceptance + TODO.md DONE entry

Confirm the full v0 acceptance script from the spec, then promote to DONE per the work-map contract. Unplanned work goes straight to DONE.

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md` (append DONE entry)
- Test: full manual acceptance script

**Interfaces:**
- Consumes: everything Tasks 1-6 produced
- Produces: a stable, documented v0 shipped

- [ ] **Step 1: Run the spec's manual acceptance**

1. Reboot, or at minimum log out + back in to confirm systemd-user `landscape-snap.service` autostarts.
2. Visit workspaces 1, 2, 3 — populate each with at least one window.
3. Open canvas (Super+RETURN).
4. Click `Landscape` pill — section renders within ~200ms.
5. Cells 1, 2, 3 show their respective contents. Current cell carries the soft inset shadow.
6. Cells 4-9 show flat empty surfaces.
7. Click cell 2 — canvas closes, you land on workspace 2.
8. Reopen canvas → Landscape — current cell now reflects ws 2.

If any step fails, debug and re-run. Do NOT proceed to Step 2 until acceptance passes end-to-end.

- [ ] **Step 2: Hazard audit (per `standard-os` skill "Verification before claiming done")**

Walk through each applicable item:

- [ ] Cache writes atomic (`tmp + mv -f`)? Inspect `landscape-snap-daemon.sh`.
- [ ] Inotify watches the DIRECTORY with `--format '%f'`? Inspect both `landscape-snap-daemon.sh` and `canvas-landscape-listen`.
- [ ] `eww.scss` strictly ASCII? `grep -P '[^\x00-\x7f]' /etc/nixos/home/widgets/eww/eww.scss; echo $?` → must be `1`.
- [ ] No `jq` in tight hot loops? `jq` is only inside `snapshot_current` (debounced 300ms) — yes.
- [ ] No new error pill on OPTIONS? `grep -r landscape /etc/nixos/home/waybar/` should return no pill emission paths — yes.
- [ ] `nixos-rebuild switch` (not `test`)? Task 4 used `switch`.
- [ ] `pkill -RTMIN+N` dedup? N/A — Landscape uses eww deflisten + inotify, not RTMIN signals.

- [ ] **Step 3: Append DONE entry**

Append to `/etc/nixos/home/waybar/TODO.md` under the `## DONE` heading (newest first), in the same voice as the existing entries:

```markdown
- **2026-06-25** — **canvas: Landscape section (3x3 workspace exposé).**
  New `landscape` pill appended to `section-nav` (16 pills now, +1 over v31).
  Selecting it renders a 3x3 grid of cached workspace screenshots; clicking
  a cell dispatches the corresponding `hyprctl workspace N` and closes the
  canvas via the existing `canvas-close` script. Current workspace cell
  carries an `opt-pushed`-style soft top-inset shadow; never-visited
  workspaces render as flat `opt-surface-child` rectangles. New
  systemd-user daemon (`modules/landscape-snap.nix` →
  `scripts/landscape-snap-daemon.sh`) subscribes to Hyprland IPC via
  `socat`, debounced-grims the focused workspace on window events (300 ms
  coalesce), and inotify-watches `/tmp/standardos/landscape/open-trigger`
  so the current cell refreshes the moment the canvas opens. Eww side:
  one `defpoll focused-ws`, one `deflisten ws-paths` reading the
  daemon's manifest via `widgets/scripts/canvas-landscape-listen`,
  cache-buster path trick (`/tmp/.../ws-N.png?t=<mtime>`) to force
  `(image :path ...)` re-render on file change. **Hint:** the daemon's
  capture function lives behind `LANDSCAPE_ONESHOT=1` for one-off testing
  without the event loop. Spec at
  `docs/superpowers/specs/2026-06-25-canvas-landscape-section-design.md`;
  plan at `docs/superpowers/plans/2026-06-25-canvas-landscape-section.md`.
  Variant B (annotated cells with workspace numbers + app captions) is
  intentionally deferred per "build A, improve later".
```

- [ ] **Step 4: Commit the TODO.md update**

```bash
cd /etc/nixos/home
git add waybar/TODO.md
git commit -m "landscape: TODO.md DONE entry for canvas Landscape section v0"
```

- [ ] **Step 5: Final clean-tree check**

```bash
cd /etc/nixos/home && git status -s
```

Expected: empty. If anything lingers, it's an unrelated stream — DO NOT lump it into a "landscape:" commit. Either commit it under its own scope or stash for the user.

---

## Self-Review

**1. Spec coverage:**
- New 16th `Landscape` pill → Task 6 Step 1 ✓
- 3x3 grid widget rendering workspaces 1-9 row-major → Task 6 Step 3 ✓
- Cached PNG per cell with empty-surface fallback → Task 5 (listener) + Task 6 (overlay) ✓
- Current-cell soft top-inset shadow → Task 6 Step 5 (`.ls-cell-current` rule) ✓
- Click → `hyprctl dispatch workspace N` → `canvas-close` → Task 1 ✓
- `landscape-snap-daemon.sh` with debounced window-event capture + open-trigger inotify → Tasks 2 + 3 ✓
- `landscape-snap.nix` HM module → Task 4 ✓
- Cache layout `/tmp/standardos/landscape/{ws-N.png,manifest.json,open-trigger}` → Task 2 establishes ✓
- Eww deflisten cache-buster trick → Task 5 ✓
- Universal `opt-hover-bright` (inherited from existing global rule, no per-cell override) → no task needed (handled by `style.css` existing rule) ✓
- Hazard audit checklist → Task 7 Step 2 ✓
- TODO.md DONE entry → Task 7 Step 3 ✓

**2. Placeholder scan:** No "TBD", no "add error handling", no "similar to Task N". Every code block is complete.

**3. Type/naming consistency:**
- `focused-ws` defpoll (Task 6 Step 2) is consumed in `ls-cell` widget (Task 6 Step 3) — name matches.
- `ws-paths` deflisten (Task 6 Step 2) — keys `ws1`..`ws9` consumed via `ws-paths.ws${n}` in `ls-cell`. Listener emits exactly those keys (Task 5 Step 1).
- `services.landscapeSnap.enable` option path matches between `landscape-snap.nix` (Task 4 Step 1) and `home.nix` (Task 4 Step 2).
- `canvas-jump-ws` script name matches between Task 1 (creates) and Task 6 Step 3 (eventbox `onclick`).
- Cache path `/tmp/standardos/landscape/` consistent across daemon, listener, and canvas-open trigger.
- `manifest.json` is the inotify-watched signal file — name consistent between daemon (Task 2 Step 1) and listener (Task 5 Step 1).
