#!/usr/bin/env bash
set -euo pipefail

# Configure a static IPv4 address for eth0 via NetworkManager (Pi OS Lite / Bookworm).
#
# This helper intentionally creates/uses a *separate* NetworkManager connection
# profile (default: "lume-eth-static") so you can switch back to DHCP later.
#
# Usage:
#   ./setup-eth-static.sh
#   ./setup-eth-static.sh --ip 10.2.60.50/24 --gw 10.2.60.1 --dns "10.2.60.1 1.1.1.1"
#   ./setup-eth-static.sh --name my-static --device eth0
#
# Environment:
#   This script optionally loads lume-pi/.env.
#   Supported keys:
#     ETH_STATIC_IP            # default: 10.2.60.50/24
#     ETH_STATIC_GW            # default: 10.2.60.1
#     ETH_STATIC_DNS           # default: ""
#     ETH_STATIC_CONN_NAME     # default: lume-eth-static
#     ETH_STATIC_DEVICE        # default: eth0

usage() {
  cat <<'USAGE'
Usage:
  setup-eth-static.sh [options]

Options:
  --ip <cidr>        Static IPv4 address in CIDR notation (e.g. 10.2.60.50/24)
  --gw <ip>          IPv4 gateway (e.g. 10.2.60.1)
  --dns <"a b c">    Space-separated DNS servers (optional)
  --name <name>      NetworkManager connection name (default: lume-eth-static)
  --device <dev>     Network device (default: eth0)
  --no-activate      Only create/update the profile; do not switch connections
  --force-activate   Bring up the static profile and bring down other active profile(s) on the same device
  -h, --help         Show this help

Notes:
  - Requires NetworkManager + nmcli.
  - Switching back to DHCP later is as easy as:
      nmcli -t -f NAME,DEVICE connection show --active
      sudo nmcli con up "<your-old-dhcp-conn>" && sudo nmcli con down lume-eth-static
USAGE
}

IP_CIDR=""
GW=""
DNS=""
CONN_NAME=""
DEVICE=""
NO_ACTIVATE=0
FORCE_ACTIVATE=0

# Absolute path to this directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ENV_FILE="${SCRIPT_DIR}/.env"

load_env_file() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

load_env_file "$PROJECT_ENV_FILE"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)
      IP_CIDR="${2:-}"
      shift 2
      ;;
    --gw)
      GW="${2:-}"
      shift 2
      ;;
    --dns)
      DNS="${2:-}"
      shift 2
      ;;
    --name)
      CONN_NAME="${2:-}"
      shift 2
      ;;
    --device)
      DEVICE="${2:-}"
      shift 2
      ;;
    --no-activate)
      NO_ACTIVATE=1
      shift
      ;;
    --force-activate)
      FORCE_ACTIVATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$IP_CIDR" && -n "${ETH_STATIC_IP:-}" ]]; then
  IP_CIDR="${ETH_STATIC_IP}"
fi
if [[ -z "$GW" && -n "${ETH_STATIC_GW:-}" ]]; then
  GW="${ETH_STATIC_GW}"
fi
if [[ -z "$DNS" && -n "${ETH_STATIC_DNS:-}" ]]; then
  DNS="${ETH_STATIC_DNS}"
fi
if [[ -z "$CONN_NAME" && -n "${ETH_STATIC_CONN_NAME:-}" ]]; then
  CONN_NAME="${ETH_STATIC_CONN_NAME}"
fi
if [[ -z "$DEVICE" && -n "${ETH_STATIC_DEVICE:-}" ]]; then
  DEVICE="${ETH_STATIC_DEVICE}"
fi

IP_CIDR="${IP_CIDR:-10.2.60.50/24}"
GW="${GW:-10.2.60.1}"
CONN_NAME="${CONN_NAME:-lume-eth-static}"
DEVICE="${DEVICE:-eth0}"

if ! has_cmd nmcli; then
  echo "ERROR: nmcli not found. Is NetworkManager installed/enabled?" >&2
  exit 1
fi

if ! systemctl is-active --quiet NetworkManager; then
  echo "ERROR: NetworkManager service is not active." >&2
  exit 1
fi

echo "==> Configuring NetworkManager static profile"
echo "- Device:      ${DEVICE}"
echo "- Conn name:   ${CONN_NAME}"
echo "- IPv4:        ${IP_CIDR}"
echo "- Gateway:     ${GW}"
echo "- DNS:         ${DNS:-<unchanged>}"

if ! nmcli -t -f NAME connection show | grep -Fxq "$CONN_NAME"; then
  echo "==> Creating connection profile '$CONN_NAME'"
  # Use explicit type; for Pi OS this is typically the right type for eth0.
  sudo nmcli connection add type ethernet ifname "$DEVICE" con-name "$CONN_NAME" >/dev/null
else
  echo "==> Connection profile '$CONN_NAME' already exists; updating"
fi

echo "==> Applying IPv4 settings to '$CONN_NAME'"
sudo nmcli connection modify "$CONN_NAME" \
  connection.autoconnect yes \
  connection.interface-name "$DEVICE" \
  ipv4.method manual \
  ipv4.addresses "$IP_CIDR" \
  ipv4.gateway "$GW" \
  ipv6.method auto

if [[ -n "${DNS}" ]]; then
  # nmcli accepts space or comma-separated dns list.
  sudo nmcli connection modify "$CONN_NAME" ipv4.dns "$DNS"
fi

if [[ "$NO_ACTIVATE" -eq 1 ]]; then
  echo "==> --no-activate requested; leaving connections untouched"
  exit 0
fi

active_conn_ids=( )
while IFS= read -r line; do
  # line format: NAME:DEVICE
  active_conn_ids+=("${line%%:*}")
done < <(nmcli -t -f NAME,DEVICE connection show --active | grep -F ":${DEVICE}" || true)

if [[ "$FORCE_ACTIVATE" -eq 1 ]]; then
  echo "==> --force-activate requested; bringing down other active profile(s) on ${DEVICE}"
  for c in "${active_conn_ids[@]}"; do
    if [[ "$c" != "$CONN_NAME" ]]; then
      sudo nmcli connection down "$c" || true
    fi
  done
fi

echo "==> Bringing up '$CONN_NAME'"
sudo nmcli connection up "$CONN_NAME"

echo ""
echo "==> Status"
nmcli -t -f NAME,DEVICE,TYPE connection show --active || true
ip -br a show "$DEVICE" || true
ip route | sed -n '1,80p' || true

echo ""
echo "==> Done"
echo "To switch back later, bring up your old DHCP profile and then bring down '$CONN_NAME'."
