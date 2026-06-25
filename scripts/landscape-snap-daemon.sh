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

# --- event loop -------------------------------------------------------------
#
# Two event sources push a single byte into a FIFO; a debounce reader
# coalesces bursts and runs snapshot_current at most every 300 ms.

FIFO=$(mktemp -u "$CACHE/.snap-fifo.XXXXXX")
mkfifo "$FIFO"
cleanup() {
    rm -f "$FIFO"
    [ -n "${DEBOUNCE_PID:-}" ] && kill "$DEBOUNCE_PID" 2>/dev/null
    [ -n "${SOCAT_PID:-}"    ] && kill "$SOCAT_PID"    2>/dev/null
    [ -n "${INOTIFY_PID:-}"  ] && kill "$INOTIFY_PID"  2>/dev/null
}
trap cleanup EXIT INT TERM

# Debounce: any byte in FIFO -> sleep 0.3s -> drain remaining -> snapshot.
(
    while IFS= read -r _; do
        sleep 0.3
        while IFS= read -r -t 0.01 _; do :; done
        snapshot_current
    done
) < "$FIFO" &
DEBOUNCE_PID=$!

# Source 1: Hyprland event socket. Only fire the FIFO on events that
# meaningfully change what a workspace looks like - skip windowtitle
# (background tab title flips are noise).
HYPR_SOCK="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
if [ -S "$HYPR_SOCK" ]; then
    (
        socat -U - "UNIX-CONNECT:$HYPR_SOCK" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                openwindow*|closewindow*|movewindow*|fullscreen*|workspace*|workspacev2*|focusedmon*)
                    printf '1\n' > "$FIFO"
                    ;;
            esac
        done
    ) &
    SOCAT_PID=$!
fi

# Source 2: canvas-open trigger (inotify on the cache dir, filtered).
(
    inotifywait -m -e close_write,create,attrib --format '%f' "$CACHE" 2>/dev/null \
    | while read -r name; do
        [ "$name" = "open-trigger" ] && printf '1\n' > "$FIFO"
    done
) &
INOTIFY_PID=$!

wait
