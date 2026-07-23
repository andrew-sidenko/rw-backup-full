#!/usr/bin/env bash
# install.sh — установка rw-backup-full v4.
#
# Роли:
#   sudo ./install.sh              # прод-сервер: всё (бэкапы + WAL + PITR)
#   sudo ./install.sh --sandbox    # сервер-песочница: только проверка бэкапов
#
# Установка идемпотентна: повторный запуск обновляет скрипты и юниты,
# не трогая существующие конфиги.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="${INSTALL_DIR}/backup"
FULL_CONFIG="${INSTALL_DIR}/rw-backup-full.env"
ORIGINAL_CONFIG="${INSTALL_DIR}/config.env"
INSTANCES_DIR="${INSTALL_DIR}/instances.d"
ROLE="prod"

[[ "${1:-}" == "--sandbox" ]] && ROLE="sandbox"
[[ "$(id -u)" == "0" ]] || { echo "Запустите от root: sudo ./install.sh" >&2; exit 1; }

echo "[..] Установка rw-backup-full v4 (роль: ${ROLE})"

# --------------------------------------------------------------------------
# Зависимости
# --------------------------------------------------------------------------
missing=()
command -v docker >/dev/null 2>&1 || missing+=("docker")
command -v flock  >/dev/null 2>&1 || missing+=("util-linux (flock)")
command -v aws    >/dev/null 2>&1 || echo "[WARN] awscli не найден — выгрузка в S3 работать не будет (apt install awscli)"
command -v zstd   >/dev/null 2>&1 || echo "[WARN] zstd не найден — будет использован gzip (рекомендуется: apt install zstd)"
command -v age    >/dev/null 2>&1 || echo "[INFO] age не найден — шифрование недоступно (нужно только при INST_ENCRYPT=true)"

