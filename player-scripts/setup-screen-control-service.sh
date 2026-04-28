#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi screen-control service setup.
#
# What it does:
# - Installs Node.js if missing (apt)
# - Writes a small HTTP service to:
#     /opt/lume/screen-control/screen-service.js
# - Installs and enables systemd unit:
#     /etc/systemd/system/screen-control.service
#
# Prereq:
# - Expects /usr/local/bin/lume-display-control to exist.
#   (Installed by lume-pi/setup-screen-control.sh)
#
# The service listens on 127.0.0.1:3333 and supports:
# - POST /screen/off
# - POST /screen/on
#
# NOTE:
# - We intentionally keep this dependency-free (no npm install).
# - DISPLAY/XAUTHORITY handling can be adjusted later (you mentioned another
#   script will handle the display properties).

# Absolute path to this script directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repo root (one level up from player-scripts/)
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  setup-screen-control-service.sh

Notes:
  - Intended to be run on Raspberry Pi OS / Debian.
  - Requires sudo for apt installs and writing to /opt + /etc/systemd.
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

# Determine the user we should run the service as.
# Works whether the script is executed directly or via sudo.
RUN_USER=""
if [[ "$(id -u)" -eq 0 ]]; then
  RUN_USER="${SUDO_USER:-}"
  if [[ -z "$RUN_USER" ]]; then
    RUN_USER="$(logname 2>/dev/null || true)"
  fi
else
  RUN_USER="$(id -un)"
fi
RUN_USER="${RUN_USER:-pi}"

echo "==> Installing prerequisites"
sudo apt-get update -y

if ! has_cmd node; then
  echo "==> Node.js not found; installing via apt"
  sudo apt-get install -y nodejs npm
  echo "==> Node.js: $(node --version 2>/dev/null || true)"
else
  echo "==> Node.js detected: $(node --version 2>/dev/null || true)"
fi

APP_DIR="/opt/lume/screen-control"
APP_FILE="${APP_DIR}/screen-service.js"
UNIT_FILE="/etc/systemd/system/screen-control.service"

echo "==> Writing service code: ${APP_FILE}"
sudo mkdir -p "$APP_DIR"

APP_SOURCE="${REPO_DIR}/system/screen-control/screen-service.js"
if [[ ! -f "$APP_SOURCE" ]]; then
  echo "ERROR: Missing app source: ${APP_SOURCE}" >&2
  exit 1
fi
sudo install -m 0644 "$APP_SOURCE" "$APP_FILE"
sudo chmod 0644 "$APP_FILE"

echo "==> Installing systemd unit: ${UNIT_FILE}"

UNIT_SOURCE="${REPO_DIR}/system/screen-control/screen-control.service.template"
if [[ ! -f "$UNIT_SOURCE" ]]; then
  echo "ERROR: Missing systemd template: ${UNIT_SOURCE}" >&2
  exit 1
fi

sudo install -m 0644 "$UNIT_SOURCE" "$UNIT_FILE"

# Apply runtime values.
# Escape for sed replacement: backslash, ampersand, and the delimiter (#).
escaped_run_user="$(printf '%s' "$RUN_USER" | sed 's/[\\&#]/\\\\&/g')"
escaped_app_file="$(printf '%s' "$APP_FILE" | sed 's/[\\&#]/\\\\&/g')"

sudo sed -i \
  -e "s#__RUN_USER__#${escaped_run_user}#g" \
  -e "s#__APP_FILE__#${escaped_app_file}#g" \
  "$UNIT_FILE"

echo "==> Enabling + starting screen-control.service"
sudo systemctl daemon-reload
sudo systemctl enable --now screen-control.service

echo ""
echo "============================================================"
echo " Setup complete."
echo " - Service: screen-control.service"
echo " - App: ${APP_FILE}"
echo ""
echo "Test:"
echo "  curl -XPOST http://127.0.0.1:3333/screen/off"
echo "  curl -XPOST http://127.0.0.1:3333/screen/on"
echo "Logs:"
echo "  journalctl -u screen-control -f"
echo "============================================================"