#!/usr/bin/env bash
set -euo pipefail

# Update helper for an already-installed Lume-Pi.
#
# What it does:
# - Loads runtime env from lume-pi/docker/.env (required)
# - Optionally loads setup-time env from lume-pi/.env (optional; docker registry creds)
# - Validates required runtime vars
# - Pulls the latest Docker images
# - Restarts the stack (prefers the lume-docker systemd unit when present)
#
# This script is intended to be run ON the Raspberry Pi.

usage() {
  cat <<'USAGE'
Usage:
  update-lume.sh [--docker-login] [--no-systemd]

Options:
  --docker-login   Run `docker login` before pulling images.
                  Uses DOCKER_USERNAME + DOCKER_PASSWORD (or DOCKER_TOKEN) if set.
                  Falls back to interactive login if a TTY is available.
  --no-systemd     Do not use systemd even if lume-docker.service exists; run docker compose directly.
  -h, --help       Show this help.

Examples:
  ./lume-pi/update-lume.sh
  ./lume-pi/update-lume.sh --docker-login
  ./lume-pi/update-lume.sh --no-systemd

Environment:
  Runtime configuration is loaded from (required):
    lume-pi/docker/.env

  Optional setup-time configuration is loaded from:
    lume-pi/.env

  Required runtime keys (must be present in lume-pi/docker/.env):
    RAILS_MASTER_KEY
    SECRET_KEY_BASE
    POSTGRES_PASSWORD

  Optional docker-login keys (usually stored in lume-pi/.env):
    DOCKER_REGISTRY
    DOCKER_USERNAME
    DOCKER_PASSWORD (or DOCKER_TOKEN)

USAGE
}

DOCKER_LOGIN=0
NO_SYSTEMD=0

# Absolute path to this directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/docker"

COMPOSE_ENV_FILE="${COMPOSE_DIR}/.env"
PROJECT_ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

load_env_file() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$env_file"
    set +a
  fi
}

require_var() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    echo "Missing required env var: $name" >&2
    return 1
  fi
  return 0
}

warn_if_template_hostname() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if [[ "$value" == *"lume-player.local"* ]] && [[ "$MDNS_HOSTNAME" != "lume-player.local" ]]; then
    echo "WARNING: $name contains 'lume-player.local' but this machine is '${MDNS_HOSTNAME}'." >&2
    echo "         Consider updating ${COMPOSE_ENV_FILE} so LAN clients use the correct hostname." >&2
  fi
}

maybe_docker_login() {
  # Optional registry login.
  #
  # Non-interactive mode (recommended for automation):
  #   DOCKER_REGISTRY=... DOCKER_USERNAME=... DOCKER_PASSWORD=... ./lume-pi/update-lume.sh --docker-login
  #
  # Interactive mode:
  #   ./lume-pi/update-lume.sh --docker-login
  local registry="${DOCKER_REGISTRY:-}"
  local username="${DOCKER_USERNAME:-}"
  local password="${DOCKER_PASSWORD:-${DOCKER_TOKEN:-}}"

  if [[ "$DOCKER_LOGIN" -ne 1 ]]; then
    return 0
  fi

  echo "==> Docker registry login"
  if [[ -n "$username" && -n "$password" ]]; then
    # If registry is empty, docker will default to Docker Hub.
    echo "$password" | docker login ${registry:+"$registry"} --username "$username" --password-stdin
    echo "==> docker login succeeded"
    return 0
  fi

  # Fall back to interactive login if we have a TTY.
  if [[ -t 0 ]]; then
    echo "==> No DOCKER_USERNAME/DOCKER_PASSWORD provided; starting interactive 'docker login'"
    docker login ${registry:+"$registry"}
    return 0
  fi

  echo "WARNING: --docker-login was requested but no credentials were provided and no TTY is available." >&2
  echo "         Set DOCKER_USERNAME + DOCKER_PASSWORD (or DOCKER_TOKEN) and re-run." >&2
}