if (( ${#missing[@]} > 0 )); then
  echo "[ERR] Обязательные зависимости отсутствуют: ${missing[*]}" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Файлы
# --------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$INSTANCES_DIR" \
         "${INSTALL_DIR}/scripts/lib" "${INSTALL_DIR}/scripts/wal" "${INSTALL_DIR}/scripts/sandbox" \
         "${INSTALL_DIR}/config-examples/instances.d"

install -m 0755 "$SRC_DIR/scripts/rw-backup-full.sh" "$INSTALL_DIR/rw-backup-full.sh"
ln -sf "$INSTALL_DIR/rw-backup-full.sh" /usr/local/bin/rw-backup-full

install -m 0644 "$SRC_DIR/scripts/lib/wal-lib.sh" "${INSTALL_DIR}/scripts/lib/wal-lib.sh"
for f in "$SRC_DIR"/scripts/wal/*.sh; do
  install -m 0755 "$f" "${INSTALL_DIR}/scripts/wal/$(basename "$f")"
done
install -m 0755 "$SRC_DIR/scripts/sandbox/verify-backup.sh" "${INSTALL_DIR}/scripts/sandbox/verify-backup.sh"

if [[ -f "$SRC_DIR/scripts/collect-bot-structure.sh" ]]; then
  install -m 0755 "$SRC_DIR/scripts/collect-bot-structure.sh" "$INSTALL_DIR/collect-bot-structure.sh"
  ln -sf "$INSTALL_DIR/collect-bot-structure.sh" /usr/local/bin/collect-bot-structure
fi

# Примеры конфигов инстансов (сами инстансы пользователь создаёт в instances.d/)
install -m 0644 "$SRC_DIR"/config/instances.d/*.example "${INSTALL_DIR}/config-examples/instances.d/"

# --------------------------------------------------------------------------
# Конфиги (существующие не трогаем)
# --------------------------------------------------------------------------
if [[ ! -f "$FULL_CONFIG" ]]; then
  install -m 0600 "$SRC_DIR/config/rw-backup-full.env.example" "$FULL_CONFIG"
  echo "[OK] Создан $FULL_CONFIG"
else
  echo "[OK] Существующий $FULL_CONFIG сохранён"
  if ! grep -q '^FULL_WAL_S3_ENABLED=' "$FULL_CONFIG"; then
    echo "[INFO] В конфиге нет v4-параметров. Добавьте секцию WAL из:"
    echo "       ${SRC_DIR}/config/rw-backup-full.env.example (блок 'v4: WAL-архивация')"
  fi
fi

if [[ "$ROLE" == "prod" ]]; then
  if [[ ! -f "$ORIGINAL_CONFIG" ]]; then
    install -m 0600 "$SRC_DIR/config/original-config.env.example" "$ORIGINAL_CONFIG"
    echo "[WARN] Оригинального config.env не было, создан пример: $ORIGINAL_CONFIG"
  else
    echo "[OK] Оригинальный $ORIGINAL_CONFIG сохранён"
  fi

  if [[ ! -x "$INSTALL_DIR/backup-restore.sh" && ! -x /usr/local/bin/rw-backup ]]; then
    echo "[WARN] Оригинальный rw-backup (distillium) не установлен."
    echo "[WARN] Для бэкапа панели: sudo rw-backup-full install-original"
  fi
fi

# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------
if [[ "$ROLE" == "prod" ]]; then
  # Основной таймер логических бэкапов (v3, интервал правится в install-timer)
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

  # Шаблонные юниты WAL (v4); включаются per-instance через `wal-enable`
  install -m 0644 "$SRC_DIR/systemd/rw-wal-ship@.service"   /etc/systemd/system/
  install -m 0644 "$SRC_DIR/systemd/rw-wal-ship@.timer"     /etc/systemd/system/
  install -m 0644 "$SRC_DIR/systemd/rw-basebackup@.service" /etc/systemd/system/
  install -m 0644 "$SRC_DIR/systemd/rw-basebackup@.timer"   /etc/systemd/system/
fi

# Песочница ставится и на проде (можно гонять `verify --local`),
# но таймер включается только в роли sandbox.
install -m 0644 "$SRC_DIR/systemd/rw-sandbox-verify.service" /etc/systemd/system/
install -m 0644 "$SRC_DIR/systemd/rw-sandbox-verify.timer"   /etc/systemd/system/

systemctl daemon-reload || true

if [[ "$ROLE" == "sandbox" ]]; then
  systemctl enable --now rw-sandbox-verify.timer
  echo "[OK] Таймер песочницы включён (ежедневно ~05:30 + случайная задержка)"
fi

# --------------------------------------------------------------------------
# Итог
# --------------------------------------------------------------------------
echo
echo "Установлен rw-backup-full v4 (роль: ${ROLE})"
echo "Команда:  sudo rw-backup-full"
echo "Конфиг:   $FULL_CONFIG"

if [[ "$ROLE" == "prod" ]]; then
  cat <<'EOF_NEXT'

Дальнейшие шаги (прод):
  1. sudo rw-backup-full configure-s3          # внешний S3
  2. sudo rw-backup-full configure-telegram    # уведомления
  3. sudo rw-backup-full install-timer         # таймер логических бэкапов
  4. Включение WAL-архивации (на каждый инстанс):
       cp /opt/rw-backup-restore/config-examples/instances.d/panel.env.example \
          /opt/rw-backup-restore/instances.d/panel.env
       nano /opt/rw-backup-restore/instances.d/panel.env
       sudo rw-backup-full wal-enable panel    # ВНИМАНИЕ: рестарт контейнера БД
       sudo rw-backup-full basebackup panel    # первый базовый бэкап
  5. Проверка: sudo rw-backup-full wal-status

Полная инструкция: README-RU.md
EOF_NEXT
else
  cat <<'EOF_NEXT'

Дальнейшие шаги (песочница):
  1. nano /opt/rw-backup-restore/rw-backup-full.env
       — заполнить FULL_EXTERNAL_S3_* (доступ на ЧТЕНИЕ того же бакета)
       — при шифровании: SANDBOX_AGE_IDENTITY=/root/.config/age/backup.key
  2. Скопировать instances.d/*.env с прода (описания инстансов для PITR-проверок):
       scp prod:/opt/rw-backup-restore/instances.d/*.env /opt/rw-backup-restore/instances.d/
  3. Пробный прогон: sudo rw-backup-full verify
  4. Дальше проверка идёт сама по таймеру rw-sandbox-verify.timer

Полная инструкция: README-RU.md, раздел «Песочница»
EOF_NEXT
fi
