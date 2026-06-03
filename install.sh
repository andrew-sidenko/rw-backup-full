#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/rw-backup-restore"
BIN_PATH="/usr/local/bin/rw-backup-full"
UPSTREAM_RAW_URL="https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh"
AUTO_INSTALL_ORIGINAL="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-auto-install-rw-backup)
      AUTO_INSTALL_ORIGINAL="false"
      shift
      ;;
    --help|-h)
      echo "Usage: sudo ./install.sh [--no-auto-install-rw-backup]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo ./install.sh"
  exit 1
fi

mkdir -p "$INSTALL_DIR/backup"

install -m 0755 scripts/rw-backup-full.sh "$INSTALL_DIR/rw-backup-full.sh"
ln -sf "$INSTALL_DIR/rw-backup-full.sh" "$BIN_PATH"

if [[ ! -f "$INSTALL_DIR/rw-backup-full.env" ]]; then
  install -m 0600 config/rw-backup-full.env.example "$INSTALL_DIR/rw-backup-full.env"
  echo "[OK] Created $INSTALL_DIR/rw-backup-full.env"
else
  echo "[INFO] $INSTALL_DIR/rw-backup-full.env exists, not overwritten"
fi

if [[ ! -f "$INSTALL_DIR/config.env" ]]; then
  install -m 0600 config/original-config.env.example "$INSTALL_DIR/config.env"
  echo "[WARN] Created minimal original config: $INSTALL_DIR/config.env"
  echo "[WARN] Fill Telegram/S3 settings there or run original rw-backup setup."
else
  echo "[INFO] Original $INSTALL_DIR/config.env exists, not overwritten"
fi

if [[ "$AUTO_INSTALL_ORIGINAL" == "true" ]]; then
  if [[ ! -x "$INSTALL_DIR/backup-restore.sh" && ! -x /usr/local/bin/rw-backup ]]; then
    if command -v curl >/dev/null 2>&1; then
      tmp="$(mktemp)"
      if curl -fsSL "$UPSTREAM_RAW_URL" -o "$tmp"; then
        install -m 0755 "$tmp" "$INSTALL_DIR/backup-restore.sh"
        ln -sf "$INSTALL_DIR/backup-restore.sh" /usr/local/bin/rw-backup
        echo "[OK] Original rw-backup installed"
      else
        echo "[WARN] Failed to download original rw-backup from $UPSTREAM_RAW_URL"
      fi
      rm -f "$tmp"
    else
      echo "[WARN] curl not found, original rw-backup auto-install skipped"
    fi
  else
    echo "[INFO] Original rw-backup exists, not overwritten"
  fi
fi

if [[ -d systemd ]]; then
  install -m 0644 systemd/rw-backup-full.service /etc/systemd/system/rw-backup-full.service
  install -m 0644 systemd/rw-backup-full.timer /etc/systemd/system/rw-backup-full.timer
  systemctl daemon-reload || true
  echo "[OK] systemd unit templates installed, timer is not enabled automatically"
fi

echo
 echo "[OK] Installed rw-backup-full"
echo "Next steps:"
echo "  sudo rw-backup-full config"
echo "  sudo rw-backup-full list"
echo "  sudo rw-backup-full configure"
echo "  sudo rw-backup-full install-timer"
