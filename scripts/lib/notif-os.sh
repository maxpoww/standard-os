# notif-os.sh — adapter for notif-os-daemon (Standard-OS native notif daemon).
#
# All notification access in the menu codebase routes through here so
# tests can mock busctl as a bash function before sourcing.
#
# Function names keep the `mako_` prefix for now to avoid touching every
# call site — they actually talk to org.standardos.NotifOS, not mako.
# A future cleanup pass should rename them to `notif_*`.

# All ListNotifications calls go through this helper so the parse is
# centralized. Output is the raw JSON string the daemon returns; "[]" when
# empty. busctl wraps the string in s "...", so we strip the leading `s "`
# and the trailing `"` and unescape inner quotes.
_notif_list_raw() {
    busctl --user --json=short call \
        org.standardos.NotifOS /org/standardos/NotifOS \
        org.standardos.NotifOS ListNotifications 2>/dev/null \
        | jq -r '.data[0]? // "[]"' 2>/dev/null
}

# mako_list_live — prints `id\turgency` per current notification, one per
# line. Empty output when nothing's stored or the daemon is unreachable.
mako_list_live() {
    _notif_list_raw \
        | jq -r '.[] | "\(.id)\t\(.urgency)"' 2>/dev/null
}

# mako_list_actions ID — prints `key\tlabel` per action declared by that
# notif. The entry whose key is the literal string "default" is hoisted
# to the top; remaining entries follow the order the app declared.
mako_list_actions() {
    local id="$1"
    _notif_list_raw \
        | jq -r --argjson id "$id" '
            (.[] | select(.id == $id) | .actions // []) as $rows
            | ($rows | map(select(.[0] == "default")))
              + ($rows | map(select(.[0] != "default")))
            | .[] | @tsv
        ' 2>/dev/null
}

# mako_has_default_action ID — returns 0 if the notif declared a `default`
# action key, 1 otherwise. Anchored grep avoids matching custom keys that
# happen to contain "default" mid-key.
mako_has_default_action() {
    mako_list_actions "$1" | grep -q $'^default\t'
}

# mako_invoke ID KEY — fires ActionInvoked(id, key) AND CloseNotification(id)
# via our daemon's extension method. Works for ANY id, not just the latest
# (swaync's limitation). The daemon returns a bool — true on hit.
mako_invoke() {
    busctl --user call \
        org.standardos.NotifOS /org/standardos/NotifOS \
        org.standardos.NotifOS InvokeAction "us" "$1" "$2" 2>/dev/null
}

# mako_dismiss ID — closes a specific notif. Uses the standard freedesktop
# CloseNotification method (which our daemon also exposes).
mako_dismiss() {
    busctl --user call \
        org.freedesktop.Notifications /org/freedesktop/Notifications \
        org.freedesktop.Notifications CloseNotification "u" "$1" 2>/dev/null
}

# mako_dismiss_all — iterate every stored notif and close each. No bulk
# method on the freedesktop spec; the daemon could add one but iterating
# is fine for a count rarely > 50.
mako_dismiss_all() {
    local id
    while IFS=$'\t' read -r id _urg; do
        [[ -z $id ]] && continue
        mako_dismiss "$id"
    done < <(mako_list_live)
}
