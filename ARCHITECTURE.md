# ARCHITECTURE — OPTIONS wiring map

The master wiring document. README is the soul, CLAUDE.md is the operating manual, this file is the schematic — every daemon, every cache file, every signal, every channel. When you add an option, you consult this file first to see what context is already available; only if nothing fits do you add a new daemon.

---

## Bar layout tree (current + planned)

The bar is divided into three zones — **user** (left), **task** (center), **system** (right). Each zone has its own purpose and its own expansion direction (see CLAUDE.md → Bar layout).

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ USER (left)                       TASK (center)               SYSTEM (right)     │
│                                                                                  │
│ [workspaces] [focused-window]·[+] [lock] [switcher] [⤴]      [net] [bt] [audio]  │
│              [close] [min]        (launcher)                  [clock] [battery]  │
│              [swap]  [move]                                   [theme] [power]    │
│                                                               [tray] [dictate]   │
└──────────────────────────────────────────────────────────────────────────────────┘
       expand right                  expand left                 expand left
                          ↑
              the focused-window pill at the right edge of USER touches
              the launcher "+" at the left edge of TASK — the visual
              bridge between "current task" and "start another task"
```

The **focused-window pill** is the user's current task made visible. It lives in the USER zone (right edge) because it represents where the user *is*. Task-manipulation tools (start / switch / restore) sit in the TASK zone next door. The two are visually adjacent so the bridge between "what I'm doing now" and "do something else" reads as a single fluid surface.

### Today's zone assignments

#### USER zone (left)

- `group/workspaces` — ws-current trigger + ws-1..9 cluster (current location). Drawer expands right.
- `group/active-window` — focused-window icon (right-edge anchor) + close + minimize + swap-right + win-move cluster. Drawer expands right.

#### TASK zone (center)

- `group/group-rofi` — `custom/new` (launcher "+", opens rofi drun) + `custom/hidden` (lock screen).
- `custom/window` — task switcher (clicking opens rofi window-switcher).
- `custom/x` — restore-minimized trigger.

Future TASK additions: task history, pinned-tasks, quick-new-workspace shortcut, etc. The criterion: it manipulates tasks (creates, switches, restores, archives).

#### SYSTEM zone (right)

- `tray` — third-party app indicators.
- `group/group-2` — tools trigger + bluetooth cluster + wifi cluster.
- `group/group-power` — power + reboot + lock.
- `custom/clock`.
- `custom/battery`.
- `custom/night-dimmer`.
- `group/screen-type-group` — warm-cycle + shader-paper + shader-newspaper.
- `custom/dictate` — voice-dictation indicator.

When you add a new module, decide its zone first, then add it here, then add it to `config.jsonc`, then commit both together.

---

## Context daemon registry

Every piece of system state that more than one module might want lives behind a single daemon. The daemon owns the polling (or event subscription), the dedup, the cache write, and the signal. Modules subscribe by reading the cache file and listening for the daemon's signal. **No module forks `hyprctl` / `wpctl` / `nmcli` on its own** — that's the rule that makes the bar cheap.

### Live daemons (running today)

| Daemon | Service unit | Source | Writes | Signal |
|---|---|---|---|---|
| **workspace-daemon** | `waybar-workspace-daemon.service` | `~/.config/waybar/scripts/workspace-daemon.sh` | `/tmp/waybar-cache/{ws-current, ws-1..9, window, win-close, win-minimize, win-swap-right, win-move-trigger, win-move-1..9, win-move-new}` | RTMIN+10 |
| **glass-text-daemon** | `waybar-glass-text-daemon.service` | `~/.config/waybar/scripts/glass-text-daemon.sh` | `/tmp/glass-mode` (single line, `light` \| `dark`) | none (consumers re-exec at their own cadence) |

### Planned daemons (to be added as options arrive)

| Daemon | Concern | Will write | Signal | Trigger source |
|---|---|---|---|---|
| **system-daemon** | CPU, GPU, memory, battery, thermal | `/tmp/waybar-cache/sys-{cpu, gpu, mem, battery, temp}` | RTMIN+12 | polling `/proc/loadavg`, `nvidia-smi`, `/sys/class/power_supply/BAT0/*`, `/sys/class/hwmon/*/temp1_input` at 2 s |
| **network-daemon** | WiFi + ethernet + VPN state | `/tmp/waybar-cache/net-{wifi, eth, vpn, link}` | RTMIN+13 | `nmcli monitor` (event push) + initial state from `nmcli -t device,connection show` |
| **bluetooth-daemon** | BT state, paired devices, scan results | `/tmp/waybar-cache/bt-{state, devices, scanning}` | RTMIN+13 | `dbus-monitor --system "type='signal',interface='org.bluez.*'"` |
| **audio-daemon** | Default sink, volume, mute, playing-apps count | `/tmp/waybar-cache/audio-{sink, volume, mute, streams}` | RTMIN+14 | `pw-mon --color=never` filtered to `^changed:` |
| **clipboard-daemon** | Selection / clipboard contents | `/tmp/waybar-cache/clip-{selection, clipboard}` | RTMIN+15 | `wl-paste --watch` (primary and clipboard) |
| **media-daemon** | MPRIS players, cava bars, active player | TBD — moved to `/home/max/mpris-waybar/` for rewrite | RTMIN+16 (reserved) | `playerctl --follow`, `dbus-monitor`, `pw-mon` |

Bluetooth and network share RTMIN+13 because they collectively describe "connectivity" and almost no module needs one without the other; one signal refreshes every connectivity pill at once.

### Signal table (authoritative)

| Signal | Owner | Purpose |
|---|---|---|
| RTMIN+10 | workspace-daemon | Window/workspace state changes |
| RTMIN+11 | dictation | Recording / transcribing indicator |
| RTMIN+12 | system-daemon (planned) | CPU/GPU/memory/battery/temp |
| RTMIN+13 | network-daemon + bluetooth-daemon (planned) | Connectivity |
| RTMIN+14 | audio-daemon (planned) | Sink/volume/streams |
| RTMIN+15 | clipboard-daemon (planned) | Selection/clipboard |
| RTMIN+16 | media-daemon (reserved) | MPRIS / cava |
| RTMIN+17..+30 | **FREE** | future expansion |

When picking a signal: read this table, take the next free one, edit this table in the same commit. The Linux kernel guarantees RTMIN through RTMIN+30 are safe for application use.

---

## Channel format (the cache-file contract)

Every cache file is one line of JSON. The shape is:

```json
{
  "text":    "string the pill renders",
  "class":   "light|dark <state-class> [...]",
  "tooltip": "optional string shown on hover",
  "value":   <optional raw numeric or structured value for composite consumers>,
  "state":   "yes|middle|no" optional semantic state for cross-module logic,
  "extra":   { "...": "..." } optional module-specific structured data
}
```

- `text` and `class` are the waybar contract — those two are mandatory for any pill we want to render.
- `tooltip` shows up if `"tooltip": true` is set in the module config.
- `value`, `state`, `extra` are the **OPTIONS extensions**. waybar ignores them. Other daemons or composite modules can read them by `cat`'ing the cache file or watching it via inotify. This is what makes cache files real channels rather than just display buffers.

### State semantics

`state` is a single-word semantic flag. The values are bound to the OPTIONS color system:

| `state` value | OPTIONS primary color | OPTIONS animation color |
|---|---|---|
| `"yes"` | Blue | Violet |
| `"middle"` | Yellow | Green |
| `"no"` | Red | Orange |
| `"off"` | (no pill — module emits `class:"... empty"`) | n/a |

A pill's CSS rules can key off `state` indirectly through its class list. The recommended convention: include `state-yes` / `state-middle` / `state-no` in the `class` field, then style each in CSS:

```css
#custom-foo.state-yes { background-color: rgba(80, 120, 220, 0.30); }
#custom-foo.state-middle { background-color: rgba(255, 200, 50, 0.30); }
#custom-foo.state-no { background-color: rgba(255, 100, 100, 0.30); }
```

### Atomic-write recipe (every daemon must use this)

```bash
new_content='{"text":"23%","class":"dark state-yes","value":23,"state":"yes"}'
[[ $new_content == "$LAST_CONTENT" ]] && return       # in-memory dedup; cheapest possible
printf '%s' "$new_content" > "$CACHE.tmp" && \
    mv -f "$CACHE.tmp" "$CACHE"
