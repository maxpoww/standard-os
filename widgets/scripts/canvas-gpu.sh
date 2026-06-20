#!/usr/bin/env bash
# canvas-gpu.sh — best-effort GPU usage percent. Returns "0" if no detector found.
# Mode "pct" (default): integer percent
# Mode "temp": integer °C

set -uo pipefail
mode="${1:-pct}"

if command -v nvidia-smi >/dev/null 2>&1; then
  case "$mode" in
    pct)  nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' %' ;;
    temp) nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' °C' ;;
  esac
  exit 0
fi

# AMD via amdgpu_top JSON.
if command -v amdgpu_top >/dev/null 2>&1; then
  case "$mode" in
    pct)  amdgpu_top -d -J -n 1 2>/dev/null | grep -m1 '"GFX_BUSY"' | sed -E 's/.*: *([0-9]+).*/\1/' ;;
    temp) amdgpu_top -d -J -n 1 2>/dev/null | grep -m1 '"edge"'      | sed -E 's/.*"value": *([0-9]+).*/\1/' ;;
  esac
  exit 0
fi

# Intel (rough) — fall back to silence.
echo "0"
exit 0
