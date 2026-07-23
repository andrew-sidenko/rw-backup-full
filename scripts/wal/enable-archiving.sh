#!/usr/bin/env bash
# enable-archiving.sh <instance> [--disable] — включает/выключает WAL-архивацию.
#
# Что делает:
#   1. Готовит спул на хосте и кладёт туда archive-command.sh
#   2. Создаёт docker-compose.override.yml рядом с compose проекта,
#      где пробрасывает спул в контейнер как /wal-spool
#   3. Через ALTER SYSTEM выставляет archive_mode / archive_command / archive_timeout
#   4. Пересоздаёт контейнер БД (archive_mode требует рестарта)
#   5. Проверяет сквозным тестом: переключает сегмент и ждёт его в спуле
#
# Почему override, а не правка docker-compose.yml:
# файл панели обновляется скриптами Remnawave, а compose сам подхватывает
# docker-compose.override.yml из того же каталога. Наши изменения переживают
# обновление панели и снимаются одной командой --disable.
#
# ВНИМАНИЕ для Patroni-кластеров: там параметры archive_* должны задаваться
# через DCS (patronictl edit-config), а не ALTER SYSTEM — Patroni перезапишет
# postgresql.auto.conf. Скрипт это детектирует и остановится.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE="${1:-}"
MODE="${2:-enable}"
ASSUME_YES="false"
[[ "${3:-}" == "--yes" || "$MODE" == "--yes" ]] && ASSUME_YES="true"
[[ "$MODE" == "--yes" ]] && MODE="enable"
[[ -n "$INSTANCE" ]] || { echo "Usage: enable-archiving.sh <instance> [--disable] [--yes]" >&2; exit 1; }

wal_load_full_config
wal_load_instance "$INSTANCE"

COMPOSE_FILE="${INST_COMPOSE_FILE:-}"
COMPOSE_SERVICE="${INST_COMPOSE_SERVICE:-}"

[[ -f "$COMPOSE_FILE" ]] || { msg ERR "[${INSTANCE}] compose-файл не найден: ${COMPOSE_FILE}"; exit 1; }
[[ -n "$COMPOSE_SERVICE" ]] || { msg ERR "[${INSTANCE}] INST_COMPOSE_SERVICE не задан"; exit 1; }

COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
OVERRIDE_FILE="${COMPOSE_DIR}/docker-compose.override.yml"
MARKER="# managed-by: rw-backup-full"

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# --------------------------------------------------------------------------
# Отключение
# --------------------------------------------------------------------------
if [[ "$MODE" == "--disable" ]]; then
  msg INFO "[${INSTANCE}] отключаю WAL-архивацию"

  if wal_container_running; then
    wal_psql "ALTER SYSTEM SET archive_mode = 'off'" >/dev/null || true
    wal_psql "ALTER SYSTEM RESET archive_command" >/dev/null || true
    wal_psql "ALTER SYSTEM RESET archive_timeout" >/dev/null || true
  fi

  if [[ -f "$OVERRIDE_FILE" ]] && grep -q "$MARKER" "$OVERRIDE_FILE"; then
    rm -f "$OVERRIDE_FILE"
    msg OK "[${INSTANCE}] override удалён: ${OVERRIDE_FILE}"
  elif [[ -f "$OVERRIDE_FILE" ]]; then
    msg WARN "[${INSTANCE}] ${OVERRIDE_FILE} создан не нами, оставляю как есть"
  fi

  ( cd "$COMPOSE_DIR" && dc up -d "$COMPOSE_SERVICE" )
  "${SCRIPT_DIR}/wal-timers.sh" "$INSTANCE" --remove 2>/dev/null || true
  msg OK "[${INSTANCE}] WAL-архивация выключена"
  exit 0
fi

# --------------------------------------------------------------------------
# Проверки перед включением
# --------------------------------------------------------------------------
wal_container_running || { msg ERR "[${INSTANCE}] контейнер ${INST_CONTAINER} не запущен"; exit 1; }
wal_wait_pg_ready 60 || { msg ERR "[${INSTANCE}] PostgreSQL не отвечает"; exit 1; }

