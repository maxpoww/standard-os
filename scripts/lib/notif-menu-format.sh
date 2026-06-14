# notif-menu-format.sh — pure row formatters for notif-menu.
#
# Output is plain text (no Pango, no NUL/icon metadata). The entry script
# (notif-menu) wires these formatters to the journal + mako adapter.

# fmt_l1_header LABEL
# Non-selectable section row. The entry script treats any row starting with
# '── ' as a no-op when picked.
fmt_l1_header() {
    printf '── %s ──' "$1"
}

# fmt_l1_row TS APP SUMMARY UNREAD CRITICAL
# Args:
#   TS        ISO 8601 timestamp; HH:MM extracted from chars 11-15
#   APP       app name
#   SUMMARY   notification summary; if empty, the " · " separator is suppressed
#   UNREAD    0 | 1
#   CRITICAL  0 | 1 (only meaningful when UNREAD=1)
fmt_l1_row() {
    local ts="$1" app="$2" summary="$3" unread="$4" critical="$5"
    local hhmm="${ts:11:5}"
    local body
    if [[ -n $summary ]]; then
        body="${app} · ${summary}"
    else
        body="${app}"
    fi
    local tags=""
    if (( unread )); then
        tags=" · unread"
        (( critical )) && tags+=" · critical"
    fi
    printf '%s  %s%s' "$hhmm" "$body" "$tags"
}

# fmt_l2_separator — visual divider between app actions and generic actions.
fmt_l2_separator() {
    printf '── ──'
}

# fmt_l2_back — bottom-of-L2 row that returns to L1 (the entry script
# treats this literal as a re-exec).
fmt_l2_back() {
    printf '← Back'
}
