#!/usr/bin/env bash
# test_sidecar_render — TDD for the staging → sidecar Nix renderer.
set -euo pipefail

LIB="$(cd "$(dirname "$0")"/.. && pwd)/scripts/lib/sidecar-render.sh"
source "$LIB"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name:"
        echo "  expected: $expected"
        echo "  got     : $actual"
        fail=$((fail+1))
    fi
}

# Empty staging → empty users block.
out=$(render_sidecar '{}')
check "empty staging" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
  };
}'

# Shell only.
out=$(render_sidecar '{"shell":"zsh"}')
check "shell only" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
    shell = pkgs.zsh;
  };
}'

# Groups only.
out=$(render_sidecar '{"groups":["wheel","audio"]}')
check "groups only" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
    extraGroups = [ "wheel" "audio" ];
  };
}'

# Both.
out=$(render_sidecar '{"shell":"fish","groups":["wheel","video"]}')
check "shell + groups" "$out" \
'{ config, lib, pkgs, ... }: {
  users.users.max = {
    shell = pkgs.fish;
    extraGroups = [ "wheel" "video" ];
  };
}'

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
