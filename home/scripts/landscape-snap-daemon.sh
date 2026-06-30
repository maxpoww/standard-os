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
    local mon ws raw rounded
    mon=$(hyprctl monitors -j 2>/dev/null \
          | jq -r '.[] | select(.focused) | .name' 2>/dev/null) || return 0
    ws=$(hyprctl monitors -j 2>/dev/null \
          | jq -r '.[] | select(.focused) | .activeWorkspace.id' 2>/dev/null) || return 0
    [[ "$ws" =~ ^[1-9]$ ]] || return 0
    [ -n "$mon" ] || return 0

    raw="$CACHE/ws-$ws.png.raw"
    rounded="$CACHE/ws-$ws.png.tmp"
    if ! grim -o "$mon" -s 0.4 "$raw" 2>/dev/null; then
        rm -f "$raw"
        return 0
    fi

    # Round the corners at the pixel level. GTK 3 + gtk-layer-shell does
    # NOT reliably clip background-image to border-radius (tested both
    # box-bg-image and eventbox-bg-image variants 2026-06-26 -- corners
    # stayed square). Baking the alpha mask into the PNG gives 100%
    # reliable rounded thumbnails regardless of which GTK widget renders
    # them. The 20px radius matches the user-facing visual budget; tune
    # here, not in CSS.
    # `png:` prefix forces PNG decode -- IM7 otherwise sees the .raw
    # extension and tries DNG (camera raw) which fails. Same prefix
    # on output for symmetry / explicitness.
    if magick "png:$raw" \
        \( +clone -alpha extract \
           -draw "fill black polygon 0,0 0,20 20,0 fill white circle 20,20 20,0" \
           \( +clone -flip \) -compose Multiply -composite \
           \( +clone -flop \) -compose Multiply -composite \
        \) -alpha off -compose CopyOpacity -composite "png:$rounded" 2>/dev/null; then
        mv -f "$rounded" "$CACHE/ws-$ws.png"
        rm -f "$raw"
        write_manifest
    else
        # IM failure: ship the raw screenshot anyway so the user is not
        # left with a stale cell forever. Better square corners than no
        # update.
        mv -f "$raw" "$CACHE/ws-$ws.png"
        write_manifest
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
#
# fd 3 opens the FIFO for READ+WRITE in this subshell. The write side
# is held open even when no external writers are connected, so the
# kernel never reports EOF on the read side. Without this trick the
# while loop would exit as soon as the first `printf > FIFO` writer
# closed its fd — the classic FIFO-EOF bash bug. (Symptom we hit on
# 2026-06-25: debounce subshell silently died at the first event and
# subsequent writers blocked indefinitely on open() of the FIFO.)
(
    exec 3<>"$FIFO"
    while IFS= read -r _ <&3; do
        sleep 0.3
        while IFS= read -r -t 0.01 _ <&3; do :; done
        snapshot_current
    done
) &
DEBOUNCE_PID=$!

# Source 1: Hyprland event socket. Only fire the FIFO on events that
# meaningfully change what a workspace looks like - skip windowtitle
# (background tab title flips are noise).
#
# Fail-fast if HIS or the IPC socket are missing. The daemon races
# against UWSM env-import + Hyprland IPC init at session start; the
# systemd unit's Restart=always + RestartSec=1 respawns us until both
# conditions hold. Matches the pattern in hypr-context-daemon.sh.
HIS="${HYPRLAND_INSTANCE_SIGNATURE:-}"
if [ -z "$HIS" ]; then
    echo "landscape-snap: HYPRLAND_INSTANCE_SIGNATURE unset — exiting for systemd restart" >&2
    exit 1
fi
HYPR_SOCK="${XDG_RUNTIME_DIR}/hypr/${HIS}/.socket2.sock"
if [ ! -S "$HYPR_SOCK" ]; then
    echo "landscape-snap: $HYPR_SOCK missing — exiting for systemd restart" >&2
    exit 1
fi
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
echo "landscape-snap: attached to $HYPR_SOCK (socat pid $SOCAT_PID)" >&2

# Source 2: canvas-open trigger (inotify on the cache dir, filtered).
(
    inotifywait -m -e close_write,create,attrib --format '%f' "$CACHE" 2>/dev/null \
    | while read -r name; do
        [ "$name" = "open-trigger" ] && printf '1\n' > "$FIFO"
    done
) &
INOTIFY_PID=$!

wait