if docker exec "$INST_CONTAINER" sh -c 'test -f /etc/patroni.yml || command -v patroni' >/dev/null 2>&1; then
  msg ERR "[${INSTANCE}] обнаружен Patroni. Настраивайте archive_* через patronictl edit-config,"
  msg ERR "иначе Patroni перезапишет postgresql.auto.conf. См. docs/WAL.md, раздел Patroni."
  exit 1
fi

pgver="$(wal_pg_version)"
if [[ -n "$pgver" ]] && (( pgver < 120000 )); then
  msg ERR "[${INSTANCE}] требуется PostgreSQL 12+, обнаружен ${pgver}"
  exit 1
fi

# --------------------------------------------------------------------------
# 1. Спул и archive-command
# --------------------------------------------------------------------------
wal_instance_dirs_init
install -d -m 0770 "${INST_SPOOL_DIR}/incoming"
install -m 0755 "${SCRIPT_DIR}/pg-archive-command.sh" "${INST_SPOOL_DIR}/archive-command.sh"

uid="$(docker inspect -f '{{.Config.User}}' "$INST_CONTAINER" 2>/dev/null || true)"
uid="${uid%%:*}"
[[ "$uid" =~ ^[0-9]+$ ]] || uid="999"
chown -R "${uid}:${uid}" "$INST_SPOOL_DIR"
msg OK "[${INSTANCE}] спул готов: ${INST_SPOOL_DIR} (uid ${uid})"

# --------------------------------------------------------------------------
# 2. compose override
# --------------------------------------------------------------------------
if [[ -f "$OVERRIDE_FILE" ]] && ! grep -q "$MARKER" "$OVERRIDE_FILE"; then
  msg ERR "[${INSTANCE}] ${OVERRIDE_FILE} уже существует и создан не нами."
  msg ERR "Добавьте вручную в сервис ${COMPOSE_SERVICE}:"
  msg ERR "    volumes:"
  msg ERR "      - ${INST_SPOOL_DIR}:${WAL_SPOOL_MOUNT}"
  exit 1
fi

cat > "$OVERRIDE_FILE" <<EOF_OVERRIDE
${MARKER}
# Проброс спула WAL-архивации. Файл создан rw-backup-full и удаляется командой:
#   rw-backup-full wal-disable ${INSTANCE}
services:
  ${COMPOSE_SERVICE}:
    volumes:
      - ${INST_SPOOL_DIR}:${WAL_SPOOL_MOUNT}
EOF_OVERRIDE

msg OK "[${INSTANCE}] создан ${OVERRIDE_FILE}"

# --------------------------------------------------------------------------
# 3. Параметры PostgreSQL
# --------------------------------------------------------------------------
archive_timeout="${INST_ARCHIVE_TIMEOUT:-300}"
archive_cmd="WAL_SPOOL_DIR=${WAL_SPOOL_MOUNT}/incoming ${WAL_SPOOL_MOUNT}/archive-command.sh %p %f"

wal_psql "ALTER SYSTEM SET wal_level = 'replica'" >/dev/null
wal_psql "ALTER SYSTEM SET archive_mode = 'on'" >/dev/null
wal_psql "ALTER SYSTEM SET archive_command = '${archive_cmd}'" >/dev/null
wal_psql "ALTER SYSTEM SET archive_timeout = '${archive_timeout}s'" >/dev/null

# max_wal_senders нужен для pg_basebackup. По умолчанию 10, но на маленьких
# инстансах его иногда режут в ноль — тогда базовый бэкап молча не заработает.
senders="$(wal_psql "SHOW max_wal_senders" | head -n1)"
if [[ "$senders" =~ ^[0-9]+$ ]] && (( senders < 2 )); then
  wal_psql "ALTER SYSTEM SET max_wal_senders = '4'" >/dev/null
  msg WARN "[${INSTANCE}] max_wal_senders=${senders} поднят до 4 (нужен для pg_basebackup)"
fi

msg OK "[${INSTANCE}] параметры записаны в postgresql.auto.conf"

