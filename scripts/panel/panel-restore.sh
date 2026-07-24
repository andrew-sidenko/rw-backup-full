#!/usr/bin/env bash
# panel-restore.sh [файл | --from-s3 [--backend NAME]] — восстановление панели
# из remnawave_backup_*.tar.gz (формат оригинального distillium rw-backup).
#
# ПРИНЦИП: восстановление панели деструктивно, поэтому каждый шаг, меняющий
# систему, выполняется только после явного подтверждения с полным описанием
# последствий. Старые данные НЕ удаляются — откладываются в *.before_restore_*.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

wal_load_full_config

PANEL_DB_CONTAINER="${PANEL_DB_CONTAINER:-remnawave-db}"
PANEL_DB_USER="${PANEL_DB_USER:-${DB_USER:-postgres}}"
PANEL_ROOT_DIR="${PANEL_ROOT_DIR:-${REMNALABS_ROOT_DIR:-/opt/remnawave}}"
PANEL_DB_VOLUME="${PANEL_DB_VOLUME:-remnawave-db-data}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"

ASSUME_YES="false"
SRC_FILE=""
FROM_S3="false"
S3_BACKEND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-s3)  FROM_S3="true"; shift ;;
    --backend)  S3_BACKEND="$2"; shift 2 ;;
    --yes|-y)   ASSUME_YES="true"; shift ;;
    -h|--help)  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          SRC_FILE="$1"; shift ;;
  esac
done

# ask "<описание действия и последствий>" — подтверждение каждого шага.
ask() {
  truthy "$ASSUME_YES" && { msg INFO "[auto-yes] $1"; return 0; }
  echo
  echo -e "${YELLOW}${BOLD}ТРЕБУЕТСЯ ПОДТВЕРЖДЕНИЕ${RESET}"
  echo -e "$1"
  local a
  read -r -p "Продолжить? [y/N]: " a
  [[ "$a" == "y" || "$a" == "Y" ]]
}

# --------------------------------------------------------------------------
# Выбор архива
# --------------------------------------------------------------------------
WORK="$(mktemp -d /tmp/rw-panel-restore.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if truthy "$FROM_S3"; then
  local_first="$(s3m_backends | head -n1)"
  S3_BACKEND="${S3_BACKEND:-$local_first}"
  [[ -n "$S3_BACKEND" ]] || { msg ERR "Нет настроенных S3-бэкендов"; exit 1; }
  s3m_load "$S3_BACKEND" || exit 1
  echo "Архивы панели в S3[${S3_BACKEND}] (свежие снизу):"
  s3m_aws s3 ls "s3://${B_BUCKET}/${B_PREFIX}/panel/" --recursive 2>/dev/null \
    | grep -E 'remnawave_backup_.*\.tar\.gz' | sort | tail -n 15 | awk '{print "  "$1" "$2"  "$4}'
  read -r -p "[?] Полный ключ архива (столбец справа): " key
  [[ -n "$key" ]] || { msg ERR "Ключ не задан"; exit 1; }
  SRC_FILE="${WORK}/$(basename "$key")"
  s3m_aws s3 cp "s3://${B_BUCKET}/${key}" "$SRC_FILE" --only-show-errors \
    || { msg ERR "Не удалось скачать из S3"; exit 1; }
elif [[ -z "$SRC_FILE" ]]; then
  echo "Локальные архивы панели (свежие снизу):"
  find "$BACKUP_DIR" -maxdepth 1 -name 'remnawave_backup_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n 10 | awk '{print "  "$2}'
  read -r -p "[?] Путь к архиву [Enter = самый свежий]: " SRC_FILE
  if [[ -z "$SRC_FILE" ]]; then
    SRC_FILE="$(find "$BACKUP_DIR" -maxdepth 1 -name 'remnawave_backup_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}')"
  fi
fi

[[ -f "$SRC_FILE" ]] || { msg ERR "Архив не найден: ${SRC_FILE}"; exit 1; }

# --------------------------------------------------------------------------
# Осмотр архива и информирование
# --------------------------------------------------------------------------
tar -xzf "$SRC_FILE" -C "$WORK" || { msg ERR "Архив не распаковался"; exit 1; }
[[ -f "${WORK}/backup_meta.info" ]] || { msg ERR "В архиве нет backup_meta.info — это не архив панели"; exit 1; }

set +u; # shellcheck disable=SC1090
source "${WORK}/backup_meta.info"; set -u

