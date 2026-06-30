#!/usr/bin/env bash
# test_system_daemon — unit tests for system-daemon.sh's read+emit path.
# Each emit_* function reads from $SYS_PROC and $SYS_SYS roots so tests
# can supply fixture trees and verify the JSON output.
set -euo pipefail

DAEMON="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/system-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Library-mode: define emit_* without entering the poll loop.
SYSTEM_DAEMON_LIB_ONLY=1 source "$DAEMON"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# ─── Fixture: /proc ─────────────────────────────────────────
PROC="$TMP/proc"
mkdir -p "$PROC"
cat > "$PROC/loadavg" <<'EOF'
0.42 0.38 0.31 2/812 12345
EOF
cat > "$PROC/meminfo" <<'EOF'
MemTotal:       16384000 kB
MemFree:         2048000 kB
MemAvailable:    8200000 kB
Buffers:          512000 kB
Cached:          2048000 kB
EOF
cat > "$PROC/stat" <<'EOF'
cpu  10000 0 5000 90000 0 0 100 0 0 0
EOF

# ─── Fixture: /sys for battery ──────────────────────────────
SYS="$TMP/sys"
mkdir -p "$SYS/class/power_supply/BAT0"
echo 82                  > "$SYS/class/power_supply/BAT0/capacity"
echo Discharging         > "$SYS/class/power_supply/BAT0/status"
echo 14400000000         > "$SYS/class/power_supply/BAT0/energy_full"
echo 11808000000         > "$SYS/class/power_supply/BAT0/energy_now"
echo 2500000000          > "$SYS/class/power_supply/BAT0/power_now"

# ─── Fixture: /sys for thermals ─────────────────────────────
mkdir -p "$SYS/class/hwmon/hwmon0"
echo 'coretemp'          > "$SYS/class/hwmon/hwmon0/name"
echo '52000'             > "$SYS/class/hwmon/hwmon0/temp1_input"

SYS_PROC="$PROC" SYS_SYS="$SYS" out=$(emit_cpu)
check "cpu pct present"   "$(printf '%s' "$out" | jq -r 'has("pct") | tostring')" "true"
check "cpu temp present"  "$(printf '%s' "$out" | jq -r '.temp')" "52°"

SYS_PROC="$PROC" SYS_SYS="$SYS" out=$(emit_mem)
# 1 - 8200000/16384000 = 49.94 → 50 (rounded)
check "mem pct close to 50"  "$(printf '%s' "$out" | jq -r '.pct')" "50"

SYS_PROC="$PROC" SYS_SYS="$SYS" out=$(emit_battery)
check "battery pct"          "$(printf '%s' "$out" | jq -r '.pct')" "82"
check "battery state"        "$(printf '%s' "$out" | jq -r '.state')" "discharging"

# Disk uses df; mock via PATH override
DF_DIR="$TMP/bin"
mkdir -p "$DF_DIR"
cat > "$DF_DIR/df" <<'EOF'
#!/usr/bin/env bash
# Fixture: emulate `df -B1 --output=size,used,pcent <path>`
# Outputs header + one row.
echo "  1B-blocks       Used Use%"
echo "250000000000 80000000000 32%"
EOF
chmod +x "$DF_DIR/df"
PATH="$DF_DIR:$PATH" out=$(emit_disk /)
check "disk pct"            "$(printf '%s' "$out" | jq -r '.pct')" "32"

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
