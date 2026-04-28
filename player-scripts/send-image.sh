#!/bin/sh
set -eu

# Send an image to Telegram (via bot API).
#
# Reads credentials from `lume-pi/.env`:
# - TELEGRAM_BOT_TOKEN
# - TELEGRAM_CHAT_ID
#
# Usage:
#   ./send-image.sh ./screen.png
#   ./send-image.sh ./screen.png "optional caption"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

IMAGE_PATH="${1:-}"
CAPTION="${2:-}"

if [ -z "$IMAGE_PATH" ]; then
  echo "Usage: $0 <image-path> [caption]" >&2
  exit 2
fi

if [ ! -f "$IMAGE_PATH" ]; then
  echo "Image not found: $IMAGE_PATH" >&2
  exit 2
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "Missing TELEGRAM_BOT_TOKEN (set it in ${ENV_FILE})" >&2
  exit 2
fi

if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "Missing TELEGRAM_CHAT_ID (set it in ${ENV_FILE})" >&2
  exit 2
fi

if [ -z "$CAPTION" ]; then
  # Portable ISO-8601-ish timestamp (works on BusyBox/date variants too)
  CAPTION="$(hostname): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
  -F "chat_id=${TELEGRAM_CHAT_ID}" \
  -F "photo=@${IMAGE_PATH}" \
  -F "caption=${CAPTION}"
