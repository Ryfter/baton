#!/usr/bin/env bash
# dark-factory-night.sh — Kevin sleeps; factory seeds lanes and ticks Maestro once.
set -euo pipefail

OUT="${HOME}/.baton/overnight"
BATON="${BATON_REPO:-/Users/kev/Dev/Baton}"
LOG="${OUT}/lanes/dark-factory-night.log"
PWSH="${PWSH:-$HOME/.baton/bin/pwsh}"

mkdir -p "${OUT}/lanes"
if [[ -f "${OUT}/.openrouter.env" ]]; then
  # shellcheck disable=SC1091
  source "${OUT}/.openrouter.env"
fi

export DOTNET_ROOT="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}"
export PATH="$HOME/.baton/bin:$PATH"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

{
  echo "[$(ts)] dark-factory-night start"
  "$PWSH" -NoProfile -File "${BATON}/scripts/fleet-dark-factory.ps1" -Action night -Fire -Json
  if [[ -x "${OUT}/bin/maestro-watch.sh" ]]; then
    "${OUT}/bin/maestro-watch.sh" --once || true
  fi
  echo "[$(ts)] dark-factory-night done"
} >>"$LOG" 2>&1

echo "dark-factory-night: logged to $LOG"
