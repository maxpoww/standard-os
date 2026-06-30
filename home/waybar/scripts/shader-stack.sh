#!/usr/bin/env bash
# shader-stack.sh — sole writer of Hyprland's decoration:screen_shader.
#
# Composes multiple GLSL effects into a single shader so the global
# screen_shader slot can hold more than one effect at a time (e.g. paper
# texture + night dim simultaneously). Other scripts push/pop their slot
# via `set`/`clear` instead of calling `hyprctl keyword decoration:screen_shader`
# directly, which was the source of stomping (paper toggle vs night-dimmer).
#
# Usage:
#   shader-stack.sh set <slot> <effect> [arg]     # set/replace a slot
#   shader-stack.sh clear <slot>                  # remove a slot
#   shader-stack.sh apply                         # recompose and apply
#   shader-stack.sh debug                         # print current state
#
# Slots (composed in this order — texture before dim, so dim modulates
# whatever the texture effect produced):
#   texture   value: paper | newspaper
#   dim       value: <float in (0,1]>     e.g. 0.5, 0.25, 0.1
#
# State files (manager-private):
#   /tmp/shader-stack/texture       contains "<effect>"   when set, absent otherwise
#   /tmp/shader-stack/dim           contains "<k>"        when set, absent otherwise
#   /tmp/shader-stack/composed.glsl generated shader (also content-hashed copies)

set -euo pipefail

STATE_DIR="/tmp/shader-stack"
EFFECTS_DIR="${HOME}/.config/hypr/shaders/effects"
mkdir -p "$STATE_DIR"

# --- helpers ----------------------------------------------------------------

die() { printf 'shader-stack: %s\n' "$*" >&2; exit 1; }

validate_slot() {
    case "$1" in
        texture|dim) ;;
        *) die "unknown slot: $1 (allowed: texture, dim)" ;;
    esac
}

# Strict per-slot value validation. Anything that would inject raw text into
# the generated GLSL must be checked here — defense in depth, because the
# only callers today are the waybar/brightness scripts.
validate_value() {
    local slot="$1" val="$2"
    case "$slot" in
        texture)
            [[ "$val" == "paper" || "$val" == "newspaper" ]] \
                || die "texture slot rejects value: $val (allowed: paper, newspaper)"
            [[ -r "$EFFECTS_DIR/$val.glsl" ]] \
                || die "missing effect file: $EFFECTS_DIR/$val.glsl"
            ;;
        dim)
            # Accept e.g. 0.5 / .25 / 1.0 — strict numeric, no expressions.
            [[ "$val" =~ ^(0|0?\.[0-9]+|1\.0+|1)$ ]] \
                || die "dim slot rejects value: $val (need float in [0,1])"
            [[ -r "$EFFECTS_DIR/dim.glsl" ]] \
                || die "missing effect file: $EFFECTS_DIR/dim.glsl"
            ;;
    esac
}

# --- composition ------------------------------------------------------------

# Read the active value for a slot ("" if absent).
slot_value() {
    cat "$STATE_DIR/$1" 2>/dev/null || true
}

# Write the composed shader to stdout. No effects → emit nothing (caller
# detects empty and clears Hyprland's slot instead of feeding it an empty file).
compose() {
    local texture dim
    texture=$(slot_value texture)
    dim=$(slot_value dim)

    [[ -z "$texture" && -z "$dim" ]] && return 0

    # Header
    cat <<'EOF'
#version 300 es
precision mediump float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

EOF

    # Effect function definitions (only the ones we'll call)
    if [[ -n "$texture" ]]; then
        cat "$EFFECTS_DIR/$texture.glsl"
        printf '\n'
    fi
    if [[ -n "$dim" ]]; then
        cat "$EFFECTS_DIR/dim.glsl"
        printf '\n'
    fi

    # main() — call effects in fixed order (texture → dim)
    printf 'void main() {\n'
    printf '    vec4 c = texture(tex, v_texcoord);\n'
    if [[ -n "$texture" ]]; then
        printf '    c = effect_%s(c, v_texcoord);\n' "$texture"
    fi
    if [[ -n "$dim" ]]; then
        printf '    c = effect_dim(c, %s);\n' "$dim"
    fi
    printf '    fragColor = c;\n'
    printf '}\n'
}

