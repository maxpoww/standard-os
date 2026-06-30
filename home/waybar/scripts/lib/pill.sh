#!/usr/bin/env bash
# OPTIONS pill helpers — the single source of truth for how a waybar module
# emits its JSON. Every custom module either uses the inline `pill` / `pill-child`
# wrapper (for static buttons) or sources this file from a daemon and calls
# pill_write (for state-driven modules).
#
# Class vocabulary (from docs/superpowers/specs/2026-05-28-options-foundation-design.md):
#   Structure (required): opt-pill | opt-pill-child
#   Theme (required):     dark | light          (glass-text-daemon driven)
#   State (0/1):          opt-yes | opt-middle | opt-no
#   Animation (0/1):      opt-pulse | opt-glow | opt-breathe
#   Tone override (rare): opt-tone-red | opt-tone-yellow | opt-tone-blue
#   Swap (0/1):           opt-swap-<kind>      (per-pill, the action face)
#   Empty:                empty                (collapse the pill)
#
# Functions:
#   pill_theme                          → echoes "dark" or "light"
#   pill_class <c1> [c2 ...]            → joins non-empty classes with " "
#   pill_emit <text> <classes> [tooltip]→ prints JSON to stdout (no newline)
#   pill_write <name> <text> <classes> [tooltip]
#                                       → atomic write to /tmp/waybar-cache/<name>,
#                                         dedup against previous content,
#                                         signals waybar (RTMIN+10) only on change.

# Cache directory shared with waybar config.jsonc consumers.
PILL_CACHE_DIR="${PILL_CACHE_DIR:-/tmp/waybar-cache}"
PILL_GLASS_FILE="${PILL_GLASS_FILE:-/tmp/glass-mode}"

# Per-pill geometry registry — used by rofi-anchor.sh to anchor popups
# under their trigger pill. Each pill_write emits a small JSON record
# to PILL_GEOM_DIR/<name>.json (one file per pill — avoids jq merging
# in the hot loop). Width is estimated from text length; X is computed
# later by the rofi anchor library walking sibling widths.
PILL_GEOM_DIR="${PILL_GEOM_DIR:-/tmp/waybar-cache/pill-geom}"
PILL_GEOM_HYPR_CTX="${PILL_GEOM_HYPR_CTX:-/tmp/waybar-cache/hypr-context.json}"
PILL_PAD_X="${PILL_PAD_X:-8}"            # left+right padding combined (logical px)
PILL_FONT_ADVANCE_PX="${PILL_FONT_ADVANCE_PX:-8}"  # avg glyph width at 13pt bar font

# Read /tmp/glass-mode. Default "dark" if the file is missing or unreadable —
# this is the safe choice because dark text on a light wallpaper disappears
# but white text on dark is always visible. The glass-text-daemon writes
# either "light" or "dark"; nothing else is ever expected.
pill_theme() {
    local m
    m=$(cat "$PILL_GLASS_FILE" 2>/dev/null) || m=""
    case "$m" in
        light|dark) printf '%s' "$m" ;;
        *)          printf '%s' "dark" ;;
    esac
}

# Join non-empty positional args with a single space. Empty args are skipped
# so callers can pass dynamic class names that may be "" without producing
# "opt-pill  opt-yes" (double-space) or trailing whitespace.
pill_class() {
    local out="" c
    for c in "$@"; do
        [ -n "$c" ] || continue
        if [ -z "$out" ]; then out="$c"; else out="$out $c"; fi
    done
    printf '%s' "$out"
}

