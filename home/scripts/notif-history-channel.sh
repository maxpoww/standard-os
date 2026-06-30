#!/usr/bin/env bash
# notif-history-channel — derive a canvas-shaped JSON cache from the
# notif-os-daemon journal at ~/.local/share/standard-os/notif-history.jsonl.
#
# notif-os-daemon (Rust) already journals every notification. Wave 3
# adds this thin shell channel so the canvas's notifications card
# has a stable, atomically-written input (JSONL is append-only and
# can be tailed mid-write, which is not friendly to a defpoll).
#
# Cache:  /tmp/waybar-cache/notif-history.json
# Signal: RTMIN+12 (shared with notif-daemon — connectivity-style sharing
#                   per ARCHITECTURE.md; one signal refreshes every
#                   notif-related consumer).
#
# Triggers: inotify on the journal directory (the file inode may
# rotate when notif-os-daemon truncates; watch the parent dir with
# --format '%f' filtered by basename, per the hazard in waybar/CLAUDE.md).
#
# Library mode: NOTIF_HISTORY_LIB_ONLY=1 source defines derive_history_json
# without entering the loop.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

JOURNAL="${HOME}/.local/share/standard-os/notif-history.jsonl"
CACHE=/tmp/waybar-cache/notif-history.json
SIG=12
mkdir -p "$(dirname "$CACHE")" "$(dirname "$JOURNAL")"
touch "$JOURNAL"  # so inotifywait doesn't bail when journal hasn't been written yet

derive_history_json() {
    local journal="$1"
    if [[ ! -r "$journal" ]]; then
        echo '{"count":0,"entries":[],"updated":'"$(date +%s)"'}'
        return
    fi
    # tac to get newest first, take top 10. Use a jq slurp so we get a
    # single array; count uses wc -l for cheapness.
    local count entries
    count=$(wc -l < "$journal" 2>/dev/null || echo 0)
    if (( count == 0 )); then
        echo '{"count":0,"entries":[],"updated":'"$(date +%s)"'}'
        return
    fi
    entries=$(tac "$journal" 2>/dev/null | head -10 | jq -s '.')
    jq -nc --argjson count "$count" --argjson entries "$entries" \
       --argjson updated "$(date +%s)" \
       '{count:$count, entries:$entries, updated:$updated}'
}

[[ -n "${NOTIF_HISTORY_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# Initial write.
cache_signal_if_changed "$CACHE" "$(derive_history_json "$JOURNAL")" "$SIG"

# Watch the parent dir for changes to the journal basename. The
# notif-os-daemon writes via append; inotify CLOSE_WRITE + MODIFY
# both fire. We coalesce: any event → re-derive.
JOURNAL_NAME=$(basename "$JOURNAL")
JOURNAL_DIR=$(dirname "$JOURNAL")

inotifywait -m -e modify -e close_write -e moved_to --format '%f' "$JOURNAL_DIR" 2>/dev/null \
| while read -r fname; do
    [[ "$fname" == "$JOURNAL_NAME" ]] || continue
    cache_signal_if_changed "$CACHE" "$(derive_history_json "$JOURNAL")" "$SIG"
done
