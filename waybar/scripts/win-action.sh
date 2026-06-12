#!/usr/bin/env bash
# Window actions for active-window module
action="$1"
case "$action" in
  new-instance)
    win=$(hyprctl activewindow -j 2>/dev/null)
    [ -z "$win" ] && exit 0
    class=$(echo "$win" | jq -r '.class // empty')
    pid=$(echo "$win" | jq -r '.pid // empty')
    [ -z "$class" ] && exit 0

    # Strategy 1: find .desktop file matching the class
    desktop=""
    for dir in /usr/share/applications /home/$USER/.local/share/applications /run/current-system/sw/share/applications /etc/profiles/per-user/$USER/share/applications; do
      [ -d "$dir" ] || continue
      # Try exact match first, then case-insensitive
      for f in "$dir"/*.desktop; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .desktop)
        if [[ "${name,,}" == "${class,,}" ]]; then
          desktop="$f"
          break 2
        fi
      done
    done

    # Strategy 2: search by StartupWMClass
    if [ -z "$desktop" ]; then
      for dir in /usr/share/applications /home/$USER/.local/share/applications /run/current-system/sw/share/applications /etc/profiles/per-user/$USER/share/applications; do
        [ -d "$dir" ] || continue
        match=$(grep -rl "StartupWMClass=${class}" "$dir"/*.desktop 2>/dev/null | head -1)
        if [ -n "$match" ]; then
          desktop="$match"
          break
        fi
      done
    fi

    # Strategy 3: get exe from /proc and launch it directly
    if [ -z "$desktop" ] && [ -n "$pid" ]; then
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
      if [ -n "$exe" ]; then
        hyprctl dispatch exec "$exe" &
        exit 0
      fi
    fi

    if [ -n "$desktop" ]; then
      # Extract Exec line, strip field codes (%u %F etc)
      exec_line=$(grep -m1 '^Exec=' "$desktop" | sed 's/^Exec=//' | sed 's/ %[a-zA-Z]//g')
      hyprctl dispatch exec "$exec_line" &
    else
      # Last resort: try class name as command
      hyprctl dispatch exec "$class" &
    fi
    ;;
esac
