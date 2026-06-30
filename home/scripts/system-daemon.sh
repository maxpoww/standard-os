#!/usr/bin/env bash
# system-daemon — CPU / GPU / memory / battery / thermal cache writer.
#
# Replaces widgets/scripts/canvas-{cpu,gpu,mem,disk}.sh (each was an
# eww defpoll shell-out). Wave 3 moves the polls into a single
# long-running systemd-user service so:
#   - Caches stay fresh for future bar pillar-6 surfaces
#     (audio / brightness / battery existing pills will read sys-battery
#     for true %).
#   - Canvas defpolls become `cat | jq -r`, removing the per-tick
#     `nvidia-smi` / `radeontop` invocations that briefly spike GPU
#     polling when the canvas is open.
#
# Cache files:    /tmp/waybar-cache/sys-{cpu, gpu, mem, battery, temp,
#                                       disk-root, disk-home}
# Signal:         RTMIN+18 (reserved in waybar/ARCHITECTURE.md;
#                 dedup at writer per the global anti-CPU-burn pattern)
#
# Library mode: SYSTEM_DAEMON_LIB_ONLY=1 source system-daemon.sh
# defines emit_* without entering the loop.
#
# Fixture roots: SYS_PROC and SYS_SYS env vars override /proc and /sys
# for tests. Default: SYS_PROC=/proc, SYS_SYS=/sys.

set -uo pipefail

source /etc/nixos/home/scripts/lib/canvas-cache.sh

CACHE_DIR=/tmp/waybar-cache
mkdir -p "$CACHE_DIR"

POLL_INTERVAL="${SYSTEM_POLL_INTERVAL:-2}"
SIG=18

: "${SYS_PROC:=/proc}"
: "${SYS_SYS:=/sys}"

# ─── CPU ─────────────────────────────────────────────────────
_PREV_CPU_IDLE=0
_PREV_CPU_TOTAL=0
emit_cpu() {
    local idle total diff_idle diff_total pct temp load_1
    read -r _ user nice sys idle iowait irq softirq steal _ < "$SYS_PROC/stat"
    total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
    diff_total=$((total - _PREV_CPU_TOTAL))
    diff_idle=$((idle - _PREV_CPU_IDLE))
    if (( diff_total > 0 )); then
        pct=$(( 100 * (diff_total - diff_idle) / diff_total ))
    else
        pct=0
    fi
    _PREV_CPU_IDLE=$idle
    _PREV_CPU_TOTAL=$total

    # Temperature from coretemp hwmon node, if present.
    temp="—"
    local hw
    for hw in "$SYS_SYS"/class/hwmon/hwmon*; do
        [[ -r "$hw/name" ]] || continue
        local n; n=$(<"$hw/name")
        case "$n" in
            coretemp|k10temp|zenpower)
                local t; t=$(cat "$hw/temp1_input" 2>/dev/null || echo "")
                if [[ -n "$t" ]]; then
                    temp="$((t / 1000))°"
                fi
                break
                ;;
        esac
    done

    read -r load_1 _ < "$SYS_PROC/loadavg"
    jq -nc --argjson pct "$pct" --arg temp "$temp" --arg load_1 "$load_1" \
       '{pct:$pct, temp:$temp, load_1:$load_1}'
}

# ─── Memory ──────────────────────────────────────────────────
emit_mem() {
    local total avail pct used_h total_h
    total=$(awk '/^MemTotal:/  {print $2}' "$SYS_PROC/meminfo")
    avail=$(awk '/^MemAvailable:/ {print $2}' "$SYS_PROC/meminfo")
    # Use awk for rounding (bash integer division truncates)
    pct=$(awk -v total="$total" -v avail="$avail" \
        'BEGIN{ used=total-avail; print int(100*used/total + 0.5) }')
    used_h=$(awk -v total="$total" -v avail="$avail" \
        'BEGIN{ used=total-avail; printf "%.1fG", used/1024/1024 }')
    total_h=$(awk -v k="$total" 'BEGIN{printf "%.0fG", k/1024/1024}')
    jq -nc --argjson pct "$pct" --arg used "$used_h" --arg total "$total_h" \
       '{pct:$pct, used:$used, total:$total}'
}

# ─── Battery ─────────────────────────────────────────────────
emit_battery() {
    # Detect first available battery (BAT0, BAT1, etc.)
    local bat=""
    local b
    for b in "$SYS_SYS/class/power_supply"/BAT*; do
        [[ -d "$b" ]] && bat="$b" && break
    done
    if [[ -z "$bat" ]]; then
        # Desktop / no battery: emit a stable "absent" payload.
        echo '{"pct":-1,"state":"absent","time_remaining":"—"}'
        return
    fi
    local pct state energy_now power_now state_lc time_remaining
    pct=$(<"$bat/capacity")
    state=$(<"$bat/status")
    state_lc="${state,,}"  # Discharging → discharging
    # "Not charging" is the kernel's way of saying "full + on AC, not drawing power"
    # — semantically full, not unknown. Map it before the regex filter.
    case "$state_lc" in
        "not charging") state_lc=full ;;
    esac
    [[ "$state_lc" =~ ^(charging|discharging|full|unknown)$ ]] || state_lc=unknown

    # time_remaining: only meaningful while charging/discharging.
    time_remaining="—"
    if [[ "$state_lc" == discharging || "$state_lc" == charging ]]; then
        energy_now=$(cat "$bat/energy_now" 2>/dev/null || echo 0)
        power_now=$(cat "$bat/power_now" 2>/dev/null || echo 0)
        if (( power_now > 0 )); then
            local hours=$(( energy_now / power_now ))
            local mins=$(( (energy_now * 60 / power_now) % 60 ))
            time_remaining="${hours}h${mins}m"
        fi
    fi
    jq -nc --argjson pct "$pct" --arg state "$state_lc" --arg tr "$time_remaining" \
       '{pct:$pct, state:$state, time_remaining:$tr}'
}

