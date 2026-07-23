#!/usr/bin/env bash
# pitr-restore.sh — восстановление PostgreSQL из базового бэкапа и/или WAL.
#
# Примеры:
#   # проверить восстановление, ничего не ломая: поднимет временный контейнер
#   pitr-restore.sh panel --target latest
#
#   # восстановление на точку во времени
#   pitr-restore.sh panel --target-time "2026-07-22 09:30:00+00"
#
#   # взять данные из S3, конкретный базовый бэкап, зашифрованные архивы
#   pitr-restore.sh bot_oneok --from s3 --backup base_2026-07-21_03_00_00_0000000100000000000000A7 \
#       --age-identity /root/age-restore.key
#
#   # заменить рабочую БД (деструктивно, с подтверждением)
#   pitr-restore.sh panel --target latest --in-place
#
# По умолчанию восстановление НЕ трогает рабочую БД: оно разворачивает копию
# в отдельном каталоге и поднимает временный контейнер на свободном порту.
# Это же используется песочницей проверки бэкапов.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE=""
SOURCE="local"
BACKUP_NAME=""
TARGET_MODE="latest"
TARGET_TIME=""
TARGET_LSN=""
TARGET_NAME=""
WORK_DIR=""
AGE_IDENTITY=""
IN_PLACE="false"
KEEP_RUNNING="false"
ASSUME_YES="false"
PG_PORT=""

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

INSTANCE="${1:-}"
[[ -n "$INSTANCE" && "$INSTANCE" != -* ]] || usage
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)          SOURCE="$2"; shift 2 ;;
    --backup)        BACKUP_NAME="$2"; shift 2 ;;
    --target)        TARGET_MODE="$2"; shift 2 ;;
    --target-time)   TARGET_MODE="time"; TARGET_TIME="$2"; shift 2 ;;
    --target-lsn)    TARGET_MODE="lsn"; TARGET_LSN="$2"; shift 2 ;;
    --target-name)   TARGET_MODE="name"; TARGET_NAME="$2"; shift 2 ;;
    --work-dir)      WORK_DIR="$2"; shift 2 ;;
    --age-identity)  AGE_IDENTITY="$2"; shift 2 ;;
    --port)          PG_PORT="$2"; shift 2 ;;
    --in-place)      IN_PLACE="true"; shift ;;
    --keep-running)  KEEP_RUNNING="true"; shift ;;
    --yes|-y)        ASSUME_YES="true"; shift ;;
    -h|--help)       usage ;;
    *) msg ERR "Неизвестный аргумент: $1"; usage ;;
  esac
done

wal_load_full_config
wal_load_instance "$INSTANCE"

WORK_DIR="${WORK_DIR:-/var/lib/rw-wal/restore/${INSTANCE}_$(wal_ts)}"
PGDATA_DIR="${WORK_DIR}/pgdata"
WAL_STAGE_DIR="${WORK_DIR}/wal"
mkdir -p "$PGDATA_DIR" "$WAL_STAGE_DIR"

msg INFO "Рабочий каталог: ${WORK_DIR}"

# --------------------------------------------------------------------------
# Расшифровка / распаковка
# --------------------------------------------------------------------------
decrypt_stream() {
  if [[ -n "$AGE_IDENTITY" ]]; then
    age -d -i "$AGE_IDENTITY"
  else
    cat
  fi
}

unpack_stream() {
  local name="$1"
  local base="$name"
  if [[ "$base" == *.age ]]; then
    base="${base%.age}"
    decrypt_stream | wal_decompress_stream "$base"
  else
    wal_decompress_stream "$base"
  fi
}

# --------------------------------------------------------------------------
# Выбор базового бэкапа
# --------------------------------------------------------------------------
META_FILE="${WORK_DIR}/backup.meta"

if [[ "$SOURCE" == "local" ]]; then
  if [[ -z "$BACKUP_NAME" ]]; then
    BACKUP_NAME="$(find "$INST_BASEBACKUP_DIR" -maxdepth 1 -name 'base_*.meta' 2>/dev/null \
      | sort -r | head -n1 | xargs -r basename | sed 's/\.meta$//')"
  fi
  [[ -n "$BACKUP_NAME" ]] || { msg ERR "Локальных базовых бэкапов нет. Попробуйте --from s3"; exit 1; }
  cp "${INST_BASEBACKUP_DIR}/${BACKUP_NAME}.meta" "$META_FILE"
  BACKUP_SRC="local"
