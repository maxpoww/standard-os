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
6. **Quiet invitation.** Standard-OS is for every person — students, parents, professionals coming from macOS or Windows. The mouse is the entry door, and every option is fully reachable with it. *Above* that floor, the OS quietly invites the user toward a richer vocabulary: pressing a basic hardware key (volume, brightness, mute, play/pause, screenshot, airplane) makes the same pill respond as a mouse click would. The button does the same job faster, and over time the user notices. The OS never advertises the keyboard, never nags, never shows a "did you know?" tip. Discovery is voluntary and earned. The mouse user who never presses a hardware button experiences no degradation. Only basic, universal keys are part of the invitation — niche actions stay mouse-driven or discoverable through the option grammar itself; we do not train the user on Hyprland.

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

Options uses **six colors and four motions** to express *meaning*, painted onto **two surfaces** that express *structure*. The set is closed: anything new must replace something existing, not extend the budget.

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

**Parents are naturally uncolored.** A parent pill — one that sits permanently on the bar — does *not* carry a primary state color at rest. The healthy bar reads as neutral surface plus content, not as a field of blue. Color on a parent only ever appears in two ways:

- As a **hover-swap action-reveal face** (`opt-swap-*`) — `ws-current`'s blue "+" with `opt-pulse-plus`, the power pill's red on hover. The hover IS the meaning: "here is what clicking me does."
- As a **secondary-color animation** (`opt-pulse | opt-glow | opt-breathe`) or a **pin** (see below) when the system needs the user's attention.

Primary state colors live on **children** — pills revealed inside an expanded cluster. There the rule inverts: children should use blue / yellow / red to express action semantics (`win-close` = red destructive, `win-move-new` = blue forward) and "you are here" markers (`win-move-N` for the current workspace = blue). A child without state is fine; a parent with persistent state color is not.

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

### Pins

An animation gets the user's eye. A **pin** holds it. When a secondary-color motion resolves, the pill can keep that secondary color painted solid — the *pin* — until the underlying state changes or the user acknowledges the option by hovering or clicking it.

| Class | Color | Typical antecedent |
|---|---|---|
| `opt-pin-violet` | violet (solid) | something completed healthily — build finished, sync done |
| `opt-pin-green` | green (solid) | a soft "look here" worth noting — update available, low-but-not-critical battery |
| `opt-pin-orange` | orange (solid) | something needs attention — WiFi dropped, render failed |

The animation (pulse / glow / breathe) calls the user's attention; the pin keeps that attention persistent without burning CPU on infinite motion. A pin without a preceding animation is allowed but rare — usually the animation does the calling, the pin does the holding.

**Pin clearing.** A pin clears when any of: the underlying state changes (the daemon recomputes and overwrites), the user hovers the pill (acknowledgement), the user clicks the pill (engagement). The daemon owns pin lifecycle; pills never animate forever.

### Hover

Hover splits into two tiers. The pill's class composition picks which.

**Default — brighten the rest color.** Every pill gets a semi-transparent white film layered over its existing background-color (`opt-hover-bright`, implemented as `box-shadow: inset 0 0 0 999px rgba(255, 255, 255, 0.30)`). A blue pill brightens to light-blue; a red pill to light-red; a neutral parent to near-white-gray. Identity is *preserved, not erased*. Hover says "you're targeting *this specific* option."

This replaces the earlier uniform gray veil, which painted every hovered pill the same color regardless of its state — flat, muddied colors, and erased identity. Brightening the pill's own color reads cleaner and teaches the user what the option IS, not just that it exists.

**Action — beat on hover.** Pills whose click *changes the world* — verbs with consequence — beat on hover instead of brightening. Font/glyph pulses in size; color cycles between the pill's rest tone and a brighter same-tone. Motion = "this matters." Static brighten = "you're just looking." Reserve motion so it keeps meaning.