# ─── GPU (best-effort, kind detected once) ────────────────────
_GPU_KIND=""
detect_gpu_kind() {
    if command -v nvidia-smi >/dev/null 2>&1; then echo nvidia
    elif command -v radeontop  >/dev/null 2>&1; then echo amd
    elif command -v intel_gpu_top >/dev/null 2>&1; then echo intel
    else echo none
    fi
}
emit_gpu() {
    [[ -z "$_GPU_KIND" ]] && _GPU_KIND=$(detect_gpu_kind)
    local pct=0 temp="—"
    case "$_GPU_KIND" in
        nvidia)
            local raw; raw=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu \
                              --format=csv,noheader,nounits 2>/dev/null | head -1) || raw=""
            if [[ -n "$raw" ]]; then
                IFS=',' read -r pct temp <<<"$raw"
                pct=$(printf '%s' "$pct" | tr -d ' ')
                temp="$(printf '%s' "$temp" | tr -d ' ')°"
            fi
            ;;
        intel|amd|none) : ;; # Wave 3 ships nvidia-only metrics; intel/amd
                              # land in a follow-up. pct stays 0, temp "—".
    esac
    jq -nc --argjson pct "$pct" --arg temp "$temp" --arg kind "$_GPU_KIND" \
       '{pct:$pct, temp:$temp, kind:$kind}'
}

# ─── Helper: read CPU temp from hwmon (no CPU counter side effects) ─
_read_cpu_temp() {
    local hw t
    for hw in "${SYS_SYS:-/sys}"/class/hwmon/hwmon*; do
        [[ -r "$hw/name" ]] || continue
        local n; n=$(cat "$hw/name" 2>/dev/null || true)
        case "$n" in
            coretemp|k10temp|zenpower)
                t=$(cat "$hw/temp1_input" 2>/dev/null || echo "")
                if [[ -n "$t" ]]; then
                    echo "$((t / 1000))°"
                    return
                fi
                ;;
        esac
    done
    echo "—"
}

# ─── Thermals (cpu + gpu + fan, aggregated for SYSTEM·TEMPS card) ──
emit_temp() {
    local cpu_temp gpu_temp fan_rpm
    # Read CPU temp via the no-side-effect helper.
    cpu_temp=$(_read_cpu_temp)
    # Read GPU temp from the already-written sys-gpu cache if available,
    # else fall back to calling emit_gpu (which is side-effect-free on GPU).
    if [[ -r "$CACHE_DIR/sys-gpu" ]]; then
        gpu_temp=$(jq -r '.temp // "—"' "$CACHE_DIR/sys-gpu" 2>/dev/null || echo "—")
    else
        gpu_temp=$(printf '%s' "$(emit_gpu)" | jq -r .temp)
    fi
    fan_rpm=0
    local hw
    for hw in "$SYS_SYS"/class/hwmon/hwmon*; do
        [[ -r "$hw/fan1_input" ]] || continue
        local raw; raw=$(cat "$hw/fan1_input" 2>/dev/null || echo "")
        if [[ -n "$raw" ]] && [[ "$raw" =~ ^[0-9]+$ ]]; then
            fan_rpm="$raw"
            break
        fi
    done
    jq -nc --arg cpu "$cpu_temp" --arg gpu "$gpu_temp" --argjson fan "$fan_rpm" \
       '{cpu:$cpu, gpu:$gpu, fan_rpm:$fan}'
}

# ─── Disk (per mountpoint, called per cache file) ────────────
emit_disk() {
    local mp="$1"
    local line
    line=$(df -B1 --output=size,used,pcent "$mp" 2>/dev/null | tail -1) || {
        echo '{"pct":0,"used":"—","total":"—"}'
        return
    }
    local size used pct
    read -r size used pct <<<"$line"
    pct="${pct%\%}"
    local used_h total_h
    used_h=$(awk -v k="$used" 'BEGIN{ printf "%.0fG", k/1024/1024/1024}')
    total_h=$(awk -v k="$size" 'BEGIN{ printf "%.0fG", k/1024/1024/1024}')
    jq -nc --argjson pct "$pct" --arg used "$used_h" --arg total "$total_h" \
       '{pct:$pct, used:$used, total:$total}'
}

[[ -n "${SYSTEM_DAEMON_LIB_ONLY:-}" ]] && return 0

# ─── Main loop ──────────────────────────────────────────────────────
# Prime CPU counters with one read so the next iteration produces a
# meaningful diff. Without this, the first emit_cpu returns 100 %.
emit_cpu >/dev/null

while true; do
    cache_signal_if_changed "$CACHE_DIR/sys-cpu"        "$(emit_cpu)"     "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-mem"        "$(emit_mem)"     "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-battery"    "$(emit_battery)" "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-gpu"        "$(emit_gpu)"     "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-temp"       "$(emit_temp)"    "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-disk-root"  "$(emit_disk /)"  "$SIG"
    cache_signal_if_changed "$CACHE_DIR/sys-disk-home"  "$(emit_disk /home)" "$SIG"
    sleep "$POLL_INTERVAL"
done
