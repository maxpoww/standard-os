# notif-mako.sh — adapter between notif-menu and mako (D-Bus + makoctl).
#
# All busctl/makoctl calls in the menu codebase go through here so tests can
# mock these primitives by overriding `busctl` and `makoctl` as bash functions
# before sourcing this lib.

_mako_busctl_list() {
    busctl --user --json=short call \
        org.freedesktop.Notifications /fr/emersion/Mako \
        fr.emersion.Mako ListNotifications 2>/dev/null
}

# mako_list_live — prints `id\turgency` per live notification, one per line.
# Empty output when no live notifs (or busctl error).
mako_list_live() {
    _mako_busctl_list \
        | jq -r '.data[0][]? | "\(.id.data)\t\(.urgency.data)"' 2>/dev/null
}

# mako_list_actions ID — prints `key\tlabel` per action on the given notif,
# one per line. The entry whose key == "default" is hoisted to the top of
# the output; remaining entries follow mako's natural order.
# Handles both mako 1.10's object actions payload (a{ss} → JSON object)
# and older mako's alternating-string-array payload.
mako_list_actions() {
    local id="$1"
    _mako_busctl_list | jq -r --argjson id "$id" '
        .data[0][]? | select(.id.data == $id) | .actions.data as $a
        | (if ($a | type) == "object" then
              ($a | to_entries | map([.key, .value]))
           elif ($a | type) == "array" then
              [range(0; ($a | length); 2) as $i | [$a[$i], $a[$i+1]]]
           else [] end) as $rows
        | ($rows | map(select(.[0] == "default")))
          + ($rows | map(select(.[0] != "default")))
        | .[] | @tsv
    ' 2>/dev/null
}

mako_invoke()      { makoctl invoke -n "$1" "$2" 2>/dev/null; }
mako_dismiss()     { makoctl dismiss -n "$1" 2>/dev/null; }
mako_dismiss_all() { makoctl dismiss --all 2>/dev/null; }
