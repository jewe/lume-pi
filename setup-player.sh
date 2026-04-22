#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi (optional) player kiosk setup.
#
# What it does:
# - Installs Cog (WebKit kiosk browser) + required DRM/KMS deps
# - Ensures full KMS is enabled in the Pi boot config
# - Adds the run user to the video/render groups
# - Installs + enables a systemd service that launches the Lume Player URL on boot
#
# URL:
# - Reads LUME_HOSTNAME from lume-pi/.env
# - If LUME_HOSTNAME looks like a base hostname (no dots), we assume mDNS and open: http://${LUME_HOSTNAME}.local:3014
# - If it already contains a dot (e.g. lume-player.local) or is an IP, it is used as-is.
# - Always opens: http://<resolved-host>:3014
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).

usage() {
  cat <<'USAGE'
Usage:
  setup-player.sh

Environment:
  setup-player.sh optionally loads lume-pi/.env.
  Supported keys:
    LUME_HOSTNAME=...     # base hostname (e.g. lume-player); will open http://<hostname>.local:3014 by default
                          # If you set a FQDN/IP (e.g. lume-player.local / 192.168.1.10), it is used as-is.

Notes:
  - Requires sudo for apt installs, boot config edits, and systemd installation.
  - If the browser does not appear after reboot, try changing DRM_DEVICE in /etc/lume-browser.conf
    from /dev/dri/card1 to /dev/dri/card0.
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
PROJECT_ENV_FILE="${SCRIPT_DIR}/.env"

load_env_file() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$env_file"
    set +a
  fi
}

load_env_file "$PROJECT_ENV_FILE"

# Determine the user we should run cog as / add to groups.
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
RUN_USER="${RUN_USER:-root}"

LUME_HOSTNAME_VALUE="${LUME_HOSTNAME:-}"
KIOSK_HOST=""
if [[ -n "$LUME_HOSTNAME_VALUE" ]]; then
  # If the hostname already looks fully-qualified (contains a dot) or is localhost,
  # use it as-is. Otherwise, assume mDNS and append .local.
  #
  # NOTE: If you use an IPv6 literal, it must be bracketed in URLs.
  # We auto-bracket values that look like IPv6 (contain multiple ':').
  if [[ "$LUME_HOSTNAME_VALUE" == "localhost" || "$LUME_HOSTNAME_VALUE" == *.* ]]; then
    KIOSK_HOST="$LUME_HOSTNAME_VALUE"
  elif [[ "$LUME_HOSTNAME_VALUE" == *:*:* ]]; then
    # Likely an IPv6 literal
    # Detect already-bracketed IPv6 literal: [::1]
    if [[ "$LUME_HOSTNAME_VALUE" == "[[]"*"]" ]]; then
      KIOSK_HOST="$LUME_HOSTNAME_VALUE"
    else
      KIOSK_HOST="[${LUME_HOSTNAME_VALUE}]"
    fi
  else
    KIOSK_HOST="${LUME_HOSTNAME_VALUE}.local"
  fi
else
  # Fallback for purely local installs.
  KIOSK_HOST="lume-player.local"
fi

KIOSK_URL="http://${KIOSK_HOST}:3014/?playerId=1&debug=0"

if ! is_debian_like; then
  echo "ERROR: This script currently supports Debian/Raspberry Pi OS (apt)." >&2
  exit 1
fi

echo "==> Installing Cog + DRM/KMS dependencies"
sudo apt-get update -y
sudo apt-get install -y \
  cog \
  libdrm2 \
  libgbm1 \
  libinput10 \
  libudev1 \
  libwpe-1.0-1 \
  libwpebackend-fdo-1.0-1 \
  mesa-utils \
  v4l-utils

echo "==> Configuring KMS (vc4-kms-v3d)"
BOOT_CONFIG=""
if [[ -f /boot/firmware/config.txt ]]; then
  BOOT_CONFIG="/boot/firmware/config.txt"
elif [[ -f /boot/config.txt ]]; then
  BOOT_CONFIG="/boot/config.txt"
else
  echo "WARNING: Could not find /boot/firmware/config.txt or /boot/config.txt; skipping KMS config." >&2
fi

if [[ -n "$BOOT_CONFIG" ]]; then
  # Remove conflicting fake-KMS overlay if present
  sudo sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d  # disabled by setup-player.sh/' "$BOOT_CONFIG"

  # Add full KMS overlay if not already present
  if ! sudo grep -q "^dtoverlay=vc4-kms-v3d" "$BOOT_CONFIG"; then
    sudo bash -lc "printf '\n# Added by setup-player.sh\ndtoverlay=vc4-kms-v3d\n' >> '$BOOT_CONFIG'"
  fi

  # Ensure enough GPU memory
  if ! sudo grep -q "^gpu_mem" "$BOOT_CONFIG"; then
    sudo bash -lc "printf 'gpu_mem=128\n' >> '$BOOT_CONFIG'"
  else
    sudo sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$BOOT_CONFIG"
  fi
fi

echo "==> Adding user '$RUN_USER' to video + render groups"
if [[ "$RUN_USER" != "root" ]]; then
  EXTRA_GROUPS=(video render)

  # 'input' is often required to read /dev/input/event* (libinput) on Debian/RPi OS.
  # Some minimal systems may not have the group, so check first.
  if getent group input >/dev/null 2>&1; then
    EXTRA_GROUPS+=(input)
  fi

  sudo usermod -aG "$(IFS=,; echo "${EXTRA_GROUPS[*]}")" "$RUN_USER"
else
  # root does not need group changes, but keep output consistent.
  true
fi

echo "==> Writing /etc/lume-browser.conf"

CONF_SOURCE="${SCRIPT_DIR}/system/lume-browser.conf.template"
if [[ ! -f "$CONF_SOURCE" ]]; then
  echo "ERROR: Missing config template: ${CONF_SOURCE}" >&2
  exit 1
fi

sudo install -m 0644 "$CONF_SOURCE" /etc/lume-browser.conf

# Replace placeholder with computed URL.
# Escape for sed replacement: backslash, ampersand, and the delimiter (#).
escaped_kiosk_url="$(printf '%s' "$KIOSK_URL" | sed 's/[\\&#]/\\\\&/g')"
sudo sed -i "s#__KIOSK_URL__#${escaped_kiosk_url}#g" /etc/lume-browser.conf

echo "==> Installing systemd unit: lume-browser.service"

# IMPORTANT: This file is a known-good version from testing.
# Do not inline/modify it here; install it verbatim.
UNIT_SOURCE="${SCRIPT_DIR}/system/lume-browser.service"
if [[ ! -f "$UNIT_SOURCE" ]]; then
  echo "ERROR: Missing systemd unit file: ${UNIT_SOURCE}" >&2
  exit 1
fi

sudo install -m 0644 "$UNIT_SOURCE" /etc/systemd/system/lume-browser.service

sudo systemctl daemon-reload
sudo systemctl enable --now lume-browser.service

echo ""
echo "============================================================"
echo " Setup complete."
echo " - URL: ${KIOSK_URL}"
echo " - Service: sudo systemctl status lume-browser.service"
echo " - Config: /etc/lume-browser.conf"
echo ""
echo "If you changed KMS settings, reboot is recommended."
echo "============================================================"