# Hyprland's screen_shader is applied per-layer with damage tracking on,
# which leaves ghost trails behind moving cursors and closing layers (rofi,
# notifications). Disabling damage_tracking forces a full-screen redraw every
# frame so the shader output is always fresh. Cost: higher GPU/power use,
# paid only while a shader is active.
# Refs:
#   https://github.com/hyprwm/Hyprland/issues/8561  (closed as not planned)
#   https://github.com/hyprwm/Hyprland/pull/1700    (notes damage_tracking=0 is required)
DAMAGE_TRACKING_DEFAULT=2   # Hyprland default; restored when no shader is active

set_damage_tracking() {
    local val="$1" cur
    cur=$(hyprctl -j getoption debug:damage_tracking 2>/dev/null \
        | grep -oE '"int": *-?[0-9]+' | head -1 | grep -oE '\-?[0-9]+$')
    [[ "$cur" == "$val" ]] && return 0
    hyprctl keyword debug:damage_tracking "$val" >/dev/null 2>&1 || true
}

# Apply current stack: regenerate composed.glsl, hand the path to Hyprland.
# If nothing is active, clear the slot (empty string) and restore damage tracking.
apply() {
    local tmp content_hash target prev
    tmp=$(mktemp "$STATE_DIR/composed.XXXXXX.glsl")
    compose >"$tmp"

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        hyprctl keyword decoration:screen_shader "" >/dev/null 2>&1 || true
        # Restore full damage tracking now that no shader needs forced redraws.
        set_damage_tracking "$DAMAGE_TRACKING_DEFAULT"
        # Remove any leftover composed-*.glsl so the directory stays clean.
        find "$STATE_DIR" -maxdepth 1 -name 'composed-*.glsl' -delete 2>/dev/null || true
        return 0
    fi

    # Content-addressed name so Hyprland sees a fresh path iff the content
    # changed — and so we never overwrite a file Hyprland is mid-read on.
    content_hash=$(sha1sum "$tmp" | awk '{print $1}' | head -c 12)
    target="$STATE_DIR/composed-${content_hash}.glsl"

    if [[ ! -e "$target" ]]; then
        mv -f "$tmp" "$target"
    else
        rm -f "$tmp"
    fi

    # Disable damage tracking BEFORE swapping the shader so the very first
    # frame using the new shader is a full redraw (avoids inheriting stale
    # damaged regions from the previous shader state).
    set_damage_tracking 0

    prev=$(hyprctl -j getoption decoration:screen_shader 2>/dev/null \
        | grep -o '"str": *"[^"]*"' | head -1 | sed 's/.*"str": *"\(.*\)".*/\1/')
    if [[ "$prev" != "$target" ]]; then
        hyprctl keyword decoration:screen_shader "$target" >/dev/null 2>&1 || true
    fi

    # GC old composed files (keep current target).
    find "$STATE_DIR" -maxdepth 1 -name 'composed-*.glsl' ! -path "$target" -delete 2>/dev/null || true
}

# --- commands ---------------------------------------------------------------

case "${1:-}" in
    set)
        slot="${2:?missing slot}"
        value="${3:?missing value}"
        validate_slot "$slot"
        validate_value "$slot" "$value"
        printf '%s' "$value" >"$STATE_DIR/$slot.tmp"
        mv -f "$STATE_DIR/$slot.tmp" "$STATE_DIR/$slot"
        apply
        ;;
    clear)
        slot="${2:?missing slot}"
        validate_slot "$slot"
        rm -f "$STATE_DIR/$slot"
        apply
        ;;
    apply)
        apply
        ;;
    debug)
        printf 'texture=%s\n' "$(slot_value texture)"
        printf 'dim=%s\n'     "$(slot_value dim)"
        printf '%s\n' '--- composed ---'
        compose
        ;;
    ''|help|-h|--help)
        sed -n '2,30p' "$0"
        ;;
    *)
        die "unknown command: $1 (try: set | clear | apply | debug | help)"
        ;;
esac
