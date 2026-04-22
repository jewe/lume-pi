#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi (optional) Borg backup setup for the Lume docker stack.
#
# What it does:
# - Installs borgbackup (apt)
# - Writes a secrets template to /etc/backup-secrets (root:root, 600)
# - Installs:
#   - /usr/local/bin/lume-backup          (creates borg archives)
#   - /usr/local/bin/lume-restore-backup  (guided restore)
#   - /etc/systemd/system/lume-backup.service
#   - /etc/systemd/system/lume-backup.timer
# - Enables and starts the timer.
#
# This script is intended to be run ON the Raspberry Pi (Raspberry Pi OS / Debian).

usage() {
  cat <<'USAGE'
Usage:
  setup-backup.sh

Notes:
  - Requires sudo for apt installs, writing /usr/local/bin and /etc/systemd.
  - Runtime compose env is read from: lume-pi/docker/.env
  - Borg secrets are read from: /etc/backup-secrets

After running:
  sudo nano /etc/backup-secrets
  sudo systemctl list-timers | grep lume-backup
  sudo journalctl -u lume-backup -n 200 --no-pager

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

run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_sudo_as() {
  local user="$1"
  shift

  # We intentionally use sudo here even if we're already root.
  # This lets us reliably run commands as a non-root user.
  sudo -u "$user" "$@"
}

# Determine the user who is running setup (for sane defaults in installed helper scripts).
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

# Primary group for RUN_USER (may not always equal the username).
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || true)"
RUN_GROUP="${RUN_GROUP:-$RUN_USER}"

RUN_HOME=""
if command -v getent >/dev/null 2>&1; then
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
fi
RUN_HOME="${RUN_HOME:-/home/${RUN_USER}}"
DEFAULT_LUME_PI_DIR="${RUN_HOME}/lume-pi"

# BorgBase typically uses SSH. We'll generate an SSH keypair for the invoking user
# (not root), so the systemd timer can run unattended using that identity.
SSH_DIR="${RUN_HOME}/.ssh"
SSH_KEY_FILE="${SSH_DIR}/id_ed25519"
SSH_PUB_FILE="${SSH_KEY_FILE}.pub"

if ! is_debian_like; then
  echo "ERROR: This script currently supports Debian/Raspberry Pi OS (apt)." >&2
  exit 1
fi

# Absolute path to this directory (intended to be copied onto the Pi).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/docker"

COMPOSE_ENV_FILE="${COMPOSE_DIR}/.env"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.pi.yml"

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
  echo "       Please create/edit ${COMPOSE_ENV_FILE} first (copy from docker/.env.sample)." >&2
  exit 1
fi

echo "==> Installing borgbackup"
run_sudo apt-get update -y
run_sudo apt-get install -y borgbackup openssh-client

echo "==> Ensuring SSH key for Borg (user: ${RUN_USER})"
run_sudo install -d -m 700 -o "$RUN_USER" -g "$RUN_GROUP" "$SSH_DIR"
if [[ ! -f "$SSH_KEY_FILE" ]]; then
  if ! has_cmd ssh-keygen; then
    echo "ERROR: ssh-keygen not found (openssh-client)." >&2
    exit 1
  fi
  run_sudo_as "$RUN_USER" ssh-keygen -t ed25519 -a 100 -f "$SSH_KEY_FILE" -N "" -C "lume-backup@$(hostname)"
  run_sudo chown "$RUN_USER:$RUN_GROUP" "$SSH_KEY_FILE" "$SSH_PUB_FILE"
  run_sudo chmod 600 "$SSH_KEY_FILE"
  run_sudo chmod 644 "$SSH_PUB_FILE"
else
  # Ensure permissions are reasonable.
  run_sudo chown "$RUN_USER:$RUN_GROUP" "$SSH_KEY_FILE" "$SSH_PUB_FILE" 2>/dev/null || true
  run_sudo chmod 600 "$SSH_KEY_FILE" 2>/dev/null || true
  run_sudo chmod 644 "$SSH_PUB_FILE" 2>/dev/null || true
fi

if [[ -f "$SSH_PUB_FILE" ]]; then
  echo "==> Borg SSH public key (add this to BorgBase): ${SSH_PUB_FILE}"
  echo "------------------------------------------------------------"
  cat "$SSH_PUB_FILE"
  echo "------------------------------------------------------------"
fi

echo "==> Writing /etc/backup-secrets (template if missing)"
if [[ ! -f /etc/backup-secrets ]]; then
  SECRETS_SOURCE="${SCRIPT_DIR}/system/backup/backup-secrets.template"
  if [[ ! -f "$SECRETS_SOURCE" ]]; then
    echo "ERROR: Missing secrets template: ${SECRETS_SOURCE}" >&2
    exit 1
  fi
  run_sudo install -m 0600 "$SECRETS_SOURCE" /etc/backup-secrets

  run_sudo chown root:root /etc/backup-secrets
  run_sudo chmod 600 /etc/backup-secrets
  echo "==> Created /etc/backup-secrets (please edit it!)"
else
  # Keep permissions tight.
  run_sudo chown root:root /etc/backup-secrets
  run_sudo chmod 600 /etc/backup-secrets
  echo "==> /etc/backup-secrets exists"
fi

echo ""
echo "============================================================"
echo " IMPORTANT: Group membership changes may require a reboot"
echo " - Added '${RUN_USER}' to groups: docker (if present), lume-backup"
echo " - If systemd backup runs but can't access docker.sock, reboot the Pi."
echo "============================================================"
echo ""

