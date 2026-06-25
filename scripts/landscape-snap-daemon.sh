#!/usr/bin/env bash
# StandardOS landscape snapshot daemon.
# Captures the currently-focused workspace on window events (debounced)
# and on canvas-open trigger. Output: /tmp/standardos/landscape/ws-N.png.

set -u

CACHE=/tmp/standardos/landscape
mkdir -p "$CACHE"

# --- capture ----------------------------------------------------------------

snapshot_current() {
    # Silent on any failure: no error pill on OPTIONS.
    local mon ws tmp
    mon=$(hyprctl monitors -j 2>/dev/null \
          | jq -r '.[] | select(.focused) | .name' 2>/dev/null) || return 0
    ws=$(hyprctl monitors -j 2>/dev/null \
          | jq -r '.[] | select(.focused) | .activeWorkspace.id' 2>/dev/null) || return 0
    [[ "$ws" =~ ^[1-9]$ ]] || return 0
    [ -n "$mon" ] || return 0

    tmp="$CACHE/ws-$ws.png.tmp"
    if grim -o "$mon" -s 0.4 "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CACHE/ws-$ws.png"
        write_manifest
    else
        rm -f "$tmp"
    fi
}

write_manifest() {
    local tmp="$CACHE/manifest.json.tmp"
    {
        printf '{'
        local first=1 f m n
        for n in 1 2 3 4 5 6 7 8 9; do
            f="$CACHE/ws-$n.png"
            if [ -r "$f" ]; then
                m=$(stat -c %Y "$f")
                [ $first -eq 0 ] && printf ','
                printf '"ws%d_mtime":%d' "$n" "$m"
                first=0
            fi
        done
        printf '}\n'
    } > "$tmp"
    mv -f "$tmp" "$CACHE/manifest.json"
}

# --- entry ------------------------------------------------------------------

if [ "${LANDSCAPE_ONESHOT:-0}" = "1" ]; then
    snapshot_current
    exit 0
fi

# Event loop comes in Task 3.
echo "landscape-snap: event loop not implemented yet (Task 3)" >&2
exit 1
