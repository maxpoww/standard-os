# notif-hypr.sh — Hyprland adapter for notif-menu.
#
# All hyprctl calls in the menu codebase go through here so tests can
# mock by overriding `hyprctl` as a bash function before sourcing.

# hypr_focus_by_class CLASS [SUMMARY] [BODY]
# Lowercases CLASS, finds Hyprland windows whose class (lowercased) contains
# it as a substring, then disambiguates among multiple matches by scoring
# each candidate's descendant-process cmdlines against the notif's
# SUMMARY+BODY words (lowercase, length > 3, alphanumeric). Highest score
# wins; ties broken by focusHistoryID (lower = more recently focused). On
# hit, dispatches `focuswindow address:<addr>` (Hyprland switches workspace
# automatically). Returns 0 on hit, 1 on miss / hyprctl error / malformed
# JSON. Stderr from all hyprctl calls is suppressed.
#
# The descendant-cmdline scoring is what makes "Claude in one of three
# kitty windows" focus the right kitty: only one kitty has `claude` in its
# subtree, so the "claude" word from the notif summary scores 1 there and
# 0 elsewhere.
hypr_focus_by_class() {
    local needle="${1,,}"
    local summary="${2:-}"
    local body="${3:-}"

    # Get all matching clients as tab-separated address\tpid\tfocusHistoryID
    local clients
    clients=$(hyprctl -j clients 2>/dev/null \
        | jq -r --arg n "$needle" '
            .[]? | select((.class // "" | ascii_downcase) | contains($n))
                 | "\(.address // "")\t\(.pid // 0)\t\(.focusHistoryID // 0)"' \
            2>/dev/null \
        | grep -v $'^\t')

    [[ -z $clients ]] && return 1

    local n_clients
    n_clients=$(printf '%s\n' "$clients" | grep -c '^')

    # Single match — focus it, done.
    if (( n_clients == 1 )); then
        local addr
        addr=$(printf '%s' "$clients" | head -1 | cut -f1)
        hyprctl dispatch focuswindow "address:$addr" 2>/dev/null
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

    local best_addr=""
    local best_score=-1
    local best_focus_hid=999999
    local addr pid fhid tree score word
    while IFS=$'\t' read -r addr pid fhid; do
        [[ -z $addr ]] && continue
        # Collect all descendant cmdlines, lowercased.
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
        # Better if higher score, OR same score AND smaller focusHistoryID.
        if (( score > best_score )) || (( score == best_score && fhid < best_focus_hid )); then
            best_addr="$addr"
            best_score=$score
            best_focus_hid=$fhid
        fi
    done <<<"$clients"

    [[ -z $best_addr ]] && return 1
    hyprctl dispatch focuswindow "address:$best_addr" 2>/dev/null
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
