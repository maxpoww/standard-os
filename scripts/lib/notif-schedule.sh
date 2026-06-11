# notif-schedule.sh — pure schedule-evaluation helpers.
#
# Schedules: "HH:MM-HH:MM Day-Day" or "HH:MM-HH:MM" (=all days).
# Day-Day is one of: Mon-Sun, Mon-Fri, Sat-Sun, *.
# All times LOCAL. Day-of-week: POSIX %u (1=Mon..7=Sun).

parse_schedule() {
    local s="$1"
    [[ -z $s ]] && { printf '0\t0\t0'; return; }
    local range="${s%% *}"
    local days="${s#* }"
    [[ "$s" != *' '* ]] && days='*'
    local start_str="${range%%-*}"
    local end_str="${range##*-}"
    local start_hh="${start_str%%:*}"
    local start_mm="${start_str##*:}"
    local end_hh="${end_str%%:*}"
    local end_mm="${end_str##*:}"
    start_hh=$((10#${start_hh:-0}))
    start_mm=$((10#${start_mm:-0}))
    end_hh=$((10#${end_hh:-0}))
    end_mm=$((10#${end_mm:-0}))
    local start_hhmm=$(( start_hh * 100 + start_mm ))
    local end_hhmm=$(( end_hh * 100 + end_mm ))

    local mask=0
    case "$days" in
        '*'|'Mon-Sun'|'') mask=127 ;;
        'Mon-Fri') mask=31 ;;
        'Sat-Sun') mask=96 ;;
        'Mon-Mon') mask=1 ;;
        'Tue-Tue') mask=2 ;;
        'Wed-Wed') mask=4 ;;
        'Thu-Thu') mask=8 ;;
        'Fri-Fri') mask=16 ;;
        'Sat-Sat') mask=32 ;;
        'Sun-Sun') mask=64 ;;
        *) mask=127 ;;
    esac
    printf '%d\t%d\t%d' "$start_hhmm" "$end_hhmm" "$mask"
}

schedule_matches() {
    local start="$1" end="$2" mask="$3" wd="$4" hhmm="$5"
    local wd_bit=$(( 1 << (wd - 1) ))
    (( mask & wd_bit )) || return 1
    if (( start <= end )); then
        (( hhmm >= start && hhmm < end )) && return 0 || return 1
    else
        (( hhmm >= start || hhmm < end )) && return 0 || return 1
    fi
}

next_boundary_epoch() {
    local start="$1" end="$2" mask="$3" now_epoch="$4"
    local current_in
    local now_hhmm now_wd
    now_hhmm=$(date -d "@$now_epoch" +%H%M)
    now_hhmm=$((10#$now_hhmm))
    now_wd=$(date -d "@$now_epoch" +%u)
    if schedule_matches "$start" "$end" "$mask" "$now_wd" "$now_hhmm"; then
        current_in=1
    else
        current_in=0
    fi
    local check_epoch=$(( now_epoch + 60 ))
    local i
    for (( i = 0; i < 60 * 24 * 8; i++ )); do
        local h w
        h=$(date -d "@$check_epoch" +%H%M)
        h=$((10#$h))
        w=$(date -d "@$check_epoch" +%u)
        local in_now=0
        schedule_matches "$start" "$end" "$mask" "$w" "$h" && in_now=1
        if (( in_now != current_in )); then
            printf '%d' "$check_epoch"
            return 0
        fi
        check_epoch=$(( check_epoch + 60 ))
    done
    printf '%d' "$(( now_epoch + 60 * 60 * 24 * 8 ))"
}

resolve_active_profile() {
    local override_file="$1" profiles_json="$2" now_epoch="$3"

    if [[ -n $override_file && -f $override_file ]]; then
        local ov_profile ov_until ov_until_epoch
        ov_profile=$(grep -oP '^profile=\K.*' "$override_file" 2>/dev/null | head -1)
        ov_until=$(grep -oP '^valid_until=\K.*' "$override_file" 2>/dev/null | head -1)
        if [[ -n $ov_profile ]]; then
            if [[ -n $ov_until ]]; then
                ov_until_epoch=$(date -d "$ov_until" +%s 2>/dev/null)
                if [[ -n $ov_until_epoch && $now_epoch -lt $ov_until_epoch ]]; then
                    printf '%s\t%s' "$ov_profile" "$ov_until"
                    return 0
                fi
            else
                printf '%s\t' "$ov_profile"
                return 0
            fi
            rm -f "$override_file"
        fi
    fi

    local now_wd now_hhmm
    now_wd=$(date -d "@$now_epoch" +%u)
    now_hhmm=$(date -d "@$now_epoch" +%H%M)
    now_hhmm=$((10#$now_hhmm))

    local profile_names
    profile_names=$(jq -r 'keys_unsorted[]' "$profiles_json" 2>/dev/null) || profile_names=""

    local p sched parsed start end mask
    while IFS= read -r p; do
        [[ -z $p ]] && continue
        sched=$(jq -r --arg p "$p" '.[$p].schedule // empty' "$profiles_json" 2>/dev/null)
        [[ -z $sched ]] && continue
        parsed=$(parse_schedule "$sched")
        IFS=$'\t' read -r start end mask <<< "$parsed"
        if schedule_matches "$start" "$end" "$mask" "$now_wd" "$now_hhmm"; then
            local boundary_epoch
            boundary_epoch=$(next_boundary_epoch "$start" "$end" "$mask" "$now_epoch")
            local until_iso
            until_iso=$(date -d "@$boundary_epoch" -Iseconds)
            printf '%s\t%s' "$p" "$until_iso"
            return 0
        fi
    done <<< "$profile_names"

    printf '%s\t' "${NOTIF_DEFAULT_PROFILE:-off}"
}
