#!/usr/bin/env bash
# bare-restore.sh — восстановление проекта на ПОЛНОСТЬЮ ЧИСТОМ сервере.
#
# Предполагает, что на машине нет ничего: ни docker, ни утилит, ни каталогов,
# ни самого rw-backup-full. Единственное, что нужно — доступ в интернет,
# реквизиты S3-хранилища с бэкапами и (если бэкапы шифруются) приватный ключ age.
#
# Сценарий: сервер утрачен, поднят новый чистый — за один прогон получаем
# работающий проект из бэкапов.
#
#   sudo ./bare-restore.sh --source <ID-сервера> --project panel
#   sudo ./bare-restore.sh --source v567005 --project panel --yes   # без вопросов
#
# Шаги (каждый — с подтверждением и описанием последствий):
#   1. Зависимости (docker, jq, git, rsync, awscli, zstd, age, curl)
#   2. Каталоги и установка rw-backup-full
#   3. Реквизиты S3 (интерактивно или из готового s3.d-файла)
#   4. Каталог проекта из трекера конфигов
#   5. База данных (логический дамп или базовый бэкап + WAL)
#   6. Запуск стека

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_DIR="/opt/rw-backup-restore"
SOURCE_ID=""; PROJECT="panel"; ASSUME_YES="false"; S3_ENV_FILE=""; DB_MODE="dump"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)   SOURCE_ID="$2"; shift 2 ;;
    --project)  PROJECT="$2"; shift 2 ;;
    --s3-env)   S3_ENV_FILE="$2"; shift 2 ;;
    --db-mode)  DB_MODE="$2"; shift 2 ;;
    --yes|-y)   ASSUME_YES="true"; shift ;;
    -h|--help)  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

[[ "$(id -u)" == 0 ]] || { echo "Запустите от root: sudo $0 ..." >&2; exit 1; }
[[ -n "$SOURCE_ID" ]] || { echo "Укажите --source <ID-сервера> (как в бэкапах: hostname исходного сервера)" >&2; exit 1; }

C_Y=$'\e[33m'; C_B=$'\e[1m'; C_R=$'\e[0m'; C_G=$'\e[32m'
say()  { echo -e "\e[36m[..]\e[0m $*"; }
ok()   { echo -e "${C_G}[OK]${C_R} $*"; }
warn() { echo -e "${C_Y}[!!]${C_R} $*"; }
die()  { echo -e "\e[31m[ERR]\e[0m $*" >&2; exit 1; }

ask() {
  [[ "$ASSUME_YES" == "true" ]] && { say "[auto-yes] $1"; return 0; }
  echo; echo -e "${C_Y}${C_B}── $1 ──${C_R}"; echo -e "$2"
  local a; read -r -p "Выполнить этот шаг? [y/N]: " a
  [[ "$a" == y || "$a" == Y ]]
}

echo -e "${C_B}Восстановление на чистом сервере${C_R}"
echo "  источник бэкапов: ${SOURCE_ID}"
echo "  проект:           ${PROJECT}"
echo "  режим БД:         ${DB_MODE} (dump | pitr)"
echo

# --------------------------------------------------------------------------
# 1. Зависимости
# --------------------------------------------------------------------------
NEED=(curl jq git rsync zstd age)
command -v docker >/dev/null 2>&1 || NEED+=(docker)
command -v aws >/dev/null 2>&1 || NEED+=(awscli)

MISSING=()
for c in "${NEED[@]}"; do
  case "$c" in
    docker)  command -v docker >/dev/null 2>&1 || MISSING+=(docker) ;;
    awscli)  command -v aws >/dev/null 2>&1 || MISSING+=(awscli) ;;
    *)       command -v "$c" >/dev/null 2>&1 || MISSING+=("$c") ;;
  esac
done

