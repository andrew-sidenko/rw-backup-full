#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="${INSTALL_DIR}/backup"
FULL_CONFIG="${INSTALL_DIR}/rw-backup-full.env"
ORIGINAL_CONFIG="${INSTALL_DIR}/config.env"

mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"

install -m 0755 "$SRC_DIR/scripts/rw-backup-full.sh" "$INSTALL_DIR/rw-backup-full.sh"
ln -sf "$INSTALL_DIR/rw-backup-full.sh" /usr/local/bin/rw-backup-full

if [[ -f "$SRC_DIR/scripts/collect-bot-structure.sh" ]]; then
  install -m 0755 "$SRC_DIR/scripts/collect-bot-structure.sh" "$INSTALL_DIR/collect-bot-structure.sh"
  ln -sf "$INSTALL_DIR/collect-bot-structure.sh" /usr/local/bin/collect-bot-structure
fi

if [[ ! -f "$FULL_CONFIG" ]]; then
  install -m 0600 "$SRC_DIR/config/rw-backup-full.env.example" "$FULL_CONFIG"
  echo "[OK] Created $FULL_CONFIG"
else
  echo "[OK] Existing $FULL_CONFIG preserved"
fi

if [[ ! -f "$ORIGINAL_CONFIG" ]]; then
  install -m 0600 "$SRC_DIR/config/original-config.env.example" "$ORIGINAL_CONFIG"
  echo "[WARN] Original config did not exist, created example: $ORIGINAL_CONFIG"
  echo "[WARN] Fill it if you use original rw-backup panel backup."
else
  echo "[OK] Existing original $ORIGINAL_CONFIG preserved"
fi

if [[ ! -x "$INSTALL_DIR/backup-restore.sh" && ! -x /usr/local/bin/rw-backup ]]; then
  echo "[WARN] Original rw-backup is not installed."
  echo "[WARN] You can install it later: sudo rw-backup-full install-original"
fi

cat > /etc/systemd/system/rw-backup-full.service <<'EOF_SERVICE'
[Unit]
Description=rw-backup-full scheduled backup
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rw-backup-full run-timer
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF_SERVICE

cat > /etc/systemd/system/rw-backup-full.timer <<'EOF_TIMER'
[Unit]
Description=Run rw-backup-full every configured interval

[Timer]
OnBootSec=10min
OnUnitActiveSec=3h
Persistent=true
Unit=rw-backup-full.service

[Install]
WantedBy=timers.target
EOF_TIMER

systemctl daemon-reload || true

echo
 echo "Installed rw-backup-full v3"
echo "Command: sudo rw-backup-full"
echo "Config:  $FULL_CONFIG"
echo "Original rw-backup config: $ORIGINAL_CONFIG"
echo
 echo "Next steps:"
echo "  sudo rw-backup-full config"
echo "  sudo rw-backup-full configure-s3"
echo "  sudo rw-backup-full configure-telegram"
echo "  sudo rw-backup-full install-timer"