echo "==> Configuring /etc/backup-secrets access for user '${RUN_USER}'"
# Backups are run as RUN_USER, so it needs read access to borg credentials.
# We'll use a dedicated group to avoid world-readable secrets.
if ! getent group lume-backup >/dev/null 2>&1; then
  run_sudo groupadd lume-backup
fi
run_sudo chown root:lume-backup /etc/backup-secrets
run_sudo chmod 640 /etc/backup-secrets
run_sudo usermod -aG lume-backup "$RUN_USER"

# Ensure the user can run docker compose without sudo.
if getent group docker >/dev/null 2>&1; then
  run_sudo usermod -aG docker "$RUN_USER"
fi

# systemd service supplementary groups.
SUP_GROUPS="lume-backup"
if getent group docker >/dev/null 2>&1; then
  SUP_GROUPS="docker lume-backup"
fi

echo "==> Installing /usr/local/bin/lume-backup"
BACKUP_SOURCE="${SCRIPT_DIR}/system/backup/lume-backup"
if [[ ! -f "$BACKUP_SOURCE" ]]; then
  echo "ERROR: Missing backup script source: ${BACKUP_SOURCE}" >&2
  exit 1
fi
run_sudo install -m 0755 "$BACKUP_SOURCE" /usr/local/bin/lume-backup

# Replace placeholders with the current user's home-based default.
# NOTE: We use '#' as the sed delimiter below, so we only need to escape:
# - backslash (\\)
# - ampersand (&) (special in sed replacement)
# - the delimiter itself (#)
# Do NOT escape '/' here; we want a normal path like /home/user/lume-pi.
escaped_default_lume_pi_dir="$(printf '%s' "$DEFAULT_LUME_PI_DIR" | sed 's/[\\&#]/\\\\&/g')"
run_sudo sed -i "s#__DEFAULT_LUME_PI_DIR__#${escaped_default_lume_pi_dir}#g" /usr/local/bin/lume-backup

echo "==> Installing /usr/local/bin/lume-restore-backup"
RESTORE_SOURCE="${SCRIPT_DIR}/system/backup/lume-restore-backup"
if [[ ! -f "$RESTORE_SOURCE" ]]; then
  echo "ERROR: Missing restore script source: ${RESTORE_SOURCE}" >&2
  exit 1
fi
run_sudo install -m 0755 "$RESTORE_SOURCE" /usr/local/bin/lume-restore-backup

# Replace placeholders with the current user's home-based default.
run_sudo sed -i "s#__DEFAULT_LUME_PI_DIR__#${escaped_default_lume_pi_dir}#g" /usr/local/bin/lume-restore-backup

# Ensure placeholders were replaced.
if grep -q "__DEFAULT_LUME_PI_DIR__" /usr/local/bin/lume-restore-backup; then
  echo "ERROR: placeholder replacement failed in /usr/local/bin/lume-restore-backup" >&2
  exit 1
fi

# Ensure we didn't accidentally leave placeholders behind.
if grep -q "__DEFAULT_LUME_PI_DIR__" /usr/local/bin/lume-backup /usr/local/bin/lume-restore-backup; then
  echo "ERROR: placeholder replacement failed in installed scripts" >&2
  exit 1
fi

echo "==> Installing systemd unit: lume-backup.service"
SERVICE_SOURCE="${SCRIPT_DIR}/system/backup/lume-backup.service.template"
if [[ ! -f "$SERVICE_SOURCE" ]]; then
  echo "ERROR: Missing systemd template: ${SERVICE_SOURCE}" >&2
  exit 1
fi
run_sudo install -m 0644 "$SERVICE_SOURCE" /etc/systemd/system/lume-backup.service

# Apply runtime values.
# Escape for sed replacement: backslash, ampersand, and the delimiter (#).
escaped_run_user="$(printf '%s' "$RUN_USER" | sed 's/[\\&#]/\\\\&/g')"
escaped_sup_groups="$(printf '%s' "$SUP_GROUPS" | sed 's/[\\&#]/\\\\&/g')"
run_sudo sed -i \
  -e "s#__RUN_USER__#${escaped_run_user}#g" \
  -e "s#__SUP_GROUPS__#${escaped_sup_groups}#g" \
  /etc/systemd/system/lume-backup.service

echo "==> Installing systemd unit: lume-backup.timer"
TIMER_SOURCE="${SCRIPT_DIR}/system/backup/lume-backup.timer"
if [[ ! -f "$TIMER_SOURCE" ]]; then
  echo "ERROR: Missing systemd timer source: ${TIMER_SOURCE}" >&2
  exit 1
fi
run_sudo install -m 0644 "$TIMER_SOURCE" /etc/systemd/system/lume-backup.timer

# If the user configured a different schedule in secrets, apply it.
if grep -qE '^LUME_BACKUP_ONCALENDAR=' /etc/backup-secrets; then
  # shellcheck disable=SC1091
  set -a
  source /etc/backup-secrets
  set +a

  if [[ -n "${LUME_BACKUP_ONCALENDAR:-}" ]]; then
    echo "==> Applying custom OnCalendar from /etc/backup-secrets: ${LUME_BACKUP_ONCALENDAR}"
    run_sudo sed -i "s/^OnCalendar=.*/OnCalendar=${LUME_BACKUP_ONCALENDAR}/" /etc/systemd/system/lume-backup.timer
  fi
fi

echo "==> Enabling backup timer"
run_sudo systemctl daemon-reload
run_sudo systemctl enable --now lume-backup.timer

echo "==> Done"
echo "Next steps:"
echo "  1) sudo nano /etc/backup-secrets"
echo "  2) sudo -u \"$USER\" /usr/local/bin/lume-backup"
echo "  3) sudo systemctl list-timers | grep lume-backup"