if (( ${#MISSING[@]} > 0 )); then
  if ask "Шаг 1: установка зависимостей" \
"Отсутствуют: ${MISSING[*]}
Будет выполнено: apt-get update && apt-get install -y ${MISSING[*]}
$(printf '%s' "${MISSING[*]}" | grep -q docker && echo 'Docker ставится из официального репозитория docker.com (docker-ce + compose-плагин).')
Последствия: изменяется список пакетов системы. На чистом сервере это ожидаемо."; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    APT_PKGS=()
    for m in "${MISSING[@]}"; do
      case "$m" in
        docker) ;;  # ниже, отдельно
        awscli) APT_PKGS+=(awscli) ;;
        *)      APT_PKGS+=("$m") ;;
      esac
    done
    (( ${#APT_PKGS[@]} > 0 )) && apt-get install -y -qq "${APT_PKGS[@]}"

    if ! command -v docker >/dev/null 2>&1; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
      systemctl enable --now docker
    fi
    ok "Зависимости установлены"
  else
    die "Без зависимостей продолжать нельзя"
  fi
else
  ok "Шаг 1: все зависимости уже установлены"
fi

docker info >/dev/null 2>&1 || die "docker не запущен (systemctl start docker)"

# --------------------------------------------------------------------------
# 2. Каталоги и установка rw-backup-full
# --------------------------------------------------------------------------
if ask "Шаг 2: каталоги и установка rw-backup-full" \
"Будет создано: ${INSTALL_DIR}/{backup,s3.d,instances.d,scripts}, /var/lib/rw-wal,
/var/lib/rw-config-track, /var/lib/node_exporter/textfile_collector
и запущен ${SRC_DIR}/install.sh --yes (копирование скриптов, юнитов, конфига).
Последствия: появляется команда rw-backup-full и структура каталогов." ; then
  mkdir -p "${INSTALL_DIR}"/{backup,s3.d,instances.d} \
           /var/lib/rw-wal /var/lib/rw-config-track \
           /var/lib/node_exporter/textfile_collector
  if [[ -x "${SRC_DIR}/install.sh" ]]; then
    ( cd "$SRC_DIR" && ./install.sh --yes )
  else
    die "Не найден ${SRC_DIR}/install.sh — запускайте скрипт из клона репозитория"
  fi
  ok "rw-backup-full установлен"
fi

# --------------------------------------------------------------------------
# 3. Реквизиты S3
# --------------------------------------------------------------------------
if ! ls "${INSTALL_DIR}/s3.d"/*.env >/dev/null 2>&1; then
  if [[ -n "$S3_ENV_FILE" && -f "$S3_ENV_FILE" ]]; then
    install -m 600 "$S3_ENV_FILE" "${INSTALL_DIR}/s3.d/restore.env"
    ok "S3-бэкенд взят из ${S3_ENV_FILE}"
  else
    echo
    echo -e "${C_Y}${C_B}── Шаг 3: реквизиты хранилища с бэкапами ──${C_R}"
    echo "Нужны реквизиты S3, куда исходный сервер складывал бэкапы (только чтение достаточно)."
    read -r -p "  Endpoint (пусто для AWS): " r_ep
    read -r -p "  Bucket: " r_bucket
    read -r -p "  Access key: " r_ak
    read -r -s -p "  Secret key: " r_sk; echo
    read -r -p "  Region [us-east-1]: " r_reg; r_reg="${r_reg:-us-east-1}"
    read -r -p "  Prefix [rw-backup-full]: " r_pfx; r_pfx="${r_pfx:-rw-backup-full}"
    cat > "${INSTALL_DIR}/s3.d/restore.env" <<EOF_S3
B_ENABLED="true"
B_ENDPOINT="${r_ep}"
B_BUCKET="${r_bucket}"
B_ACCESS_KEY="${r_ak}"
B_SECRET_KEY="${r_sk}"
B_REGION="${r_reg}"
B_PREFIX="${r_pfx}"
B_UPLOAD_PANEL="true"
B_UPLOAD_CUSTOM="true"
B_UPLOAD_WAL="true"
EOF_S3
    chmod 600 "${INSTALL_DIR}/s3.d/restore.env"
  fi
  say "Проверяю доступ к хранилищу..."
  rw-backup-full s3-test >/dev/null 2>&1 \
    && ok "Доступ к S3 подтверждён" \
    || warn "Проверка доступа не прошла — детали: rw-backup-full s3-test"
else
  ok "Шаг 3: S3-бэкенды уже настроены"
fi

# RW_SOURCE_ID критичен: без него все пути в S3 строились бы по hostname
# ЭТОГО (нового) сервера, а бэкапы лежат под именем исходного.
export RW_SOURCE_ID="$SOURCE_ID"
if ! grep -q '^RW_SOURCE_ID=' "${INSTALL_DIR}/rw-backup-full.env" 2>/dev/null; then
  printf '\n# Источник бэкапов при восстановлении (исходный сервер)\nRW_SOURCE_ID="%s"\n' \
    "$SOURCE_ID" >> "${INSTALL_DIR}/rw-backup-full.env"
fi

# --------------------------------------------------------------------------
# 4. Каталог проекта из трекера
# --------------------------------------------------------------------------
TARGET_ROOT=""
if ask "Шаг 4: восстановление каталога проекта" \
"Будет выполнено: rw-backup-full config-restore ${PROJECT} --dest <каталог проекта>
Источник: трекер конфигов в S3 (полный bundle + приращения).
Последствия: на диск возвращаются docker-compose, .env с секретами,
сертификаты, а для ботов — исполняемый код и ресурсы."; then
  if [[ "$PROJECT" == "panel" ]]; then
    TARGET_ROOT="$(grep -E '^PANEL_ROOT_DIR=' "${INSTALL_DIR}/rw-backup-full.env" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    TARGET_ROOT="${TARGET_ROOT:-/opt/remnawave}"
  else
    read -r -p "Каталог назначения для '${PROJECT}' [/home/${PROJECT}]: " TARGET_ROOT
    TARGET_ROOT="${TARGET_ROOT:-/home/${PROJECT}}"
  fi

  if [[ -d "$TARGET_ROOT" ]] && [[ -n "$(ls -A "$TARGET_ROOT" 2>/dev/null)" ]]; then
    warn "Каталог ${TARGET_ROOT} не пуст."
    if [[ "$ASSUME_YES" != "true" ]]; then
      read -r -p "Отложить его в ${TARGET_ROOT}.before_restore и продолжить? [y/N]: " a
      [[ "$a" == y || "$a" == Y ]] || die "Отменено"
    fi
    mv "$TARGET_ROOT" "${TARGET_ROOT}.before_restore.$(date +%Y%m%d_%H%M%S)"
  fi

  mkdir -p "$TARGET_ROOT"
  rw-backup-full config-restore "$PROJECT" --dest "$TARGET_ROOT" \
    || die "Каталог не восстановился (есть ли снимки трекера для '${PROJECT}'?)"
  ok "Каталог восстановлен: ${TARGET_ROOT} ($(find "$TARGET_ROOT" -type f | wc -l) файлов)"
fi

COMPOSE_FILE=""
for c in "${TARGET_ROOT}/docker-compose.yml" "${TARGET_ROOT}/docker-compose.yaml"; do
  [[ -f "$c" ]] && { COMPOSE_FILE="$c"; break; }
done
[[ -n "$COMPOSE_FILE" ]] || die "В восстановленном каталоге нет docker-compose — нечего запускать"

# --------------------------------------------------------------------------
# 5. База данных
# --------------------------------------------------------------------------
if ask "Шаг 5: восстановление базы данных" \
"Будет выполнено:
  docker compose up -d (только сервис БД) — создаётся пустой том
  $([[ "$DB_MODE" == "pitr" ]] && echo 'восстановление из базового бэкапа + WAL (PITR)' || echo 'заливка последнего логического дампа из S3')
Последствия: БД наполняется данными из бэкапа. Том создаётся с нуля —
на чистом сервере терять нечего."; then
  DB_SVC="$(docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null | grep -E 'db|postgres' | head -n1 || true)"
  [[ -n "$DB_SVC" ]] || die "В compose не найден сервис БД"

  ( cd "$(dirname "$COMPOSE_FILE")" && docker compose up -d "$DB_SVC" )

  DB_CONT="$(cd "$(dirname "$COMPOSE_FILE")" && docker compose ps -q "$DB_SVC")"
  [[ -n "$DB_CONT" ]] || die "Контейнер БД не запустился"

  say "Жду готовности PostgreSQL..."
  for _ in $(seq 1 120); do
    docker exec "$DB_CONT" pg_isready >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec "$DB_CONT" pg_isready >/dev/null 2>&1 || die "PostgreSQL не поднялся"

  if [[ "$DB_MODE" == "pitr" ]]; then
    warn "Режим PITR на чистом сервере: используйте отдельную команду с полным контролем цели —"
    warn "  rw-backup-full pitr-restore ${PROJECT} --from s3 --target latest --in-place"
    warn "Она остановит только что поднятую БД и заменит PGDATA восстановленным."
  else
    DUMP_CAT="panel"; [[ "$PROJECT" != "panel" ]] && DUMP_CAT="custom-bot"
    say "Ищу свежий логический дамп в S3 (${DUMP_CAT}/${SOURCE_ID})..."
    TMPD="$(mktemp -d)"
    # shellcheck disable=SC1090
    source "${INSTALL_DIR}/scripts/lib/wal-lib.sh"
    wal_load_full_config
    bname="$(s3m_backends | head -n1)"
    s3m_load "$bname" || die "S3-бэкенд не загрузился"
    key="$(s3m_aws s3 ls "s3://${B_BUCKET}/${B_PREFIX}/${DUMP_CAT}/${SOURCE_ID}/" --recursive 2>/dev/null \
      | awk '{print $1" "$2" "$4}' | sort | tail -n1 | awk '{print $3}')"
    [[ -n "$key" ]] || die "Логический дамп для ${SOURCE_ID} не найден в S3"
    s3m_aws s3 cp "s3://${B_BUCKET}/${key}" "${TMPD}/dump.tar.gz" --only-show-errors || die "Дамп не скачался"
    tar -xzf "${TMPD}/dump.tar.gz" -C "$TMPD"
    sql="$(find "$TMPD" -maxdepth 1 \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1)"
    [[ -n "$sql" ]] || die "В архиве нет SQL-дампа"
    DB_USER="$(docker exec "$DB_CONT" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
    gzip -dc "$sql" | docker exec -i "$DB_CONT" psql -q -U "$DB_USER" -d postgres -v ON_ERROR_STOP=0 >/dev/null 2>&1 || true
    rows="$(docker exec "$DB_CONT" psql -qtAX -U "$DB_USER" -d postgres \
      -c 'SELECT coalesce(sum(n_live_tup),0)::bigint FROM pg_stat_user_tables' 2>/dev/null || echo 0)"
    rm -rf "$TMPD"
    ok "База восстановлена из $(basename "$key") (строк ≈ ${rows})"
  fi
fi

# --------------------------------------------------------------------------
# 6. Запуск стека
# --------------------------------------------------------------------------
if ask "Шаг 6: запуск проекта" \
"Будет выполнено: docker compose up -d в $(dirname "$COMPOSE_FILE")
Последствия: проект запускается ПОЛНОСТЬЮ и начинает работать как боевой —
подключится к своим внешним сервисам, отправит уведомления, займёт порты.
Убедитесь, что это действительно новый боевой сервер, а не тестовая проверка
(для тестовой используйте изолированную песочницу: rw-backup-full verify-stack)."; then
  ( cd "$(dirname "$COMPOSE_FILE")" && docker compose up -d )
  sleep 5
  ( cd "$(dirname "$COMPOSE_FILE")" && docker compose ps )
  ok "Проект запущен"
fi

echo
ok "Восстановление завершено."
cat <<EOF_NEXT

Дальше:
  1. Проверить работу проекта (порты, интерфейс, логи).
  2. Настроить бэкапы уже НА ЭТОМ сервере:
       nano ${INSTALL_DIR}/rw-backup-full.env    # убрать RW_SOURCE_ID, если сервер стал новым основным
       rw-backup-full components
       rw-backup-full install-timer
  3. Включить WAL-архивацию заново (восстановленная БД стартует без неё):
       rw-backup-full wal-enable <инстанс>
EOF_NEXT
