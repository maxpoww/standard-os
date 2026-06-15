# notif-hypr.sh — Hyprland adapter for notif-menu.
#
# All hyprctl calls in the menu codebase go through here so tests can
# mock by overriding `hyprctl` as a bash function before sourcing.

# hypr_focus_by_class CLASS [SUMMARY] [BODY] [SOURCE_WINDOW]
# Lowercases CLASS, finds Hyprland windows whose class (lowercased) contains
# it as a substring, then disambiguates among multiple matches with this
# precedence (highest priority first):
#
#   1. Highest descendant-cmdline word-match score against SUMMARY+BODY
#      (lowercase, length > 3, alphanumeric). Catches "Claude is in one
#      of three kittys" via the `claude` word in the subtree cmdlines.
#   2. If still tied AND SOURCE_WINDOW matches a tied candidate's address,
#      pick that. Catches "you ran notify-send from THIS kitty" — the
#      notif-daemon captures hyprctl activewindow at arrival.
#   3. focusHistoryID (lower = more recently focused).
#
# On hit dispatches `focuswindow address:<addr>` (Hyprland switches
# workspace automatically). Returns 0 on hit, 1 on miss / hyprctl error /
# malformed JSON. Stderr from all hyprctl calls is suppressed.
hypr_focus_by_class() {
    local needle="${1,,}"
    local summary="${2:-}"
    local body="${3:-}"
    local source_window="${4:-}"

    declare -F _dbg >/dev/null && _dbg "hypr_focus_by_class needle='$needle' src='$source_window'"

    # Get all matching clients as tab-separated address\tpid\tfocusHistoryID
    local clients
    clients=$(hyprctl -j clients 2>/dev/null \
        | jq -r --arg n "$needle" '
            .[]? | select((.class // "" | ascii_downcase) | contains($n))
                 | "\(.address // "")\t\(.pid // 0)\t\(.focusHistoryID // 0)"' \
            2>/dev/null \
        | grep -v $'^\t')

    if [[ -z $clients ]]; then
        declare -F _dbg >/dev/null && _dbg "hypr_focus_by_class: no clients matching '$needle' → return 1"
        return 1
    fi

    local n_clients
    n_clients=$(printf '%s\n' "$clients" | grep -c '^')
    declare -F _dbg >/dev/null && _dbg "hypr_focus_by_class: $n_clients candidate(s)"

    # Single match — focus it, done.
    if (( n_clients == 1 )); then
        local addr rc
        addr=$(printf '%s' "$clients" | head -1 | cut -f1)
        hyprctl dispatch focuswindow "address:$addr" 2>/dev/null
        rc=$?
        declare -F _dbg >/dev/null && _dbg "hypr_focus_by_class: single-match dispatch addr=$addr rc=$rc"
        return 0
    fi

    # Multi-match — score by descendant cmdline word matches.
    # Extract distinguishing words (>3 chars, lowercase, alphanumeric).
    local words
    words=$(printf '%s %s' "$summary" "$body" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '\n' \
        | awk 'length > 3' \
        | sort -u)

    # Two-pass: first compute scores per candidate, then resolve ties with
    # source_window before falling back to focusHistoryID.
    local scored=""   # lines of "addr\tscore\tfhid"
    local addr pid fhid tree score word
    while IFS=$'\t' read -r addr pid fhid; do
        [[ -z $addr ]] && continue
        tree=$(_pid_subtree_cmdlines "$pid" | tr '[:upper:]' '[:lower:]')
        score=0
        if [[ -n $words ]]; then
            while IFS= read -r word; do
                [[ -z $word ]] && continue
                if [[ "$tree" == *"$word"* ]]; then
                    score=$((score+1))
                fi
            done <<<"$words"
        fi
        scored+="$addr"$'\t'"$score"$'\t'"$fhid"$'\n'
    done <<<"$clients"

    # Find max score.
    local max_score
    max_score=$(printf '%s' "$scored" | awk -F'\t' 'NF==3 { if ($2 > m) m = $2 } END { print m+0 }')

    # Filter to candidates at max score.
    local at_max
    at_max=$(printf '%s' "$scored" | awk -F'\t' -v m="$max_score" 'NF==3 && $2 == m')

    local best_addr=""
    # Tier 2: source_window match among tied candidates.
    if [[ -n $source_window ]]; then
        if grep -qF $'\t' <<<"$source_window"; then : ; fi   # noop, defensive
        best_addr=$(awk -F'\t' -v sw="$source_window" '$1 == sw { print $1; exit }' <<<"$at_max")
    fi

    # Tier 3: lowest focusHistoryID among tied candidates.
    if [[ -z $best_addr ]]; then
        best_addr=$(printf '%s' "$at_max" | sort -t$'\t' -k3,3n | head -1 | cut -f1)
    fi

    if [[ -z $best_addr ]]; then
        declare -F _dbg >/dev/null && _dbg "hypr_focus_by_class: multi-match but no winner → return 1"
        return 1
    fi
    hyprctl dispatch focuswindow "address:$best_addr" 2>/dev/null
    local rc=$?
    declare -F _dbg >/dev/null && _dbg "hypr_focus_by_class: multi-match dispatch addr=$best_addr rc=$rc"
    return 0
}

# _pid_subtree_cmdlines PID
# Prints the cmdline of every descendant process of PID, one per line.
# Used by hypr_focus_by_class for multi-match scoring. Tests can override
# this function with a canned-output mock.
_pid_subtree_cmdlines() {
    local pid="$1" children child
    children=$(pgrep -P "$pid" 2>/dev/null)
    for child in $children; do
        ps -o args= -p "$child" 2>/dev/null
        _pid_subtree_cmdlines "$child"
    done
}
