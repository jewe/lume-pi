#!/usr/bin/env bash
set -euo pipefail

# Install + enroll this Raspberry Pi into a Tailscale tailnet.
#
# Default behavior: interactive login (prints a URL).
#
# Usage:
#   ./setup-tailscale.sh
#   ./setup-tailscale.sh --authkey <TS_AUTHKEY>
#
# Environment:
#   This script optionally loads lume-pi/.env.
#   Supported keys:
#     TS_AUTHKEY               # optional; if set, performs non-interactive login
#     TS_ARGS                  # optional; extra args appended to `tailscale up`
#
# Notes:
# - Requires sudo for package installs + enabling the service.
# - We intentionally do NOT enable Tailscale SSH by default.

usage() {
  cat <<'USAGE'
Usage:
  setup-tailscale.sh [--authkey <key>] [--force]

Options:
  --authkey <key>  Use a Tailscale auth key for non-interactive enrollment.
                   If omitted, `tailscale up` will print a login URL.
  --force          Re-run `tailscale up` even if the node is already logged in.
  -h, --help       Show this help.

Environment (optional):
  setup-tailscale.sh optionally loads lume-pi/.env. CLI flags override env vars.
  Supported keys:
    TS_AUTHKEY
    TS_ARGS

Examples:
  ./setup-tailscale.sh
  ./setup-tailscale.sh --authkey tskey-auth-xxxxxxxx

USAGE
}

AUTHKEY=""
FORCE=0

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

is_debian_like() {
  [[ -f /etc/debian_version ]] && has_cmd apt-get
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)
      AUTHKEY="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=1
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

if [[ -z "$AUTHKEY" && -n "${TS_AUTHKEY:-}" ]]; then
  AUTHKEY="${TS_AUTHKEY}"
fi

if ! is_debian_like; then
  echo "ERROR: This helper currently supports Debian/Raspberry Pi OS (apt)." >&2
  exit 1
fi

echo "==> Installing Tailscale (if missing)"
if has_cmd tailscale && has_cmd tailscaled; then
  echo "==> tailscale already installed: $(tailscale version 2>/dev/null || true)"
else
  sudo apt-get update -y
  sudo apt-get install -y curl ca-certificates
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> Enabling tailscaled"
sudo systemctl enable --now tailscaled

already_logged_in=0
if tailscale status >/dev/null 2>&1; then
  # If status works, we might already be logged in; check for an assigned IP.
  if tailscale ip -4 >/dev/null 2>&1; then
    already_logged_in=1
  fi
fi

if [[ "$already_logged_in" -eq 1 && "$FORCE" -ne 1 ]]; then
  echo "==> Tailscale seems already configured; skipping 'tailscale up' (use --force to re-run)"
else
  echo "==> Running 'tailscale up'"

  # Allow users to pass additional flags via env var (e.g. --advertise-tags=tag:pi)
  #
  # NOTE: This is intentionally a simple space-splitting approach (good enough
  # for flags). If you need complex quoting, prefer passing flags explicitly.
  extra_args_raw="${TS_ARGS:-}"
  extra_args=()
  if [[ -n "$extra_args_raw" ]]; then
    # shellcheck disable=SC2206
    extra_args=( $extra_args_raw )
  fi

  if [[ -n "$AUTHKEY" ]]; then
    # Non-interactive enrollment
    sudo tailscale up --authkey "$AUTHKEY" "${extra_args[@]}"
  else
    # Interactive enrollment (prints a login URL)
    sudo tailscale up "${extra_args[@]}"
  fi
fi

echo "==> Tailscale status"
tailscale status || true

ts_ip="$(tailscale ip -4 2>/dev/null || true)"
echo ""
echo "==> Useful info"
echo "- Tailscale IPv4: ${ts_ip:-<unknown>}"
echo "- Use your Tailscale device name or IP to reach the Pi:"
echo "    SSH:      ssh pi@<tailscale-name>   (or ssh pi@${ts_ip:-100.x.y.z})"
echo "    Lume API: http://<tailscale-name>:3011/up"
echo "    Dashboard:http://<tailscale-name>:3012"
echo "    Player:   http://<tailscale-name>:3014"

echo ""
echo "==> Done"