# --------------------------------------------------------------------------
# 4. Пересоздание контейнера (archive_mode требует рестарта)
# --------------------------------------------------------------------------
if ! truthy "$ASSUME_YES"; then
  echo
  echo -e "${YELLOW}${BOLD}ТРЕБУЕТСЯ ПОДТВЕРЖДЕНИЕ${RESET}"
  echo "Для применения archive_mode PostgreSQL требует рестарта."
  echo "Будет выполнено: docker compose up -d ${COMPOSE_SERVICE}"
  echo "  (контейнер ${INST_CONTAINER} будет пересоздан с монтированием спула)"
  echo "Последствия: БД инстанса '${INSTANCE}' будет недоступна несколько секунд;"
  echo "зависящие от неё сервисы (панель/бот) на это время потеряют соединение"
  echo "и переподключатся автоматически. Данные не изменяются."
  read -r -p "Перезапустить контейнер БД сейчас? [y/N]: " __a
  if [[ "$__a" != "y" && "$__a" != "Y" ]]; then
    msg WARN "[${INSTANCE}] отменено пользователем. Параметры записаны в postgresql.auto.conf,"
    msg WARN "архивация включится после ручного рестарта БД и повторного запуска: rw-backup-full wal-enable ${INSTANCE}"
    exit 1
  fi
fi
msg INFO "[${INSTANCE}] пересоздаю ${COMPOSE_SERVICE}..."
( cd "$COMPOSE_DIR" && dc up -d "$COMPOSE_SERVICE" )

wal_wait_pg_ready 180 || { msg ERR "[${INSTANCE}] PostgreSQL не поднялся после рестарта"; exit 1; }

# --------------------------------------------------------------------------
# 5. Сквозная проверка
# --------------------------------------------------------------------------
mode="$(wal_psql "SHOW archive_mode" | head -n1)"
[[ "$mode" == "on" || "$mode" == "always" ]] || { msg ERR "[${INSTANCE}] archive_mode=${mode}"; exit 1; }

if ! docker exec "$INST_CONTAINER" test -x "${WAL_SPOOL_MOUNT}/archive-command.sh"; then
  msg ERR "[${INSTANCE}] ${WAL_SPOOL_MOUNT}/archive-command.sh не виден в контейнере — проверьте override"
  exit 1
fi

msg INFO "[${INSTANCE}] сквозная проверка: переключаю WAL-сегмент..."
before="$(find "${INST_SPOOL_DIR}/incoming" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l)"
wal_psql "SELECT pg_switch_wal()" >/dev/null

ok=false
for _ in $(seq 1 30); do
  after="$(find "${INST_SPOOL_DIR}/incoming" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l)"
  if (( after > before )); then ok=true; break; fi
  sleep 1
done

if [[ "$ok" != "true" ]]; then
  msg ERR "[${INSTANCE}] сегмент не появился в спуле за 30с."
  msg ERR "Диагностика: docker logs ${INST_CONTAINER} --tail 50 | grep -i archive"
  wal_psql "SELECT last_failed_wal, last_failed_time FROM pg_stat_archiver" >&2 || true
  exit 1
fi

failed_count="$(wal_psql "SELECT failed_count FROM pg_stat_archiver" | head -n1)"
msg OK "[${INSTANCE}] архивация работает (pg_stat_archiver.failed_count=${failed_count})"

# --------------------------------------------------------------------------
# 6. Таймеры
# --------------------------------------------------------------------------
if systemctl list-unit-files 'rw-wal-ship@.service' --no-legend 2>/dev/null | grep -q rw-wal-ship; then
  "${SCRIPT_DIR}/wal-timers.sh" "$INSTANCE" || msg WARN "[${INSTANCE}] таймеры не установились, включите вручную: rw-backup-full wal-timers ${INSTANCE}"
fi

wal_notify "🟢 WAL-архивация включена
Инстанс: ${INSTANCE} (${INST_KIND})
Хост: $(wal_hostname)
Контейнер: ${INST_CONTAINER}
archive_timeout: ${archive_timeout}s
Спул: ${INST_SPOOL_DIR}"

msg OK "[${INSTANCE}] готово. Первый базовый бэкап: rw-backup-full basebackup ${INSTANCE}"
exit 0
