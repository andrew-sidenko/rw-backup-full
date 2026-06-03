#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
BIN_LINK="${BIN_LINK:-/usr/local/bin/rw-backup-full}"
SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/rw-backup-full.sh"
CONFIG_EXAMPLE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config/config.env.example"
CONFIG_FILE="${INSTALL_DIR}/config.env"

msg() {
  echo "[install] $*"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./install.sh"
  exit 1
fi

if [[ ! -f "$SCRIPT_SRC" ]]; then
  echo "Script not found: $SCRIPT_SRC"
  exit 1
fi

msg "Creating ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/backup"

msg "Installing rw-backup-full.sh"
install -m 0755 "$SCRIPT_SRC" "${INSTALL_DIR}/rw-backup-full.sh"
ln -sf "${INSTALL_DIR}/rw-backup-full.sh" "$BIN_LINK"

if [[ ! -f "$CONFIG_FILE" ]]; then
  msg "Creating config from example: ${CONFIG_FILE}"
  install -m 0600 "$CONFIG_EXAMPLE_SRC" "$CONFIG_FILE"
else
  msg "Config exists, not overwriting: ${CONFIG_FILE}"
  if ! grep -q 'rw-backup-full custom bot settings' "$CONFIG_FILE" 2>/dev/null; then
    cat >> "$CONFIG_FILE" <<'CFG'

# ==========================================================
# rw-backup-full custom bot settings
# ==========================================================

# telegram | s3 | both | local
UPLOAD_METHOD="telegram"

# Local retention for custom_bot_*.tar.gz
RETAIN_BACKUPS_DAYS=3

# S3 retention for custom_bot_*.tar.gz
S3_RETENTION_DAYS=10
S3_RETAIN_DAYS=10

# Optional explicit Telegram aliases.
# If original config.env already has BOT_TOKEN/CHAT_ID/MESSAGE_THREAD_ID, these are not required.
# TG_BOT_TOKEN=""
# TG_CHAT_ID=""
# TG_MESSAGE_THREAD_ID=""
# TG_PROXY=""

# Optional explicit S3 aliases.
# If original config.env already has S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY, these are not required.
# S3_BUCKET=""
# S3_ACCESS_KEY=""
# S3_SECRET_KEY=""
# S3_REGION="us-east-1"
# S3_ENDPOINT=""
# S3_PREFIX="rw-backup"
CFG
    msg "Appended rw-backup-full settings block to existing config"
  fi
fi

msg "Checking syntax"
bash -n "${INSTALL_DIR}/rw-backup-full.sh"

msg "Installed: ${BIN_LINK}"
msg "Next commands:"
echo "  sudo rw-backup-full config"
echo "  sudo rw-backup-full list"
echo "  sudo rw-backup-full custom-backup"
