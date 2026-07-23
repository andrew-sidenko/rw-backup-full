#!/usr/bin/env bash
# wal-timers.sh <instance> [--remove] — включает таймеры WAL для инстанса
# с интервалами из конфига инстанса (периодичность задаёт пользователь).
#
# Интервалы из instances.d/<inst>.env:
#   INST_WAL_SHIP_INTERVAL_MIN       (по умолчанию 1)  — как часто гонять спул в S3
#   INST_BASEBACKUP_INTERVAL_HOURS   (по умолчанию 24) — как часто полный базовый бэкап
#
# Реализация: шаблонные юниты + drop-in override на конкретный инстанс,
# чтобы у каждого инстанса была своя периодичность.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE="${1:-}"
MODE="${2:-install}"
[[ -n "$INSTANCE" ]] || { echo "Usage: wal-timers.sh <instance> [--remove]" >&2; exit 1; }

if [[ "$MODE" == "--remove" ]]; then
  systemctl disable --now "rw-wal-ship@${INSTANCE}.timer" 2>/dev/null || true
  systemctl disable --now "rw-basebackup@${INSTANCE}.timer" 2>/dev/null || true
  rm -rf "/etc/systemd/system/rw-wal-ship@${INSTANCE}.timer.d" \
         "/etc/systemd/system/rw-basebackup@${INSTANCE}.timer.d"
  systemctl daemon-reload
  msg OK "[${INSTANCE}] таймеры WAL удалены"
  exit 0
fi

wal_load_full_config
wal_load_instance "$INSTANCE"

ship_min="${INST_WAL_SHIP_INTERVAL_MIN:-1}"
base_h="${INST_BASEBACKUP_INTERVAL_HOURS:-24}"
[[ "$ship_min" =~ ^[0-9]+$ ]] && (( ship_min >= 1 )) || ship_min=1
[[ "$base_h" =~ ^[0-9]+$ ]] && (( base_h >= 1 )) || base_h=24

d1="/etc/systemd/system/rw-wal-ship@${INSTANCE}.timer.d"
d2="/etc/systemd/system/rw-basebackup@${INSTANCE}.timer.d"
mkdir -p "$d1" "$d2"

cat > "${d1}/override.conf" <<EOF_D1
# managed-by: rw-backup-full (интервал из instances.d/${INSTANCE}.env)
[Timer]
OnUnitActiveSec=
OnUnitActiveSec=${ship_min}min
EOF_D1

cat > "${d2}/override.conf" <<EOF_D2
# managed-by: rw-backup-full (интервал из instances.d/${INSTANCE}.env)
[Timer]
OnUnitActiveSec=
OnUnitActiveSec=${base_h}h
EOF_D2

systemctl daemon-reload
systemctl enable --now "rw-wal-ship@${INSTANCE}.timer"
systemctl enable --now "rw-basebackup@${INSTANCE}.timer"

msg OK "[${INSTANCE}] таймеры: WAL-ship каждые ${ship_min} мин, базовый бэкап каждые ${base_h} ч"