DUMP_SQL="$(find "$WORK" -maxdepth 1 -name 'dump_*.sql.gz' | head -n1)"
DIR_TAR="$(find "$WORK" -maxdepth 1 -name 'remnawave_dir_*.tar.gz' | head -n1)"
[[ -n "$DUMP_SQL" && -n "$DIR_TAR" ]] || { msg ERR "В архиве нет дампа или каталога панели"; exit 1; }

echo
echo -e "${BOLD}Архив: $(basename "$SRC_FILE")${RESET}"
echo "  Дата бэкапа:     ${TIMESTAMP:-?}"
echo "  Тип дампа:       ${DUMP_TYPE:-?}"
echo "  Версия панели:   ${PANEL_VERSION:-?}"
echo "  Версия бэкапа:   ${BACKUP_VERSION:-?}"
echo "  Дамп БД:         $(basename "$DUMP_SQL") ($(du -h "$DUMP_SQL" | awk '{print $1}'))"
echo "  Каталог панели:  $(basename "$DIR_TAR") ($(du -h "$DIR_TAR" | awk '{print $1}'))"
if [[ "${DUMP_TYPE:-dumpall}" != "dumpall" ]]; then
  msg WARN "Дамп типа '${DUMP_TYPE}' (external pg_dump). Восстановление продолжится в БД '${DB_NAME:-postgres}'."
fi

COMPOSE_FILE=""
for c in "${PANEL_ROOT_DIR}/docker-compose.yml" "${PANEL_ROOT_DIR}/docker-compose.yaml"; do
  [[ -f "$c" ]] && COMPOSE_FILE="$c" && break
done

TS_NOW="$(date +%Y%m%d_%H%M%S)"

# --------------------------------------------------------------------------
# Шаг 1: остановка панели
# --------------------------------------------------------------------------
if [[ -n "$COMPOSE_FILE" ]]; then
  ask "Шаг 1/5 — ОСТАНОВКА ПАНЕЛИ.
Будет выполнено: docker compose -f ${COMPOSE_FILE} down
Последствия: панель и все её контейнеры остановятся, пользователи потеряют
доступ к интерфейсу до завершения восстановления. Данные не изменяются." || { msg ERR "Отменено"; exit 1; }
  ( cd "$(dirname "$COMPOSE_FILE")" && docker compose down )
else
  msg WARN "compose панели не найден в ${PANEL_ROOT_DIR} — пропускаю остановку (новый сервер?)"
fi

# --------------------------------------------------------------------------
# Шаг 2: каталог панели в сторону
# --------------------------------------------------------------------------
if [[ -d "$PANEL_ROOT_DIR" ]]; then
  aside="${PANEL_ROOT_DIR}.before_restore_${TS_NOW}"
  ask "Шаг 2/5 — ЗАМЕНА КАТАЛОГА ПАНЕЛИ.
Будет выполнено:
  mv ${PANEL_ROOT_DIR} ${aside}
  распаковка каталога из бэкапа в ${PANEL_ROOT_DIR}
Последствия: текущие конфиги (.env, docker-compose.yml и т.д.) заменяются
версиями из бэкапа. Старый каталог НЕ удаляется — он останется в ${aside},
удалить его позже можно вручную." || { msg ERR "Отменено"; exit 1; }
  mv "$PANEL_ROOT_DIR" "$aside"
  msg OK "Старый каталог: ${aside}"
fi
mkdir -p "$(dirname "$PANEL_ROOT_DIR")"
tar -xzf "$DIR_TAR" -C "$(dirname "$PANEL_ROOT_DIR")"
[[ -d "$PANEL_ROOT_DIR" ]] || { msg ERR "После распаковки нет ${PANEL_ROOT_DIR}"; exit 1; }
msg OK "Каталог панели восстановлен из бэкапа"

COMPOSE_FILE=""
for c in "${PANEL_ROOT_DIR}/docker-compose.yml" "${PANEL_ROOT_DIR}/docker-compose.yaml"; do
  [[ -f "$c" ]] && COMPOSE_FILE="$c" && break
done
[[ -n "$COMPOSE_FILE" ]] || { msg ERR "В восстановленном каталоге нет docker-compose"; exit 1; }

# --------------------------------------------------------------------------
# Шаг 3: пересоздание тома БД
# --------------------------------------------------------------------------
if docker volume inspect "$PANEL_DB_VOLUME" >/dev/null 2>&1; then
  vol_backup="${PANEL_DB_VOLUME}_before_restore_${TS_NOW}"
  ask "Шаг 3/5 — ПЕРЕСОЗДАНИЕ ТОМА БД.
