#!/usr/bin/env bash
# sync-fleet-creds.sh — актуализация S3/Telegram реквизитов с подключённых
# серверов на песочнице.
#
# Реквизиты НЕ хранятся руками на песочнице: при каждой проверке (и по
# этой команде) манифест забирается из веб-сервиса и материализуется в
# кэш ${INSTALL_DIR}/fleet-creds/<server-id>/ (s3.d + telegram.env).
# verify-stack / ручные операции могут брать свежие креды оттуда.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

wal_load_full_config
require_component sandbox
command -v jq >/dev/null 2>&1 || { msg ERR "Нужен jq"; exit 1; }
command -v curl >/dev/null 2>&1 || { msg ERR "Нужен curl"; exit 1; }

WEB_ENV="${WEB_ENV:-/etc/rw-backup-web.env}"
WEB_URL="${RW_WEB_URL:-http://127.0.0.1:8787}"
CREDS_ROOT="${FLEET_CREDS_DIR:-${INSTALL_DIR}/fleet-creds}"
TOKEN="${WEB_TOKEN:-}"
[[ -z "$TOKEN" && -f "$WEB_ENV" ]] && TOKEN="$(grep -E '^WEB_TOKEN=' "$WEB_ENV" | head -n1 | cut -d= -f2- || true)"
[[ -n "$TOKEN" ]] || { msg ERR "WEB_TOKEN не найден (${WEB_ENV})"; exit 1; }

MANIFEST=""
for attempt in 1 2 3 4 5; do
  MANIFEST="$(curl -fsS -m 60 -H "x-token: ${TOKEN}" "${WEB_URL}/api/fleet/manifest?force=1" 2>/dev/null)" && break
  msg WARN "Веб-сервис недоступен (попытка ${attempt}/5)..."
  sleep $((attempt * 3))
  MANIFEST=""
done
[[ -n "$MANIFEST" ]] || { msg ERR "Не удалось получить манифест"; exit 1; }

mkdir -p "$CREDS_ROOT"
chmod 700 "$CREDS_ROOT"
synced=0

while IFS= read -r srv; do
  sid="$(jq -r '.id // .source // empty' <<<"$srv")"
  reachable="$(jq -r '.reachable // false' <<<"$srv")"
  [[ -n "$sid" ]] || continue
  if [[ "$reachable" != "true" ]]; then
    msg WARN "Сервер ${sid}: недоступен — креды не обновлены"
    continue
  fi
  dest="${CREDS_ROOT}/${sid}"
  mkdir -p "${dest}/s3.d"
  chmod 700 "$dest"

  # Telegram этого сервера
  {
    echo "# synced $(date -u +%Y-%m-%dT%H:%M:%SZ) from fleet manifest"
    echo "FULL_TG_BOT_TOKEN=\"$(jq -r '.telegram.token // empty' <<<"$srv")\""
    echo "FULL_TG_CHAT_ID=\"$(jq -r '.telegram.chat_id // empty' <<<"$srv")\""
    echo "FULL_TG_MESSAGE_THREAD_ID=\"$(jq -r '.telegram.thread_id // empty' <<<"$srv")\""
    echo "RW_SOURCE_ID=\"$(jq -r '.source // .id' <<<"$srv")\""
  } > "${dest}/telegram.env"
  chmod 600 "${dest}/telegram.env"

  # S3-бэкенды
  rm -f "${dest}/s3.d/"*.env 2>/dev/null || true
  while IFS= read -r bj; do
    bname="$(jq -r '.name' <<<"$bj")"
    [[ -n "$bname" && "$bname" != null ]] || continue
    cat > "${dest}/s3.d/${bname}.env" <<EOF
# synced $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${sid}
B_ENABLED="$(jq -r 'if .enabled==false then "false" else "true" end' <<<"$bj")"
B_ENDPOINT="$(jq -r '.endpoint // empty' <<<"$bj")"
B_BUCKET="$(jq -r '.bucket // empty' <<<"$bj")"
B_ACCESS_KEY="$(jq -r '.access_key // empty' <<<"$bj")"
B_SECRET_KEY="$(jq -r '.secret_key // empty' <<<"$bj")"
B_REGION="$(jq -r '.region // "us-east-1"' <<<"$bj")"
B_PREFIX="$(jq -r '.prefix // "rw-backup-full"' <<<"$bj")"
B_UPLOAD_PANEL="$(jq -r 'if .panel==false then "false" else "true" end' <<<"$bj")"
B_UPLOAD_CUSTOM="$(jq -r 'if .custom==false then "false" else "true" end' <<<"$bj")"
B_UPLOAD_WAL="$(jq -r 'if .wal==false then "false" else "true" end' <<<"$bj")"
EOF
    chmod 600 "${dest}/s3.d/${bname}.env"
  done < <(jq -c '.backends[]?' <<<"$srv")

  echo "$(date +%s)" > "${dest}/synced_at"
  chmod 600 "${dest}/synced_at"
  synced=$((synced+1))
  msg OK "Креды ${sid}: $(jq -r '.backends|length' <<<"$srv") бэкенд(ов), TG=$(jq -r 'if (.telegram.token//"")!="" then "да" else "нет" end' <<<"$srv")"
done < <(jq -c '.servers[]?' <<<"$MANIFEST")

msg OK "Синхронизировано серверов: ${synced} → ${CREDS_ROOT}"
echo "$synced"
