#!/usr/bin/env bash
# ==============================================================================
# screen-type.sh — Waybar Screen Type profile switcher
# ==============================================================================
# Subcommands:
#   get        → print active type label
#   get-icon   → print active type Nerd Font icon
#   set <id>   → activate a type by ID
#   next       → cycle forward, activate next type
#   prev       → cycle backward, activate previous type
#   restore    → re-apply saved state (use in Hyprland exec-once)
#   status     → print Waybar JSON {"text","tooltip","class"}
#
# State file: ~/.local/share/screen-type/current  (stores type ID, plain text)
# Default on first run: "full"
#
# Dependencies (must be in PATH; install via NixOS):
#   brightnessctl, hyprsunset, hyprctl
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------
STATE_DIR="${HOME}/.local/share/screen-type"
STATE_FILE="${STATE_DIR}/current"
SHADER_DIR="${HOME}/.config/hypr/shaders"
WAYBAR_SIGNAL="RTMIN+8"   # signal number used to refresh the Waybar anchor

# ------------------------------------------------------------------------------
# Type registry
#
# Each type is defined as a set of parallel arrays indexed by TYPES order.
# Fields: id, label, description, icon, brightness, temperature, shader
#
# EYE PROTECTION RATIONALE:
#   Brightness 60% → targets ~200 cd/m² output on a typical 330 cd/m² panel,
#   matching the evidence-based recommendation from Sheedy et al. (2003) and
#   subsequent AAO guidance: ambient luminance ≈ screen luminance minimises
#   accommodative fatigue and asthenopia.
#
#   Temperature 5000 K → the ISO 3664 D50 viewing standard, which filters a
#   significant portion of short-wave blue light (< 455 nm) compared to 6500 K
#   while avoiding the excessive amber shift of 4000 K that distorts colour
#   perception of blue and green UI elements. Studies by Chang et al. (2015)
#   and Harvard Medical School blue-light guidance support 5000 K as the
#   optimal daytime reading temperature for reduced eye strain.
#
#   No shader → avoids double-processing; the hardware colour temperature
#   pipeline already handles blue reduction cleanly.
# ------------------------------------------------------------------------------

# Ordered list of type IDs (determines cycling order)
TYPES=(
    "full"
    "eye"
    "cinema"
    "gaming"
    "dark-real"
    "dark-warm"
    "amber-retro"
    "paper"
    "newspaper"
)

# ---- Labels ------------------------------------------------------------------
declare -A LABEL
LABEL["full"]="Full"
LABEL["eye"]="Eye Protection"
LABEL["cinema"]="Cinema"
LABEL["gaming"]="Gaming"
LABEL["dark-real"]="Dark Real Colors"
LABEL["dark-warm"]="Dark Warm"
LABEL["amber-retro"]="Dark Amber Retro"
LABEL["paper"]="Paper"
LABEL["newspaper"]="Newspaper"

# ---- Descriptions ------------------------------------------------------------
declare -A DESC
DESC["full"]="Maximum brightness and neutral color. Hardware at its best."
DESC["eye"]="Scientifically optimal settings for long-term eye health during extended screen use."
DESC["cinema"]="Warm, dim display. Comfortable for watching video in a dark room."
DESC["gaming"]="Full brightness and neutral color. Maximum clarity, nothing in the way."
DESC["dark-real"]="Minimum brightness, neutral color. Night use without color distortion."
DESC["dark-warm"]="Minimum brightness, very warm color. Circadian-friendly night mode."
DESC["amber-retro"]="Phosphor CRT amber tint. Stylistic and night-safe."
DESC["paper"]="Cream-warm tint with grain. Makes reading feel like a physical page."
DESC["newspaper"]="Greyscale with halftone grain and aged-white tint. Printed newspaper feel."

# ---- Nerd Font icons ---------------------------------------------------------
declare -A ICON
ICON["full"]="󰃞"
ICON["eye"]="󱄴"
ICON["cinema"]="󰯜"
ICON["gaming"]="󰊴"
ICON["dark-real"]="󰃟"
ICON["dark-warm"]="󰃠"
ICON["amber-retro"]="󱠓"
ICON["paper"]="󱉟"
ICON["newspaper"]="󰦩"

# ---- Brightness (percent passed to brightnessctl) ----------------------------
declare -A BRIGHTNESS
BRIGHTNESS["full"]="100%"
BRIGHTNESS["eye"]="60%"
BRIGHTNESS["cinema"]="70%"
BRIGHTNESS["gaming"]="100%"
BRIGHTNESS["dark-real"]="8%"
BRIGHTNESS["dark-warm"]="8%"
BRIGHTNESS["amber-retro"]="12%"
BRIGHTNESS["paper"]="60%"
BRIGHTNESS["newspaper"]="70%"

# ---- Color temperature (Kelvin, passed to hyprsunset -t K) ------------------
declare -A TEMPERATURE
TEMPERATURE["full"]="6500"
TEMPERATURE["eye"]="5000"
TEMPERATURE["cinema"]="4500"
TEMPERATURE["gaming"]="6500"
TEMPERATURE["dark-real"]="6500"
TEMPERATURE["dark-warm"]="2700"
TEMPERATURE["amber-retro"]="2200"
TEMPERATURE["paper"]="4000"
TEMPERATURE["newspaper"]="5500"

