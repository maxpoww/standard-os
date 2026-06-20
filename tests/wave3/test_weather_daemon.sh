#!/usr/bin/env bash
# test_weather_daemon — unit tests for weather-daemon.sh's parse + emit.
# Mocks `curl` via a function override; runs the daemon's one_fetch()
# function (sourced via WEATHER_DAEMON_LIB_ONLY=1) and inspects the
# JSON it would emit.
set -euo pipefail

DAEMON="$(cd "$(dirname "$0")"/../.. && pwd)/scripts/weather-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Library-mode source: should define one_fetch + condition_canonicalize
# without entering the poll loop.
WEATHER_DAEMON_LIB_ONLY=1 source "$DAEMON"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name: expected '$expected', got '$actual'"; fail=$((fail+1))
    fi
}

# Override curl with a function that emits a fixture per URL.
curl() {
    case "$*" in
        *"format=%C"*) printf 'Partly cloudy|+18°C|45%%|Mendoza, AR\n' ;;
        *"format=j1"*) printf '{"weather":[{"maxtempC":"22","mintempC":"9"}]}\n' ;;
        *) return 7 ;;
    esac
}
export -f curl

# --- canonicalize ---
check "canonicalize clear"          "$(condition_canonicalize 'Clear')"               "clear"
check "canonicalize partly cloudy"  "$(condition_canonicalize 'Partly cloudy')"       "partly-cloudy"
check "canonicalize rain"           "$(condition_canonicalize 'Light rain shower')"   "rain"
check "canonicalize snow"           "$(condition_canonicalize 'Light snow')"          "snow"
check "canonicalize storm"          "$(condition_canonicalize 'Thunderstorm')"        "storm"
check "canonicalize unknown→clear"  "$(condition_canonicalize 'Volcanic ash plume')"  "clear"

# --- one_fetch (full integration with mocked curl) ---
out="$(STANDARDOS_WEATHER_CITY=Mendoza one_fetch)"
check "one_fetch returns JSON cond"  "$(printf '%s' "$out" | jq -r .cond)"  "partly-cloudy"
check "one_fetch returns JSON temp"  "$(printf '%s' "$out" | jq -r .temp)"  "+18°C"
check "one_fetch returns JSON hi"    "$(printf '%s' "$out" | jq -r .hi)"    "22"
check "one_fetch returns JSON lo"    "$(printf '%s' "$out" | jq -r .lo)"    "9"
check "one_fetch returns JSON hum"   "$(printf '%s' "$out" | jq -r .hum)"   "45%"
check "one_fetch returns JSON city"  "$(printf '%s' "$out" | jq -r .city)"  "Mendoza"

# --- one_fetch failure (curl exit 7) ---
curl() { return 7; }
export -f curl
out="$(one_fetch || true)"
check "fetch failure returns empty"  "$out"  ""

echo "---"
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
