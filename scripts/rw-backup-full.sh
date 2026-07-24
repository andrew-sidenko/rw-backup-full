#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
FULL_CONFIG_FILE="${FULL_CONFIG_FILE:-${INSTALL_DIR}/rw-backup-full.env}"
WAL_SCRIPTS_DIR="${WAL_SCRIPTS_DIR:-${INSTALL_DIR}/scripts/wal}"
SANDBOX_SCRIPTS_DIR="${SANDBOX_SCRIPTS_DIR:-${INSTALL_DIR}/scripts/sandbox}"
INSTANCES_DIR="${INSTANCES_DIR:-${INSTALL_DIR}/instances.d}"
PANEL_SCRIPTS_DIR="${PANEL_SCRIPTS_DIR:-${INSTALL_DIR}/scripts/panel}"
METRICS_SCRIPTS_DIR="${METRICS_SCRIPTS_DIR:-${INSTALL_DIR}/scripts/metrics}"
TRACK_SCRIPTS_DIR="${TRACK_SCRIPTS_DIR:-${INSTALL_DIR}/scripts/track}"
if [[ -f "${INSTALL_DIR}/scripts/lib/s3-multi.sh" ]]; then
  # shellcheck disable=SC1091
  source "${INSTALL_DIR}/scripts/lib/s3-multi.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/s3-multi.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/lib/s3-multi.sh"
fi
if [[ -f "${INSTALL_DIR}/scripts/lib/wal-lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${INSTALL_DIR}/scripts/lib/wal-lib.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/wal-lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/lib/wal-lib.sh"
fi

RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
RESET=$'\e[0m'
BOLD=$'\e[1m'


FULL_LOCAL_RETENTION_DAYS="3"
FULL_EXTERNAL_S3_RETENTION_DAYS="10"
FULL_TIMER_INTERVAL_HOURS="3"
FULL_TIMER_MODE="backup-all"
FULL_INCLUDE_EXTRA_CONFIGS="true"
FULL_PANEL_EXTERNAL_S3_ENABLED="true"
FULL_CUSTOM_EXTERNAL_S3_ENABLED="true"
FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD="true"
FULL_TELEGRAM_IMPORT_FROM_ORIGINAL="true"
FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL="false"
FULL_TG_BOT_TOKEN=""
FULL_TG_CHAT_ID=""
FULL_TG_MESSAGE_THREAD_ID=""
FULL_TG_PROXY=""
FULL_EXTERNAL_S3_BUCKET=""
FULL_EXTERNAL_S3_ACCESS_KEY=""
FULL_EXTERNAL_S3_SECRET_KEY=""
FULL_EXTERNAL_S3_REGION="us-east-1"
FULL_EXTERNAL_S3_ENDPOINT=""
FULL_EXTERNAL_S3_PREFIX="rw-backup-full"

msg() {
  local type="$1"
  local text="$2"
  local color="$RESET"

  case "$type" in
    INFO) color="$CYAN" ;;
    OK) color="$GREEN" ;;
    WARN) color="$YELLOW" ;;
    ERR) color="$RED" ;;
  esac

  echo -e "${color}[${type}]${RESET} ${text}"
}

pause() {
  echo
  read -r -p "Enter..." _ || true
}

