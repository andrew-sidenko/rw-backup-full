#!/usr/bin/env bash
# panel-backup.sh — встроенный бэкап панели Remnawave (замена оригинального
# distillium rw-backup, формат архива полностью совместим).
#
# Структура итогового remnawave_backup_<TS>.tar.gz идентична оригиналу:
#   dump_<TS>.sql.gz          — pg_dumpall -c из контейнера remnawave-db
#   remnawave_dir_<TS>.tar.gz — каталог панели (/opt/remnawave)
#   backup_meta.info          — DUMP_TYPE/DB_NAME/BACKUP_VERSION/... (нужен restore)
# Поэтому архивы v5 восстанавливаются и оригинальным скриптом, и наоборот.
#
# Настройки — ЕДИНЫЙ конфиг rw-backup-full.env (PANEL_*). Если PANEL_* не
# заданы, значения берутся из оригинального config.env (DB_USER,
# REMNALABS_ROOT_DIR и т.д.) — настройки не дублируются.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

wal_load_full_config

# Единые настройки с fallback на оригинальный config.env (без дублирования).
PANEL_DB_CONTAINER="${PANEL_DB_CONTAINER:-remnawave-db}"
PANEL_CONTAINER="${PANEL_CONTAINER:-remnawave}"
PANEL_DB_USER="${PANEL_DB_USER:-${DB_USER:-postgres}}"
PANEL_ROOT_DIR="${PANEL_ROOT_DIR:-${REMNALABS_ROOT_DIR:-/opt/remnawave}}"
PANEL_EXCLUDES="${PANEL_EXCLUDES:-${BACKUP_EXCLUDE_PATTERNS:-*.log *.tmp .git}}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
LOCAL_RETENTION_DAYS="${FULL_LOCAL_RETENTION_DAYS:-3}"

mkdir -p "$BACKUP_DIR"
wal_lock "panel-backup" || exit 0

TS="$(date +%Y-%m-%d"_"%H_%M_%S)"   # формат оригинала
DUMP_FILE="dump_${TS}.sql.gz"
DIR_ARCHIVE="remnawave_dir_${TS}.tar.gz"
FINAL="remnawave_backup_${TS}.tar.gz"
WORK="$(mktemp -d "${BACKUP_DIR}/.panel.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  msg ERR "Panel backup: $1"
  wal_metric_write "rw_panel_backup" <<EOF_M
# HELP rw_panel_backup_last_result Результат последнего бэкапа панели (1 — успех).
# TYPE rw_panel_backup_last_result gauge
rw_panel_backup_last_result 0
EOF_M
  wal_notify "❌ Бэкап панели не выполнен
Хост: $(wal_hostname)
Причина: $1"
  exit 1
}

# --------------------------------------------------------------------------
# 1. Дамп БД (pg_dumpall -c, как в оригинале)
# --------------------------------------------------------------------------
docker ps --format '{{.Names}}' | grep -Fxq "$PANEL_DB_CONTAINER" \
  || fail "контейнер ${PANEL_DB_CONTAINER} не запущен"

msg INFO "Дамп БД панели (pg_dumpall, ${PANEL_DB_CONTAINER})..."
if ! docker exec "$PANEL_DB_CONTAINER" pg_dumpall -c -U "$PANEL_DB_USER" 2>"${WORK}/dump.err" \
     | gzip -9 > "${WORK}/${DUMP_FILE}"; then
  fail "pg_dumpall: $(tail -n2 "${WORK}/dump.err" | tr '\n' ' ')"
fi
dump_bytes="$(stat -c %s "${WORK}/${DUMP_FILE}")"
(( dump_bytes > 100 )) || fail "дамп подозрительно мал (${dump_bytes} байт)"

# --------------------------------------------------------------------------
# 2. Каталог панели
# --------------------------------------------------------------------------
[[ -d "$PANEL_ROOT_DIR" ]] || fail "каталог панели не найден: ${PANEL_ROOT_DIR}"

msg INFO "Архив каталога ${PANEL_ROOT_DIR}..."
exargs=()
for pat in $PANEL_EXCLUDES; do exargs+=(--exclude="$pat"); done
tar -czf "${WORK}/${DIR_ARCHIVE}" "${exargs[@]}" \
    -C "$(dirname "$PANEL_ROOT_DIR")" "$(basename "$PANEL_ROOT_DIR")" \
  || fail "tar каталога панели"

# --------------------------------------------------------------------------
# 3. Метаданные (совместимы с restore оригинала)
# --------------------------------------------------------------------------
panel_version="$(docker exec "$PANEL_CONTAINER" sh -c \
  "sed -n 's/.*\"version\"[: ]*\"\\([^\"]*\\)\".*/\\1/p' package.json 2>/dev/null | head -n1" 2>/dev/null || true)"