LAST_CONTENT=$new_content
pkill -RTMIN+12 waybar 2>/dev/null || true
```

Half-written cache files (no `tmp + mv`) make waybar render empty pills. Signalling without dedup makes waybar wake up for nothing — exactly the "10,000 polls" problem the user wants to avoid.

### Composite modules (subscribe to multiple channels)

A module that needs state from several daemons reads multiple cache files in its exec, or — when it needs to react to *any* upstream change instantly — uses an inotify watch on `/tmp/waybar-cache/` and recomputes on close_write / moved_to events whose filename matches its set of dependencies.

The mpris work in `/home/max/mpris-waybar/` is the reference example of this composite pattern (one main loop, multiple producers, debounced FIFO, atomic cache writes, single waybar signal on real change).

---

## Hyprland event subscription (the cheapest context source)

Hyprland exposes a unix socket that pushes events for every window/workspace/monitor state change. The workspace-daemon currently polls `hyprctl` at 1 Hz — when we tighten this, the move is to subscribe.

```bash
socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock - | \
    while read -r line; do
        case "$line" in
            activewindow*|activewindowv2*) ... ;;
            workspace*) ... ;;
            openwindow*|closewindow*) ... ;;
            monitoradded*|monitorremoved*) ... ;;
            configreloaded*) ... ;;
        esac
    done
