#!/usr/bin/env bash
set -u

# Local player setup wrapper.
#
# Runs all player-related setup scripts (located in ./player-scripts/) and
# continues even if one fails.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/player-scripts"

usage() {
  cat <<'USAGE'
Usage:
  ./setup-player.sh

What it does:
  Runs the following scripts in order (continuing on errors):
    - player-scripts/setup-player-service.sh
    - player-scripts/setup-screen-control.sh
    - player-scripts/setup-screen-control-service.sh
    - player-scripts/setup-triggerhappy.sh
    - player-scripts/install_kmsgrab.sh
    - player-scripts/send-image.sh

Notes:
  - This wrapper exits 0 only if all scripts exit 0.
  - Some scripts are optional / may fail depending on hardware or missing env.
    (e.g. send-image.sh requires arguments + TELEGRAM_* in .env)
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

run_step() {
  local name="$1"
  local script="$2"

  echo ""
  echo "============================================================"
  echo "==> ${name}"
  echo "     ${script}"
  echo "============================================================"

  if [[ ! -f "$script" ]]; then
    echo "ERROR: Missing script: $script" >&2
    return 127
  fi

  # Make sure the file is executable (helpful when repo was copied with lost mode bits)
  chmod +x "$script" 2>/dev/null || true

  # Run in a subshell so any `cd` inside doesn't affect subsequent steps.
  ( bash "$script" )
}

declare -a failures

step() {
  local name="$1"
  local script_rel="$2"
  local script_abs="${SCRIPTS_DIR}/${script_rel}"

  if ! run_step "$name" "$script_abs"; then
    local rc=$?
    failures+=("${script_rel} (exit ${rc})")
    echo "WARNING: ${script_rel} failed with exit code ${rc} (continuing)" >&2
  fi
}

step "Player kiosk service" "setup-player-service.sh"
step "Screen control helper" "setup-screen-control.sh"
step "Screen control service" "setup-screen-control-service.sh"
step "Triggerhappy hotkeys" "setup-triggerhappy.sh"
step "kmsgrab install" "install_kmsgrab.sh"
step "Telegram send-image helper" "send-image.sh"

echo ""
echo "============================================================"
echo " Summary"
echo "============================================================"

if (( ${#failures[@]} == 0 )); then
  echo "All scripts completed successfully."
  exit 0
fi

echo "Some scripts failed:" >&2
for f in "${failures[@]}"; do
  echo " - $f" >&2
done

exit 1
