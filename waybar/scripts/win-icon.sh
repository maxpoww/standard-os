#!/usr/bin/env bash
# Output icon file path for the active window (with caching)
# Outputs empty when no window is focused → hides image module

CACHE_FILE="/tmp/waybar-win-icon-cache"

activewin=$(hyprctl activewindow -j 2>/dev/null)

# Detect no active window: check class AND address
class=$(echo "$activewin" | jq -r '.class // empty' 2>/dev/null)
addr=$(echo "$activewin" | jq -r '.address // empty' 2>/dev/null)
pid=$(echo "$activewin" | jq -r '.pid // 0' 2>/dev/null)

if [ -z "$class" ] || [ -z "$addr" ] || [ "$addr" = "0x" ] || [ "$pid" = "0" ] || [ "$pid" = "null" ]; then
    rm -f "$CACHE_FILE"
    echo ""
    exit 0
fi

# Check cache: if class hasn't changed, reuse last result
if [ -f "$CACHE_FILE" ]; then
  cached_class=$(head -1 "$CACHE_FILE")
  if [ "$cached_class" = "$class" ]; then
    sed -n '2p' "$CACHE_FILE"
    exit 0
  fi
fi

# Icon theme search dirs (NixOS + standard)
ICON_DIRS=(
  "$HOME/.local/share/icons"
  "/run/current-system/sw/share/icons"
  "/etc/profiles/per-user/$USER/share/icons"
  "/usr/share/icons"
)
SIZES=("32x32" "24x24" "48x48" "16x16" "64x64" "128x128" "256x256" "scalable")
DESKTOP_DIRS=(
  "$HOME/.local/share/applications"
  "/run/current-system/sw/share/applications"
  "/etc/profiles/per-user/$USER/share/applications"
  "/usr/share/applications"
)

# Find .desktop file and extract Icon= name
icon_name=""
for dir in "${DESKTOP_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  if [ -f "$dir/${class}.desktop" ]; then
    icon_name=$(grep -m1 '^Icon=' "$dir/${class}.desktop" | cut -d= -f2)
    break
  fi
  for f in "$dir"/*.desktop; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .desktop)
    if [[ "${name,,}" == "${class,,}" ]]; then
      icon_name=$(grep -m1 '^Icon=' "$f" | cut -d= -f2)
      break 2
    fi
  done
done

# Search by StartupWMClass
if [ -z "$icon_name" ]; then
  for dir in "${DESKTOP_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    match=$(grep -rl "StartupWMClass.*${class}" "$dir"/*.desktop 2>/dev/null | head -1)
    if [ -n "$match" ]; then
      icon_name=$(grep -m1 '^Icon=' "$match" | cut -d= -f2)
      break
    fi
  done
fi

if [ -z "$icon_name" ]; then
    rm -f "$CACHE_FILE"
    echo ""
    exit 0
fi

# Absolute path
if [[ "$icon_name" == /* ]] && [ -f "$icon_name" ]; then
  printf '%s\n%s\n' "$class" "$icon_name" > "$CACHE_FILE"
  echo "$icon_name"
  exit 0
fi

# Search icon theme hierarchy
for dir in "${ICON_DIRS[@]}"; do
  for theme in hicolor Adwaita; do
    for size in "${SIZES[@]}"; do
      for ext in png svg; do
        path="$dir/$theme/$size/apps/$icon_name.$ext"
        if [ -f "$path" ] || [ -L "$path" ]; then
          result=$(readlink -f "$path" 2>/dev/null || echo "$path")
          printf '%s\n%s\n' "$class" "$result" > "$CACHE_FILE"
          echo "$result"
          exit 0
        fi
      done
    done
  done
done

# Pixmaps fallback
for dir in /usr/share/pixmaps /run/current-system/sw/share/pixmaps; do
  for ext in png svg xpm; do
    if [ -f "$dir/$icon_name.$ext" ]; then
      printf '%s\n%s\n' "$class" "$dir/$icon_name.$ext" > "$CACHE_FILE"
      echo "$dir/$icon_name.$ext"
      exit 0
    fi
  done
done

# No icon found
rm -f "$CACHE_FILE"
echo ""
exit 0
