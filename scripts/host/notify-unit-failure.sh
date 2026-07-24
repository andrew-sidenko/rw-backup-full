#!/usr/bin/env bash
# notify-unit-failure.sh <имя юнита> — вызывается через OnFailure= у других
# юнитов. Не зависит от fleet.json/tg_summary: читает Telegram напрямую из
# rw-backup-full.env (FULL_TG_BOT_TOKEN/FULL_TG_CHAT_ID) — тех же настроек,
# что уже используются для отчётов о бэкапах. Поэтому отказ обнаруживается
# даже если про отдельный tg_summary для песочницы никто не вспомнил.
set -euo pipefail

UNIT="${1:?Usage: notify-unit-failure.sh <unit>}"
INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
FULL_CONFIG_FILE="${FULL_CONFIG_FILE:-${INSTALL_DIR}/rw-backup-full.env}"

TOKEN=""; CHAT=""
if [[ -f "$FULL_CONFIG_FILE" ]]; then
  TOKEN="$(grep -E '^FULL_TG_BOT_TOKEN=' "$FULL_CONFIG_FILE" | head -n1 | cut -d'"' -f2 || true)"
  CHAT="$(grep -E '^FULL_TG_CHAT_ID=' "$FULL_CONFIG_FILE" | head -n1 | cut -d'"' -f2 || true)"
fi
# fleet.json:settings.tg_summary — резервный канал, если основной не задан.
if [[ -z "$TOKEN" && -f "${INSTALL_DIR}/fleet.json" ]] && command -v jq >/dev/null 2>&1; then
  TOKEN="$(jq -r '.settings.tg_summary.token // ""' "${INSTALL_DIR}/fleet.json" 2>/dev/null || true)"
  CHAT="$(jq -r '.settings.tg_summary.chat_id // ""' "${INSTALL_DIR}/fleet.json" 2>/dev/null || true)"
fi

HOST="$(hostname -s 2>/dev/null || hostname)"
LOG_TAIL="$(journalctl -u "$UNIT" -n 8 --no-pager 2>/dev/null | tail -c 800 || true)"
TEXT="🔴 ${UNIT} упал на ${HOST}
$(date -u +%Y-%m-%dT%H:%M:%SZ)

${LOG_TAIL}"

if [[ -n "$TOKEN" && -n "$CHAT" ]]; then
  curl -sS -m 20 "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${CHAT}" --data-urlencode "text=${TEXT}" >/dev/null 2>&1 || true
else
  # Нет Telegram — хотя бы в системный журнал, чтобы не потеряться молча.
  logger -t rw-backup-full "АЛЕРТ: ${UNIT} упал, Telegram не настроен (FULL_TG_BOT_TOKEN/FULL_TG_CHAT_ID)"
fi
