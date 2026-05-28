# OPTIONS

> The user-experience layer of Standard-OS — the new-generation system for all people.

Designed and developed by **Standard-OS**. This document describes the design and the rules that future maintenance must respect.

---

## What is Options

Standard-OS is built on three nouns: **spaces** (workspaces), **windows** (running applications), and **options** (everything else the user might want to do). Spaces and windows are direct — the user moves, opens, closes, focuses them. Options is the rest, and the rest is large: network state, audio routing, screen brightness, the active file's actions, the running render's progress, the time of day, the clipboard, the suggested next step.

In conventional systems each of these lives in a different place — a tray, a menu bar, a settings app, a hotkey, a tooltip — and the user is the one who has to remember where. Options removes that responsibility. Instead of every tool being available all the time, the right tool is available at the right moment. The user discovers what they need by being in the world that needs it.

The system always offers help without ever demanding the user ask for it. Frustration becomes revelation.

---

## Design pillars

1. **The environment is the assistant.** No separate help layer. The desktop itself speaks.
2. **The system reads and reacts.** User actions are the input language; system responses are the dialogue.
3. **Resources appear when their use is logical.** No persistent toolbars of buttons that are 95% irrelevant 95% of the time.
4. **Help scales to skill.** A newcomer sees more scaffolding; a fluent user sees less, until the system dissolves into the workflow.
5. **Diegetic information.** Tools live *in* the environment, not stacked on top of it.

---

## The unit: the option

Every piece of Options the user sees is an **option** — a pill. Pills are the only visible primitive. The grammar is small on purpose; a small grammar is teachable, and a teachable grammar disappears.

### Pill grammar

