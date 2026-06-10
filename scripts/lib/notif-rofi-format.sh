# notif-rofi-format.sh — pure formatters for rofi rows.
#
# Output is plain-text for `rofi -dmenu` (no markup). The launcher script
# (home/scripts/notif-rofi) wires this lib up to mako + the journal lib.

# format_rofi_header LABEL
# Section header row, prefixed with a horizontal-bar character so it's
# visually distinct without markup. The launcher treats any line starting
# with '── ' as a no-op when the user selects it.
format_rofi_header() {
    local label="$1"
    printf '── %s ──' "$label"
}

# format_rofi_entry TS APP SUMMARY URGENCY UNREAD CRITICAL
# Args:
#   TS        — ISO 8601 timestamp (HH:MM extracted)
#   APP       — app name
#   SUMMARY   — notification summary
#   URGENCY   — 0 | 1 | 2
#   UNREAD    — 0 | 1 (is this entry still in mako's live list?)
#   CRITICAL  — 0 | 1 (urgency == 2 AND unread)
format_rofi_entry() {
    local ts="$1" app="$2" summary="$3" urgency="$4" unread="$5" critical="$6"
    local hhmm="${ts:11:5}"
    local tags=""
    if (( unread )); then
        tags+=" · unread"
        (( critical )) && tags+=" · critical"
    fi
    printf '%s  %s · %s%s' "$hhmm" "$app" "$summary" "$tags"
}
