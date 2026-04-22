#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi bootstrap helper.
#
# What it does:
# - Installs Docker Engine + docker compose plugin (if missing)
# - Optionally sets the system hostname (so you can reach the Pi as <hostname>.local)
# - Enables & starts the docker service
# - Optionally installs mDNS tooling (avahi) for hostname.local on the LAN
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).
#
# Usage:
#   setup-lume.sh --hostname lume-player
#
# Notes:
# - Requires sudo for package installs + hostname changes.
# - After setting hostname, you may need to reconnect SSH / reboot.

usage() {
  cat <<'USAGE'
Usage:
  setup-lume.sh [--hostname <name>] [--install-mdns] [--no-install-mdns] [--docker-login]

Options:
  --hostname <name>        Set the system hostname (recommended). Example: lume-player
  --install-mdns           Install avahi-daemon + mDNS NSS (default: auto)
  --no-install-mdns        Skip mDNS package installation
  --docker-login           Run `docker login` after Docker is installed (interactive if no credentials are provided)

Examples:
  setup-lume.sh --hostname lume-player 

Environment:
  setup-lume.sh optionally loads lume-pi/.env. CLI flags override env vars.
  Supported keys:
    LUME_HOSTNAME
    LUME_INSTALL_MDNS=1|0|true|false
    LUME_DOCKER_LOGIN=1|0|true|false

    DOCKER_REGISTRY
    DOCKER_USERNAME
    DOCKER_PASSWORD (or DOCKER_TOKEN)

USAGE
}

HOSTNAME_ARG=""
INSTALL_MDNS_AUTO=1
DOCKER_LOGIN=0

# Default options can be provided via lume-pi/.env.
# CLI flags always take precedence.
INSTALL_MDNS_AUTO_SET=0
DOCKER_LOGIN_SET=0

# Absolute path to this directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/docker"
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

# Load setup-time env vars (optional). This allows keeping secrets like
# DOCKER_PASSWORD out of the command line.
load_env_file "$PROJECT_ENV_FILE"

# Apply defaults from .env (if present). CLI flags override these values.
if [[ -n "${LUME_HOSTNAME:-}" ]]; then
  HOSTNAME_ARG="${LUME_HOSTNAME}"
fi

# Determine the user we should run docker-compose as / add to docker group.
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

docker_cmd() {
  # Run docker commands as the user that will later run the systemd unit.
  #
  # This matters because `docker login` stores credentials in $HOME/.docker,
  # and the `lume-docker` systemd unit runs as ${RUN_USER}.
  if [[ "$(id -u)" -eq 0 && "${RUN_USER}" != "root" ]]; then
    sudo -u "${RUN_USER}" -H docker "$@"
  else
    docker "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      HOSTNAME_ARG="${2:-}"
      shift 2
      ;;
    --install-mdns)
      INSTALL_MDNS_AUTO=1
      INSTALL_MDNS_AUTO_SET=1
      shift
      ;;
    --no-install-mdns)
      INSTALL_MDNS_AUTO=0
      INSTALL_MDNS_AUTO_SET=1
      shift
      ;;
    --docker-login)
      DOCKER_LOGIN=1
      DOCKER_LOGIN_SET=1
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

if [[ "$INSTALL_MDNS_AUTO_SET" -eq 0 ]]; then
  if [[ "${LUME_INSTALL_MDNS:-}" == "0" || "${LUME_INSTALL_MDNS:-}" == "false" ]]; then
    INSTALL_MDNS_AUTO=0
  elif [[ "${LUME_INSTALL_MDNS:-}" == "1" || "${LUME_INSTALL_MDNS:-}" == "true" ]]; then
    INSTALL_MDNS_AUTO=1
  fi
fi

if [[ "$DOCKER_LOGIN_SET" -eq 0 ]]; then
  if [[ "${LUME_DOCKER_LOGIN:-}" == "1" || "${LUME_DOCKER_LOGIN:-}" == "true" ]]; then
    DOCKER_LOGIN=1
  fi
fi