```

When the workspace-daemon migrates from polling to event-subscription, it slots in here. The cache schema and signal stay identical; only the trigger source changes.

---

## Light/dark adaptation (system-wide UX feature)

The glass-text-daemon writes `light` or `dark` to `/tmp/glass-mode` based on the desktop color behind the bar. Every text-bearing pill must:

1. Read `/tmp/glass-mode` in its exec (default to `dark` if missing).
2. Emit `"class": "<mode> ..."` with the mode as the first space-separated token.
3. Have matching `#custom-<name>.light label` and `#custom-<name>.light:hover label` selectors in `style.css` so the text flips to dark when the wallpaper is light.

**Forgetting any of this** = invisible pill over half of wallpapers. The light-block selectors in `style.css` (the long comma-separated lists) must be kept in sync with the set of light-text-bearing modules. When you add a module, append its ID to those lists in the same commit.

This is the single most-violated invariant. Audit it on every commit that adds a module ID.

---

## Adding a new option — the recipe

1. **Pick its zone.** USER / TASK / SYSTEM. Write the zone in the module's commit message.
2. **Pick its size class.** Trigger (small, icon-only) or value (long, displays text). Binding for the option's lifetime.
3. **Pick its state colors.** Which primary (Blue/Yellow/Red) does it use, in which conditions? Which secondary (Violet/Green/Orange) animations? Document in a comment above the CSS rules.
4. **Check the daemon registry above.** If an existing daemon already publishes the context this option needs, subscribe to that cache file. If not, decide: extend an existing daemon, or add a new one (and update the daemon registry + signal table in this file).
5. **Implement the module in `config.jsonc`** under the correct zone section. Use the daemon-driven pattern (read from `/tmp/waybar-cache/<name>`, set `signal:` to the daemon's signal). Use the read-pattern (one-shot exec) only when the option is truly stateless (e.g., a launcher trigger).
6. **Implement the CSS** in `style.css` under the correct section. Always include the `.light` label selectors. Always include the empty-collapse recipe if the pill can be conditionally hidden.
7. **Implement (or extend) the daemon** as a Nix module under `/etc/nixos/home/modules/option-<name>.nix` per the CLAUDE.md template. Wire it into `home.nix`.
8. **Test:** `sudo nixos-rebuild switch && systemctl --user restart waybar.service <new-daemon>.service`. Verify pill renders correctly under both light and dark `/tmp/glass-mode` (force-toggle by `echo light > /tmp/glass-mode` and signal waybar with `pkill -RTMIN+10 waybar`).
9. **Commit:** one commit, message includes zone, daemon used, signal number, and the failure mode the option prevents.

---

## What we explicitly do NOT do

- **No per-module polling for state another module already needs.** That's the daemon's job.
- **No fork-per-tick in the daemon's hot loop.** Read `/sys/...`, use bash builtins, do one `jq` per snapshot. The mpris CPU regression of 2026-05-27 was the lesson.
- **No signalling waybar on every tick.** Dedup at the daemon. Only signal when content actually changed.
- **No introducing a new color, motion, or surface** without a written justification that no existing one suffices. The budget is closed.
- **No assuming "/tmp/waybar-cache/" exists.** Every daemon `mkdir -p` it on startup. Daemons restart; the directory might not be there yet.
- **No leaving the daemon registry above out of sync** with reality. If you add a daemon, update the table in the same commit. If we don't, this file lies, and future-you (or future-me) makes architectural decisions on bad data.

---

## Migration status (what of OPTIONS is wired today)

- ✓ Pill primitive, hover-brighter rule, 30 px border-radius
- ✓ Group drawer + expansion-direction zones
- ✓ Glass-text adaptive text (`light`/`dark` class)
- ✓ Cache-file + signal pattern (RTMIN+10/11)
- ✓ Workspace-daemon publishes window/workspace/win-move state
- ~ Color system — used unsystematically; primary/secondary semantics not yet enforced; `state-yes/middle/no` classes not yet adopted
- ~ Three-zone layout — implicit in current placement, will be made explicit in next `config.jsonc` pass
- ✗ Parent vs child surface differentiation (cool 50,50,70 vs warm 70,50,50)
- ✗ `opt-pulse` / `opt-glow` / `opt-breathe` named animations — `blink`/`shine`/`pulse-plus` exist as un-renamed predecessors
- ✗ system-daemon, network-daemon, bluetooth-daemon, audio-daemon, clipboard-daemon — none of the planned daemons exist yet
- ✗ Composite-module pattern with inotify on `/tmp/waybar-cache/` — pattern documented, not implemented for any pill

When this list reaches all ✓, OPTIONS is fully wired and the rest is just adding options that fit the grammar.
