#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi monitoring setup.
#
# What it does:
# - Ensures vcgencmd is available (via libraspberrypi-bin on Debian/RPi OS)
# - Installs a small monitoring script to /usr/local/bin/lume-monitor
# - Installs + enables a systemd timer that runs every 60 minutes
# - Logs to journald (view with: journalctl -u lume-monitor.service)
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).

usage() {
  cat <<'USAGE'
Usage:
  setup-monitoring.sh

What gets installed:
  - /usr/local/bin/lume-monitor
  - /etc/systemd/system/lume-monitor.service
  - /etc/systemd/system/lume-monitor.timer

Timer:
  - Runs every 60 minutes (plus a first run ~5 minutes after boot)

Logs:
  - journalctl -u lume-monitor.service -n 200 --no-pager
  - systemctl status lume-monitor.timer

Notes:
  - Requires sudo for apt installs and systemd installation.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_debian_like() {
  [[ -f /etc/debian_version ]] && has_cmd apt-get
}

# Absolute path to this directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! is_debian_like; then
  echo "ERROR: This script currently supports Debian/Raspberry Pi OS (apt)." >&2
  exit 1
fi

# echo "==> Installing dependencies"
# sudo apt-get update -y

# vcgencmd is provided by libraspberrypi-bin on Raspberry Pi OS / Debian.
# If you're on a non-RPi kernel/userspace, vcgencmd may not exist; the monitor
# script still logs basic RAM/disk and attempts a thermal_zone fallback.
# sudo apt-get install -y libraspberrypi-bin

echo "==> Installing monitor script to /usr/local/bin/lume-monitor"
MONITOR_SOURCE="${SCRIPT_DIR}/system/lume-monitor"
if [[ ! -f "$MONITOR_SOURCE" ]]; then
  echo "ERROR: Missing monitor script: ${MONITOR_SOURCE}" >&2
  exit 1
fi
sudo install -m 0755 "$MONITOR_SOURCE" /usr/local/bin/lume-monitor

echo "==> Installing systemd unit + timer"
UNIT_SOURCE="${SCRIPT_DIR}/system/lume-monitor.service"
TIMER_SOURCE="${SCRIPT_DIR}/system/lume-monitor.timer"

if [[ ! -f "$UNIT_SOURCE" ]]; then
  echo "ERROR: Missing systemd unit file: ${UNIT_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "$TIMER_SOURCE" ]]; then
  echo "ERROR: Missing systemd timer file: ${TIMER_SOURCE}" >&2
  exit 1
fi

sudo install -m 0644 "$UNIT_SOURCE" /etc/systemd/system/lume-monitor.service
sudo install -m 0644 "$TIMER_SOURCE" /etc/systemd/system/lume-monitor.timer

sudo systemctl daemon-reload
sudo systemctl enable --now lume-monitor.timer

echo ""
echo "============================================================"
echo " Setup complete."
echo " - Timer:   sudo systemctl status lume-monitor.timer"
echo " - Run now: sudo systemctl start lume-monitor.service"
echo " - Logs:    sudo journalctl -u lume-monitor.service -n 200 --no-pager"
echo "============================================================"