Будет выполнено: переименование данных тома ${PANEL_DB_VOLUME} в резервный
том ${vol_backup} (копированием), затем очистка ${PANEL_DB_VOLUME}.
Последствия: текущая БД панели будет заменена содержимым дампа на шаге 5.
Резервный том с текущими данными сохранится — при неудаче можно откатиться.
Это самый ответственный шаг восстановления." || { msg ERR "Отменено"; exit 1; }
  docker volume create "$vol_backup" >/dev/null
  docker run --rm -v "${PANEL_DB_VOLUME}:/from:ro" -v "${vol_backup}:/to" \
    alpine sh -c 'cd /from && cp -a . /to/' \
    || { msg ERR "Не удалось скопировать данные тома в резерв"; exit 1; }
  docker volume rm "$PANEL_DB_VOLUME" >/dev/null
  msg OK "Данные тома сохранены в ${vol_backup}"
fi

# --------------------------------------------------------------------------
# Шаг 4: старт БД и ожидание готовности
# --------------------------------------------------------------------------
ask "Шаг 4/5 — ЗАПУСК КОНТЕЙНЕРА БД.
Будет выполнено: docker compose up -d ${PANEL_DB_CONTAINER##*/}
Последствия: создаётся чистый том БД, поднимается PostgreSQL." || { msg ERR "Отменено"; exit 1; }
( cd "$(dirname "$COMPOSE_FILE")" && docker compose up -d "$(docker compose -f "$COMPOSE_FILE" config --services | grep -E 'db|postgres' | head -n1 || echo remnawave-db)" )

ready=false
for _ in $(seq 1 90); do
  st="$(docker inspect -f '{{.State.Health.Status}}' "$PANEL_DB_CONTAINER" 2>/dev/null || echo none)"
  if [[ "$st" == "healthy" ]] || { [[ "$st" == "none" ]] && docker exec "$PANEL_DB_CONTAINER" pg_isready -U "$PANEL_DB_USER" >/dev/null 2>&1; }; then
    ready=true; break
  fi
  sleep 2
done
[[ "$ready" == "true" ]] || { msg ERR "БД не поднялась за 3 минуты. docker logs ${PANEL_DB_CONTAINER}"; exit 1; }
sleep 3
msg OK "PostgreSQL готов"

# --------------------------------------------------------------------------
# Шаг 5: заливка дампа и полный старт
# --------------------------------------------------------------------------
restore_db="postgres"
[[ "${DUMP_TYPE:-dumpall}" != "dumpall" ]] && restore_db="${DB_NAME:-postgres}"

ask "Шаг 5/5 — ЗАЛИВКА ДАМПА И ЗАПУСК ПАНЕЛИ.
Будет выполнено:
  gunzip -c $(basename "$DUMP_SQL") | docker exec -i ${PANEL_DB_CONTAINER} psql -U ${PANEL_DB_USER} -d ${restore_db}
  docker compose up -d
Последствия: БД наполняется данными бэкапа, панель запускается полностью." || { msg ERR "Отменено"; exit 1; }

if ! gzip -dc "$DUMP_SQL" | docker exec -i "$PANEL_DB_CONTAINER" \
     psql -q -U "$PANEL_DB_USER" -d "$restore_db" -v ON_ERROR_STOP=0 2>"${WORK}/psql.err"; then
  msg WARN "psql завершился с ошибками, последние строки:"
  tail -n 5 "${WORK}/psql.err" >&2 || true
fi
errs="$(grep -cE '^ERROR' "${WORK}/psql.err" 2>/dev/null || echo 0)"
msg INFO "SQL-ошибок при заливке: ${errs} (ошибки DROP/EXISTS при dumpall безвредны)"

( cd "$(dirname "$COMPOSE_FILE")" && docker compose up -d )

msg OK "Восстановление панели завершено."
echo
echo "Проверьте работу панели. После проверки можно удалить резервы:"
[[ -d "${PANEL_ROOT_DIR}.before_restore_${TS_NOW}" ]] && echo "  rm -rf ${PANEL_ROOT_DIR}.before_restore_${TS_NOW}"
docker volume inspect "${PANEL_DB_VOLUME}_before_restore_${TS_NOW}" >/dev/null 2>&1 && \
  echo "  docker volume rm ${PANEL_DB_VOLUME}_before_restore_${TS_NOW}"
echo
msg WARN "Если на панели была включена WAL-архивация — включите заново: rw-backup-full wal-enable <инстанс>"

wal_notify "♻️ Панель восстановлена из бэкапа
Хост: $(wal_hostname)
Архив: $(basename "$SRC_FILE")
SQL-ошибок: ${errs}"
exit 0