else
  wal_s3_ready || { msg ERR "S3 не настроен"; exit 1; }
  if [[ -z "$BACKUP_NAME" ]]; then
    BACKUP_NAME="$(wal_aws s3 ls "$(wal_s3_uri 'basebackup/')" 2>/dev/null \
      | awk '{print $4}' | grep -E '^base_.*\.meta$' | sort -r | head -n1 | sed 's/\.meta$//')"
  fi
  [[ -n "$BACKUP_NAME" ]] || { msg ERR "В S3 нет базовых бэкапов"; exit 1; }
  wal_aws s3 cp "$(wal_s3_uri "basebackup/${BACKUP_NAME}.meta")" "$META_FILE" --only-show-errors
  BACKUP_SRC="s3"
fi

set +u; # shellcheck disable=SC1090
source "$META_FILE"; set -u

msg OK "Базовый бэкап: ${BACKUP_NAME}"
msg INFO "  создан:          ${CREATED_AT}"
msg INFO "  стартовый WAL:   ${START_SEGMENT}"
msg INFO "  PostgreSQL:      ${PG_VERSION_NUM}"
msg INFO "  зашифрован:      ${ENCRYPTED}"
msg INFO "  источник:        ${BACKUP_SRC}"

if truthy "$ENCRYPTED" && [[ -z "$AGE_IDENTITY" ]]; then
  msg ERR "Бэкап зашифрован. Укажите приватный ключ: --age-identity /path/key"
  exit 1
fi

# --------------------------------------------------------------------------
# Распаковка базового бэкапа
# --------------------------------------------------------------------------
msg INFO "Распаковываю базовый бэкап..."

if [[ "$BACKUP_SRC" == "local" ]]; then
  BASE_FILE="${INST_BASEBACKUP_DIR}/${FILE}"
  [[ -f "$BASE_FILE" ]] || { msg ERR "Файл бэкапа отсутствует: ${BASE_FILE}"; exit 1; }
  actual_sha="$(sha256sum "$BASE_FILE" | awk '{print $1}')"
  if [[ -n "${SHA256:-}" && "$actual_sha" != "$SHA256" ]]; then
    msg ERR "Контрольная сумма не совпадает! Ожидалось ${SHA256}, получено ${actual_sha}"
    exit 1
  fi
  msg OK "SHA256 совпадает"
else
  BASE_FILE="${WORK_DIR}/${FILE}"
  wal_aws s3 cp "$(wal_s3_uri "basebackup/${FILE}")" "$BASE_FILE" --only-show-errors
  actual_sha="$(sha256sum "$BASE_FILE" | awk '{print $1}')"
  if [[ -n "${SHA256:-}" && "$actual_sha" != "$SHA256" ]]; then
    msg ERR "Контрольная сумма не совпадает после загрузки из S3"
    exit 1
  fi
  msg OK "SHA256 совпадает"
fi

unpack_stream "$FILE" < "$BASE_FILE" | tar -xf - -C "$PGDATA_DIR"
[[ -f "${PGDATA_DIR}/PG_VERSION" ]] || { msg ERR "После распаковки нет PG_VERSION"; exit 1; }
msg OK "PGDATA развёрнут: ${PGDATA_DIR}"

# --------------------------------------------------------------------------
# Стейджинг WAL
# --------------------------------------------------------------------------
msg INFO "Готовлю WAL начиная с ${START_SEGMENT}..."

stage_one() {
  local fname="$1" src="$2" seg
  seg="${fname:0:24}"
  # .history файлы нужны целиком, у них другое имя
  if [[ "$fname" == *.history* ]]; then
    seg="${fname%%.history*}.history"
  fi
  [[ -f "${WAL_STAGE_DIR}/${seg}" ]] && return 0
  if [[ "$src" == "local" ]]; then
    unpack_stream "$fname" < "${INST_ARCHIVE_DIR}/${fname}" > "${WAL_STAGE_DIR}/${seg}.part" 2>/dev/null || return 1
  else
    wal_aws s3 cp "$(wal_s3_uri "wal/${fname}")" - --only-show-errors 2>/dev/null \
      | unpack_stream "$fname" > "${WAL_STAGE_DIR}/${seg}.part" || return 1
  fi
  mv -f "${WAL_STAGE_DIR}/${seg}.part" "${WAL_STAGE_DIR}/${seg}"
  return 0
}

