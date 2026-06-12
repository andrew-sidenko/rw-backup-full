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
  # Миграция: дописываем ключи, появившиеся в новых версиях, не трогая существующие значения.
  added=0
  while IFS= read -r line; do
    key="${line%%=*}"
    [[ "$key" =~ ^FULL_[A-Z0-9_]+$ ]] || continue
    if ! grep -q "^${key}=" "$FULL_CONFIG"; then
      echo "$line" >> "$FULL_CONFIG"
      added=$((added + 1))
    fi
  done < "$SRC_DIR/config/rw-backup-full.env.example"
  if (( added > 0 )); then
    echo "[OK] Added $added new config key(s) to $FULL_CONFIG (defaults, review them)"
  fi
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

# Зависимости: awscli (external S3) и curl (Telegram). Ставим, если отсутствуют.
missing_pkgs=()
command -v aws  >/dev/null 2>&1 || missing_pkgs+=(awscli)
command -v curl >/dev/null 2>&1 || missing_pkgs+=(curl)

if (( ${#missing_pkgs[@]} > 0 )); then
  if command -v apt-get >/dev/null 2>&1; then
    echo "[INFO] Installing missing dependencies: ${missing_pkgs[*]}"
    apt-get update -qq || true
    if apt-get install -y "${missing_pkgs[@]}"; then
      echo "[OK] Dependencies installed: ${missing_pkgs[*]}"
    else
      echo "[WARN] Failed to install: ${missing_pkgs[*]} — install them manually"
    fi
  else
    echo "[WARN] apt-get not found; install manually: ${missing_pkgs[*]}"
  fi
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
TimeoutStartSec=2h
EOF_SERVICE

cat > /etc/systemd/system/rw-backup-full.timer <<'EOF_TIMER'
[Unit]
Description=Run rw-backup-full every configured interval

[Timer]
OnBootSec=10min
OnUnitActiveSec=3h
Persistent=true
RandomizedDelaySec=5min
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
