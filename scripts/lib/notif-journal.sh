# notif-journal.sh — persistent notification journal helpers.
#
# Append-only JSON-Lines log at ~/.local/share/standard-os/notif-history.jsonl
# (or any path passed as $1). Ring-bounded via journal_prune. Read newest-first
# via journal_read. mark_dismissed updates the most recent entry with the
# given id to set dismissed_at.
#
# All functions are pure (no global state, no implicit paths) so they're
# trivially testable. The daemon owns the canonical path and passes it in.

# json_escape — reuse the daemon's helper.
# When sourced standalone, define locally to avoid runtime coupling.
if ! declare -F json_escape >/dev/null; then
    json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }
fi

# json_escape_into VAR STRING — same as json_escape but writes the result
# to VAR via printf -v, avoiding the command-substitution fork that the
# hot-path journal_append previously paid 3-4× per arrival.
json_escape_into() {
    local __var="$1" s="$2"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf -v "$__var" '%s' "$s"
}

# journal_append PATH TS ID APP SUMMARY BODY URGENCY
# Atomically appends one JSON line. Creates the file if missing.
journal_append() {
    local path="$1" id="$3" urgency="$7"
    local ts app summary body
    json_escape_into ts "$2"
    json_escape_into app "$4"
    json_escape_into summary "$5"
    json_escape_into body "$6"
    local line
    line=$(printf '{"ts":"%s","id":%s,"app":"%s","summary":"%s","body":"%s","urgency":%s,"dismissed_at":""}\n' \
        "$ts" "$id" "$app" "$summary" "$body" "$urgency")
    mkdir -p "$(dirname "$path")"
    # Append is atomic per line for files opened O_APPEND on local fs; we still
    # use a serialized write (single >>) rather than multiple sub-writes.
    printf '%s\n' "$line" >> "$path"
}

# journal_mark_dismissed PATH ID TS
# Updates the most recent entry whose id matches and whose dismissed_at is empty,
# setting dismissed_at to the given timestamp. No-op if no match.
journal_mark_dismissed() {
    local path="$1" id="$2" ts="$3"
    [[ -f $path && -s $path ]] || return 0
    local tmp="${path}.tmp.$$"
    # Walk lines bottom-up; first matching unset becomes the dismissed one;
    # all other lines pass through. Implemented with jq -nR for streaming.
    # We can't use a single jq pass top-down because we want LATEST-matching.
    # Strategy: read all lines into a jq array, walk indexes in reverse,
    # mark the first match, emit lines in original order.
    if jq -c -nR --argjson id "$id" --arg ts "$ts" '
        [inputs | fromjson? // empty] as $arr
        | ([range(($arr | length) - 1; -1; -1) | . as $i
             | if $arr[$i].id == $id and $arr[$i].dismissed_at == ""
                 then $i
                 else empty
               end] | first) as $mark
        | $arr
        | to_entries
        | map(if .key == $mark then .value + {dismissed_at: $ts} else .value end)
        | .[]
    ' < "$path" > "$tmp" 2>/dev/null && [[ -s $tmp ]]; then
        mv -f "$tmp" "$path"
    else
        rm -f "$tmp" 2>/dev/null
    fi
}

# journal_prune PATH MAX_LINES
# Trims the journal to keep only the last MAX_LINES lines (newest).
journal_prune() {
    local path="$1" max="$2"
    (( max < 1 )) && return 0
    [[ -f $path ]] || return 0
    local lines
    lines=$(wc -l < "$path")
    (( lines <= max )) && return 0
    local tmp="${path}.tmp.$$"
    tail -n "$max" "$path" > "$tmp"
    mv -f "$tmp" "$path"
}

# journal_read PATH N
# Prints the last N entries, newest first (one JSON per line).
# Empty / missing file → no output.
journal_read() {
    local path="$1" n="$2"
    [[ -f $path && -s $path ]] || return 0
    tail -n "$n" "$path" | tac
}

# journal_remove PATH ID TS
# Removes the single journal line whose id matches AND ts matches exactly.
# (Two args used together because mako recycles numeric ids over time, so
# id alone isn't a unique key across the journal's lifetime.)
# Clean no-op when the file is missing, empty, or has no matching line.
journal_remove() {
    local path="$1" id="$2" ts="$3"
    [[ -f $path && -s $path ]] || return 0
    local tmp="${path}.tmp.$$"
    if jq -c --argjson id "$id" --arg ts "$ts" '
        select(.id != $id or .ts != $ts)
    ' < "$path" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path"
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