staged=0
if [[ "$SOURCE" == "local" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n="$(basename "$f")"
    [[ "$n" == .* ]] && continue
    # shellcheck disable=SC2071  # hex-имена сегментов, сравнение лексикографическое
    if [[ "$n" == *.history* ]] || [[ "${n:0:24}" > "$START_SEGMENT" ]] || [[ "${n:0:24}" == "$START_SEGMENT" ]]; then
      stage_one "$n" local && staged=$((staged + 1)) || msg WARN "не удалось подготовить ${n}"
    fi
  done < <(find "$INST_ARCHIVE_DIR" -maxdepth 1 -type f 2>/dev/null | sort)
else
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    # shellcheck disable=SC2071  # hex-имена сегментов, сравнение лексикографическое
    if [[ "$n" == *.history* ]] || [[ "${n:0:24}" > "$START_SEGMENT" ]] || [[ "${n:0:24}" == "$START_SEGMENT" ]]; then
      stage_one "$n" s3 && staged=$((staged + 1)) || msg WARN "не удалось подготовить ${n}"
    fi
  done < <(wal_aws s3 ls "$(wal_s3_uri 'wal/')" 2>/dev/null | awk '{print $4}' | sort)
fi

msg OK "Подготовлено WAL-сегментов: ${staged}"
if (( staged == 0 )); then
  msg WARN "WAL не найден. Восстановление возможно только на момент базового бэкапа."
fi

# --------------------------------------------------------------------------
# Конфигурация восстановления
# --------------------------------------------------------------------------
AUTOCONF="${PGDATA_DIR}/postgresql.auto.conf"
{
  echo ""
  echo "# --- rw-backup-full restore ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ---"
  echo "# Последнее значение параметра побеждает, поэтому боевые archive_* здесь глушатся."
  echo "archive_mode = 'off'"
  echo "archive_command = ''"
  echo "restore_command = 'cp /wal-archive/%f %p'"
  echo "recovery_end_command = ''"
  case "$TARGET_MODE" in
    latest)
      echo "# цель: проиграть весь доступный WAL"
      ;;
    immediate)
      echo "recovery_target = 'immediate'"
      ;;
    time)
      echo "recovery_target_time = '${TARGET_TIME}'"
      echo "recovery_target_inclusive = on"
      ;;
    lsn)
      echo "recovery_target_lsn = '${TARGET_LSN}'"
      ;;
    name)
      echo "recovery_target_name = '${TARGET_NAME}'"
      ;;
    *)
      msg ERR "Неизвестный режим цели: ${TARGET_MODE}"; exit 1 ;;
  esac
  echo "recovery_target_action = 'promote'"
  echo "hot_standby = on"
} >> "$AUTOCONF"

touch "${PGDATA_DIR}/recovery.signal"
rm -f "${PGDATA_DIR}/postmaster.pid"

chown -R 999:999 "$PGDATA_DIR" "$WAL_STAGE_DIR" 2>/dev/null || true
chmod 0700 "$PGDATA_DIR"

msg OK "Параметры восстановления записаны (режим: ${TARGET_MODE})"

# --------------------------------------------------------------------------
# Определение образа
# --------------------------------------------------------------------------
IMAGE="${IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(docker inspect -f '{{.Config.Image}}' "$INST_CONTAINER" 2>/dev/null || true)"
fi
if [[ -z "$IMAGE" ]]; then
  major=$(( PG_VERSION_NUM / 10000 ))
  IMAGE="postgres:${major}"
fi
msg INFO "Образ для восстановления: ${IMAGE}"

