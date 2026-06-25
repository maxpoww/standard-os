#!/usr/bin/env bash
# sidecar-render.sh — pure function library. Source it; call
# render_sidecar with a JSON staging blob; get back a Nix expression
# string that defines users.users.max with the staged shell + groups.
#
# Keeps the apply orchestration (sudo, rebuild, error handling) out
# of the rendering logic so the renderer is unit-testable.

render_sidecar() {
    local staging="$1"
    local shell groups_list extra
    shell="$(printf '%s' "$staging" | jq -r '.shell // empty')"
    groups_list="$(printf '%s' "$staging" \
        | jq -r 'if .groups then (.groups | map("\"" + . + "\"") | join(" ")) else empty end')"

    extra=""
    if [ -n "$shell" ]; then
        extra+="    shell = pkgs.${shell};"$'\n'
    fi
    if [ -n "$groups_list" ]; then
        extra+="    extraGroups = [ $groups_list ];"$'\n'
    fi

    # Build the body: extra already ends with \n when non-empty.
    # We need a literal newline before "  };" so we use printf directly.
    printf '{ config, lib, pkgs, ... }: {\n'
    printf '  users.users.max = {\n'
    printf '%s' "$extra"
    printf '  };\n'
    printf '}\n'
}
