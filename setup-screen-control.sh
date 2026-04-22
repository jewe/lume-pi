#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi (optional) screen control setup.
#
# What it does:
# - Installs DDC/CI tooling (ddcutil + i2c-tools)
# - Runs diagnostics:
#   - ddcutil detect
#   - sudo ddcutil capabilities
# - If a DDC/CI-capable display is detected, installs a helper at:
#     /usr/local/bin/lume-display-control
#   which supports:
#     on|off|bright <0-100>
# - If no display is detected, attempts an HDMI-CEC fallback scan (cec-utils)
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).

usage() {
  cat <<'USAGE'
Usage:
  setup-screen-control.sh

Notes:
  - Requires sudo for apt installs and /usr/local/bin writes.
  - If you are added to the i2c group, a logout/login (or reboot) is required
    before you can run ddcutil without sudo.
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

# Determine the user we should add to i2c group.
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

echo "==> Installing DDC/CI tooling (ddcutil + i2c-tools)"
sudo apt-get update -y
sudo apt-get install -y ddcutil i2c-tools

if [[ "$RUN_USER" != "root" ]]; then
  if id -nG "$RUN_USER" | grep -qw i2c; then
    echo "==> User '$RUN_USER' is already in the i2c group"
  else
    echo "==> Adding user '$RUN_USER' to the i2c group (re-login required)"
    sudo usermod -aG i2c "$RUN_USER"
    echo "    NOTE: Logout/login (or reboot) required before ddcutil works without sudo."
  fi
fi

echo ""
echo "==> Diagnostic: ddcutil detect"
echo "    Explanation: discovers DDC/CI-capable displays and the I2C bus/DRM connector mapping."
echo ""

# Capture output so we can decide whether a display was detected.
DDC_DETECT_OUTPUT="$(ddcutil detect 2>&1 || true)"
echo "$DDC_DETECT_OUTPUT"

echo ""
echo "==> Diagnostic: sudo ddcutil capabilities"
echo "    Explanation: queries the monitor's MCCS/VCP feature list (e.g. brightness/power support)."
echo ""
sudo ddcutil capabilities 2>&1 || true

ddc_detected=0
if echo "$DDC_DETECT_OUTPUT" | grep -qE "^Display[[:space:]]+[0-9]+"; then
  ddc_detected=1
fi

install_display_control_helper() {
  echo "==> Installing helper: /usr/local/bin/lume-display-control"
  local helper_source
  helper_source="${SCRIPT_DIR}/system/lume-display-control"
  if [[ ! -f "$helper_source" ]]; then
    echo "ERROR: Missing helper script: ${helper_source}" >&2
    exit 1
  fi
  sudo install -m 0755 "$helper_source" /usr/local/bin/lume-display-control

  # Sanity check: fail early if the installed helper has bash syntax errors.
  # This prevents confusing runtime errors like "syntax error near unexpected token `newline'".
  sudo bash -n /usr/local/bin/lume-display-control

  echo ""
  echo "==> Try it"
  echo "  lume-display-control bright 50"
  echo "  lume-display-control off"
  echo "  lume-display-control on"
}

if [[ "$ddc_detected" -eq 1 ]]; then
  echo ""
  echo "==> DDC/CI display detected. Installing control helper."
  install_display_control_helper
  exit 0
fi

echo ""
echo "==> No DDC/CI device detected via 'ddcutil detect'."
echo "    Common causes:"
echo "    - Monitor doesn't support DDC/CI"
echo "    - DDC/CI disabled in the monitor's on-screen menu"
echo "    - Adapter/cable/dock blocks the DDC channel"
echo ""

echo "==> Installing HDMI-CEC tools (cec-utils) and scanning for CEC devices"
sudo apt-get install -y cec-utils
echo ""
echo "==> Diagnostic: HDMI-CEC scan"
echo "    Explanation: scans for HDMI-CEC devices and shows logical addresses / power state."
echo ""

# cec-client can block while listening; use a timeout so setup doesn't hang forever.
if has_cmd timeout; then
  timeout 8s bash -lc 'echo "scan" | cec-client -s -d 1' 2>&1 || true
else
  # Busybox images might not have timeout; run anyway (may require Ctrl-C).
  echo "WARNING: 'timeout' not found; running cec-client without a timeout (may block)." >&2
  echo "scan" | cec-client -s -d 1 2>&1 || true
fi

echo ""
echo "==> Done"