# --------------------------------------------------------------------------
# Восстановление на месте (деструктивно)
# --------------------------------------------------------------------------
if truthy "$IN_PLACE"; then
  msg WARN "РЕЖИМ IN-PLACE: рабочая БД инстанса ${INSTANCE} будет заменена."
  if ! truthy "$ASSUME_YES"; then
    read -r -p "Введите ${INSTANCE} для подтверждения: " confirm
    [[ "$confirm" == "$INSTANCE" ]] || { msg ERR "Отменено"; exit 1; }
  fi

  COMPOSE_DIR="$(dirname "$INST_COMPOSE_FILE")"
  ( cd "$COMPOSE_DIR" && docker compose -f "$INST_COMPOSE_FILE" stop "$INST_COMPOSE_SERVICE" )

  live_pgdata="$(docker inspect -f \
    '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' \
    "$INST_CONTAINER" 2>/dev/null || true)"
  [[ -n "$live_pgdata" ]] || { msg ERR "Не удалось определить путь PGDATA контейнера"; exit 1; }

  backup_path="${live_pgdata}.before_restore_$(date +%Y%m%d_%H%M%S)"
  mv "$live_pgdata" "$backup_path"
  msg OK "Старый PGDATA сохранён: ${backup_path}"

  mkdir -p "$live_pgdata"
  cp -a "${PGDATA_DIR}/." "$live_pgdata/"
  install -d -m 0755 "${live_pgdata}/../rw-restore-wal"
  cp -a "${WAL_STAGE_DIR}/." "${live_pgdata}/../rw-restore-wal/" 2>/dev/null || true

  msg WARN "PGDATA заменён. WAL для восстановления: ${live_pgdata}/../rw-restore-wal"
  msg WARN "Смонтируйте его как /wal-archive и запустите сервис:"
  msg WARN "  docker compose -f ${INST_COMPOSE_FILE} up -d ${INST_COMPOSE_SERVICE}"
  msg WARN "После успешного восстановления снова включите архивацию:"
  msg WARN "  rw-backup-full wal-enable ${INSTANCE}"
  exit 0
fi

# --------------------------------------------------------------------------
# Временный контейнер
# --------------------------------------------------------------------------
CONTAINER="rw-restore-${INSTANCE}-$$"
PG_PORT="${PG_PORT:-$(shuf -i 15432-25432 -n 1)}"

msg INFO "Поднимаю временный контейнер ${CONTAINER} на порту ${PG_PORT}..."

docker run -d --rm \
  --name "$CONTAINER" \
  -v "${PGDATA_DIR}:/var/lib/postgresql/data" \
  -v "${WAL_STAGE_DIR}:/wal-archive:ro" \
  -p "127.0.0.1:${PG_PORT}:5432" \
  -e POSTGRES_PASSWORD=rw_restore_tmp \
  "$IMAGE" \
  -c listen_addresses='*' >/dev/null

recovered=false
for i in $(seq 1 300); do
  if docker exec "$CONTAINER" pg_isready -h localhost -U "$INST_PGUSER" >/dev/null 2>&1; then
    in_recovery="$(docker exec "$CONTAINER" psql -h localhost -U "$INST_PGUSER" -d postgres -qtAX \
      -c 'SELECT pg_is_in_recovery()' 2>/dev/null | tr -d ' ' || echo t)"
    if [[ "$in_recovery" == "f" ]]; then recovered=true; break; fi
  fi
  if ! docker ps -q -f "name=${CONTAINER}" | grep -q .; then
    msg ERR "Контейнер восстановления упал"
    docker logs "$CONTAINER" --tail 60 2>&1 || true
    exit 1
  fi
  sleep 2
done

if [[ "$recovered" != "true" ]]; then
  msg ERR "Восстановление не завершилось за 10 минут"
  docker logs "$CONTAINER" --tail 60 2>&1 || true
  docker stop "$CONTAINER" >/dev/null 2>&1 || true
  exit 1
fi

last_ts="$(docker exec "$CONTAINER" psql -h localhost -U "$INST_PGUSER" -d postgres -qtAX \
  -c 'SELECT pg_last_committed_xact()' 2>/dev/null || true)"

msg OK "Восстановление завершено. БД доступна на 127.0.0.1:${PG_PORT}"
msg INFO "  psql -h 127.0.0.1 -p ${PG_PORT} -U ${INST_PGUSER} ${INST_PGDATABASE}"
[[ -n "$last_ts" ]] && msg INFO "  последняя транзакция: ${last_ts}"

echo "$CONTAINER" > "${WORK_DIR}/container"
echo "$PG_PORT" > "${WORK_DIR}/port"

if ! truthy "$KEEP_RUNNING"; then
  msg INFO "Контейнер оставлен запущенным. Остановить: docker stop ${CONTAINER}"
  msg INFO "Удалить данные: rm -rf ${WORK_DIR}"
fi

exit 0