# Minimal JSON string escaping: backslashes and double quotes. Newlines and
# tabs are extremely unlikely in waybar pill text (icons + short strings)
# but we collapse newlines to spaces defensively so a stray title with a \n
# can't break parsing.
pill_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# Estimate visual width of a pill in logical screen pixels.
# Returns PILL_PAD_X + (char_count * PILL_FONT_ADVANCE_PX).
# Used by the geometry registry to predict where each pill sits, so
# rofi popups can be anchored under their trigger. Error budget ~±10px.
pill_estimate_width() {
    local text="${1:-}"
    local n=${#text}
    printf '%d' $(( PILL_PAD_X + n * PILL_FONT_ADVANCE_PX ))
}

# Resolve the focused monitor's name from hypr-context.json. Returns
# empty if hypr-context is missing or unparseable — callers fall back
# to "".
pill_geom_focused_monitor() {
    local ctx
    [ -r "$PILL_GEOM_HYPR_CTX" ] || { printf ''; return; }
    ctx=$(cat "$PILL_GEOM_HYPR_CTX" 2>/dev/null) || { printf ''; return; }
    # Extract "monitor_focused":"<name>" without a jq fork.
    # Pattern: matches the literal key + value, captures the name.
    if [[ $ctx =~ \"monitor_focused\":\"([^\"]+)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Emit a per-pill geometry record. One file per pill — avoids jq merging
# in the pill_write hot path. Atomic via tmp+mv. Caller passes the
# already-estimated width (0 for .empty pills); monitor is the focused
# monitor's name, defaulting to whatever hypr-context publishes.
pill_emit_geom() {
    local name="$1"
    local w="$2"
    local monitor="${3:-}"
    [ -z "$monitor" ] && monitor=$(pill_geom_focused_monitor)
    mkdir -p "$PILL_GEOM_DIR"
    local f="$PILL_GEOM_DIR/$name.json"
    local content; content=$(printf '{"w":%d,"monitor":"%s"}' "$w" "$monitor")
    local prev=""; [ -r "$f" ] && prev=$(cat "$f" 2>/dev/null)
    [ "$content" = "$prev" ] && return 0
    printf '%s' "$content" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# Emit a single JSON object to stdout (no trailing newline — waybar reads
# the whole stdout, newline-agnostic). Tooltip is optional; omitted if empty.
#
# CRITICAL: the class field is emitted as a JSON ARRAY of strings, never a
# space-separated string. waybar/GTK 3 reliably splits arrays into individual
# style classes; the space-separated string form is interpreted as a single
# class by some waybar versions, which silently breaks every .class selector.
# (Bit us on 2026-05-28 during the OPTIONS foundation refactor.)
pill_emit() {
    local text classes_str classes_json tooltip first c theme
    text="$(pill_json_escape "${1:-}")"
    classes_str="${2:-}"
    tooltip="${3:-}"
    # Re-read the theme right before emit. Callers often cache `m=$(pill_theme)`
    # once at the top of a loop and reuse it for many pill_write calls per
    # iteration. If glass-text-daemon flips /tmp/glass-mode mid-iteration, the
    # cached value would land in the cache file and stay until the next tick.
    # Substituting here collapses that race to microseconds.
    theme="$(pill_theme)"
    local theme_emitted=0
    classes_json="["
    first=1
    for c in $classes_str; do
        [ -n "$c" ] || continue
        case "$c" in
            dark|light)
                # Emit at most one theme token even if caller passed several
                # (the static `pill` wrapper auto-injects pill_theme then
                # appends caller args, so `pill 'x' dark` would otherwise
                # produce two theme classes).
                [ "$theme_emitted" = 1 ] && continue
                c="$theme"
                theme_emitted=1
                ;;
        esac
        if [ $first -eq 1 ]; then first=0; else classes_json="$classes_json,"; fi
        classes_json="$classes_json\"$(pill_json_escape "$c")\""
    done
    classes_json="$classes_json]"
    if [ -n "$tooltip" ]; then
        tooltip="$(pill_json_escape "$tooltip")"
        printf '{"text":"%s","class":%s,"tooltip":"%s"}' \
            "$text" "$classes_json" "$tooltip"
    else
        printf '{"text":"%s","class":%s}' "$text" "$classes_json"
    fi
}

# Atomically write a cache file. Dedup against previous content; only signal
# waybar if the content actually changed. This is the rule that keeps CPU
# down — the mpris CPU regression of 2026-05-27 was caused by signaling on
# every tick whether the content changed or not.
pill_write() {
    local name="$1"; shift
    mkdir -p "$PILL_CACHE_DIR"
    local cache="$PILL_CACHE_DIR/$name"
    local text="${1:-}"
    local classes_str="${2:-}"
    local content prev=""
    content="$(pill_emit "$@")"
    [ -r "$cache" ] && prev="$(cat "$cache" 2>/dev/null)"

    # Geometry registry: width=0 when the pill is .empty (collapsed,
    # no visual footprint), otherwise estimated from text length.
    # Emitted EVERY call (not gated by content dedup) so that a width
    # change in another sibling can trigger this pill's geom refresh
    # via the natural waybar tick cadence. pill_emit_geom is internally
    # dedup'd so unchanged widths don't churn disk.
    local geom_w=0
    case " $classes_str " in
        *" empty "*) geom_w=0 ;;
        *)           geom_w=$(pill_estimate_width "$text") ;;
    esac
    pill_emit_geom "$name" "$geom_w"

    [ "$content" = "$prev" ] && return 0
    printf '%s' "$content" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
    pkill -RTMIN+10 waybar 2>/dev/null || true
}