# ---- GLSL shaders (basename under SHADER_DIR, or "" for none) ---------------
declare -A SHADER
SHADER["full"]=""
SHADER["eye"]=""
SHADER["cinema"]=""
SHADER["gaming"]=""
SHADER["dark-real"]=""
SHADER["dark-warm"]=""
SHADER["amber-retro"]="amber-retro.glsl"
SHADER["paper"]="paper.glsl"
SHADER["newspaper"]="newspaper.glsl"

# ==============================================================================
# Helpers
# ==============================================================================

# Read the currently active type ID from state file (default: "full")
_read_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        local id
        id="$(cat "${STATE_FILE}")"
        # Validate: must be a known type
        for t in "${TYPES[@]}"; do
            if [[ "${t}" == "${id}" ]]; then
                echo "${id}"
                return
            fi
        done
    fi
    echo "full"
}

# Write a type ID to the state file (creates directory if needed)
_write_state() {
    local id="$1"
    mkdir -p "${STATE_DIR}"
    printf '%s' "${id}" > "${STATE_FILE}"
}

# Return the index of a type ID in the TYPES array
_type_index() {
    local id="$1"
    local i
    for i in "${!TYPES[@]}"; do
        if [[ "${TYPES[$i]}" == "${id}" ]]; then
            echo "${i}"
            return 0
        fi
    done
    echo "0"  # fallback to first
}

# Apply all settings for a given type ID.
# Second arg: "no-shader" to skip the shader step (used by restore on boot,
# so paper/newspaper/amber-retro never auto-load — user can opt in each session).
_apply_type() {
    local id="$1"
    local mode="${2:-all}"

    # --- Brightness ---
    local br="${BRIGHTNESS[$id]}"
    brightnessctl set "${br}" --quiet || true

    # --- Color temperature ---
    local temp="${TEMPERATURE[$id]}"
    # Kill any running hyprsunset instance before starting a new one
    pkill -x hyprsunset 2>/dev/null || true
    sleep 0.1
    # Launch hyprsunset in background (it daemonises itself)
    hyprsunset -t "${temp}" &
    disown $! 2>/dev/null || true

    # --- GLSL Shader ---
    if [[ "${mode}" == "no-shader" ]]; then
        # Always clear, regardless of profile, so prior session's shader
        # doesn't survive a reboot in any case.
        hyprctl keyword decoration:screen_shader "" > /dev/null 2>&1 || true
        return
    fi
    local shader_file="${SHADER[$id]}"
    if [[ -n "${shader_file}" ]]; then
        local shader_path="${SHADER_DIR}/${shader_file}"
        hyprctl keyword decoration:screen_shader "${shader_path}" > /dev/null 2>&1 || true
    else
        # Disable shader by passing empty string
        hyprctl keyword decoration:screen_shader "" > /dev/null 2>&1 || true
    fi
}

# ==============================================================================
# Subcommands
# ==============================================================================

cmd_get() {
    local id
    id="$(_read_state)"
    echo "${LABEL[$id]}"
}

cmd_get_icon() {
    local id
    id="$(_read_state)"
    echo "${ICON[$id]}"
}

cmd_set() {
    local id="$1"
    # Validate ID
    local valid=false
    for t in "${TYPES[@]}"; do
        if [[ "${t}" == "${id}" ]]; then
            valid=true
            break
        fi
    done
    if [[ "${valid}" == false ]]; then
        echo "screen-type: unknown type '${id}'" >&2
        exit 1
    fi

    _apply_type "${id}"
    _write_state "${id}"

    # Signal Waybar to refresh the anchor module
    pkill -"${WAYBAR_SIGNAL}" waybar 2>/dev/null || true
}

cmd_next() {
    local current
    current="$(_read_state)"
    local idx
    idx="$(_type_index "${current}")"
    local count="${#TYPES[@]}"
    local next_idx=$(( (idx + 1) % count ))
    cmd_set "${TYPES[$next_idx]}"
}

cmd_prev() {
    local current
    current="$(_read_state)"
    local idx
    idx="$(_type_index "${current}")"
    local count="${#TYPES[@]}"
    local prev_idx=$(( (idx - 1 + count) % count ))
    cmd_set "${TYPES[$prev_idx]}"
}

cmd_restore() {
    local id
    id="$(_read_state)"
    # Boot path: restore brightness+temperature but never auto-apply the
    # shader. User opts back into paper/newspaper/amber-retro per session.
    _apply_type "${id}" "no-shader"
    # No need to write state (already saved); no need to signal Waybar yet
    # (Waybar may not be running when restore is called from exec-once)
}

cmd_status() {
    local id
    id="$(_read_state)"
    local icon="${ICON[$id]}"
    local label="${LABEL[$id]}"
    local desc="${DESC[$id]}"
    # Escape quotes for JSON safety
    label="${label//\"/\\\"}"
    desc="${desc//\"/\\\"}"
    printf '{"text":"%s","tooltip":"%s: %s","class":"%s"}\n' \
        "${icon}" "${label}" "${desc}" "${id}"
}

# ==============================================================================
# Dispatch
# ==============================================================================

CMD="${1:-}"
shift || true

case "${CMD}" in
    get)        cmd_get ;;
    get-icon)   cmd_get_icon ;;
    set)
        if [[ -z "${1:-}" ]]; then
            echo "Usage: screen-type.sh set <type_id>" >&2
            exit 1
        fi
        cmd_set "$1"
        ;;
    next)       cmd_next ;;
    prev)       cmd_prev ;;
    restore)    cmd_restore ;;
    status)     cmd_status ;;
    *)
        echo "Usage: screen-type.sh <get|get-icon|set <id>|next|prev|restore|status>" >&2
        exit 1
        ;;
esac