The "+" option is the canonical example: every "+" pill in the bar (apps launcher, ws-current's hover face, win-move-new) shares the `opt-plus` class, which paints the + SVG at rest and runs `opt-pulse-plus` (size + blue color ladder) on hover. The user reads "+" as ONE option no matter where it appears.

Forward-looking, the same beat pattern extends to:
- **Destructive verbs** (kill, close, shutdown, disconnect) — beats red.
- **Toggle-off verbs** (mute, disable, turn off) — beats orange.

Today only blue (the `+` family) is wired; the red/orange tones are defined in the design vocabulary so future action pills join the same discipline.

**Swap pills** (`opt-swap-*`) are a third special case: their hover is the *action reveal* — the rest face shows the pill's info content, hover shows the action. Swap hovers paint their own colors and run their own motions. The `opt-plus.opt-swap` composition (used by ws-current) marries the canonical `+` pattern to the swap mechanic — same hover face as a non-swap `+` pill, just hidden at rest behind the workspace number.

**Borders carry one thing only: `opt-pushed`** (see below). No hover border, no state border, no decorative border. The single carve-out exists because a binary toggle in the ON state needs to read as a *pressed-in* surface, and the inset edge is the cheapest, most universal way to say "depressed." Everywhere else: surfaces and motion carry the lift; outlines do not.

### Motion vocabulary

Three motions. The motion is the *shape* of the change; the *color* carries the meaning.

- **Pulse** — opacity 0.5 → 1.0 → 0.5, ~1 Hz. Used when the system needs the user to look *now*.
- **Glow** — slow fade in, hold ~2 s, fade out. Used when the system wants to *offer* something the user may or may not act on.
- **Breathe** — very slow opacity sine, ~6 s cycle. Used when *background activity is ongoing* (sync, render, healthy continuous state).
- **Flash** — one-shot ~250 ms. The pill briefly darkens with a small inset shadow that reads as a physical button being pressed in. Used **only** to acknowledge a hardware-key press or a fresh transient pill appearing in direct response to user input. Carries no state meaning — it's just the bar saying "I received that." Composes with everything: an `opt-pushed` pill flashing reads as *deeper-pressed* for the moment, then settles back; an `opt-yes` pill flashing reads as briefly-darker-blue. Mute-while-flashing shows the press-feedback layered over the muted state — the user sees they pressed something AND that nothing succeeded (because mute is still on).

Primary state colors do **not** animate. State is state; if it's changing, a secondary-color animation paints over it to show the change. State itself is calm.

### Input is acknowledged; context shifts are silent

A precise rule about *when* the bar performs and when it doesn't:

- The bar **performs** for the user — `opt-flash`, the swap-reveal animation, the hover veil, the drawer expansion. These are *acknowledgements* of input. Direct input → direct response.
- The bar **does not perform** for itself. When pills appear or disappear because *context* changed — the focused window's class shifted, a USB audio device showed up, the dive flag flipped, the workspace's occupancy changed — the swap is silent. No fade, no flash, no transition. The pill is just *there now* or *not anymore*. The user shouldn't be drawn to notice; the environment simply adapts.

The reason: any system-driven motion competes with the user's actual task for attention. A pill that announces its own appearance is asking to be looked at, and 99 % of the time the user neither needs nor wants to look at it. Silent context adaptation is what makes the bar disappear into the workflow — pillar 5's diegesis, applied to motion.

### Pushed (toggle ON)

Some options are mechanical toggles — sound mute, paper-texture shader, WiFi radio. A toggle is currently engaged when it carries `opt-pushed`: a slightly darker surface plus a 1 px inset border that reads as a pressed-in button.

`opt-pushed` is a **structural** modifier, separate from state. They compose orthogonally:

- `opt-pushed` alone — engaged, no value judgment (a shader texture is on).
- `opt-pushed.opt-yes` — engaged and good (WiFi radio on AND connected).
- `opt-pushed.opt-breathe` — engaged with ongoing ambient activity (microphone recording).

The 1 px inset border is the **only** border in OPTIONS. Borders carry exactly this one meaning; allowing them anywhere else dilutes the signal.

### Dimmed (occupied, not selected)

When a module lists peer items — workspaces, sinks, paired devices — and some of those peers *exist but are not currently the focus*, those peers get **dimmed**: reduced opacity, surface unchanged, no state color. The eye is then drawn naturally to the items that are either empty (collapsed via `.empty`) or current (full opacity).

Dimmed is not "off" (`opt-no`) and not "absent" (`.empty`). It is **occupied, not selected**:

- Workspaces 1–9 that have windows but aren't the one you're on: dimmed.
- A paired Bluetooth device that exists in the cluster but isn't the active sink: dimmed.
- A network connection profile saved but not connected right now: dimmed.

Implemented in CSS as `.inactive` (the class wired into the workspace daemon). The rule's vocabulary name is *dimmed*; the implementation class is `.inactive` for backward compatibility until the daemon migrates to Nix.

---

## Tooltips

Help text appears when the pill alone doesn't carry the full meaning. Tooltips are part of the diegetic contract: short, imperative, and only where they earn their keep.

- They appear after GTK's standard hover delay (~700 ms — practically "a deliberate hover"). Same delay as every other GTK app the user touches, which reinforces a single muscle memory.
- One line. Imperative for triggers, status-then-action for value pills.
  - Trigger → the action: `"Lock screen"`, `"Open task switcher"`, `"Scan for networks"`.
  - Value pill → status, optionally action: `"23% — Discharging"`, `"WiFi: home-5G"`.
- A pill is **denied a tooltip** when the icon or label is self-evident. The launcher "+" gets no tooltip. The workspace number `3` gets no tooltip. The focused-window title is its own tooltip.
- Forbidden: restating the icon (`"This is a + button"`), naming the technology (`"swaylock"`, `"rofi -show drun"`), or two-line essays.

The tooltip popup is styled to match the pill aesthetic (deep parent surface, white text, 8 px radius) so it reads as the bar speaking rather than as a system intrusion.

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

A future maintainer of Options should keep these rules in mind:

1. **Every new pill declares its size class, its zone, and its color rules before any code is written.** If the answer to "is this a trigger or a value pill", "which zone", or "which primary state(s) does it have" is not obvious, the option is not ready.
2. **Parents are naturally uncolored.** If a parent acquires color, it is one of: a hover-swap action-reveal face, a secondary-color animation, a pin, or `opt-pushed`. Never persistent primary state.
3. **Animations are grammar, not decoration.** Adding a new motion, color, or surface requires a written justification that no existing one suffices. The set is six colors, four motions, two surfaces, and the one border that lives on `opt-pushed` — that is the budget.
4. **Input is acknowledged; context shifts are silent.** Motion happens in response to user action (a press, a hover, a click) or as a call for attention the user should resolve. The bar never animates *itself* — context-driven appearance and disappearance is instantaneous and quiet.
5. **Modules do not consult each other.** A module subscribes to context signals and decides its own visibility. Coupling between modules is a maintenance smell. The bar composes; modules author; the context is the only shared world.
6. **Same option, same look.** When the same option (verb + glyph) appears in multiple places — every `+`, every "kill", every "open", every "lock" — it MUST share class composition across all instances. The user reads it as ONE option no matter where it appears; inconsistent treatment teaches contradictory mental models. New code adding a recurring option reuses the canonical class string. It does not reinvent one. The first example is `opt-plus`: a single class binding apps launcher, ws-current's hover face, and win-move-new to one shared visual.
7. **No-op options don't appear.** If clicking a pill would do nothing, the pill collapses to `.empty`. The move-to-workspace list excludes the current workspace (moving a window to where it already lives is a no-op). The sink chooser excludes the current sink. The brightness profile list omits the active profile. Every visible pill represents an action that would change something — option lists stay honest. Pairs with Rule 6 from the other direction: same-option says "if it's the same action, give it the same look"; no-op says "if it's not an action at all, don't show it."

The hardest part of Options is not building it. It is having the discipline to *not* add the obvious-feeling seventh color, the eighth motion, the toolbar that is always there. The user's attention is finite. Options spends it carefully.

---

*Standard-OS designs Options to feel less like a tool and more like an environment that pays attention. The reader of this document is the future maintainer who will keep that promise.*