# If explicit docker registry credentials are provided, assume the user expects
# us to run `docker login`.
if [[ "$DOCKER_LOGIN_SET" -eq 0 && -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-${DOCKER_TOKEN:-}}" ]]; then
  DOCKER_LOGIN=1
fi

if [[ -n "$HOSTNAME_ARG" ]]; then
  if ! [[ "$HOSTNAME_ARG" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
    echo "Invalid hostname: '$HOSTNAME_ARG'" >&2
    echo "Hostnames may contain letters, numbers and '-' and must not start/end with '-'" >&2
    exit 1
  fi

  echo "==> Setting hostname to: $HOSTNAME_ARG"
  sudo hostnamectl set-hostname "$HOSTNAME_ARG"

  # Ensure /etc/hosts has a 127.0.1.1 entry for the hostname.
  # Keep it minimal and avoid removing any existing comments.
  if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
    sudo sed -i.bak -E "s/^127\.0\.1\.1\s+.*/127.0.1.1\t${HOSTNAME_ARG}/" /etc/hosts
  else
    echo "127.0.1.1\t${HOSTNAME_ARG}" | sudo tee -a /etc/hosts >/dev/null
  fi
  echo "==> Hostname now: $(hostname) (mDNS: ${HOSTNAME_ARG}.local)"
fi

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_debian_like() {
  [[ -f /etc/debian_version ]] && has_cmd apt-get
}

install_docker() {
  if ! is_debian_like; then
    echo "ERROR: Docker install helper currently supports Debian/Raspberry Pi OS (apt)." >&2
    exit 1
  fi

  echo "==> Installing Docker (Engine + compose plugin)"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg

  # Use Docker's official apt repo (preferred over the convenience script).
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker
}

ensure_user_in_docker_group() {
  # Ensure the invoking user can talk to the Docker daemon without sudo.
  #
  # NOTE: This must run even if Docker was already installed, otherwise users
  # will hit:
  #   permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
  if [[ -n "${RUN_USER:-}" && "${RUN_USER}" != "root" ]]; then
    if id -nG "$RUN_USER" | grep -qw docker; then
      echo "==> User '$RUN_USER' is already in the docker group"
    else
      echo "==> Adding user '$RUN_USER' to the docker group (re-login required)"
      sudo usermod -aG docker "$RUN_USER"
    fi
  fi
}

install_mdns() {
  if ! is_debian_like; then
    echo "==> Skipping mDNS install (non-Debian OS detected)"
    return 0
  fi

  echo "==> Installing mDNS (avahi) so <hostname>.local resolves on the LAN"
  sudo apt-get update -y
  sudo apt-get install -y avahi-daemon libnss-mdns
  sudo systemctl enable --now avahi-daemon
}

maybe_docker_login() {
  # Optional registry login.
  #
  # Non-interactive mode (recommended for automation):
  #   DOCKER_REGISTRY=... DOCKER_USERNAME=... DOCKER_PASSWORD=... ./pi/setup.sh --docker-login
  #
  # Interactive mode:
  #   ./pi/setup.sh --docker-login
  local registry="${DOCKER_REGISTRY:-}"
  local username="${DOCKER_USERNAME:-}"
  local password="${DOCKER_PASSWORD:-${DOCKER_TOKEN:-}}"

  if [[ "$DOCKER_LOGIN" -ne 1 ]]; then
    return 0
  fi

  echo "==> Docker registry login"
  if [[ -n "$username" && -n "$password" ]]; then
    # If registry is empty, docker will default to Docker Hub.
    echo "$password" | docker_cmd login ${registry:+"$registry"} --username "$username" --password-stdin
    echo "==> docker login succeeded"
    return 0
  fi

  # Fall back to interactive login if we have a TTY.
  if [[ -t 0 ]]; then
    echo "==> No DOCKER_USERNAME/DOCKER_PASSWORD provided; starting interactive 'docker login'"
    docker_cmd login ${registry:+"$registry"}
    return 0
  fi

  echo "WARNING: --docker-login was requested but no credentials were provided and no TTY is available." >&2
  echo "         Set DOCKER_USERNAME + DOCKER_PASSWORD (or DOCKER_TOKEN) and re-run." >&2
}

preflight_compose_pull() {
  # Fail fast if compose images can't be pulled (common cause: missing docker login).
  local compose_file="${COMPOSE_DIR}/docker-compose.pi.yml"
  local compose_env_file="${COMPOSE_DIR}/.env"

  if [[ ! -d "$COMPOSE_DIR" || ! -f "$compose_file" ]]; then
    return 0
  fi
  if [[ ! -f "$compose_env_file" ]]; then
    # Keep the existing behavior: warn elsewhere; don't hard-fail here.
    return 0
  fi
  if ! docker_cmd compose version >/dev/null 2>&1; then
    return 0
  fi

  echo "==> Preflight: pulling docker images"
  local pull_output
  if ! pull_output="$(docker_cmd compose --env-file "$compose_env_file" -f "$compose_file" pull 2>&1)"; then
    echo "ERROR: docker compose pull failed" >&2
    echo "$pull_output" >&2
    echo "" >&2
    if echo "$pull_output" | grep -qiE "unauthorized|authentication required|denied: requested access"; then
      echo "It looks like you're not logged in to the docker registry that hosts the Lume images." >&2
      echo "Re-run with --docker-login (or set LUME_DOCKER_LOGIN=1) and provide credentials via env vars:" >&2
      echo "  DOCKER_REGISTRY (optional; empty = Docker Hub)" >&2
      echo "  DOCKER_USERNAME" >&2
      echo "  DOCKER_PASSWORD (or DOCKER_TOKEN)" >&2
    fi
    exit 1
  fi
}

ensure_docker_service() {
  # Even if docker is already installed, ensure the daemon is enabled + started.
  if has_cmd systemctl; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  fi
}

install_lume_docker_service() {
  local compose_file="${COMPOSE_DIR}/docker-compose.pi.yml"
  local compose_env_file="${COMPOSE_DIR}/.env"

  if [[ ! -d "$COMPOSE_DIR" || ! -f "$compose_file" ]]; then
    echo "==> Skipping lume-docker systemd service install (compose files not found at: ${COMPOSE_DIR})"
    return 0
  fi
  if [[ ! -f "$compose_env_file" ]]; then
    echo "WARNING: ${compose_env_file} is missing; lume-docker service will still be installed, but compose may fail." >&2
  fi

  echo "==> Installing systemd unit: lume-docker"

  UNIT_SOURCE="${SCRIPT_DIR}/system/lume-docker.service.template"
  if [[ ! -f "$UNIT_SOURCE" ]]; then
    echo "ERROR: Missing systemd template: ${UNIT_SOURCE}" >&2
    exit 1
  fi

  sudo install -m 0644 "$UNIT_SOURCE" /etc/systemd/system/lume-docker.service

  # Apply runtime values.
  # Escape for sed replacement: backslash, ampersand, and the delimiter (#).
  escaped_compose_dir="$(printf '%s' "$COMPOSE_DIR" | sed 's/[\\&#]/\\\\&/g')"
  escaped_compose_env_file="$(printf '%s' "$compose_env_file" | sed 's/[\\&#]/\\\\&/g')"
  escaped_compose_file="$(printf '%s' "$compose_file" | sed 's/[\\&#]/\\\\&/g')"
  escaped_run_user="$(printf '%s' "$RUN_USER" | sed 's/[\\&#]/\\\\&/g')"

  sudo sed -i \
    -e "s#__COMPOSE_DIR__#${escaped_compose_dir}#g" \
    -e "s#__COMPOSE_ENV_FILE__#${escaped_compose_env_file}#g" \
    -e "s#__COMPOSE_FILE__#${escaped_compose_file}#g" \
    -e "s#__RUN_USER__#${escaped_run_user}#g" \
    /etc/systemd/system/lume-docker.service

  sudo systemctl daemon-reload
  sudo systemctl enable --now lume-docker
}

if has_cmd docker; then
  echo "==> Docker already installed: $(docker --version)"
  ensure_docker_service
else
  echo "==> Docker not found; installing (auto)"
  install_docker
fi

ensure_user_in_docker_group

maybe_docker_login

preflight_compose_pull

if docker compose version >/dev/null 2>&1; then
  echo "==> docker compose available: $(docker compose version --short 2>/dev/null || true)"
else
  echo "WARNING: docker compose plugin not available via 'docker compose'." >&2
  echo "         If you installed Docker via this script, something is off; please check your apt packages." >&2
fi

if [[ "$INSTALL_MDNS_AUTO" -eq 1 ]]; then
  if has_cmd avahi-daemon; then
    echo "==> avahi already installed"
  else
    install_mdns
  fi
fi

install_lume_docker_service



echo "==> Setup complete"
echo "- If your hostname was changed, reconnect SSH or reboot for it to fully propagate."
echo "- If you were added to the docker group, log out/in (or reboot) before running docker without sudo."