cat > "${WORK}/backup_meta.info" <<EOF_META
DUMP_TYPE=dumpall
DB_CONNECTION_TYPE=docker
DB_NAME=${DB_NAME:-postgres}
BACKUP_VERSION=5.0.0
PANEL_VERSION=${panel_version:-unknown}
TIMESTAMP=${TS}
EOF_META

# --------------------------------------------------------------------------
# 4. Финальный архив + проверка целостности
# --------------------------------------------------------------------------
tar -czf "${WORK}/${FINAL}" -C "$WORK" "$DUMP_FILE" "$DIR_ARCHIVE" backup_meta.info \
  || fail "сборка финального архива"

gzip -t "${WORK}/${FINAL}" || fail "финальный архив не проходит gzip -t"
tar -tzf "${WORK}/${FINAL}" | grep -q backup_meta.info || fail "в архиве нет backup_meta.info"

mv "${WORK}/${FINAL}" "${BACKUP_DIR}/${FINAL}"
size_h="$(du -h "${BACKUP_DIR}/${FINAL}" | awk '{print $1}')"
size_b="$(stat -c %s "${BACKUP_DIR}/${FINAL}")"
msg OK "Panel backup готов: ${BACKUP_DIR}/${FINAL} (${size_h})"

# --------------------------------------------------------------------------
# 5. Выгрузки: все S3-бэкенды категории panel + Telegram-документ
# --------------------------------------------------------------------------
s3m_upload_all "panel" "${BACKUP_DIR}/${FINAL}" "remnawave-panel" \
  || msg WARN "Ни один S3-бэкенд не принял panel backup"

# Telegram-документ (лимит Bot API 50 МБ — как в оригинале: при превышении
# файл не отправляется, шлётся предупреждение).
if truthy "${FULL_TG_SEND_PANEL_ARCHIVE:-false}" && [[ -n "${FULL_TG_BOT_TOKEN:-}" ]]; then
  if (( size_b <= 50*1024*1024 )); then
    proxy=()
    [[ -n "${FULL_TG_PROXY:-}" ]] && proxy=(--proxy "$FULL_TG_PROXY")
    thread=()
    [[ -n "${FULL_TG_MESSAGE_THREAD_ID:-}" ]] && thread=(-F "message_thread_id=${FULL_TG_MESSAGE_THREAD_ID}")
    curl -sS -m 300 "${proxy[@]}" \
      "https://api.telegram.org/bot${FULL_TG_BOT_TOKEN}/sendDocument" \
      -F "chat_id=${FULL_TG_CHAT_ID}" "${thread[@]}" \
      -F "document=@${BACKUP_DIR}/${FINAL}" \
      -F "caption=Panel backup $(wal_hostname): ${FINAL} (${size_h})" >/dev/null 2>&1 \
      && msg OK "Архив отправлен в Telegram" \
      || msg WARN "Не удалось отправить архив в Telegram"
  else
    wal_notify "⚠️ Panel backup ${FINAL} (${size_h}) больше лимита Telegram 50 МБ — файл не отправлен, доступен локально и в S3"
  fi
fi

# --------------------------------------------------------------------------
# 6. Локальная ретенция + метрики
# --------------------------------------------------------------------------
if [[ "$LOCAL_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( LOCAL_RETENTION_DAYS > 0 )); then
  find "$BACKUP_DIR" -maxdepth 1 -name 'remnawave_backup_*.tar.gz' \
    -mtime +"$LOCAL_RETENTION_DAYS" -delete 2>/dev/null || true
fi

wal_metric_write "rw_panel_backup" <<EOF_M
# HELP rw_panel_backup_last_result Результат последнего бэкапа панели (1 — успех).
# TYPE rw_panel_backup_last_result gauge
rw_panel_backup_last_result 1
# HELP rw_panel_backup_last_success_timestamp_seconds Время последнего успешного бэкапа панели.
# TYPE rw_panel_backup_last_success_timestamp_seconds gauge
rw_panel_backup_last_success_timestamp_seconds $(date +%s)
# HELP rw_panel_backup_size_bytes Размер последнего архива панели.
# TYPE rw_panel_backup_size_bytes gauge
rw_panel_backup_size_bytes ${size_b}
EOF_M

wal_notify "✅ Panel backup
Хост: $(wal_hostname)
Файл: ${FINAL}
Размер: ${size_h}
Версия панели: ${panel_version:-?}"

exit 0