# parse_times_list "03:00, 15:30" -> "03:00:00 15:30:00"; код 1 при ошибке.
parse_times_list() {
  local raw="$1" out="" t hh mm ss
  raw="${raw//,/ }"
  for t in $raw; do
    if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$ ]]; then
      hh="${BASH_REMATCH[1]}"; mm="${BASH_REMATCH[2]}"; ss="${BASH_REMATCH[4]:-00}"
      (( 10#$hh > 23 || 10#$mm > 59 || 10#$ss > 59 )) && { msg ERR "Некорректное время: ${t}"; return 1; }
      out+="$(printf '%02d:%s:%s' "$((10#$hh))" "$mm" "$ss") "
    else
      msg ERR "Некорректный формат времени: '${t}' (HH:MM или HH:MM:SS)"
      return 1
    fi
  done
  [[ -n "$out" ]] || { msg ERR "Пустой список времён"; return 1; }
  printf '%s\n' "${out% }"
}


load_config() {
  mkdir -p "$BACKUP_DIR"

  if [[ -f "$FULL_CONFIG_FILE" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$FULL_CONFIG_FILE"
    set -u
  fi

  FULL_LOCAL_RETENTION_DAYS="${FULL_LOCAL_RETENTION_DAYS:-3}"
  FULL_EXTERNAL_S3_RETENTION_DAYS="${FULL_EXTERNAL_S3_RETENTION_DAYS:-10}"
  FULL_TIMER_INTERVAL_HOURS="${FULL_TIMER_INTERVAL_HOURS:-3}"
  FULL_TIMER_TIMES="${FULL_TIMER_TIMES:-}"
  FULL_SCHEDULE_TZ="${FULL_SCHEDULE_TZ:-}"
  FULL_TIMER_MODE="${FULL_TIMER_MODE:-backup-all}"
  FULL_INCLUDE_EXTRA_CONFIGS="${FULL_INCLUDE_EXTRA_CONFIGS:-true}"
  FULL_PANEL_EXTERNAL_S3_ENABLED="${FULL_PANEL_EXTERNAL_S3_ENABLED:-true}"
  FULL_CUSTOM_EXTERNAL_S3_ENABLED="${FULL_CUSTOM_EXTERNAL_S3_ENABLED:-true}"
  FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD="${FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD:-true}"
  FULL_EXTERNAL_S3_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}"
  FULL_EXTERNAL_S3_PREFIX="${FULL_EXTERNAL_S3_PREFIX:-rw-backup-full}"
}

ensure_tools() {
  # Машинный статус не требует docker: веб-сервис должен получать JSON
  # даже с сервера, где docker временно недоступен.
  if [[ "${1:-}" == "fleet-manifest" ]] || [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
    return 0
  fi
  command -v docker >/dev/null 2>&1 || {
    msg ERR "docker не найден"
    exit 1
  }

  docker compose version >/dev/null 2>&1 || {
    msg ERR "docker compose не найден"
    exit 1
  }

  command -v tar >/dev/null 2>&1 || {
    msg ERR "tar не найден"
    exit 1
  }

  command -v gzip >/dev/null 2>&1 || {
    msg ERR "gzip не найден"
    exit 1
  }
}

truthy() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

safe_project_name() {
  echo "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

full_s3_prefix_normalized() {
  local prefix="${FULL_EXTERNAL_S3_PREFIX:-rw-backup-full}"
  prefix="${prefix#/}"
  prefix="${prefix%/}"

  if [[ -n "$prefix" ]]; then
    echo "${prefix}/"
  else
    echo ""
  fi
}

full_s3_ready() {
  [[ -n "${FULL_EXTERNAL_S3_BUCKET:-}" && -n "${FULL_EXTERNAL_S3_ACCESS_KEY:-}" && -n "${FULL_EXTERNAL_S3_SECRET_KEY:-}" ]]
}

full_telegram_ready() {
  [[ -n "${FULL_TG_BOT_TOKEN:-}" && -n "${FULL_TG_CHAT_ID:-}" ]]
}

full_telegram_api_url() {
  echo "https://api.telegram.org/bot${FULL_TG_BOT_TOKEN}/$1"
}

send_full_telegram_message() {
  local text="$1"

  full_telegram_ready || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local args=(
    -s
    -X POST
    "$(full_telegram_api_url sendMessage)"
    -d "chat_id=${FULL_TG_CHAT_ID}"
    -d "text=${text}"
  )

  if [[ -n "${FULL_TG_MESSAGE_THREAD_ID:-}" ]]; then
    args+=(-d "message_thread_id=${FULL_TG_MESSAGE_THREAD_ID}")
  fi

  if [[ -n "${FULL_TG_PROXY:-}" ]]; then
    args=(--proxy "$FULL_TG_PROXY" "${args[@]}")
  fi

  # Разовые сетевые сбои (curl exit 56/28/7) не должны стоить пропущенного
  # уведомления — 3 попытки с нарастающей паузой, как и при выгрузке в S3.
  local attempt
  for attempt in 1 2 3; do
    curl "${args[@]}" >/dev/null 2>&1 && return 0
    sleep $((attempt * 3))
  done
  return 1
}

full_s3_upload() {
  # v5: выгрузка во ВСЕ настроенные S3-бэкенды категории (s3.d/*.env).
  # Опционально 4-й аргумент — текстовый журнал (.txt рядом с архивом).
  local file_path="$1"
  local category="$2"
  local label="$3"
  local journal="${4:-}"
  if declare -F s3m_upload_all >/dev/null; then
    s3m_upload_all "$category" "$file_path" "$label" ${journal:+"$journal"}
    return $?
  fi

  if ! command -v aws >/dev/null 2>&1; then
    msg ERR "awscli не найден. Установи: apt-get update && apt-get install -y awscli"
    return 1
  fi

  if ! full_s3_ready; then
    msg ERR "FULL external S3 не настроен в ${FULL_CONFIG_FILE}"
    return 1
  fi

  local endpoint_arg=()
  if [[ -n "${FULL_EXTERNAL_S3_ENDPOINT:-}" ]]; then
    endpoint_arg=(--endpoint-url "$FULL_EXTERNAL_S3_ENDPOINT")
  fi

  local host
  local prefix
  local file_name
  local s3_key
  local size

  host="$(hostname -s 2>/dev/null || hostname)"
  prefix="$(full_s3_prefix_normalized)"
  file_name="$(basename "$file_path")"
  s3_key="${prefix}${category}/${host}/${file_name}"
  size="$(du -h "$file_path" | awk '{print $1}')"

  msg INFO "External S3 upload: s3://${FULL_EXTERNAL_S3_BUCKET}/${s3_key}"

  AWS_ACCESS_KEY_ID="$FULL_EXTERNAL_S3_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$FULL_EXTERNAL_S3_SECRET_KEY" \
  AWS_DEFAULT_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}" \
  aws s3 cp "$file_path" "s3://${FULL_EXTERNAL_S3_BUCKET}/${s3_key}" "${endpoint_arg[@]}" --quiet

  if truthy "$FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD"; then
    send_full_telegram_message "✅ External S3 backup saved
Type: ${category}
Name: ${label}
File: ${file_name}
Size: ${size}
S3: s3://${FULL_EXTERNAL_S3_BUCKET}/${s3_key}" || true
  fi
}

full_s3_retention_cleanup() {
  # v5: ретенция по всем бэкендам, у каждого свои сроки.
  if declare -F s3m_retention_logical_all >/dev/null; then
    s3m_retention_logical_all
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    msg WARN "awscli не найден, external S3 retention cleanup пропущен"
    return 0
  fi

  if ! full_s3_ready; then
    msg WARN "FULL external S3 не настроен, retention cleanup пропущен"
    return 0
  fi

  local retention_days="${FULL_EXTERNAL_S3_RETENTION_DAYS:-10}"

  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
    msg WARN "Некорректный FULL_EXTERNAL_S3_RETENTION_DAYS=${retention_days}, использую 10"
    retention_days="10"
  fi

  if (( retention_days <= 0 )); then
    msg WARN "External S3 retention выключен: ${retention_days}"
    return 0
  fi

  local endpoint_arg=()
  if [[ -n "${FULL_EXTERNAL_S3_ENDPOINT:-}" ]]; then
    endpoint_arg=(--endpoint-url "$FULL_EXTERNAL_S3_ENDPOINT")
  fi

  local prefix
  local s3_path
  local cutoff_epoch
  local checked_count=0
  local deleted_count=0

  prefix="$(full_s3_prefix_normalized)"
  s3_path="s3://${FULL_EXTERNAL_S3_BUCKET}/${prefix}"
  cutoff_epoch="$(date -u -d "-${retention_days} days" +%s)"

  msg INFO "External S3 retention: ${retention_days} дней, path=${s3_path}"

  while read -r file_date file_time file_size file_key; do
    [[ -n "${file_key:-}" ]] || continue

    local base_name
    local file_epoch

    base_name="$(basename "$file_key")"

    # Чистим только архивы, созданные full-дублированием: custom_bot_* и remnawave_backup_*.
    if [[ ! "$base_name" =~ ^custom_bot_.*\.tar\.gz$ && ! "$base_name" =~ ^remnawave_backup_.*\.tar\.gz$ ]]; then
      continue
    fi

    checked_count=$((checked_count + 1))
    file_epoch="$(date -u -d "${file_date} ${file_time}" +%s 2>/dev/null || echo 0)"

    if (( file_epoch > 0 && file_epoch < cutoff_epoch )); then
      msg INFO "Удаляю старый external S3 backup: ${file_key}"

      AWS_ACCESS_KEY_ID="$FULL_EXTERNAL_S3_ACCESS_KEY" \
      AWS_SECRET_ACCESS_KEY="$FULL_EXTERNAL_S3_SECRET_KEY" \
      AWS_DEFAULT_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}" \
      aws s3 rm "s3://${FULL_EXTERNAL_S3_BUCKET}/${file_key}" "${endpoint_arg[@]}" --quiet || true

      deleted_count=$((deleted_count + 1))
    fi
  done < <(
    AWS_ACCESS_KEY_ID="$FULL_EXTERNAL_S3_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$FULL_EXTERNAL_S3_SECRET_KEY" \
    AWS_DEFAULT_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}" \
    aws s3 ls "$s3_path" "${endpoint_arg[@]}" --recursive 2>/dev/null || true
  )

  msg OK "External S3 retention complete: checked=${checked_count}, deleted=${deleted_count}, retention_days=${retention_days}"
}

cleanup_local_custom_backups() {
  local retention_days="${FULL_LOCAL_RETENTION_DAYS:-3}"

  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
    msg WARN "Некорректный FULL_LOCAL_RETENTION_DAYS=${retention_days}, использую 3"
    retention_days="3"
  fi

  if (( retention_days <= 0 )); then
    msg WARN "Локальная очистка выключена: ${retention_days}"
    return 0
  fi

  msg INFO "Очищаю локальные custom_bot_*.tar.gz старше ${retention_days} дней"

  find "$BACKUP_DIR" \
    -type f \
    -name 'custom_bot_*.tar.gz' \
    -mtime "+${retention_days}" \
    -delete 2>/dev/null || true
}




local_panel_detected() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "remnawave-db"; then
    return 0
  fi

  if [[ -f "/opt/remnawave/docker-compose.yml" || -f "/opt/remnawave/docker-compose.yaml" ]]; then
    return 0
  fi

  return 1
}

latest_panel_backup() {
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'remnawave_backup_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}'
}

run_panel_backup() {
  if ! local_panel_detected; then
    msg WARN "Локальная Remnawave panel не найдена, panel backup пропущен"
    return 0
  fi

  local before_latest
  local after_latest

  before_latest="$(latest_panel_backup || true)"

  msg INFO "Panel backup: встроенный движок"
  "${PANEL_SCRIPTS_DIR}/panel-backup.sh"

  after_latest="$(latest_panel_backup || true)"

  if [[ -z "$after_latest" ]]; then
    msg WARN "После panel backup не найден remnawave_backup_*.tar.gz"
    return 0
  fi

  msg OK "Panel backup найден: ${after_latest}"

  # Встроенный движок сам выгружает во все S3-бэкенды; здесь только ретенция.
  full_s3_retention_cleanup
}

docker_label() {
  local container="$1"
  local label="$2"

  docker inspect -f "{{ index .Config.Labels \"$label\" }}" "$container" 2>/dev/null || true
}

detect_custom_projects() {
  declare -A project_dirs

  while read -r container; do
    [[ -n "$container" ]] || continue

    local project
    local workdir

    project="$(docker_label "$container" "com.docker.compose.project")"
    workdir="$(docker_label "$container" "com.docker.compose.project.working_dir")"

    [[ -n "$project" && "$project" != "<no value>" ]] || continue
    [[ -n "$workdir" && "$workdir" != "<no value>" ]] || continue
    [[ "$workdir" == /home/* ]] || continue
    [[ -d "$workdir" ]] || continue

    project_dirs["$project"]="$workdir"
  done < <(docker ps -a --format '{{.Names}}')

  local project

  for project in "${!project_dirs[@]}"; do
    local dir="${project_dirs[$project]}"
    local pg_container=""
    local pg_service=""
    local redis_container=""
    local redis_service=""
    local apps=()

    while read -r container; do
      [[ -n "$container" ]] || continue

      local c_project
      local c_service
      local c_image

      c_project="$(docker_label "$container" "com.docker.compose.project")"
      [[ "$c_project" == "$project" ]] || continue

      c_service="$(docker_label "$container" "com.docker.compose.service")"
      c_image="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"

      if [[ "$c_service" == "postgres" || "$c_image" =~ postgres ]]; then
        pg_container="$container"
        pg_service="${c_service:-postgres}"
      elif [[ "$c_service" == "redis" || "$c_image" =~ redis || "$c_image" =~ valkey ]]; then
        redis_container="$container"
        redis_service="${c_service:-redis}"
      else
        apps+=("$container")
      fi
    done < <(docker ps -a --format '{{.Names}}')

    if [[ -n "$pg_container" && -n "$redis_container" ]]; then
      echo "${project}|${dir}|${pg_container}|${pg_service}|${redis_container}|${redis_service}|${apps[*]}"
    fi
  done
}

print_custom_projects() {
  local found=0

  while IFS='|' read -r project dir pg pg_service redis redis_service apps; do
    found=1
    echo
    echo -e "${GREEN}${BOLD}${project}${RESET}"
    echo "  dir:      ${dir}"
    echo "  postgres: ${pg} / service=${pg_service}"
    echo "  redis:    ${redis} / service=${redis_service}"
    echo "  apps:     ${apps}"
  done < <(detect_custom_projects)

  if [[ "$found" -eq 0 ]]; then
    msg WARN "Custom bot compose-проекты в /home не найдены"
  fi
}

select_custom_project() {
  mapfile -t projects < <(detect_custom_projects)

  if [[ "${#projects[@]}" -eq 0 ]]; then
    msg ERR "Не найдено custom bot проектов в /home"
    return 1
  fi

  if [[ "${#projects[@]}" -eq 1 ]]; then
    echo "${projects[0]}"
    return 0
  fi

  echo
  echo -e "${GREEN}${BOLD}Выбери custom bot project:${RESET}"
  echo

  local i=1
  local entry

  for entry in "${projects[@]}"; do
    IFS='|' read -r project dir pg pg_service redis redis_service apps <<< "$entry"
    echo " ${i}. ${project} — ${dir}"
    ((i++))
  done

  echo
  read -r -p "[?] Номер: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    msg ERR "Некорректный выбор"
    return 1
  fi

  if (( choice < 1 || choice > ${#projects[@]} )); then
    msg ERR "Некорректный выбор"
    return 1
  fi

  echo "${projects[$((choice - 1))]}"
}

write_profile_env() {
  local file="$1"
  local project_name="$2"
  local project_dir="$3"
  local pg_container="$4"
  local pg_service="$5"
  local redis_container="$6"
  local redis_service="$7"
  local app_containers="$8"
  local timestamp="$9"

  {
    printf 'PROJECT_NAME=%q\n' "$project_name"
    printf 'PROJECT_DIR=%q\n' "$project_dir"
    printf 'POSTGRES_CONTAINER=%q\n' "$pg_container"
    printf 'POSTGRES_SERVICE=%q\n' "$pg_service"
    printf 'REDIS_CONTAINER=%q\n' "$redis_container"
    printf 'REDIS_SERVICE=%q\n' "$redis_service"
    printf 'APP_CONTAINERS=%q\n' "$app_containers"
    printf 'CREATED_AT=%q\n' "$timestamp"
  } > "$file"
}

backup_custom_project_entry() {
  local entry="$1"

  IFS='|' read -r PROJECT_NAME PROJECT_DIR POSTGRES_CONTAINER POSTGRES_SERVICE REDIS_CONTAINER REDIS_SERVICE APP_CONTAINERS <<< "$entry"

  local TIMESTAMP
  local SAFE_PROJECT
  local WORK_DIR
  local FINAL_ARCHIVE
  local PROJECT_BASE

  TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
  SAFE_PROJECT="$(safe_project_name "$PROJECT_NAME")"
  WORK_DIR="${BACKUP_DIR}/custom_bot_${SAFE_PROJECT}_${TIMESTAMP}"
  FINAL_ARCHIVE="${BACKUP_DIR}/custom_bot_${SAFE_PROJECT}_${TIMESTAMP}.tar.gz"
  PROJECT_BASE="$(basename "$PROJECT_DIR")"

  mkdir -p "$WORK_DIR"

  msg INFO "Backup custom bot: ${PROJECT_NAME}"
  msg INFO "Project dir: ${PROJECT_DIR}"
  msg INFO "PostgreSQL: ${POSTGRES_CONTAINER}"
  msg INFO "Redis: ${REDIS_CONTAINER}"

  [[ -d "$PROJECT_DIR" ]] || {
    msg ERR "Project dir не найден: ${PROJECT_DIR}"
    return 1
  }

  docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1 || {
    msg ERR "PostgreSQL container не найден: ${POSTGRES_CONTAINER}"
    return 1
  }

  docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1 || {
    msg ERR "Redis container не найден: ${REDIS_CONTAINER}"
    return 1
  }

  write_profile_env \
    "$WORK_DIR/PROFILE.env" \
    "$PROJECT_NAME" \
    "$PROJECT_DIR" \
    "$POSTGRES_CONTAINER" \
    "$POSTGRES_SERVICE" \
    "$REDIS_CONTAINER" \
    "$REDIS_SERVICE" \
    "$APP_CONTAINERS" \
    "$TIMESTAMP"

  msg INFO "Сохраняю docker metadata..."

  docker ps -a > "$WORK_DIR/docker-ps-a.txt" 2>/dev/null || true
  docker volume ls > "$WORK_DIR/docker-volume-ls.txt" 2>/dev/null || true
  docker network ls > "$WORK_DIR/docker-network-ls.txt" 2>/dev/null || true

  for c in $APP_CONTAINERS "$POSTGRES_CONTAINER" "$REDIS_CONTAINER"; do
    docker inspect "$c" > "$WORK_DIR/inspect-${c}.json" 2>/dev/null || true
  done

  msg INFO "Сохраняю compose metadata..."

  (
    cd "$PROJECT_DIR"
    docker compose ps -a > "$WORK_DIR/docker-compose-ps-a.txt" 2>/dev/null || true
    docker compose config --services > "$WORK_DIR/docker-compose-services.txt" 2>/dev/null || true
    docker compose config > "$WORK_DIR/docker-compose-rendered.yaml" 2>/dev/null || true
  )

  msg INFO "Создаю PostgreSQL dump..."

  docker exec "$POSTGRES_CONTAINER" sh -lc '
    export PGPASSWORD="${POSTGRES_PASSWORD:-}"
    pg_dumpall -c -U "${POSTGRES_USER:-postgres}"
  ' | gzip -9 > "$WORK_DIR/postgres_dump.sql.gz"

  msg INFO "Создаю Redis dump..."

  if docker exec "$REDIS_CONTAINER" sh -lc '
    if [ -n "${REDIS_PASSWORD:-}" ]; then
      redis-cli -a "$REDIS_PASSWORD" --no-auth-warning SAVE
    else
      redis-cli SAVE
    fi
  ' >/dev/null 2>&1; then
    docker cp "$REDIS_CONTAINER:/data/dump.rdb" "$WORK_DIR/redis_dump.rdb" 2>/dev/null || true
  else
    msg WARN "Redis SAVE не прошёл, пробую забрать существующий dump.rdb"
    echo "Redis SAVE failed; copied existing dump.rdb if available" > "$WORK_DIR/redis-warning.txt"
    docker cp "$REDIS_CONTAINER:/data/dump.rdb" "$WORK_DIR/redis_dump.rdb" 2>/dev/null || true
  fi

  msg INFO "Сохраняю информацию о volumes..."

  find "$PROJECT_DIR/volumes" -maxdepth 6 -print > "$WORK_DIR/volumes-tree.txt" 2>/dev/null || true
  du -sh "$PROJECT_DIR/volumes"/* > "$WORK_DIR/volumes-size.txt" 2>/dev/null || true

  msg INFO "Архивирую проект без live PostgreSQL/Redis каталогов..."

  tar \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='.pytest_cache' \
    --exclude='*.pyc' \
    --exclude='*.log' \
    --exclude='venv' \
    --exclude='.venv' \
    --exclude='node_modules' \
    --exclude="${PROJECT_BASE}/volumes/pgdata" \
    --exclude="${PROJECT_BASE}/volumes/redis" \
    --exclude='*/volumes/pgdata' \
    --exclude='*/volumes/redis' \
    -czf "$WORK_DIR/project_dir.tar.gz" \
    -C "$(dirname "$PROJECT_DIR")" \
    "$PROJECT_BASE"

  if truthy "$FULL_INCLUDE_EXTRA_CONFIGS"; then
    msg INFO "Сохраняю дополнительные конфиги Caddy/subscription, если есть..."

    mkdir -p "$WORK_DIR/extra_configs"

    if [[ -d "/opt/remnawave/caddy" ]]; then
      tar -czf "$WORK_DIR/extra_configs/caddy_config.tar.gz" \
        -C /opt/remnawave \
        caddy
    fi

    if [[ -d "/opt/remnawave/subscription" ]]; then
      tar -czf "$WORK_DIR/extra_configs/subscription_config.tar.gz" \
        -C /opt/remnawave \
        subscription
    fi
  fi

  cat > "$WORK_DIR/BACKUP_NOTES.txt" <<NOTES
Custom bot backup

Project: ${PROJECT_NAME}
Project dir: ${PROJECT_DIR}
Created at: ${TIMESTAMP}

PostgreSQL:
  container: ${POSTGRES_CONTAINER}
  service: ${POSTGRES_SERVICE}
  method: pg_dumpall

Redis:
  container: ${REDIS_CONTAINER}
  service: ${REDIS_SERVICE}
  method: redis-cli SAVE + dump.rdb

App containers:
  ${APP_CONTAINERS}

Excluded from project archive:
  volumes/pgdata
  volumes/redis
NOTES

  (
    cd "$WORK_DIR"
    find . -type f -maxdepth 3 -print0 | xargs -0 sha256sum > SHA256SUMS 2>/dev/null || true
  )

  msg INFO "Создаю финальный архив..."

  (
    cd "$BACKUP_DIR"
    tar -czf "$FINAL_ARCHIVE" "$(basename "$WORK_DIR")"
  )

  rm -rf "$WORK_DIR"

  msg OK "Backup создан: ${FINAL_ARCHIVE}"
  du -h "$FINAL_ARCHIVE" || true

  local journal jname
  jname="$(declare -F s3m_journal_name >/dev/null && s3m_journal_name "$(basename "$FINAL_ARCHIVE")" || echo "$(basename "$FINAL_ARCHIVE" .tar.gz).txt")"
  journal="${BACKUP_DIR}/${jname}"
  {
    echo "rw-backup-full custom-bot backup journal"
    echo "host=$(hostname -s 2>/dev/null || hostname) project=${PROJECT_NAME}"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "file=$(basename "$FINAL_ARCHIVE")"
    echo "size=$(du -h "$FINAL_ARCHIVE" | awk '{print $1}')"
    echo "result=ok"
  } > "$journal"

  if truthy "$FULL_CUSTOM_EXTERNAL_S3_ENABLED"; then
    full_s3_upload "$FINAL_ARCHIVE" "custom-bot" "$PROJECT_NAME" "$journal" || msg WARN "Не удалось загрузить custom bot backup во внешний S3"
    full_s3_retention_cleanup
  fi

  cleanup_local_custom_backups
}

backup_custom_menu() {
  local entry
  entry="$(select_custom_project)" || return 1
  backup_custom_project_entry "$entry"
}

backup_custom_all() {
  local found=0
  local entry

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    found=1
    backup_custom_project_entry "$entry"
  done < <(detect_custom_projects)

  if [[ "$found" -eq 0 ]]; then
    msg WARN "Custom bot проекты не найдены"
    return 1
  fi
}

select_restore_archive() {
  mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'custom_bot_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')

  echo
  echo -e "${GREEN}${BOLD}Выбери архив для восстановления:${RESET}"
  echo

  if [[ "${#archives[@]}" -gt 0 ]]; then
    local i=1
    local a

    for a in "${archives[@]}"; do
      echo " ${i}. $(basename "$a") — $(du -h "$a" | awk '{print $1}')"
      ((i++))
    done

    echo
  else
    msg WARN "Локальные custom_bot архивы не найдены в ${BACKUP_DIR}"
  fi

  echo " 0. Указать путь вручную"
  echo

  read -r -p "[?] Номер или 0: " choice

  if [[ "$choice" == "0" ]]; then
    read -r -p "Путь к архиву: " manual_archive

    [[ -f "$manual_archive" ]] || {
      msg ERR "Файл не найден: ${manual_archive}"
      return 1
    }

    echo "$manual_archive"
    return 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    msg ERR "Некорректный выбор"
    return 1
  fi

  if (( choice < 1 || choice > ${#archives[@]} )); then
    msg ERR "Некорректный выбор"
    return 1
  fi

  echo "${archives[$((choice - 1))]}"
}

restore_custom_archive() {
  local archive="$1"
  local assume_yes="${2:-no}"

  [[ -f "$archive" ]] || {
    msg ERR "Архив не найден: ${archive}"
    return 1
  }

  local restore_ts="$(date +%Y%m%d_%H%M%S)"
  local tmp_root="/tmp/rw-custom-restore-${restore_ts}"
  local extract_dir="${tmp_root}/outer"
  local project_extract_dir="${tmp_root}/project"

  mkdir -p "$extract_dir" "$project_extract_dir"

  cleanup_restore_tmp() {
    rm -rf "$tmp_root"
  }

  trap cleanup_restore_tmp RETURN

  msg INFO "Распаковываю архив: ${archive}"

  tar -xzf "$archive" -C "$extract_dir"

  local project_tar="$(find "$extract_dir" -type f -name 'project_dir.tar.gz' | head -n 1 || true)"
  local postgres_dump="$(find "$extract_dir" -type f -name 'postgres_dump.sql.gz' | head -n 1 || true)"
  local redis_dump="$(find "$extract_dir" -type f -name 'redis_dump.rdb' | head -n 1 || true)"
  local profile_env="$(find "$extract_dir" -type f -name 'PROFILE.env' | head -n 1 || true)"

  [[ -n "$project_tar" ]] || {
    msg ERR "В архиве нет project_dir.tar.gz"
    return 1
  }

  [[ -n "$postgres_dump" ]] || {
    msg ERR "В архиве нет postgres_dump.sql.gz"
    return 1
  }

  if [[ -n "$profile_env" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$profile_env"
    set -u
  fi

  local project_top="$(tar -tzf "$project_tar" | head -n 1 | cut -d/ -f1)"

  [[ -n "$project_top" ]] || {
    msg ERR "Не могу определить папку проекта внутри project_dir.tar.gz"
    return 1
  }

  PROJECT_NAME="${PROJECT_NAME:-$project_top}"
  PROJECT_DIR="${PROJECT_DIR:-/home/$project_top}"
  POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-vpn_postgres}"
  POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
  REDIS_CONTAINER="${REDIS_CONTAINER:-vpn_redis}"
  REDIS_SERVICE="${REDIS_SERVICE:-redis}"

  echo
  echo -e "${YELLOW}${BOLD}Restore custom bot${RESET}"
  echo "  archive:            ${archive}"
  echo "  project in archive: ${project_top}"
  echo "  target dir:         ${PROJECT_DIR}"
  echo "  postgres:           ${POSTGRES_CONTAINER} / service=${POSTGRES_SERVICE}"
  echo "  redis:              ${REDIS_CONTAINER} / service=${REDIS_SERVICE}"
  echo

  if [[ "$assume_yes" != "yes" ]]; then
    read -r -p "Восстановить в ${PROJECT_DIR}? Напиши RESTORE: " confirm

    if [[ "$confirm" != "RESTORE" ]]; then
      msg WARN "Restore отменён"
      return 1
    fi
  fi

  local old_dir="${PROJECT_DIR}.before_restore_${restore_ts}"

  if [[ -d "$PROJECT_DIR" ]]; then
    msg INFO "Останавливаю текущий compose-проект..."

    if [[ -f "$PROJECT_DIR/docker-compose.yaml" || -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/compose.yaml" || -f "$PROJECT_DIR/compose.yml" ]]; then
      (
        cd "$PROJECT_DIR"
        docker compose down || true
      )
    fi

    msg INFO "Переименовываю текущую папку в: ${old_dir}"
    mv "$PROJECT_DIR" "$old_dir"
  fi

  msg INFO "Распаковываю project_dir.tar.gz..."

  tar -xzf "$project_tar" -C "$project_extract_dir"

  mkdir -p "$(dirname "$PROJECT_DIR")"
  mv "$project_extract_dir/$project_top" "$PROJECT_DIR"

  msg OK "Папка проекта восстановлена: ${PROJECT_DIR}"

  if [[ -n "$redis_dump" && -f "$redis_dump" ]]; then
    msg INFO "Восстанавливаю Redis dump до запуска Redis..."

    mkdir -p "$PROJECT_DIR/volumes/redis"
    cp -a "$redis_dump" "$PROJECT_DIR/volumes/redis/dump.rdb"
    chmod 777 "$PROJECT_DIR/volumes/redis" 2>/dev/null || true
    chmod 666 "$PROJECT_DIR/volumes/redis/dump.rdb" 2>/dev/null || true
  else
    msg WARN "redis_dump.rdb не найден, Redis восстановление пропущено"
  fi

  cd "$PROJECT_DIR"

  msg INFO "Поднимаю PostgreSQL service: ${POSTGRES_SERVICE}"
  docker compose up -d "$POSTGRES_SERVICE"

  msg INFO "Жду готовности PostgreSQL..."

  local ready="no"

  for i in $(seq 1 60); do
    if docker exec "$POSTGRES_CONTAINER" sh -lc 'pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' >/dev/null 2>&1; then
      ready="yes"
      break
    fi

    echo "[INFO] PostgreSQL not ready: ${i}/60"
    sleep 2
  done

  if [[ "$ready" != "yes" ]]; then
    msg ERR "PostgreSQL не стал готовым"
    docker logs "$POSTGRES_CONTAINER" --tail 100 || true
    return 1
  fi

  msg INFO "Заливаю PostgreSQL dump..."

  gzip -dc "$postgres_dump" | docker exec -i "$POSTGRES_CONTAINER" sh -lc '
    export PGPASSWORD="${POSTGRES_PASSWORD:-}"
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d postgres
  '

  msg OK "PostgreSQL восстановлен"

  msg INFO "Поднимаю Redis service: ${REDIS_SERVICE}"
  docker compose up -d "$REDIS_SERVICE"

  sleep 3

  msg INFO "Поднимаю весь compose-проект..."
  docker compose up -d

  echo
  docker compose ps -a
  echo

  msg OK "Restore завершён"

  if [[ -d "$old_dir" ]]; then
    msg INFO "Старая папка сохранена: ${old_dir}"
  fi
}

restore_custom_menu() {
  local archive
  archive="$(select_restore_archive)" || return 1
  restore_custom_archive "$archive"
}

backup_all() {
  msg INFO "Запускаю Backup ALL"

  run_panel_backup || msg WARN "Panel backup завершился с ошибкой или был пропущен"
  backup_custom_all || msg WARN "Custom bot backup завершился с ошибкой или проекты не найдены"

  msg OK "Backup ALL завершён"
}

backup_panel_only() {
  run_panel_backup
}

set_full_var() {
  local key="$1"
  local value="$2"

  mkdir -p "$(dirname "$FULL_CONFIG_FILE")"
  touch "$FULL_CONFIG_FILE"

  local escaped
  escaped="$(printf '%s' "$value" | sed 's/[\\&]/\\&/g')"

  if grep -qE "^${key}=" "$FULL_CONFIG_FILE"; then
    sed -i -E "s|^${key}=.*|${key}=\"${escaped}\"|" "$FULL_CONFIG_FILE"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$FULL_CONFIG_FILE"
  fi
}

configure_retention() {
  echo
  echo -e "${GREEN}${BOLD}Настройка хранения${RESET}"
  echo
  echo "Текущее локальное хранение custom backup: ${FULL_LOCAL_RETENTION_DAYS} дней"
  echo "Текущее хранение external S3 backup: ${FULL_EXTERNAL_S3_RETENTION_DAYS} дней"
  echo

  read -r -p "Локальное хранение, дней [${FULL_LOCAL_RETENTION_DAYS}]: " local_days
  local_days="${local_days:-$FULL_LOCAL_RETENTION_DAYS}"

  read -r -p "External S3 хранение, дней [${FULL_EXTERNAL_S3_RETENTION_DAYS}]: " s3_days
  s3_days="${s3_days:-$FULL_EXTERNAL_S3_RETENTION_DAYS}"

  if ! [[ "$local_days" =~ ^[0-9]+$ && "$s3_days" =~ ^[0-9]+$ ]]; then
    msg ERR "Значения должны быть числами"
    return 1
  fi

  set_full_var FULL_LOCAL_RETENTION_DAYS "$local_days"
  set_full_var FULL_EXTERNAL_S3_RETENTION_DAYS "$s3_days"

  msg OK "Хранение обновлено"
}

configure_external_s3() {
  echo
  echo -e "${GREEN}${BOLD}Настройка собственного external S3 для rw-backup-full${RESET}"
  echo
  echo "Этот S3 независим от оригинального /opt/rw-backup-restore/config.env."
  echo

  read -r -p "Bucket [${FULL_EXTERNAL_S3_BUCKET}]: " bucket
  bucket="${bucket:-$FULL_EXTERNAL_S3_BUCKET}"

  read -r -p "Access key [${FULL_EXTERNAL_S3_ACCESS_KEY:+***set***}]: " access_key
  access_key="${access_key:-$FULL_EXTERNAL_S3_ACCESS_KEY}"

  read -r -p "Secret key [${FULL_EXTERNAL_S3_SECRET_KEY:+***set***}]: " secret_key
  secret_key="${secret_key:-$FULL_EXTERNAL_S3_SECRET_KEY}"

  read -r -p "Region [${FULL_EXTERNAL_S3_REGION}]: " region
  region="${region:-$FULL_EXTERNAL_S3_REGION}"

  read -r -p "Endpoint [${FULL_EXTERNAL_S3_ENDPOINT}]: " endpoint
  endpoint="${endpoint:-$FULL_EXTERNAL_S3_ENDPOINT}"

  read -r -p "Prefix [${FULL_EXTERNAL_S3_PREFIX}]: " prefix
  prefix="${prefix:-$FULL_EXTERNAL_S3_PREFIX}"

  set_full_var FULL_EXTERNAL_S3_BUCKET "$bucket"
  set_full_var FULL_EXTERNAL_S3_ACCESS_KEY "$access_key"
  set_full_var FULL_EXTERNAL_S3_SECRET_KEY "$secret_key"
  set_full_var FULL_EXTERNAL_S3_REGION "$region"
  set_full_var FULL_EXTERNAL_S3_ENDPOINT "$endpoint"
  set_full_var FULL_EXTERNAL_S3_PREFIX "$prefix"
  set_full_var FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL "false"

  msg OK "External S3 настройки обновлены"
}

configure_telegram() {
  echo
  echo -e "${GREEN}${BOLD}Настройка Telegram уведомлений rw-backup-full${RESET}"
  echo
  echo "Уведомление отправляется отдельно по каждому архиву, успешно сохранённому во внешний S3."
  echo

  read -r -p "Импортировать Telegram из оригинального config.env? true/false [${FULL_TELEGRAM_IMPORT_FROM_ORIGINAL}]: " import
  import="${import:-$FULL_TELEGRAM_IMPORT_FROM_ORIGINAL}"
  set_full_var FULL_TELEGRAM_IMPORT_FROM_ORIGINAL "$import"

  if [[ "$import" == "true" ]]; then
    msg OK "Будет использоваться Telegram из оригинального config.env, если FULL_TG_* пустые"
    return 0
  fi

  read -r -p "Bot token [${FULL_TG_BOT_TOKEN:+***set***}]: " token
  token="${token:-$FULL_TG_BOT_TOKEN}"

  read -r -p "Chat ID [${FULL_TG_CHAT_ID}]: " chat
  chat="${chat:-$FULL_TG_CHAT_ID}"

  read -r -p "Thread ID [${FULL_TG_MESSAGE_THREAD_ID}]: " thread
  thread="${thread:-$FULL_TG_MESSAGE_THREAD_ID}"

  read -r -p "Proxy [${FULL_TG_PROXY}]: " proxy
  proxy="${proxy:-$FULL_TG_PROXY}"

  set_full_var FULL_TG_BOT_TOKEN "$token"
  set_full_var FULL_TG_CHAT_ID "$chat"
  set_full_var FULL_TG_MESSAGE_THREAD_ID "$thread"
  set_full_var FULL_TG_PROXY "$proxy"

  msg OK "Telegram настройки обновлены"
}

configure_timer() {
  echo
  echo -e "${GREEN}${BOLD}Настройка systemd timer${RESET}"
  echo
  echo "Текущий режим: ${FULL_TIMER_MODE}"
  echo "Текущий интервал: ${FULL_TIMER_INTERVAL_HOURS} часов"
  echo
  echo "Режимы:"
  echo "  backup-all     — панель + боты"
  echo "  panel-backup   — только панель"
  echo "  custom-backup  — только боты"
  echo

  read -r -p "Режим [${FULL_TIMER_MODE}]: " mode
  mode="${mode:-$FULL_TIMER_MODE}"

  case "$mode" in
    backup-all|panel-backup|custom-backup) ;;
    *) msg ERR "Некорректный режим"; return 1 ;;
  esac

  echo
  echo "Расписание запуска:"
  echo "  1) интервал (каждые N часов)"
  echo "  2) конкретные времена (список любой длины, напр.: 03:00 12:30 21:00)"
  local cur_mode="1"; [[ -n "${FULL_TIMER_TIMES:-}" ]] && cur_mode="2"
  read -r -p "Вариант [${cur_mode}]: " sched
  sched="${sched:-$cur_mode}"

  local hours="${FULL_TIMER_INTERVAL_HOURS}" times="${FULL_TIMER_TIMES:-}" norm=""
  if [[ "$sched" == "2" ]]; then
    read -r -p "Времена (HH:MM через пробел/запятую) [${times:-нет}]: " tin
    times="${tin:-$times}"
    norm="$(parse_times_list "$times")" || return 1
    times="$norm"
    read -r -p "Часовой пояс (пусто = локальный сервера; UTC; Europe/Amsterdam) [${FULL_SCHEDULE_TZ:-локальный}]: " tzin
    FULL_SCHEDULE_TZ="${tzin:-${FULL_SCHEDULE_TZ:-}}"
  else
    times=""
    read -r -p "Интервал, часов [${hours}]: " hin
    hours="${hin:-$hours}"
    if ! [[ "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 )); then
      msg ERR "Интервал должен быть числом >= 1"
      return 1
    fi
  fi

  set_full_var FULL_TIMER_MODE "$mode"
  set_full_var FULL_TIMER_INTERVAL_HOURS "$hours"
  set_full_var FULL_TIMER_TIMES "$times"
  set_full_var FULL_SCHEDULE_TZ "${FULL_SCHEDULE_TZ:-}"

  FULL_TIMER_MODE="$mode"
  FULL_TIMER_INTERVAL_HOURS="$hours"
  FULL_TIMER_TIMES="$times"

  install_timer
}

install_timer() {
  local hours="${FULL_TIMER_INTERVAL_HOURS:-3}"

  if ! [[ "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 )); then
    hours="3"
  fi

  msg INFO "Устанавливаю systemd timer: mode=${FULL_TIMER_MODE}, interval=${hours}h"

  cat > /etc/systemd/system/rw-backup-full.service <<EOF_SERVICE
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

  local times="${FULL_TIMER_TIMES:-}" tz="${FULL_SCHEDULE_TZ:-}" cal="" t desc
  if [[ -n "$times" ]]; then
    times="$(parse_times_list "$times")" || { msg ERR "FULL_TIMER_TIMES некорректен"; return 1; }
    for t in $times; do
      cal+="OnCalendar=*-*-* ${t}${tz:+ ${tz}}"$'\n'
    done
    desc="Run rw-backup-full at: ${times}${tz:+ (${tz})}"
    msg INFO "Расписание: ${times}${tz:+ (${tz})}"
    cat > /etc/systemd/system/rw-backup-full.timer <<EOF_TIMER
[Unit]
Description=${desc}

[Timer]
${cal}Persistent=true
Unit=rw-backup-full.service

[Install]
WantedBy=timers.target
EOF_TIMER
  else
    cat > /etc/systemd/system/rw-backup-full.timer <<EOF_TIMER
[Unit]
Description=Run rw-backup-full every ${hours} hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=${hours}h
Persistent=true
Unit=rw-backup-full.service

[Install]
WantedBy=timers.target
EOF_TIMER
  fi

  systemctl daemon-reload
  systemctl enable --now rw-backup-full.timer

  msg OK "Timer установлен и запущен"
  systemctl list-timers rw-backup-full.timer || true
}

run_timer_mode() {
  case "${FULL_TIMER_MODE:-backup-all}" in
    backup-all) backup_all ;;
    panel-backup) backup_panel_only ;;
    custom-backup) backup_custom_all ;;
    *) msg ERR "Неизвестный FULL_TIMER_MODE=${FULL_TIMER_MODE}"; return 1 ;;
  esac
}

show_config_summary() {
  echo
  echo -e "${GREEN}${BOLD}rw-backup-full config summary${RESET}"
  echo
  echo "FULL_CONFIG_FILE:                   ${FULL_CONFIG_FILE}"
  echo "BACKUP_DIR:                         ${BACKUP_DIR}"
  echo
  echo "FULL_TIMER_MODE:                    ${FULL_TIMER_MODE}"
  echo "FULL_TIMER_INTERVAL_HOURS:          ${FULL_TIMER_INTERVAL_HOURS}"
  echo "FULL_LOCAL_RETENTION_DAYS:          ${FULL_LOCAL_RETENTION_DAYS}"
  echo "FULL_EXTERNAL_S3_RETENTION_DAYS:    ${FULL_EXTERNAL_S3_RETENTION_DAYS}"
  echo
  echo "FULL_PANEL_EXTERNAL_S3_ENABLED:     ${FULL_PANEL_EXTERNAL_S3_ENABLED}"
  echo "FULL_CUSTOM_EXTERNAL_S3_ENABLED:    ${FULL_CUSTOM_EXTERNAL_S3_ENABLED}"
  echo "FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD:${FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD}"
  echo
  echo "FULL_EXTERNAL_S3_BUCKET:            ${FULL_EXTERNAL_S3_BUCKET:-not set}"
  echo "FULL_EXTERNAL_S3_PREFIX:            ${FULL_EXTERNAL_S3_PREFIX:-not set}"
  echo "FULL_EXTERNAL_S3_REGION:            ${FULL_EXTERNAL_S3_REGION:-not set}"
  echo "FULL_EXTERNAL_S3_ENDPOINT:          ${FULL_EXTERNAL_S3_ENDPOINT:-not set}"
  echo "FULL_EXTERNAL_S3_IMPORT_ORIGINAL:   ${FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL}"
  echo
  echo "FULL_TELEGRAM_IMPORT_ORIGINAL:      ${FULL_TELEGRAM_IMPORT_FROM_ORIGINAL}"
  echo "FULL_TG_CHAT_ID:                    ${FULL_TG_CHAT_ID:-not set}"
  echo "FULL_TG_THREAD_ID:                  ${FULL_TG_MESSAGE_THREAD_ID:-not set}"
  echo
  echo
}

s3_backends_list() {
  echo -e "${BOLD}S3-бэкенды (${S3D_DIR}):${RESET}"
  local n found=0
  for n in $(s3m_backends); do
    found=1
    if s3m_load "$n" 2>/dev/null; then
      local st="выключен"; truthy "$B_ENABLED" && st="включён"
      echo "  ● ${n} [${st}]  bucket=${B_BUCKET}  endpoint=${B_ENDPOINT:-AWS}"
      echo "      panel=${B_UPLOAD_PANEL}(${B_RETENTION_PANEL_DAYS}д)  custom=${B_UPLOAD_CUSTOM}(${B_RETENTION_CUSTOM_DAYS}д)  wal=${B_UPLOAD_WAL}(keep=${B_BASEBACKUP_KEEP})"
    else
      echo "  ● ${n} [ОШИБКА КОНФИГА]"
    fi
  done
  (( found )) || echo "  (нет; добавить: rw-backup-full s3-add)"
}

s3_backend_add() {
  mkdir -p "$S3D_DIR"
  local name
  read -r -p "[?] Имя бэкенда (латиница/цифры/дефис): " name
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { msg ERR "Недопустимое имя"; return 1; }
  local f="${S3D_DIR}/${name}.env"
  [[ -f "$f" ]] && { msg ERR "Бэкенд ${name} уже существует. Редактируйте: nano ${f}"; return 1; }

  local endpoint bucket ak sk region prefix pd cd bk
  read -r -p "  Endpoint (пусто для AWS): " endpoint
  read -r -p "  Bucket: " bucket
  read -r -p "  Access key: " ak
  read -r -s -p "  Secret key: " sk; echo
  read -r -p "  Region [us-east-1]: " region; region="${region:-us-east-1}"
  read -r -p "  Prefix [rw-backup-full]: " prefix; prefix="${prefix:-rw-backup-full}"
  read -r -p "  Заливать panel-архивы? [Y/n]: " a1
  read -r -p "  Заливать бэкапы ботов? [Y/n]: " a2
  read -r -p "  Заливать WAL/базовые бэкапы (PITR)? [Y/n]: " a3
  read -r -p "  Хранение panel-архивов, дней [10]: " pd; pd="${pd:-10}"
  read -r -p "  Хранение бот-архивов, дней [10]: " cd; cd="${cd:-10}"
  read -r -p "  Хранить базовых бэкапов, шт [7]: " bk; bk="${bk:-7}"

  cat > "$f" <<EOF_B
B_ENABLED="true"
B_ENDPOINT="${endpoint}"
B_BUCKET="${bucket}"
B_ACCESS_KEY="${ak}"
B_SECRET_KEY="${sk}"
B_REGION="${region}"
B_PREFIX="${prefix}"
B_UPLOAD_PANEL="$([[ "${a1,,}" == "n" ]] && echo false || echo true)"
B_UPLOAD_CUSTOM="$([[ "${a2,,}" == "n" ]] && echo false || echo true)"
B_UPLOAD_WAL="$([[ "${a3,,}" == "n" ]] && echo false || echo true)"
B_RETENTION_PANEL_DAYS="${pd}"
B_RETENTION_CUSTOM_DAYS="${cd}"
B_BASEBACKUP_KEEP="${bk}"
B_RETENTION_MIN_KEEP="3"
EOF_B
  chmod 600 "$f"
  msg OK "Бэкенд ${name} создан: ${f}"

  if s3m_load "$name" && s3m_aws s3 ls "s3://${B_BUCKET}/" >/dev/null 2>&1; then
    msg OK "Проверка доступа к бакету: успешно"
  else
    msg WARN "Проверка доступа не прошла — проверьте реквизиты в ${f}"
  fi
}

s3_backend_remove() {
  s3_backends_list
  local name
  read -r -p "[?] Имя бэкенда для удаления: " name
  local f="${S3D_DIR}/${name}.env"
  [[ -f "$f" ]] || { msg ERR "Нет такого бэкенда"; return 1; }
  echo -e "${YELLOW}Будет удалён файл настроек ${f}."
  echo -e "Данные в самом бакете НЕ удаляются — только конфигурация подключения.${RESET}"
  local a; read -r -p "Удалить конфигурацию бэкенда ${name}? [y/N]: " a
  [[ "$a" == "y" ]] || { msg INFO "Отменено"; return 0; }
  rm -f "$f"
  msg OK "Бэкенд ${name} удалён из конфигурации"
}

status_json() {
  # Машинно-читаемый статус для веб-сервиса. Только stdout, без цветов.
  local host ts panel_last panel_ts custom_cnt
  host="$(hostname -s 2>/dev/null || hostname)"
  ts="$(date +%s)"
  panel_last="$(latest_panel_backup 2>/dev/null || true)"
  panel_ts=0
  [[ -n "$panel_last" ]] && panel_ts="$(stat -c %Y "$panel_last" 2>/dev/null || echo 0)"
  custom_cnt="$(find "$BACKUP_DIR" -maxdepth 1 -name 'custom_bot_*.tar.gz' 2>/dev/null | wc -l | tr -d ' ' || true)"

  printf '{'
  printf '"host":"%s","version":"5.5.0","time":%s,' "$host" "$ts"
  printf '"components":"%s",' "${FULL_COMPONENTS:-panel-backup custom-backup wal config-track metrics}"
  printf '"panel":{"detected":%s,"last_backup":"%s","last_backup_ts":%s},'     "$( (command -v docker >/dev/null 2>&1 && local_panel_detected) && echo true || echo false)"     "$(basename "${panel_last:-}" 2>/dev/null)" "$panel_ts"
  printf '"custom_archives":%s,' "$custom_cnt"
  printf '"disk_free_bytes":%s,' "$(df -B1 --output=avail "${BACKUP_DIR}" 2>/dev/null | tail -n1 | tr -d ' ')"
  # S3-бэкенды
  printf '"s3_backends":['
  local n first=1
  for n in $(s3m_backends 2>/dev/null); do
    (( first )) || printf ','
    first=0
    if s3m_load "$n" 2>/dev/null; then
      printf '{"name":"%s","enabled":%s,"bucket":"%s"}' "$n" "$(truthy "$B_ENABLED" && echo true || echo false)" "$B_BUCKET"
    else
      printf '{"name":"%s","enabled":false,"bucket":""}' "$n"
    fi
  done
  printf '],'
  # WAL-инстансы
  printf '"wal_instances":['
  first=1
  local f name c spool bb bbts wr="/var/lib/rw-wal"
  if [[ -d "$INSTANCES_DIR" ]]; then
    for f in "$INSTANCES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      name="$(basename "$f" .env)"
      c="$(grep -E '^INST_CONTAINER=' "$f" | head -n1 | cut -d'"' -f2)"
      # find под pipefail валит весь status --json, если WAL для инстанса ещё
      # ни разу не включался (каталога нет) — веб-сервис показал бы сервер
      # "offline" целиком из-за одного не забутстрапленного инстанса.
      spool="$(find "${wr}/${name}/spool/incoming" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l | tr -d ' ' || true)"
      bb="$(find "${wr}/${name}/basebackup" -maxdepth 1 -name 'base_*.meta' 2>/dev/null | wc -l | tr -d ' ' || true)"
      spool="${spool:-0}"; bb="${bb:-0}"
      bbts="$(cat "${wr}/${name}/state/last_success" 2>/dev/null || echo 0)"
      (( first )) || printf ','
      first=0
      printf '{"name":"%s","container":"%s","running":%s,"spool":%s,"basebackups":%s,"last_basebackup_ts":%s,"timer_active":%s}'         "$name" "$c"         "$( (command -v docker >/dev/null 2>&1 && docker ps -q -f "name=^${c}$" 2>/dev/null | grep -q .) && echo true || echo false)"         "$spool" "$bb" "$bbts"         "$(systemctl is-active "rw-wal-ship@${name}.timer" >/dev/null 2>&1 && echo true || echo false)"
    done
  fi
  printf ']}'
  printf '\n'
}

# Манифест сервера для fleet-verify (песочница забирает его через веб-сервис
# по SSH): источник, S3-бэкенды С РЕКВИЗИТАМИ, инстансы с типами и параметрами
# проверок, настройки Telegram. Только stdout, чистый JSON.
fleet_manifest() {
  local first n f
  printf '{'
  printf '"manifest_version":1,'
  printf '"source":"%s",' "$(declare -F rw_source_id >/dev/null && rw_source_id || hostname -s)"
  printf '"telegram":{"token":"%s","chat_id":"%s","thread_id":"%s"},'     "${FULL_TG_BOT_TOKEN:-}" "${FULL_TG_CHAT_ID:-}" "${FULL_TG_MESSAGE_THREAD_ID:-}"

  printf '"backends":['
  first=1
  for n in $(s3m_backends 2>/dev/null); do
    s3m_load "$n" 2>/dev/null || continue
    (( first )) || printf ','
    first=0
    printf '{"name":"%s","enabled":%s,"endpoint":"%s","bucket":"%s","access_key":"%s","secret_key":"%s","region":"%s","prefix":"%s","panel":%s,"custom":%s,"wal":%s}'       "$n" "$(truthy "$B_ENABLED" && echo true || echo false)"       "$B_ENDPOINT" "$B_BUCKET" "$B_ACCESS_KEY" "$B_SECRET_KEY" "$B_REGION" "$B_PREFIX"       "$(truthy "$B_UPLOAD_PANEL" && echo true || echo false)"       "$(truthy "$B_UPLOAD_CUSTOM" && echo true || echo false)"       "$(truthy "$B_UPLOAD_WAL" && echo true || echo false)"
  done
  printf '],'

  printf '"instances":['
  first=1
  if [[ -d "$INSTANCES_DIR" ]]; then
    for f in "$INSTANCES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      local i_name i_kind i_tables i_user i_db
      i_name="$(basename "$f" .env)"
      i_kind="$(grep -E '^INST_KIND=' "$f" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
      i_tables="$(grep -E '^INST_VERIFY_TABLES=' "$f" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
      i_user="$(grep -E '^INST_PGUSER=' "$f" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
      i_db="$(grep -E '^INST_PGDATABASE=' "$f" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
      (( first )) || printf ','
      first=0
      printf '{"name":"%s","kind":"%s","verify_tables":"%s","pguser":"%s","pgdatabase":"%s"}'         "$i_name" "${i_kind:-bot}" "$i_tables" "${i_user:-postgres}" "${i_db:-postgres}"
    done
  fi
  printf ']}'
  printf '\n'
}

# Приводит systemd-таймеры в соответствие с FULL_COMPONENTS: лишние
# останавливаются, нужные включаются. Юниты не удаляются — возврат
# компонента не требует переустановки.
# Обнаруживает и (с согласия) отключает cron-запись оригинального
# distillium-скрипта — она ставится ЕГО СОБСТВЕННЫМ установщиком отдельно
# от наших systemd-юнитов, и после перехода на v5 (встроенный движок панели)
# продолжает работать по инерции. Реальный найденный на проде эффект:
# оригинал и rw-backup-full.service оба гоняли pg_dumpall + tar одного и
# того же /opt/remnawave в один и тот же каталог — двойная нагрузка на БД
# и риск гонки при записи.
decommission_original() {
  local found=0 crontab_hits cron_d_hits

  crontab_hits="$(crontab -l 2>/dev/null | grep -nE 'backup-restore\.sh|rw-backup([^-_a-zA-Z]|$)' || true)"
  cron_d_hits=""
  if [[ -d /etc/cron.d ]]; then
    cron_d_hits="$(grep -rlE 'backup-restore\.sh' /etc/cron.d/ 2>/dev/null || true)"
  fi

  [[ -n "$crontab_hits" ]] && found=1
  [[ -n "$cron_d_hits" ]] && found=1

  if (( found == 0 )); then
    msg OK "Cron-записей оригинального rw-backup не найдено — нечего отключать"
    return 0
  fi

  echo -e "${YELLOW}${BOLD}Найдено дублирование: оригинальный distillium-скрипт всё ещё в cron${RESET}"
  echo "Панель уже бэкапится встроенным движком (rw-backup-full.service);"
  echo "эти записи — leftover от установки, которая была ДО перехода на v5."
  [[ -n "$crontab_hits" ]] && { echo; echo "В crontab root:"; echo "$crontab_hits" | sed 's/^/  /'; }
  [[ -n "$cron_d_hits" ]] && { echo; echo "В /etc/cron.d/:"; echo "$cron_d_hits" | sed 's/^/  /'; }
  echo
  echo "Будет сделано: строки закомментированы (не удалены — обратимо)."
  echo "Crontab root предварительно сохраняется в /root/.crontab.before-rw-backup-full.<дата>."
  read -r -p "Отключить дублирующий cron? [y/N]: " a
  [[ "$a" == y || "$a" == Y ]] || { msg INFO "Отменено, cron не тронут"; return 0; }

  if [[ -n "$crontab_hits" ]]; then
    local bak="/root/.crontab.before-rw-backup-full.$(date +%Y%m%d_%H%M%S)"
    crontab -l > "$bak" 2>/dev/null || true
    crontab -l 2>/dev/null | sed -E 's@^([^#].*(backup-restore\.sh|rw-backup[^-_a-zA-Z]).*)@# disabled by rw-backup-full (dup with v5 engine): \1@' | crontab -
    msg OK "crontab root обновлён (резерв: ${bak})"
  fi
  if [[ -n "$cron_d_hits" ]]; then
    local f
    for f in $cron_d_hits; do
      cp -a "$f" "${f}.before-rw-backup-full.$(date +%Y%m%d_%H%M%S)"
      sed -i -E 's@^([^#].*backup-restore\.sh.*)@# disabled by rw-backup-full (dup with v5 engine): \1@' "$f"
      msg OK "отключено в ${f} (резерв рядом)"
    done
  fi
  msg OK "Готово. Откат: восстановить файл(ы) резерва или раскомментировать строки."
}

apply_components() {
  local changed=0
  _tm() { # <компонент> <юнит>
    if component_enabled "$1"; then
      systemctl is-enabled "$2" >/dev/null 2>&1 || {
        systemctl enable --now "$2" >/dev/null 2>&1 && { msg OK "включён ${2} (${1})"; changed=1; }
      }
    else
      systemctl is-enabled "$2" >/dev/null 2>&1 && {
        systemctl disable --now "$2" >/dev/null 2>&1 && { msg OK "выключен ${2} (компонент ${1} не используется)"; changed=1; }
      }
    fi
  }

  _tm panel-backup rw-backup-full.timer
  component_enabled custom-backup && _tm custom-backup rw-backup-full.timer
  _tm metrics      rw-metrics-export.timer
  _tm config-track rw-config-track.timer
  _tm sandbox      rw-sandbox-verify.timer
  # Сводка 09:00/21:00 — при любом из metrics/sandbox/web
  if component_enabled metrics || component_enabled sandbox || component_enabled web; then
    systemctl is-enabled rw-status-digest.timer >/dev/null 2>&1 || {
      systemctl enable --now rw-status-digest.timer >/dev/null 2>&1 && { msg OK "включён rw-status-digest.timer"; changed=1; }
    }
  else
    systemctl is-enabled rw-status-digest.timer >/dev/null 2>&1 && {
      systemctl disable --now rw-status-digest.timer >/dev/null 2>&1 && { msg OK "выключен rw-status-digest.timer"; changed=1; }
    }
  fi

  # WAL — таймеры на каждый инстанс
  local f inst
  if [[ -d "$INSTANCES_DIR" ]]; then
    for f in "$INSTANCES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      inst="$(basename "$f" .env)"
      _tm wal "rw-wal-ship@${inst}.timer"
      _tm wal "rw-basebackup@${inst}.timer"
    done
  fi

  (( changed )) || msg INFO "Изменений не потребовалось — состояние уже соответствует FULL_COMPONENTS"
  systemctl daemon-reload 2>/dev/null || true
}

sandbox_timer_install() {
  local times="${SANDBOX_VERIFY_TIMES:-}" ih="${SANDBOX_VERIFY_INTERVAL_HOURS:-}" tz="${FULL_SCHEDULE_TZ:-}"
  local d="/etc/systemd/system/rw-sandbox-verify.timer.d"
  mkdir -p "$d"
  {
    echo "# managed-by: rw-backup-full (расписание из rw-backup-full.env)"
    echo "[Timer]"
    echo "OnCalendar="
    if [[ -n "$times" ]]; then
      local norm t
      norm="$(parse_times_list "$times")" || return 1
      for t in $norm; do echo "OnCalendar=*-*-* ${t}${tz:+ ${tz}}"; done
    elif [[ -n "$ih" ]] && [[ "$ih" =~ ^[0-9]+$ ]] && (( ih >= 1 )); then
      echo "OnBootSec=30min"
      echo "OnUnitActiveSec=${ih}h"
    else
      echo "OnCalendar=*-*-* 05:30:00${tz:+ ${tz}}"
    fi
  } > "${d}/override.conf"
  systemctl daemon-reload
  systemctl enable --now rw-sandbox-verify.timer
  msg OK "Расписание песочницы применено:"
  systemctl list-timers rw-sandbox-verify.timer --no-pager 2>/dev/null | head -n 3 || true
}

wal_status_all() {
  echo -e "${BOLD}WAL-архивация (v4)${RESET}"
  echo

  if [[ ! -d "$INSTANCES_DIR" ]] || ! ls "$INSTANCES_DIR"/*.env >/dev/null 2>&1; then
    msg WARN "Инстансы не настроены: ${INSTANCES_DIR}/*.env"
    msg INFO "Примеры: ${INSTALL_DIR}/config-examples/instances.d/"
    return 0
  fi

  local f name c wal_root="/var/lib/rw-wal"
  for f in "$INSTANCES_DIR"/*.env; do
    name="$(basename "$f" .env)"
    c="$(grep -E '^INST_CONTAINER=' "$f" | head -n1 | cut -d'"' -f2 || true)"
    echo -e "${CYAN}● ${name}${RESET} (контейнер: ${c:-?})"

    if [[ -n "$c" ]] && docker ps -q -f "name=^${c}$" | grep -q .; then
      local am fc last_arch
      am="$(docker exec "$c" psql -h localhost -U postgres -qtAX -c 'SHOW archive_mode' 2>/dev/null || echo '?')"
      fc="$(docker exec "$c" psql -h localhost -U postgres -qtAX -c 'SELECT failed_count FROM pg_stat_archiver' 2>/dev/null || echo '?')"
      last_arch="$(docker exec "$c" psql -h localhost -U postgres -qtAX -c 'SELECT last_archived_wal FROM pg_stat_archiver' 2>/dev/null || echo '?')"
      echo "    archive_mode=${am}  failed_count=${fc}  last_wal=${last_arch}"
    else
      echo "    контейнер не запущен"
    fi

    local spool arch bb
    # Тот же класс бага, что уронил metrics-exporter.sh: инстанс описан в
    # instances.d/, но WAL для него ещё ни разу не включался — каталога нет,
    # find падает, и под pipefail это валит весь `wal-status` целиком.
    spool="$(find "${wal_root}/${name}/spool/incoming" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l || true)"
    arch="$(find "${wal_root}/${name}/archive" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l || true)"
    bb="$(find "${wal_root}/${name}/basebackup" -maxdepth 1 -name 'base_*.meta' 2>/dev/null | wc -l || true)"
    echo "    спул=${spool:-0}  локальный WAL=${arch:-0}  базовых бэкапов=${bb:-0}"

    local last_meta
    last_meta="$(find "${wal_root}/${name}/basebackup" -maxdepth 1 -name 'base_*.meta' 2>/dev/null | sort -r | head -n1 || true)"
    if [[ -n "$last_meta" ]]; then
      echo "    последний базовый: $(grep -E '^CREATED_AT=' "$last_meta" | cut -d'"' -f2)"
    fi

    systemctl is-active "rw-wal-ship@${name}.timer" >/dev/null 2>&1 \
      && echo "    таймеры: активны" || echo "    таймеры: НЕ активны"
    echo
  done
}

# Меню разбито на разделы по задачам, с коротким описанием каждого пункта.
# Пункты, требующие параметров, спрашивают их интерактивно — чтобы не нужно
# было держать в голове синтаксис CLI.
menu_header() {
  clear
  echo -e "${GREEN}${BOLD}rw-backup-full${RESET}  —  резервное копирование и проверка восстановления"
  local comps="${FULL_COMPONENTS:-panel-backup custom-backup wal config-track metrics}"
  echo -e "${CYAN}Хост:${RESET} $(rw_source_id)   ${CYAN}Компоненты:${RESET} ${comps}"
  echo
}

# ask_choice <заголовок> <вариант1> <вариант2> ... -> печатает выбранный текст
# Варианты хранятся в массиве (не через ${!N}): иначе при пустом/битом вводе
# легко получить одинаковый «пустой» результат для любого пункта меню.
ask_choice() {
  local title="$1"; shift
  local -a opts=("$@")
  local i=1 opt
  echo -e "  ${BOLD}${title}${RESET}" >&2
  for opt in "${opts[@]}"; do echo "    ${i}) ${opt}" >&2; i=$((i+1)); done
  local pick
  read -r -p "  Выбор [1]: " pick >&2 || true
  pick="${pick:-1}"
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#opts[@]} )); then
    pick=1
  fi
  printf '%s\n' "${opts[$((pick-1))]}"
}

# Динамическое меню: показывает только пункты с непустым ключом действия.
# Формат аргументов: пары «ключ» «подпись».
# Печатает выбранный ключ в stdout. 0 / пустой ввод → печатает "0".
# MENU_BACK_LABEL — подпись пункта 0 (по умолчанию «Назад»).
menu_pick() {
  local -a keys=() labels=()
  local key label i=1 pick back="${MENU_BACK_LABEL:-Назад}"
  while [[ $# -ge 2 ]]; do
    key="$1"; label="$2"; shift 2
    keys+=("$key"); labels+=("$label")
    printf '  %d. %s\n' "$i" "$label" >&2
    i=$((i+1))
  done
  echo >&2
  echo "  0. ${back}" >&2
  echo >&2
  read -r -p "[?] Выбор: " pick || true
  echo >&2
  [[ -z "$pick" || "$pick" == "0" ]] && { printf '0\n'; return 0; }
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#keys[@]} )); then
    echo -e "${RED}[ERR]${RESET} Некорректный выбор" >&2
    printf '?\n'
    return 0
  fi
  printf '%s\n' "${keys[$((pick-1))]}"
}

# Список ID серверов из fleet.json / кэша веб-сервиса (для меню песочницы).
fleet_server_ids() {
  local f="${RW_FLEET_FILE:-${INSTALL_DIR}/fleet.json}"
  local cache="${INSTALL_DIR}/web-data/manifest-cache.json"
  if [[ -f "$f" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.servers[]?.id // empty' "$f" 2>/dev/null || true
  elif [[ -f "$cache" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.servers[]?.id // empty' "$cache" 2>/dev/null || true
  fi
}

pick_fleet_server() {
  local -a ids=()
  local id
  while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(fleet_server_ids)
  if (( ${#ids[@]} == 0 )); then
    msg WARN "В парке нет серверов (fleet.json). Добавьте через веб-интерфейс."
    return 1
  fi
  if (( ${#ids[@]} == 1 )); then
    printf '%s' "${ids[0]}"
    return 0
  fi
  ask_choice "Сервер-источник:" "${ids[@]}"
}

# Выбор инстанса из instances.d (вместо ручного ввода имени)
pick_instance() {
  local -a insts=()
  local f
  if [[ -d "$INSTANCES_DIR" ]]; then
    for f in "$INSTANCES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      insts+=("$(basename "$f" .env)")
    done
  fi
  if (( ${#insts[@]} == 0 )); then
    msg WARN "Инстансы не настроены (${INSTANCES_DIR}/*.env)"
    msg INFO "Примеры: ${INSTALL_DIR}/config-examples/instances.d/"
    return 1
  fi
  if (( ${#insts[@]} == 1 )); then
    printf '%s' "${insts[0]}"
    return 0
  fi
  local i=1 n
  for n in "${insts[@]}"; do echo "    ${i}) ${n}" >&2; i=$((i+1)); done
  local pick; read -r -p "  Инстанс [1]: " pick >&2
  pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#insts[@]} )) || pick=1
  printf '%s' "${insts[$((pick-1))]}"
}

menu_backup() {
  while true; do
    menu_header
    echo -e " ${BOLD}Резервное копирование${RESET}"
    local -a args=()
    component_enabled panel-backup  && args+=(panel "Бэкап панели          логический архив: дамп БД + каталог панели")
    component_enabled custom-backup && args+=(custom "Бэкап ботов из /home  compose-проекты: дамп + Redis + каталог")
    if component_enabled panel-backup && component_enabled custom-backup; then
      args+=(all "Бэкап всего           панель и боты подряд")
    fi
    component_enabled config-track && args+=(track "Снимок каталогов      трекер: конфиги, код, ресурсы (инкрементально)")
    component_enabled config-track && args+=(track-list "Что отслеживается     список проектов и накопленных снимков")
    if (( ${#args[@]} == 0 )); then
      msg WARN "Нет включённых компонентов бэкапа (panel-backup / custom-backup / config-track)"
      pause; return
    fi
    local c; c="$(menu_pick "${args[@]}")"
    case "$c" in
      panel) run_panel_backup; pause ;;
      custom) backup_custom_menu; pause ;;
      all) backup_all; pause ;;
      track) "${TRACK_SCRIPTS_DIR}/config-track.sh" || true; pause ;;
      track-list) "${TRACK_SCRIPTS_DIR}/config-track.sh" --list || true; pause ;;
      0) return ;;
      *) sleep 1 ;;
    esac
  done
}

menu_restore() {
  while true; do
    menu_header
    echo -e " ${BOLD}Восстановление${RESET}  (рабочие данные не трогаются без явного подтверждения)"
    local -a args=()
    component_enabled panel-backup  && args+=(panel "Панель из архива      пошагово, со страховочными копиями")
    component_enabled custom-backup && args+=(custom "Бот из архива         выбор архива, откат старого каталога")
    component_enabled config-track  && args+=(track "Каталог из трекера    на любой момент времени, в указанный путь")
    component_enabled wal           && args+=(pitr "PITR из WAL           восстановление БД на точку во времени")
    args+=(bare "Чистый сервер         полное развёртывание с нуля (зависимости, конфиги, БД)")
    local c; c="$(menu_pick "${args[@]}")"
    case "$c" in
      panel) "${PANEL_SCRIPTS_DIR}/panel-restore.sh" || true; pause ;;
      custom) restore_custom_menu; pause ;;
      track)
        read -r -p "  Проект: " pr
        read -r -p "  Куда восстановить (--dest): " dst
        read -r -p "  На момент (пусто = последнее состояние): " at
        if [[ -n "$pr" && -n "$dst" ]]; then
          if [[ -n "$at" ]]; then
            "${TRACK_SCRIPTS_DIR}/config-restore.sh" "$pr" --dest "$dst" --at "$at" || true
          else
            "${TRACK_SCRIPTS_DIR}/config-restore.sh" "$pr" --dest "$dst" || true
          fi
        fi
        pause ;;
      pitr)
        local inst target
        inst="$(pick_instance)" || { pause; continue; }
        target="$(ask_choice "Точка восстановления:" \
          "последняя доступная (весь WAL)" \
          "только базовый бэкап (без WAL)" \
          "на момент времени")"
        case "$target" in
          "последняя"*) "${WAL_SCRIPTS_DIR}/pitr-restore.sh" "$inst" --target latest || true ;;
          "только"*)    "${WAL_SCRIPTS_DIR}/pitr-restore.sh" "$inst" --target immediate || true ;;
          *)
            read -r -p "  Момент (например 2026-07-24 09:30:00+00): " tt
            [[ -n "$tt" ]] && { "${WAL_SCRIPTS_DIR}/pitr-restore.sh" "$inst" --target-time "$tt" || true; } ;;
        esac
        pause ;;
      bare)
        msg INFO "Запускается на ЧИСТОМ сервере из клона репозитория:"
        msg INFO "  sudo scripts/host/bare-restore.sh --source <ID-сервера> --project <проект>"
        pause ;;
      0) return ;;
      *) sleep 1 ;;
    esac
  done
}

menu_wal() {
  component_enabled wal || { msg WARN "Компонент wal выключен"; pause; return; }
  while true; do
    menu_header
    echo -e " ${BOLD}WAL-архивация и PITR${RESET}"
    local c
    c="$(menu_pick \
      status "Статус                archive_mode, спул, базовые бэкапы, таймеры" \
      enable "Включить архивацию    ВНИМАНИЕ: требует рестарта контейнера БД" \
      disable "Выключить архивацию   снять override и таймеры" \
      base "Базовый бэкап сейчас  полный pg_basebackup инстанса" \
      ship "Отправить WAL сейчас  прогнать спул в архив и S3" \
      ret "Очистка по retention  удалить лишнее по границе базовых бэкапов" \
      timers "Перечитать расписания применить *_TIMES/интервалы из конфига")"
    local inst
    case "$c" in
      status) wal_status_all; pause ;;
      enable) inst="$(pick_instance)" && { "${WAL_SCRIPTS_DIR}/enable-archiving.sh" "$inst" || true; }; pause ;;
      disable) inst="$(pick_instance)" && { "${WAL_SCRIPTS_DIR}/enable-archiving.sh" "$inst" --disable || true; }; pause ;;
      base) inst="$(pick_instance)" && { "${WAL_SCRIPTS_DIR}/basebackup.sh" "$inst" || true; }; pause ;;
      ship) inst="$(pick_instance)" && { "${WAL_SCRIPTS_DIR}/wal-ship.sh" "$inst" || true; }; pause ;;
      ret)
        inst="$(pick_instance)" || { pause; continue; }
        local dry
        dry="$(ask_choice "Режим:" "показать, что удалилось бы (dry-run)" "удалить")"
        if [[ "$dry" == показать* ]]; then
          "${WAL_SCRIPTS_DIR}/wal-retention.sh" "$inst" --dry-run || true
        else
          "${WAL_SCRIPTS_DIR}/wal-retention.sh" "$inst" || true
        fi
        pause ;;
      timers) inst="$(pick_instance)" && { "${WAL_SCRIPTS_DIR}/wal-timers.sh" "$inst" || true; }; pause ;;
      0) return ;;
      *) sleep 1 ;;
    esac
  done
}

menu_verify() {
  component_enabled sandbox || { msg WARN "Компонент sandbox выключен — проверки восстановимости недоступны"; pause; return; }
  while true; do
    menu_header
    echo -e " ${BOLD}Проверка восстановимости${RESET}  (на сервере-песочнице)"
    local c
    c="$(menu_pick \
      fleet "Проверка парка        все серверы × все хранилища × все категории" \
      stack "Полный стек           каталог + БД + подъём контейнеров в изоляции" \
      local "Локальная проверка    PITR-цепочки и архивы этого сервера" \
      plan "План ротации          что будет проверяться в следующий прогон" \
      sync "Обновить S3/TG креды  скопировать с подключённых серверов")"
    case "$c" in
      fleet)
        local scope depth
        scope="$(ask_choice "Охват:" "весь парк" "один сервер")"
        depth="$(ask_choice "Глубина:" "стандартная" "быстрая (quick)" "глубокая (deep: pg_dumpall + amcheck)")"
        local -a fargs=()
        case "$depth" in быстр*) fargs+=(--depth quick) ;; глубок*) fargs+=(--depth deep) ;; esac
        if [[ "$scope" == один* ]]; then
          local sid
          sid="$(pick_fleet_server)" || { pause; continue; }
          fargs+=(--server "$sid")
        fi
        msg INFO "Запуск: verify-fleet.sh ${fargs[*]-}"
        # Актуализируем креды перед прогоном (S3/TG с серверов).
        "${SANDBOX_SCRIPTS_DIR}/sync-fleet-creds.sh" || true
        "${SANDBOX_SCRIPTS_DIR}/verify-fleet.sh" ${fargs[@]+"${fargs[@]}"} || true
        pause ;;
      stack)
        read -r -p "  Проект [panel]: " pr; pr="${pr:-panel}"
        local sid mode keep
        sid="$(pick_fleet_server)" || {
          read -r -p "  ID сервера-источника вручную: " sid
          [[ -n "$sid" ]] || { msg ERR "Без --source на песочнице стек не из чего собирать"; pause; continue; }
        }
        mode="$(ask_choice "Способ подъёма БД:" \
          "автоматически по ротации" "логический дамп" "базовый бэкап" "базовый бэкап + WAL (PITR)")"
        keep="$(ask_choice "После проверки:" "убрать всё" "оставить контейнеры для разбора")"
        local -a sargs=("$pr" --source "$sid")
        case "$mode" in
          логический*) sargs+=(--db-mode dump) ;;
          "базовый бэкап") sargs+=(--db-mode base) ;;
          *WAL*|*"PITR"*) sargs+=(--db-mode pitr) ;;
        esac
        [[ "$keep" == оставить* ]] && sargs+=(--keep)
        msg INFO "Запуск: verify-stack.sh ${sargs[*]}"
        "${SANDBOX_SCRIPTS_DIR}/sync-fleet-creds.sh" || true
        "${SANDBOX_SCRIPTS_DIR}/verify-stack.sh" "${sargs[@]}" || true
        pause ;;
      local) "${SANDBOX_SCRIPTS_DIR}/verify-backup.sh" || true; pause ;;
      plan)
        read -r -p "  Проект [panel]: " pr; pr="${pr:-panel}"
        local sid bn
        sid="$(pick_fleet_server 2>/dev/null)" || sid="$(rw_source_id)"
        read -r -p "  ID сервера [${sid}]: " sid_in; sid="${sid_in:-$sid}"
        bn="$(s3m_backends | head -n1)"
        if [[ -n "$bn" ]] && s3m_load "$bn"; then
          msg INFO "Следующий прогон проверит:"
          AWS_ACCESS_KEY_ID="$B_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$B_SECRET_KEY" \
          AWS_DEFAULT_REGION="${B_REGION:-us-east-1}" AWS_ENDPOINT_URL="${B_ENDPOINT:-}" \
          VERIFY_PLAN_DRYRUN=1 "${SANDBOX_SCRIPTS_DIR}/verify-plan.sh" "$pr" "$sid" "$B_BUCKET" "$B_PREFIX" || true
        else
          # На песочнице локальных s3.d обычно нет — берём из кэша кредов.
          local cred="${INSTALL_DIR}/fleet-creds/${sid}/s3.d"
          if [[ -d "$cred" ]]; then
            bn="$(basename "$(ls "$cred"/*.env 2>/dev/null | head -n1)" .env || true)"
            if [[ -n "$bn" ]]; then
              S3D_DIR="$cred" s3m_load "$bn" || true
              msg INFO "Следующий прогон проверит (креды ${sid}):"
              AWS_ACCESS_KEY_ID="$B_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$B_SECRET_KEY" \
              AWS_DEFAULT_REGION="${B_REGION:-us-east-1}" AWS_ENDPOINT_URL="${B_ENDPOINT:-}" \
              VERIFY_PLAN_DRYRUN=1 "${SANDBOX_SCRIPTS_DIR}/verify-plan.sh" "$pr" "$sid" "$B_BUCKET" "$B_PREFIX" || true
            else
              msg ERR "Нет S3-бэкенда. Сначала: пункт «Обновить S3/TG креды»"
            fi
          else
            msg ERR "Нет доступного S3-бэкенда. Сначала: пункт «Обновить S3/TG креды»"
          fi
        fi
        pause ;;
      sync) "${SANDBOX_SCRIPTS_DIR}/sync-fleet-creds.sh" || true; pause ;;
      0) return ;;
      *) sleep 1 ;;
    esac
  done
}

menu_storage() {
  while true; do
    menu_header
    echo -e " ${BOLD}Хранилища${RESET}"
    local c
    c="$(menu_pick \
      list "Список бэкендов       что настроено, какие категории и сроки" \
      add "Добавить бэкенд       новое S3-хранилище со своими retention" \
      del "Удалить бэкенд        только конфигурацию, данные в бакете целы" \
      test "Диагностика связи     листинг, запись, чтение, удаление + ошибки aws" \
      clean "Очистка по retention  применить сроки хранения ко всем бэкендам")"
    case "$c" in
      list) s3_backends_list; pause ;;
      add) s3_backend_add; pause ;;
      del) s3_backend_remove; pause ;;
      test)
        read -r -p "  Имя бэкенда (пусто = все): " bn
        if [[ -n "$bn" ]]; then s3m_test_backend "$bn" || true; else s3m_test_all || true; fi
        pause ;;
      clean) full_s3_retention_cleanup; pause ;;
      0) return ;;
      *) sleep 1 ;;
    esac
  done
}

menu_settings() {
  while true; do
    menu_header
    echo -e " ${BOLD}Настройки${RESET}"
    local -a args=(
      cfg "Показать конфигурацию  текущие значения из единого конфига"
      comps "Компоненты сервера     что этот сервер делает (FULL_COMPONENTS)"
      timer "Расписание бэкапов     интервал или конкретные времена"
      tg "Telegram               токен, чат, тема"
      ret "Сроки хранения         локально и во внешних хранилищах"
    )
    component_enabled sandbox && args+=(sandbox-timer "Таймер песочницы       расписание проверок восстановимости")
    component_enabled metrics && args+=(metrics "Метрики сейчас         выгрузить для Grafana немедленно")
    args+=(digest "Сводка сейчас          краткий отчёт в Telegram (09:00/21:00)")
    args+=(decommission "Отключить старый cron  убрать дублирующий distillium-скрипт")
    local c; c="$(menu_pick "${args[@]}")"
    case "$c" in
      cfg) show_config_summary; pause ;;
      comps)
        echo "Включено: ${FULL_COMPONENTS:-(по умолчанию)}"
        for comp in panel-backup custom-backup wal config-track metrics sandbox web; do
          component_enabled "$comp" && echo "  ✅ $comp" || echo "  ⬜ $comp"
        done
        echo
        read -r -p "  Новый список через пробел (Enter — не менять): " nc
        if [[ -n "$nc" ]]; then
          set_full_var FULL_COMPONENTS "$nc"
          FULL_COMPONENTS="$nc"
          msg OK "Сохранено. Применяю к таймерам..."
          apply_components
        fi
        pause ;;
      timer) configure_timer; pause ;;
      tg) configure_telegram; pause ;;
      ret) configure_retention; pause ;;
      sandbox-timer) sandbox_timer_install; pause ;;
      metrics) "${METRICS_SCRIPTS_DIR}/metrics-exporter.sh" || true; pause ;;
      digest) "${METRICS_SCRIPTS_DIR}/status-digest.sh" || true; pause ;;
      decommission) decommission_original; pause ;;
      0) return ;;
      *) sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    load_config
    menu_header
    local -a args=()
    if component_enabled panel-backup || component_enabled custom-backup || component_enabled config-track; then
      args+=(backup "Резервное копирование    бэкапы панели, ботов, снимки каталогов")
    fi
    if component_enabled panel-backup || component_enabled custom-backup || component_enabled config-track || component_enabled wal; then
      args+=(restore "Восстановление           из архивов, из WAL, на чистый сервер")
    fi
    component_enabled wal && args+=(wal "WAL-архивация и PITR     непрерывная защита БД")
    component_enabled sandbox && args+=(verify "Проверка восстановимости песочница: парк, стек, ротация проверок")
    # Хранилища: на проде — свои s3.d; на песочнице тоже полезно смотреть/тестировать кэш.
    args+=(storage "Хранилища                внешние S3, диагностика, retention")
    args+=(settings "Настройки                конфиг, компоненты, расписания, Telegram")
    args+=(status "Состояние                статус, найденные проекты, конфигурация")
    local choice; choice="$(MENU_BACK_LABEL=Выход menu_pick "${args[@]}")"
    case "$choice" in
      backup) menu_backup ;;
      restore) menu_restore ;;
      wal) menu_wal ;;
      verify) menu_verify ;;
      storage) menu_storage ;;
      settings) menu_settings ;;
      status)
        component_enabled wal && wal_status_all
        echo
        component_enabled custom-backup && print_custom_projects
        show_config_summary
        pause ;;
      0) exit 0 ;;
      *) sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF_USAGE
Usage:
  rw-backup-full
  rw-backup-full menu
  rw-backup-full config
  rw-backup-full list
  rw-backup-full panel-backup
  rw-backup-full custom-backup
  rw-backup-full backup-all
  rw-backup-full custom-restore
  rw-backup-full custom-restore-file /path/to/custom_bot_archive.tar.gz [--yes]
  rw-backup-full configure-retention
  rw-backup-full configure-s3
  rw-backup-full configure-telegram
  rw-backup-full install-timer
  rw-backup-full run-timer
  rw-backup-full s3-cleanup

WAL / PITR (v4):
  rw-backup-full wal-enable <instance>          включить WAL-архивацию (рестарт БД!)
  rw-backup-full wal-disable <instance>         выключить WAL-архивацию
  rw-backup-full basebackup <instance> [--no-s3] полный базовый бэкап сейчас
  rw-backup-full wal-ship <instance>            отправить спул в архив/S3 сейчас
  rw-backup-full wal-retention <instance> [--dry-run]
  rw-backup-full wal-timers <instance> [--remove]
  rw-backup-full wal-status                     статус всех инстансов
  rw-backup-full pitr-restore <instance> [опции]  восстановление (см. --help)
  rw-backup-full verify [--instance X|--local]  проверка бэкапов в песочнице
  rw-backup-full sandbox-timer                  применить расписание песочницы из конфига

Мульти-S3 и панель (v5):
  rw-backup-full s3-backends                    список S3-бэкендов
  rw-backup-full s3-add | s3-remove             добавить / удалить бэкенд
  rw-backup-full s3-test [имя]                  диагностика подключения к S3 (все или один)
  rw-backup-full panel-restore [файл|--from-s3] восстановление панели (встроенное)
  rw-backup-full status [--json]                статус сервера (JSON для веб-сервиса)
  rw-backup-full metrics-export                 выгрузка метрик сейчас
  rw-backup-full fleet-manifest                 JSON-манифест сервера для песочницы

Трекер каталогов (конфиги, код, ресурсы):
  rw-backup-full config-track [проект] [--full]  снимок сейчас
  rw-backup-full config-track --list             что отслеживается
  rw-backup-full config-restore <проект> --dest DIR [--at "дата"]
  rw-backup-full verify-stack <проект> [--source ID] [--db-mode dump|base|pitr] [--keep]
                                                проверка полного стека в изоляции
  rw-backup-full verify-plan <проект> <источник> <bucket> <prefix>
                                                что будет проверяться в следующий прогон
  rw-backup-full bare-restore --source ID --project P
                                                развернуть с нуля на чистом сервере

Компоненты:
  rw-backup-full components                      что включено на сервере
  rw-backup-full apply-components                применить FULL_COMPONENTS к таймерам
  rw-backup-full decommission-original          отключить дублирующий cron оригинального rw-backup
  rw-backup-full verify-fleet [--server ID] [--backend N] [--depth D]
                                                проверка парка: сервер × хранилище
  rw-backup-full fleet-pack pack|unpack         перенос настроек песочницы одним файлом
  rw-backup-full sync-creds                     актуализировать S3/TG с серверов парка
  rw-backup-full status-digest                  краткая сводка в Telegram (09:00/21:00)
EOF_USAGE
}

load_config
ensure_tools "$@"

cmd="${1:-menu}"

case "$cmd" in
  menu) main_menu ;;
  config) show_config_summary ;;
  list) print_custom_projects ;;
  panel-backup) backup_panel_only ;;
  custom-backup) backup_custom_all ;;
  backup-all) backup_all ;;
  custom-restore) restore_custom_menu ;;
  custom-restore-file)
    archive="${2:-}"
    yes_flag="${3:-}"
    [[ -n "$archive" ]] || { usage; exit 1; }
    if [[ "$yes_flag" == "--yes" || "$yes_flag" == "-y" ]]; then
      restore_custom_archive "$archive" "yes"
    else
      restore_custom_archive "$archive"
    fi
    ;;
  configure-retention) configure_retention ;;
  configure-s3) configure_external_s3 ;;
  configure-telegram) configure_telegram ;;
  install-timer) configure_timer ;;
  run-timer) run_timer_mode ;;
  s3-cleanup) full_s3_retention_cleanup ;;
  wal-enable)
    shift; exec "${WAL_SCRIPTS_DIR}/enable-archiving.sh" "$@" ;;
  wal-disable)
    inst="${2:-}"; [[ -n "$inst" ]] || { usage; exit 1; }
    exec "${WAL_SCRIPTS_DIR}/enable-archiving.sh" "$inst" --disable ;;
  basebackup)
    shift; exec "${WAL_SCRIPTS_DIR}/basebackup.sh" "$@" ;;
  wal-ship)
    shift; exec "${WAL_SCRIPTS_DIR}/wal-ship.sh" "$@" ;;
  wal-retention)
    shift; exec "${WAL_SCRIPTS_DIR}/wal-retention.sh" "$@" ;;
  wal-timers)
    shift; exec "${WAL_SCRIPTS_DIR}/wal-timers.sh" "$@" ;;
  pitr-restore)
    shift; exec "${WAL_SCRIPTS_DIR}/pitr-restore.sh" "$@" ;;
  wal-status)
    wal_status_all ;;
  sandbox-timer)
    sandbox_timer_install ;;
  s3-backends|s3-list-backends)
    s3_backends_list ;;
  s3-add)
    s3_backend_add ;;
  s3-remove)
    s3_backend_remove ;;
  s3-test)
    if [[ -n "${2:-}" ]]; then s3m_test_backend "$2"; else s3m_test_all; fi ;;
  panel-restore)
    shift; exec "${PANEL_SCRIPTS_DIR}/panel-restore.sh" "$@" ;;
  status)
    if [[ "${2:-}" == "--json" ]]; then status_json; else wal_status_all; fi ;;
  metrics-export)
    exec "${METRICS_SCRIPTS_DIR}/metrics-exporter.sh" ;;
  fleet-manifest)
    fleet_manifest ;;
  config-track)
    shift; exec "${TRACK_SCRIPTS_DIR}/config-track.sh" "$@" ;;
  config-restore)
    shift; exec "${TRACK_SCRIPTS_DIR}/config-restore.sh" "$@" ;;
  verify-stack)
    shift; exec "${SANDBOX_SCRIPTS_DIR}/verify-stack.sh" "$@" ;;
  verify-plan)
    shift; exec "${SANDBOX_SCRIPTS_DIR}/verify-plan.sh" "$@" ;;
  bare-restore)
    shift; exec "${INSTALL_DIR}/scripts/host/bare-restore.sh" "$@" ;;
  components)
    echo "Включено на этом сервере: ${FULL_COMPONENTS:-(по умолчанию)}"
    for c in panel-backup custom-backup wal config-track metrics sandbox web; do
      component_enabled "$c" && echo "  ✅ $c" || echo "  ⬜ $c"
    done ;;
  apply-components)
    apply_components ;;
  decommission-original)
    decommission_original ;;
  verify)
    shift; exec "${SANDBOX_SCRIPTS_DIR}/verify-entry.sh" "$@" ;;
  verify-fleet)
    shift; exec "${SANDBOX_SCRIPTS_DIR}/verify-fleet.sh" "$@" ;;
  fleet-pack)
    shift; exec "${SANDBOX_SCRIPTS_DIR}/fleet-pack.sh" "$@" ;;
  sync-creds)
    exec "${SANDBOX_SCRIPTS_DIR}/sync-fleet-creds.sh" ;;
  status-digest)
    exec "${METRICS_SCRIPTS_DIR}/status-digest.sh" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
