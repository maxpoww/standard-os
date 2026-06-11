# notif-profile-format.sh — pure formatters for the profile rofi picker.

# format_profile_header DISPLAY_NAME UNTIL_HHMM
# Prints "── Active: <name> — until <HH:MM> ──" or "── Active: <name> ──"
format_profile_header() {
    local display="$1" until_hhmm="${2:-}"
    if [[ -n $until_hhmm ]]; then
        printf '── Active: %s — until %s ──' "$display" "$until_hhmm"
    else
        printf '── Active: %s ──' "$display"
    fi
}

# format_profile_row PROFILE DISPLAY MARKER IS_ACTIVE [SCHEDULE]
# One rofi row. "✓ Work" / "  Sleep — 22:00-08:00 *".
# Leading "✓ " for active row; non-active rows pad with two spaces for column
# alignment. SCHEDULE optional; when present, appended as " — <schedule>".
format_profile_row() {
    local profile="$1" display="$2" marker="$3" is_active="$4" schedule="${5:-}"
    local prefix
    if (( is_active )); then
        prefix='✓ '
    else
        prefix='  '
    fi
    if [[ -n $schedule ]]; then
        printf '%s%s — %s' "$prefix" "$display" "$schedule"
    else
        printf '%s%s' "$prefix" "$display"
    fi
}