- **Size carries meaning.** A small icon-only pill is a *trigger*. A long pill displays a *value* (the connected network's name, the current resolution, the focused window).
- **In-pill chevrons (↔)** mean *cyclable*. The pill itself tells the user what it does — no tooltip required.
- **More options live below.** When an option has alternatives, hover or click reveals more pills *beneath* the parent, in the same visual language. Today these below-pills are rendered by rofi; the user does not see a seam.
- **Selection promotes.** Choosing from below-pills causes the chosen pill to *rise* and become the parent's content. The hierarchy collapses cleanly; no breadcrumb is needed.
- **Hover reveals clusters.** Hovering a trigger slides out its related pills horizontally (`WiFi` → `network-name`, `signal-strength`).
- **Multiple rows are allowed.** Standard-OS opens additional bar rows for control-panel-style depth. Each row is its own waybar instance, configured independently.

---

## Bar layout

The bar is divided horizontally into three zones. Each zone has a single responsibility, and the user learns the bar by learning the zones.

| Zone | Position | Holds | Examples |
|---|---|---|---|
| **User** | left | Where the user is — current location, current focus, actions on the focused thing | workspaces (current location), focused-window pill, per-window actions (close / minimize / swap / move) |
| **Task** | center | Task-manipulation tools — start, switch, restore | launcher "+", lock, task switcher, restore-minimized |
| **System** | right | Persistent system state | network, audio, bluetooth, battery, theme, time, power |

The **focused-window pill** at the right edge of the USER zone is the visible anchor of the user's current task. The **launcher "+"** at the left edge of the TASK zone sits directly next to it — the visual bridge between "the task you have" and "another task you could start." Clicking the focused-window pill (or the task switcher in CENTER) surfaces other windows; selecting one promotes that window to focus.

### Expansion direction

When a pill expands a horizontal cluster of siblings (via hover or click), the cluster slides **away from the nearest wall** — so the cluster never escapes the screen.

| Parent's location | Cluster slides | Wall it avoids |
|---|---|---|
| Left zone (user) | right | left screen edge |
| Right zone (system) | left | right screen edge |
| Center, right of the focused-window pill | right | the focused-window pill |
| Center, left of the focused-window pill | left | the focused-window pill |

Edge pills follow the same rule, with the screen edge as the wall.

Vertical below-pill stacks (the rofi-style "more options" column under a clicked parent) drop straight down. No horizontal direction is involved.

---

## Color and motion

Options uses **six colors and three motions** to express *meaning*, painted onto **two surfaces** that express *structure*. The set is closed: anything new must replace something existing, not extend the budget.

The system distinguishes between *what the user is doing to an option* (primary) and *what the system is saying about that option* (secondary).

### Parent and child surfaces

Pill background distinguishes the *level* of the option in the hover hierarchy. This matters during expansion: when a parent fans out its sibling cluster and another parent sits right beside it, the user needs to see where the hovered group ends and the next group begins.

| Surface | Background | Family | Meaning |
|---|---|---|---|
| Parent | `rgba(50, 50, 70, 0.30)` (cool dark blue-violet) | cool | Top-level options sitting permanently on the bar |
| Child | `rgba(70, 50, 50, 0.30)` (warm dark brown-red) | warm | Pills revealed because a parent was expanded |

The shift from cool base to warm base is intentionally subtle — same lightness, same alpha, hue rotated — enough to read as a group boundary, quiet enough not to announce itself. The state and animation colors below read clearly against both surfaces.

### Primary — state colors

Painted on the pill itself. Persistent. They tell the user the current discrete state of the option.

| Color | Meaning | Example |
|---|---|---|
| 🟦 **Blue** | YES / on / connected / good | Bluetooth is paired and connected |
| 🟨 **Yellow** | MIDDLE / on but partial / disconnected | Bluetooth is on but no device paired |
| 🟥 **Red** | NO / off / unavailable | Bluetooth is disabled |

Blue is the resting "good" state. When the system is healthy and configured, the bar reads predominantly blue. That is the design intent: blueness means *everything is in order*.

### Secondary — animation colors

Painted *over* the pill as a brief animation. Transient. They tell the user the *health* of the current state or the fact of a *transition*.

| Color | Meaning | Example |
|---|---|---|
| 🟪 **Violet** | YES / full / healthy | Battery at 100% — violet breathe |
| 🟩 **Green** | MIDDLE / attention worth noting | Battery should be charged soon — green glow |
| 🟧 **Orange** | NO / bad / failing | Battery critical — orange pulse |

### Correlative pairs

Each primary color pairs with the secondary in its temperature family:

| Primary | Secondary | Family |
|---|---|---|
| Blue (yes) | Violet (yes) | cool |
| Yellow (middle) | Green (middle) | mid |
| Red (no) | Orange (no) | hot |

This pairing is what makes transitions read naturally. An animation may move *between correlatives*: a WiFi pill searching for a network animates **violet** (we want a yes; we're trying); when the connection succeeds, the animation resolves into the solid **blue** state. The cool-family animation foreshadowed the cool-family final state.

### Hover

Hover is **not a separate color**. Hover is the option's current color, *brighter*. A blue pill becomes a brighter blue on hover; a red pill, a brighter red. The user perceives the same affordance intensified — never a swap of identity.

### Motion vocabulary

Three motions. The motion is the *shape* of the change; the *color* carries the meaning.

- **Pulse** — opacity 0.5 → 1.0 → 0.5, ~1 Hz. Used when the system needs the user to look *now*.
- **Glow** — slow fade in, hold ~2 s, fade out. Used when the system wants to *offer* something the user may or may not act on.
- **Breathe** — very slow opacity sine, ~6 s cycle. Used when *background activity is ongoing* (sync, render, healthy continuous state).

Primary state colors do **not** animate. State is state; if it's changing, a secondary-color animation paints over it to show the change. State itself is calm.

---

## Worked examples

### Bluetooth — full lifecycle

| Step | Pill | What the user sees |
|---|---|---|
| BT disabled | small, **red** | "It exists, it is off." No hover affordance. |
| User clicks | small, **yellow** | "Now on, nothing paired." Hover now reveals the device list below. |
| User picks a device from below-pills | pills collapse, BT pill → **blue**; device name appears as a long pill beside the trigger | Connected. |
| Headphone battery healthy | blue pill with **violet breathe** | Connected and well. |
| Headphone battery critical | blue pill with **orange pulse** | Connection is still fine; the warning is about the device's health. The animation does the warning work; the state stays blue. |

### WiFi — searching to connected

The pill is **yellow** (on but disconnected). It animates **violet** (we want a yes; we're trying). On connect, the animation stops; the pill snaps to **blue** and the network name appears as a long pill beside it.

### Battery — animation-only signaling

The battery pill rarely changes its primary state, but its health does. Animation does all the talking.

- 80–100 % → **violet breathe** (healthy).
- 20–80 % → no animation (calm; nothing to say).
- 10–20 % → **green glow** (attention).
- < 10 % or unhealthy → **orange pulse** (urgent).

---

## The context engine

Options decides what to show by reading a continuously updated **context** assembled from system signals.

| Signal | Source | What it tells the system |
|---|---|---|
| Focused window class & title | `hyprctl` | Which app the user is in |
| CPU load | `top` | Whether the CPU is busy |
| GPU load | `nvtop` | Whether a GPU job is ongoing |
| Time of day & timezone | system clock | Day/night adjustments |
| Audio routing & default sink | `wpctl` | Whether sound is configured and active |
| Text selection state | clipboard listeners | Whether text-operation options should surface |
| Network state | `nmcli` / wireplumber | Network options relevance |
| Battery / power | `upower` | Power-related animations |
| Bluetooth state | `bluetoothctl` | BT pill state |

Each signal is broadcast cheaply. Each module subscribes to the signals it cares about and decides for itself whether to render. The bar is the composer; the modules are the authors; the context is the world they read.

The set of signals will grow. Day-one coverage is intentionally partial — the goal is to prove the concept and refine through use. The architecture must make adding, removing, and sharpening modules cheap.

---

## Implementation substrate (today)

- **waybar** renders the persistent rows of options.
- **rofi** renders the "more options below" extensions when a pill expands.
- Both are styled to share one pill grammar so the user perceives a single fabric.

Both are replaceable. Options is the specification; waybar and rofi are the current renderers. Future Standard-OS releases may swap either for purpose-built components without changing the spec or the user's experience.

---

## Maintenance rules

A future maintainer of Options should keep three rules in mind:

1. **Every new pill declares its size class and its color rules before any code is written.** If the answer to "is this a trigger or a value pill" is not obvious, the option is not ready.
2. **Animations are grammar, not decoration.** Adding a new motion, color, or surface requires a written justification that no existing one suffices. The set is six colors, three motions, and two surfaces — and that is the budget.
3. **Modules do not consult each other.** A module subscribes to context signals and decides its own visibility. Coupling between modules is a maintenance smell. The bar composes; modules author; the context is the only shared world.

The hardest part of Options is not building it. It is having the discipline to *not* add the obvious-feeling seventh color, the eighth motion, the toolbar that is always there. The user's attention is finite. Options spends it carefully.

---

*Standard-OS designs Options to feel less like a tool and more like an environment that pays attention. The reader of this document is the future maintainer who will keep that promise.*