systemd_unit_exists() {
  # Returns success if systemd is present and lume-docker.service is known.
  if ! has_cmd systemctl; then
    return 1
  fi

  # `systemctl status` returns non-zero for inactive units; prefer `cat`.
  systemctl cat lume-docker.service >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker-login)
      DOCKER_LOGIN=1
      shift
      ;;
    --no-systemd)
      NO_SYSTEMD=1
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

if [[ ! -d "$COMPOSE_DIR" ]]; then
  echo "ERROR: Compose directory not found: ${COMPOSE_DIR}" >&2
  exit 1
fi
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi
if [[ ! -f "$COMPOSE_ENV_FILE" ]]; then
  echo "ERROR: Runtime env file not found: ${COMPOSE_ENV_FILE}" >&2
  echo "       This script updates an existing install; please create/edit ${COMPOSE_ENV_FILE} first." >&2
  exit 1
fi

# Determine the LAN hostname users will likely reach this Pi at.
SHORT_HOSTNAME="$(hostname)"
MDNS_HOSTNAME="${SHORT_HOSTNAME}.local"

# Load optional project env (e.g., docker credentials).
load_env_file "$PROJECT_ENV_FILE"

echo "==> Validating required env vars (from ${COMPOSE_ENV_FILE})"
load_env_file "$COMPOSE_ENV_FILE"

missing=0
require_var RAILS_MASTER_KEY || missing=1
require_var SECRET_KEY_BASE || missing=1
require_var POSTGRES_PASSWORD || missing=1

# Optional but strongly recommended (so the static SPAs point at the right backend).
if [[ -z "${NUXT_PUBLIC_API_URL:-}" ]]; then
  echo "WARNING: NUXT_PUBLIC_API_URL is not set in ${COMPOSE_ENV_FILE} (frontend/player will not know where the API is)." >&2
  echo "         Example: NUXT_PUBLIC_API_URL=http://${MDNS_HOSTNAME}" >&2
fi
if [[ -z "${NUXT_PUBLIC_PLAYER_URL:-}" ]]; then
  echo "WARNING: NUXT_PUBLIC_PLAYER_URL is not set in ${COMPOSE_ENV_FILE} (frontend preview links may be wrong)." >&2
  echo "         Example: NUXT_PUBLIC_PLAYER_URL=http://${MDNS_HOSTNAME}/playr" >&2
fi

warn_if_template_hostname NUXT_PUBLIC_API_URL
warn_if_template_hostname NUXT_PUBLIC_PLAYER_URL
warn_if_template_hostname CORS_ALLOWED_ORIGINS
warn_if_template_hostname ACTION_CABLE_ALLOWED_ORIGINS

if [[ "$missing" -ne 0 ]]; then
  echo "==> Aborting due to missing required env vars. Edit ${COMPOSE_ENV_FILE} and re-run." >&2
  exit 1
fi

if ! has_cmd docker; then
  echo "ERROR: docker is not installed on this machine." >&2
  echo "Run:  ./lume-pi/setup-lume.sh --hostname <your-hostname>" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin is not available (expected 'docker compose')." >&2
  echo "Run:  ./lume-pi/setup-lume.sh" >&2
  exit 1
fi

maybe_docker_login

echo "==> Pulling images"
(
  cd "$COMPOSE_DIR"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" pull
)

echo "==> Restarting services (can take 2-3 minutes)"
if [[ "$NO_SYSTEMD" -ne 1 ]] && systemd_unit_exists; then
  echo "==> Using systemd unit: lume-docker.service"
  run_sudo systemctl restart lume-docker
else
  (
    cd "$COMPOSE_DIR"
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d
  )
fi

echo "==> Service status"
(
  cd "$COMPOSE_DIR"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" ps
)

echo "==> Restarting lume-browser.service"
if has_cmd systemctl && systemctl cat lume-browser.service >/dev/null 2>&1; then
  run_sudo systemctl restart lume-browser
else
  echo "==> Skipping lume-browser restart (service not found)"
fi

echo "==> Done"
echo "Open http://${MDNS_HOSTNAME}"
