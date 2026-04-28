#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Wi-Fi Access Point (hotspot) setup.
#
# What it does:
# - Installs hostapd + dnsmasq
# - Configures wlan0 with a static IP (192.168.4.1/24) via a small systemd unit
# - Configures dnsmasq DHCP on wlan0
# - Configures hostapd using secrets from a root-readable env file
# - Enables IPv4 forwarding + NAT (wlan0 -> eth0)
# - Enables and starts services
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).
#
# Secrets:
# - Do NOT pass SSID/PSK on the command line.
# - Create /etc/lume-wifi-ap.env from ./wifi-ap.env.sample (placeholders only in repo).

usage() {
  cat <<'USAGE'
Usage:
  setup-wifi.sh [--env-file <path>] [--no-nat]

Options:
  --env-file <path>   Env file with LUME_WIFI_AP_SSID / LUME_WIFI_AP_PSK (default: /etc/lume-wifi-ap.env)
  --no-nat            Do not configure IP forwarding + NAT (clients won't get internet via eth0)
  -h, --help          Show this help

Expected environment file keys:
  LUME_WIFI_AP_SSID
  LUME_WIFI_AP_PSK         # 8..63 characters
  LUME_WIFI_AP_COUNTRY     # e.g. DE, US, GB

Examples:
  sudo ./setup-wifi.sh

Notes:
  - This script configures wlan0 as an AP on 192.168.4.1/24.
  - If you previously used wlan0 as a Wi-Fi client, it may conflict.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENV_FILE="/etc/lume-wifi-ap.env"
ENABLE_NAT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --no-nat)
      ENABLE_NAT=0
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

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

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Env file not found: $ENV_FILE" >&2
  echo "Create it from the repo sample (run these on the Pi):" >&2
  echo "  cd ~/lume-pi" >&2
  echo "  sudo install -m 600 -o root -g root ./wifi-ap.env.sample $ENV_FILE" >&2
  echo "  sudo nano $ENV_FILE" >&2
  exit 1
fi

echo "==> Installing packages (hostapd, dnsmasq, iptables-persistent, envsubst)"
sudo apt-get update -y
sudo apt-get install -y hostapd dnsmasq iptables-persistent gettext-base

echo "==> Configuring wlan0 static IP via systemd (192.168.4.1/24)"
WIFI_IP_SERVICE_SOURCE="${SCRIPT_DIR}/system/wifi/lume-wifi-ap-ip.service"
if [[ ! -f "$WIFI_IP_SERVICE_SOURCE" ]]; then
  echo "ERROR: Missing systemd unit source: ${WIFI_IP_SERVICE_SOURCE}" >&2
  exit 1
fi
sudo install -m 0644 "$WIFI_IP_SERVICE_SOURCE" /etc/systemd/system/lume-wifi-ap-ip.service

sudo systemctl daemon-reload
sudo systemctl enable --now lume-wifi-ap-ip.service

echo "==> Configuring dnsmasq (DHCP on wlan0)"
DNSMASQ_CONF_SOURCE="${SCRIPT_DIR}/system/wifi/dnsmasq.d/lume-ap.conf"
if [[ ! -f "$DNSMASQ_CONF_SOURCE" ]]; then
  echo "ERROR: Missing dnsmasq config source: ${DNSMASQ_CONF_SOURCE}" >&2
  exit 1
fi
sudo install -m 0644 "$DNSMASQ_CONF_SOURCE" /etc/dnsmasq.d/lume-ap.conf

# Ensure dnsmasq starts AFTER wlan0 has its static IP.
# Otherwise, with bind-interfaces, dnsmasq may not bind DHCP to wlan0 on boot.
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
DNSMASQ_DROPIN_SOURCE="${SCRIPT_DIR}/system/wifi/dnsmasq.service.d/lume-ap.conf"
if [[ ! -f "$DNSMASQ_DROPIN_SOURCE" ]]; then
  echo "ERROR: Missing dnsmasq drop-in source: ${DNSMASQ_DROPIN_SOURCE}" >&2
  exit 1
fi
sudo install -m 0644 "$DNSMASQ_DROPIN_SOURCE" /etc/systemd/system/dnsmasq.service.d/lume-ap.conf

echo "==> Configuring hostapd (SSID/PSK sourced from env file)"
HOSTAPD_TEMPLATE_SOURCE="${SCRIPT_DIR}/system/wifi/hostapd/hostapd.conf.template"
if [[ ! -f "$HOSTAPD_TEMPLATE_SOURCE" ]]; then
  echo "ERROR: Missing hostapd template source: ${HOSTAPD_TEMPLATE_SOURCE}" >&2
  exit 1
fi
sudo install -m 0644 "$HOSTAPD_TEMPLATE_SOURCE" /etc/hostapd/hostapd.conf.template

# Generate /etc/hostapd/hostapd.conf from template + env file.
# Keep secrets out of this repo; writing them into /etc is expected.
sudo bash -lc "set -a; source '$ENV_FILE'; set +a; envsubst < /etc/hostapd/hostapd.conf.template > /etc/hostapd/hostapd.conf"
sudo chmod 600 /etc/hostapd/hostapd.conf

echo "==> Pointing hostapd at /etc/hostapd/hostapd.conf"
if sudo grep -qE '^[[:space:]]*DAEMON_CONF=' /etc/default/hostapd; then
  sudo sed -i.bak -E 's|^[[:space:]]*DAEMON_CONF=.*$|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd >/dev/null
fi

if [[ "$ENABLE_NAT" -eq 1 ]]; then
  echo "==> Enabling IPv4 forwarding"
  SYSCTL_SOURCE="${SCRIPT_DIR}/system/wifi/sysctl.d/99-lume-ap.conf"
  if [[ ! -f "$SYSCTL_SOURCE" ]]; then
    echo "ERROR: Missing sysctl config source: ${SYSCTL_SOURCE}" >&2
    exit 1
  fi
  sudo install -m 0644 "$SYSCTL_SOURCE" /etc/sysctl.d/99-lume-ap.conf
  sudo sysctl -p /etc/sysctl.d/99-lume-ap.conf >/dev/null

  echo "==> Configuring NAT + forwarding rules (wlan0 -> eth0)"
  # NAT
  sudo iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

  # Forwarding
  sudo iptables -C FORWARD -i eth0 -o wlan0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -i eth0 -o wlan0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  sudo iptables -C FORWARD -i wlan0 -o eth0 -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

  sudo netfilter-persistent save >/dev/null
else
  echo "==> --no-nat requested; skipping IP forwarding + NAT"
fi

echo "==> Enabling and starting services"
sudo systemctl daemon-reload

# Ensure hostapd starts AFTER wlan0 has its static IP.
sudo mkdir -p /etc/systemd/system/hostapd.service.d
HOSTAPD_DROPIN_SOURCE="${SCRIPT_DIR}/system/wifi/hostapd.service.d/lume-ap.conf"
if [[ ! -f "$HOSTAPD_DROPIN_SOURCE" ]]; then
  echo "ERROR: Missing hostapd drop-in source: ${HOSTAPD_DROPIN_SOURCE}" >&2
  exit 1
fi
sudo install -m 0644 "$HOSTAPD_DROPIN_SOURCE" /etc/systemd/system/hostapd.service.d/lume-ap.conf

sudo systemctl unmask hostapd >/dev/null 2>&1 || true
sudo systemctl enable --now dnsmasq
sudo systemctl enable --now hostapd

# On first install, dnsmasq/hostapd may have started before configs existed or
# before wlan0 had its IP. Restart them so the AP is usable immediately.
sudo systemctl restart dnsmasq
sudo systemctl restart hostapd

echo ""
echo "============================================================"
echo " Setup complete."
echo " - Hotspot IP: 192.168.4.1"
echo " - Dashboard:  http://192.168.4.1/control"
echo " - Player:     http://192.168.4.1/playr"
echo " - Core health:http://192.168.4.1/up"
echo ""
echo "Troubleshooting:"
echo "  sudo systemctl status hostapd dnsmasq lume-wifi-ap-ip --no-pager"
echo "  sudo journalctl -u hostapd -n 200 --no-pager"
echo "============================================================"
