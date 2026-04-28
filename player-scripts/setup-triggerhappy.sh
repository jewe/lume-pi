#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi (optional) hotkey setup.
#
# What it does:
# - Installs triggerhappy (thd) to listen to /dev/input/event* keyboard events
# - Adds an Alt+F4 binding to stop lume-browser.service and restore tty1 login
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).

usage() {
  cat <<'USAGE'
Usage:
  setup-triggerhappy.sh

Notes:
  - Intended to be run on Raspberry Pi OS / Debian.
  - Requires sudo for apt installs and writing to /etc and /usr/local/bin.
  - Assumes you have a physical keyboard connected when you want to use Alt+F4.

Rollback:
  sudo rm -f /etc/triggerhappy/triggers.d/lume.conf
  sudo rm -f /etc/sudoers.d/lume-quit-kiosk
  sudo systemctl restart triggerhappy
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

if ! is_debian_like; then
  echo "ERROR: This script currently supports Debian/Raspberry Pi OS (apt)." >&2
  exit 1
fi

# Absolute path to this script directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repo root (one level up from player-scripts/)
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TRIGGERS_DIR="/etc/triggerhappy/triggers.d"
TRIGGER_FILE="${TRIGGERS_DIR}/lume.conf"
HELPER="/usr/local/bin/lume-quit-kiosk"
ROOT_HELPER="/usr/local/sbin/lume-quit-kiosk-root"
SUDOERS_FILE="/etc/sudoers.d/lume-quit-kiosk"

echo "==> Installing triggerhappy"
sudo apt-get update -y
sudo apt-get install -y triggerhappy

echo "==> Installing helper script: ${HELPER}"
sudo install -m 0755 "${REPO_DIR}/system/triggerhappy/lume-quit-kiosk" "${HELPER}"

echo "==> Installing root helper script: ${ROOT_HELPER}"
sudo install -m 0755 "${REPO_DIR}/system/triggerhappy/lume-quit-kiosk-root" "${ROOT_HELPER}"

echo "==> Installing sudoers rule: ${SUDOERS_FILE}"

# We need the rule to match the *actual* user triggerhappy runs as.
#
# Important: On Debian/Raspberry Pi OS the systemd unit frequently starts thd as root
# but passes `--user nobody` so the daemon *drops privileges*.
# `systemctl show -p User` won't reflect that, so we also parse ExecStart.
TH_USER=""
TH_EXECSTART=""

if has_cmd systemctl; then
  TH_EXECSTART="$(systemctl show -p ExecStart --value triggerhappy 2>/dev/null || true)"
fi

if [[ -n "$TH_EXECSTART" ]]; then
  # Example ExecStart value:
  # /usr/sbin/thd --triggers ... --user nobody --deviceglob ... ;
  # Extract the arg after '--user'.
  TH_USER="$(printf '%s' "$TH_EXECSTART" | sed -nE 's/.*[[:space:]]--user[[:space:]]+([^[:space:];]+).*/\1/p')"
fi

TH_USER="${TH_USER:-}"
if [[ -z "$TH_USER" ]]; then
  # Fallback: systemd User= (rarely set for triggerhappy)
  if has_cmd systemctl; then
    TH_USER="$(systemctl show -p User --value triggerhappy 2>/dev/null || true)"
  fi
fi

TH_USER="${TH_USER:-}"
if [[ -z "$TH_USER" ]]; then
  # Default: run as root.
  TH_USER="root"
fi

echo "==> triggerhappy ExecStart: ${TH_EXECSTART:-<unknown>}"
echo "==> Detected triggerhappy runtime user: ${TH_USER}"

# Keep it narrow: only allow this one command, and require non-interactive sudo.
sudo bash -lc "cat > '$SUDOERS_FILE' <<EOF_SUDOERS
# Allow kiosk quit hotkey to stop the browser and restore tty1.
#
# IMPORTANT:
# - Keep this limited to the single command we need.
# - This file is installed by lume-pi/player-scripts/setup-triggerhappy.sh.

${TH_USER} ALL=(root) NOPASSWD: /usr/local/sbin/lume-quit-kiosk-root
EOF_SUDOERS"
sudo chmod 0440 "$SUDOERS_FILE"

# Validate sudoers file to avoid breaking sudo.
sudo visudo -cf "$SUDOERS_FILE"

echo "==> Installing trigger config: ${TRIGGER_FILE}"
sudo mkdir -p "${TRIGGERS_DIR}"
sudo install -m 0644 "${REPO_DIR}/system/triggerhappy/lume.conf" "${TRIGGER_FILE}"

echo "==> Enabling + restarting triggerhappy"
sudo systemctl enable --now triggerhappy
sudo systemctl restart triggerhappy

echo ""
echo "============================================================"
echo " Setup complete."
echo " - Triggerhappy service: triggerhappy"
echo " - Trigger config: ${TRIGGER_FILE}"
echo ""
echo "Test on the Pi with a keyboard connected:"
echo "  Press Alt+F4 (should stop lume-browser + restore tty1 login prompt)"
echo ""
echo "Manual test (SSH):"
echo "  sudo ${HELPER}"
echo "Logs:"
echo "  journalctl -u triggerhappy -f"
echo "============================================================"
