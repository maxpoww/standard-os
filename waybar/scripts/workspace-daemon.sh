#!/usr/bin/env bash
# workspace-daemon.sh — polls hyprctl once per second and writes one JSON
# pill per waybar module into /tmp/waybar-cache. Modules read those files
# with `cat`. Every pill emitted here speaks the OPTIONS class vocabulary
# (see docs/superpowers/specs/2026-05-28-options-foundation-design.md).

set -uo pipefail

# Source the OPTIONS pill helpers (pill_theme, pill_class, pill_write).
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/pill.sh
. "$SELF_DIR/lib/pill.sh"

# ── Emit one complete snapshot of all workspace pill caches ──────────────────
# Extracted so it can be called once before the event loop (self_seed) and
# then on every subsequent tick. On fresh tmpfs /tmp (reboot, manual rm -rf),
# calling this before the loop ensures all cache files exist within ~1 second
# of daemon startup rather than waiting for the first loop iteration to complete
# past its trailing sleep 1.
emit_snapshot() {
    # Self-heal: recreate cache dir every tick so we survive any external wipe.
    mkdir -p "$PILL_CACHE_DIR"

    m="$(pill_theme)"
    active="$(hyprctl activeworkspace -j 2>/dev/null)"
    workspaces="$(hyprctl workspaces -j 2>/dev/null)"
    activewin="$(hyprctl activewindow -j 2>/dev/null)"

    a="$(echo "$active"     | jq -r '.id' 2>/dev/null)"
    ws_ids="$(echo "$workspaces" | jq -r '.[].id' 2>/dev/null)"
    title="$(echo "$activewin"   | jq -r '.title // empty' 2>/dev/null)"

    # ws-current — neutral parent pill at rest (shows current WS number).
    # Hover swaps to "+" via opt-plus.opt-swap + opt-pulse-plus animation in CSS.
    # No opt-yes at rest: the WS module's visual identity comes from the
    # number on a baseline surface, not from a permanent blue highlight.
    pill_write "ws-current" "$a" "opt-pill $m opt-plus opt-swap"

    # ws-1..9 — drawer siblings, all parent surface (NOT child). The
    # workspace drawer reveals peer locations, not sub-options of ws-current.
    # Current ws looks the same as inactive ones; the difference between
    # them is only opacity (the .inactive class) so the eye is drawn to the
    # ones you haven't visited. Empty slots collapse via .empty.
    for i in 1 2 3 4 5 6 7 8 9; do
        if echo "$ws_ids" | grep -qx "$i"; then
            if [ "$a" = "$i" ]; then
                pill_write "ws-$i" "$i" "opt-pill $m"
            else
                pill_write "ws-$i" "$i" "opt-pill $m inactive"
            fi
        else
            pill_write "ws-$i" "" "opt-pill empty"
        fi
    done

    # window title — center value pill, opt-swap-switch reveals switcher action.
    pill_write "window" "${title:-}" "opt-pill $m opt-swap-switch"

    # has-window flag — drives the focused-window cluster's existence. Empty
    # workspace ⇒ collapse the whole active-window group. Only signal waybar
    # when the flag actually flips (the OPTIONS dedup rule).
    win_class="$(echo "$activewin" | jq -r '.class   // empty' 2>/dev/null)"
    win_addr="$( echo "$activewin" | jq -r '.address // empty' 2>/dev/null)"
    prev_hw="$(cat "$PILL_CACHE_DIR/has-window" 2>/dev/null)"
    if [ -n "$win_class" ] && [ -n "$win_addr" ] && [ "$win_addr" != "0x" ]; then
        hw="1"
    else
        hw=""
    fi
    if [ "$hw" != "$prev_hw" ]; then
        printf '%s' "$hw" > "$PILL_CACHE_DIR/has-window.tmp" \
            && mv -f "$PILL_CACHE_DIR/has-window.tmp" "$PILL_CACHE_DIR/has-window"
        pkill -RTMIN+10 waybar 2>/dev/null || true
    fi

    # Per-window action pills — children of active-window drawer.
    # Visible when a window is focused; collapsed (.empty) when not.
    if [ "$hw" = "1" ]; then
        # Window-action color semantics:
        # win-close (kill) — destructive child, permanent red (opt-no)
        # win-minimize    — defer child, permanent yellow (opt-middle)
        # win-move-trigger — peer in the R/Y/B trio, even though structurally
        #                    a drawer parent; permanent blue so the three icons
        #                    read as a coherent group at rest. This is a
        #                    deliberate exception to Rule 2 (parents naturally
        #                    uncolored): when a parent sits visually as one
        #                    of a color-coded trio, it adopts the peer's
        #                    treatment for legibility.
        pill_write "win-close"       "󰅖" "opt-pill-child $m opt-no"
        pill_write "win-minimize"    "󰍶" "opt-pill-child $m opt-middle"
        pill_write "win-swap-right"  ""  "opt-pill-child $m"
        pill_write "win-move-trigger" "󰯍" "opt-pill-child $m opt-yes"
        # win-move-new: creates new workspace → opt-plus (same-option rule —
        # every "+" in the bar shares this class composition). Text content
        # is the FA plus glyph (U+F067, hidden by .opt-plus color:transparent);
        # waybar hides any custom module whose text is empty, so we pass a
        # non-empty glyph and let CSS paint the SVG over it.
        pill_write "win-move-new"    "" "opt-pill-child $m opt-plus"
    else
        for name in win-close win-minimize win-swap-right win-move-trigger win-move-new; do
            pill_write "$name" "" "opt-pill-child empty"
        done
    fi

    # win-move-1..9 — workspace targets inside the move drawer. Rule 7
    # (no-op options collapse): moving a window to the workspace it already
    # lives on is a no-op, so the current WS is emitted empty rather than
    # as a clickable pill. Non-existing WSes also collapse. Remaining pills
    # are the valid move destinations — colored opt-yes (forward/transitional
    # action, matching the move-trigger that opens this drawer).
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ "$hw" = "1" ] && echo "$ws_ids" | grep -qx "$i" && [ "$a" != "$i" ]; then
            pill_write "win-move-$i" "$i" "opt-pill-child $m opt-yes"
        else
            pill_write "win-move-$i" "" "opt-pill-child empty"
        fi
    done
}

# Seed all pill caches once before entering the event loop. On fresh tmpfs /tmp
# (reboot, manual rm -rf) this guarantees every cache file exists within ~1
# second of daemon startup without waiting for the trailing sleep 1 to expire.
emit_snapshot

while true; do
    emit_snapshot
    sleep 1
done
