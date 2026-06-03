#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${RW_BACKUP_FULL_INSTALL_DIR:-/opt/rw-backup-restore}"
BACKUP_DIR_DEFAULT="${INSTALL_DIR}/backup"
ORIGINAL_CONFIG_FILE="${RW_BACKUP_ORIGINAL_CONFIG:-${INSTALL_DIR}/config.env}"
FULL_CONFIG_FILE="${RW_BACKUP_FULL_CONFIG:-${INSTALL_DIR}/rw-backup-full.env}"
ORIGINAL_RW_BACKUP_SCRIPT="${INSTALL_DIR}/backup-restore.sh"
ORIGINAL_RW_BACKUP_BIN="rw-backup"
UPSTREAM_RAW_URL="${RW_BACKUP_UPSTREAM_RAW_URL:-https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh}"

FULL_BACKUP_DIR="$BACKUP_DIR_DEFAULT"
FULL_UPLOAD_METHOD="inherit"
FULL_LOCAL_RETENTION_DAYS="3"
FULL_S3_RETENTION_DAYS="10"
FULL_TIMER_MODE="custom-backup"
FULL_TIMER_INTERVAL_HOURS="3"
FULL_AUTO_INSTALL_RW_BACKUP="true"
FULL_REQUIRE_ORIGINAL_RW_BACKUP="true"
FULL_INCLUDE_EXTRA_CONFIGS="true"
FULL_SYSTEMD_UNIT_NAME="rw-backup-full"

ORIGINAL_UPLOAD_METHOD=""
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_MESSAGE_THREAD_ID=""
TG_PROXY=""
S3_ENDPOINT=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_BUCKET=""
S3_REGION="us-east-1"
S3_PREFIX=""

RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
RESET=$'\e[0m'
BOLD=$'\e[1m'

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

pause() { echo; read -r -p "Enter..." _ || true; }

bool_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

safe_source() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  set +u
  # shellcheck disable=SC1090
  source "$file"
  set -u
}

load_original_config() {
  safe_source "$ORIGINAL_CONFIG_FILE"

  TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-${BOT_TOKEN:-}}}"
  TG_CHAT_ID="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-${CHAT_ID:-}}}"
  TG_MESSAGE_THREAD_ID="${TG_MESSAGE_THREAD_ID:-${TELEGRAM_MESSAGE_THREAD_ID:-${MESSAGE_THREAD_ID:-${TG_THREAD_ID:-}}}}"
  TG_PROXY="${TG_PROXY:-${TELEGRAM_PROXY:-${PROXY_URL:-}}}"

  S3_BUCKET="${S3_BUCKET:-${AWS_S3_BUCKET:-${BUCKET_NAME:-}}}"
  S3_ACCESS_KEY="${S3_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-${ACCESS_KEY_ID:-}}}"
  S3_SECRET_KEY="${S3_SECRET_KEY:-${AWS_SECRET_ACCESS_KEY:-${SECRET_ACCESS_KEY:-}}}"
  S3_REGION="${S3_REGION:-${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}}"
  S3_ENDPOINT="${S3_ENDPOINT:-${AWS_ENDPOINT_URL:-${ENDPOINT_URL:-}}}"
  S3_PREFIX="${S3_PREFIX:-${AWS_S3_PREFIX:-${S3_PATH_PREFIX:-}}}"
  ORIGINAL_UPLOAD_METHOD="${UPLOAD_METHOD:-${BACKUP_UPLOAD_METHOD:-}}"
}

load_full_config() {
  safe_source "$FULL_CONFIG_FILE"

  FULL_BACKUP_DIR="${FULL_BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
  FULL_UPLOAD_METHOD="${FULL_UPLOAD_METHOD:-inherit}"
  FULL_LOCAL_RETENTION_DAYS="${FULL_LOCAL_RETENTION_DAYS:-3}"
  FULL_S3_RETENTION_DAYS="${FULL_S3_RETENTION_DAYS:-10}"
  FULL_TIMER_MODE="${FULL_TIMER_MODE:-custom-backup}"
  FULL_TIMER_INTERVAL_HOURS="${FULL_TIMER_INTERVAL_HOURS:-3}"
  FULL_AUTO_INSTALL_RW_BACKUP="${FULL_AUTO_INSTALL_RW_BACKUP:-true}"
  FULL_REQUIRE_ORIGINAL_RW_BACKUP="${FULL_REQUIRE_ORIGINAL_RW_BACKUP:-true}"
  FULL_INCLUDE_EXTRA_CONFIGS="${FULL_INCLUDE_EXTRA_CONFIGS:-true}"
  FULL_SYSTEMD_UNIT_NAME="${FULL_SYSTEMD_UNIT_NAME:-rw-backup-full}"

  mkdir -p "$FULL_BACKUP_DIR"
}

load_config() {
  load_original_config
  load_full_config
}

effective_upload_method() {
  local method="$FULL_UPLOAD_METHOD"
  if [[ "$method" == "inherit" ]]; then
    method="${ORIGINAL_UPLOAD_METHOD:-telegram}"
  fi
  case "$method" in
    telegram|s3|both|local|none) echo "$method" ;;
    *) echo "telegram" ;;
  esac
}

ensure_tools() {
  command -v docker >/dev/null 2>&1 || { msg ERR "docker не найден"; exit 1; }
  docker compose version >/dev/null 2>&1 || { msg ERR "docker compose не найден"; exit 1; }
  command -v tar >/dev/null 2>&1 || { msg ERR "tar не найден"; exit 1; }
  command -v gzip >/dev/null 2>&1 || { msg ERR "gzip не найден"; exit 1; }
}

original_rw_backup_available() {
  command -v "$ORIGINAL_RW_BACKUP_BIN" >/dev/null 2>&1 && return 0
  [[ -x "$ORIGINAL_RW_BACKUP_SCRIPT" ]] && return 0
  return 1
}

install_original_rw_backup() {
  msg INFO "Устанавливаю оригинальный rw-backup из ${UPSTREAM_RAW_URL}"
  mkdir -p "$INSTALL_DIR" "$FULL_BACKUP_DIR"

  if ! command -v curl >/dev/null 2>&1; then
    msg ERR "curl не найден. Установи: apt-get update && apt-get install -y curl"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$UPSTREAM_RAW_URL" -o "$tmp"; then
    rm -f "$tmp"
    msg ERR "Не удалось скачать оригинальный backup-restore.sh"
    return 1
  fi

  install -m 0755 "$tmp" "$ORIGINAL_RW_BACKUP_SCRIPT"
  rm -f "$tmp"
  ln -sf "$ORIGINAL_RW_BACKUP_SCRIPT" /usr/local/bin/rw-backup

  if [[ ! -f "$ORIGINAL_CONFIG_FILE" ]]; then
    cat > "$ORIGINAL_CONFIG_FILE" <<'CFG'
# Original rw-backup config.env.
# Запусти `rw-backup` и настрой оригинальный скрипт, либо заполни Telegram/S3 параметры здесь.

UPLOAD_METHOD="telegram"

# Telegram aliases supported by rw-backup-full:
BOT_TOKEN=""
CHAT_ID=""
MESSAGE_THREAD_ID=""

# S3 aliases supported by rw-backup-full:
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION="us-east-1"
S3_ENDPOINT=""
S3_PREFIX="rw-backup"
CFG
    chmod 600 "$ORIGINAL_CONFIG_FILE" || true
    msg WARN "Создан минимальный ${ORIGINAL_CONFIG_FILE}. Заполни Telegram/S3 параметры."
  fi

  msg OK "Оригинальный rw-backup установлен"
}

ensure_original_rw_backup_if_required() {
  original_rw_backup_available && return 0
  if bool_true "$FULL_AUTO_INSTALL_RW_BACKUP"; then install_original_rw_backup && return 0; fi
  if bool_true "$FULL_REQUIRE_ORIGINAL_RW_BACKUP"; then
    msg ERR "Оригинальный rw-backup не найден. Включи FULL_AUTO_INSTALL_RW_BACKUP=true или установи вручную."
    return 1
  fi
  msg WARN "Оригинальный rw-backup не найден, но FULL_REQUIRE_ORIGINAL_RW_BACKUP=false. Продолжаю только custom-функции."
  return 0
}

run_original_rw_backup_cmd() {
  local action="${1:-}"
  ensure_original_rw_backup_if_required || return 1
  if command -v "$ORIGINAL_RW_BACKUP_BIN" >/dev/null 2>&1; then
    if [[ -n "$action" ]]; then "$ORIGINAL_RW_BACKUP_BIN" "$action"; else "$ORIGINAL_RW_BACKUP_BIN"; fi
    return $?
  fi
  if [[ -x "$ORIGINAL_RW_BACKUP_SCRIPT" ]]; then
    if [[ -n "$action" ]]; then bash "$ORIGINAL_RW_BACKUP_SCRIPT" "$action"; else bash "$ORIGINAL_RW_BACKUP_SCRIPT"; fi
    return $?
  fi
  msg ERR "Оригинальный rw-backup не найден"
  return 1
}

local_panel_detected() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "remnawave-db" && return 0
  [[ -f "/opt/remnawave/docker-compose.yml" || -f "/opt/remnawave/docker-compose.yaml" ]] && return 0
  return 1
}

run_original_panel_backup() {
  ensure_original_rw_backup_if_required || return 1
  if ! local_panel_detected; then
    msg WARN "Локальная Remnawave panel не найдена, panel backup пропущен"
    return 0
  fi
  run_original_rw_backup_cmd "backup"
}

run_original_panel_restore() { run_original_rw_backup_cmd "restore"; }

telegram_api_url() { echo "https://api.telegram.org/bot${TG_BOT_TOKEN}/$1"; }

send_telegram_message() {
  local text="$1"
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  local args=(-s -X POST "$(telegram_api_url sendMessage)" -d "chat_id=${TG_CHAT_ID}" -d "text=${text}")
  [[ -n "${TG_MESSAGE_THREAD_ID:-}" ]] && args+=(-d "message_thread_id=${TG_MESSAGE_THREAD_ID}")
  [[ -n "${TG_PROXY:-}" ]] && args=(--proxy "$TG_PROXY" "${args[@]}")
  curl "${args[@]}" >/dev/null 2>&1
}

send_telegram_document() {
  local file_path="$1" caption="$2"
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  local size_bytes
  size_bytes="$(stat -c%s "$file_path" 2>/dev/null || echo 0)"
  if (( size_bytes > 50 * 1024 * 1024 )); then
    msg WARN "Файл больше 50 MB, Telegram его не примет: $(du -h "$file_path" | awk '{print $1}')"
    send_telegram_message "⚠️ Backup создан локально, но файл больше 50 MB и не отправлен в Telegram: $(basename "$file_path")" || true
    return 2
  fi
  local args=(-s -X POST "$(telegram_api_url sendDocument)" -F "chat_id=${TG_CHAT_ID}" -F "document=@${file_path}" -F "caption=${caption}")
  [[ -n "${TG_MESSAGE_THREAD_ID:-}" ]] && args+=(-F "message_thread_id=${TG_MESSAGE_THREAD_ID}")
  [[ -n "${TG_PROXY:-}" ]] && args=(--proxy "$TG_PROXY" "${args[@]}")
  curl "${args[@]}" >/dev/null 2>&1
}

s3_prefix_normalized() {
  local prefix="${S3_PREFIX:-}"
  if [[ -n "$prefix" ]]; then
    prefix="${prefix#/}"; prefix="${prefix%/}"; echo "${prefix}/"
  else echo ""; fi
}

send_s3_document() {
  local file_path="$1" file_name prefix s3_key
  file_name="$(basename "$file_path")"
  prefix="$(s3_prefix_normalized)"
  s3_key="${prefix}${file_name}"
  if ! command -v aws >/dev/null 2>&1; then msg ERR "awscli не найден. Установи: apt-get update && apt-get install -y awscli"; return 1; fi
  if [[ -z "${S3_BUCKET:-}" || -z "${S3_ACCESS_KEY:-}" || -z "${S3_SECRET_KEY:-}" ]]; then msg ERR "S3 не настроен в оригинальном ${ORIGINAL_CONFIG_FILE}"; return 1; fi
  local endpoint_arg=()
  [[ -n "${S3_ENDPOINT:-}" ]] && endpoint_arg=(--endpoint-url "$S3_ENDPOINT")
  msg INFO "Отправляю в S3: s3://${S3_BUCKET}/${s3_key}"
  AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" aws s3 cp "$file_path" "s3://${S3_BUCKET}/${s3_key}" "${endpoint_arg[@]}" --quiet
}

cleanup_local_custom_backups() {
  local retention_days="${FULL_LOCAL_RETENTION_DAYS:-3}"
  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then retention_days="3"; fi
  if (( retention_days <= 0 )); then msg WARN "Локальная очистка выключена"; return 0; fi
  msg INFO "Очищаю локальные custom_bot_*.tar.gz старше ${retention_days} дней"
  find "$FULL_BACKUP_DIR" -type f -name 'custom_bot_*.tar.gz' -mtime "+${retention_days}" -delete 2>/dev/null || true
}

cleanup_s3_custom_backups() {
  local method; method="$(effective_upload_method)"
  [[ "$method" == "s3" || "$method" == "both" ]] || return 0
  if ! command -v aws >/dev/null 2>&1; then msg WARN "awscli не найден, S3 retention пропущен"; return 0; fi
  if [[ -z "${S3_BUCKET:-}" || -z "${S3_ACCESS_KEY:-}" || -z "${S3_SECRET_KEY:-}" ]]; then msg WARN "S3 не настроен, S3 retention пропущен"; return 0; fi
  local retention_days="${FULL_S3_RETENTION_DAYS:-10}"
  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then retention_days="10"; fi
  if (( retention_days <= 0 )); then msg WARN "S3 retention выключен"; return 0; fi
  local endpoint_arg=() prefix s3_path cutoff_epoch checked=0 deleted=0
  [[ -n "${S3_ENDPOINT:-}" ]] && endpoint_arg=(--endpoint-url "$S3_ENDPOINT")
  prefix="$(s3_prefix_normalized)"
  s3_path="s3://${S3_BUCKET}/${prefix}"
  cutoff_epoch="$(date -u -d "-${retention_days} days" +%s)"
  msg INFO "Проверяю глубину хранения custom backup в S3: ${retention_days} дней"
  msg INFO "S3 path: ${s3_path}"
  while read -r file_date file_time file_size file_key; do
    [[ -n "${file_key:-}" ]] || continue
    local base_name file_epoch
    base_name="$(basename "$file_key")"
    [[ "$base_name" =~ ^custom_bot_.*\.tar\.gz$ ]] || continue
    checked=$((checked + 1))
    file_epoch="$(date -u -d "${file_date} ${file_time}" +%s 2>/dev/null || echo 0)"
    if (( file_epoch > 0 && file_epoch < cutoff_epoch )); then
      msg INFO "Удаляю старый S3 backup: ${file_key}"
      AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" aws s3 rm "s3://${S3_BUCKET}/${file_key}" "${endpoint_arg[@]}" --quiet || true
      deleted=$((deleted + 1))
    fi
  done < <(AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" aws s3 ls "$s3_path" "${endpoint_arg[@]}" --recursive 2>/dev/null || true)
  msg OK "S3 retention complete: checked=${checked}, deleted=${deleted}, retention_days=${retention_days}"
}

upload_backup() {
  local file_path="$1" caption="$2" method status=0
  method="$(effective_upload_method)"
  msg INFO "Upload method: ${method}"
  case "$method" in
    telegram) send_telegram_document "$file_path" "$caption" && msg OK "Backup отправлен в Telegram" || { msg WARN "Backup сохранён локально, но не отправлен в Telegram"; status=1; } ;;
    s3)
      if send_s3_document "$file_path"; then msg OK "Backup отправлен в S3"; send_telegram_message "✅ Backup отправлен в S3: $(basename "$file_path")" || true; cleanup_s3_custom_backups; else msg WARN "Backup сохранён локально, но не отправлен в S3"; send_telegram_message "❌ Ошибка отправки backup в S3: $(basename "$file_path")" || true; status=1; fi ;;
    both) send_telegram_document "$file_path" "$caption" && msg OK "Backup отправлен в Telegram" || { msg WARN "Backup не отправлен в Telegram"; status=1; }; send_s3_document "$file_path" && { msg OK "Backup отправлен в S3"; cleanup_s3_custom_backups; } || { msg WARN "Backup не отправлен в S3"; status=1; } ;;
    local|none) msg INFO "Backup оставлен только локально" ;;
    *) msg WARN "Неизвестный method=${method}, оставляю локально" ;;
  esac
  return "$status"
}

docker_label() {
  local container="$1" label="$2"
  docker inspect -f "{{ index .Config.Labels \"$label\" }}" "$container" 2>/dev/null || true
}

detect_custom_projects() {
  declare -A project_dirs
  while read -r container; do
    [[ -n "$container" ]] || continue
    local project workdir
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
    local dir="${project_dirs[$project]}" pg_container="" pg_service="" redis_container="" redis_service="" apps=()
    while read -r container; do
      [[ -n "$container" ]] || continue
      local c_project c_service c_image
      c_project="$(docker_label "$container" "com.docker.compose.project")"
      [[ "$c_project" == "$project" ]] || continue
      c_service="$(docker_label "$container" "com.docker.compose.service")"
      c_image="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
      if [[ "$c_service" == "postgres" || "$c_image" =~ postgres ]]; then pg_container="$container"; pg_service="${c_service:-postgres}"
      elif [[ "$c_service" == "redis" || "$c_image" =~ redis || "$c_image" =~ valkey ]]; then redis_container="$container"; redis_service="${c_service:-redis}"
      else apps+=("$container"); fi
    done < <(docker ps -a --format '{{.Names}}')
    [[ -n "$pg_container" && -n "$redis_container" ]] && echo "${project}|${dir}|${pg_container}|${pg_service}|${redis_container}|${redis_service}|${apps[*]}"
  done
}

print_custom_projects() {
  local found=0
  while IFS='|' read -r project dir pg pg_service redis redis_service apps; do
    found=1
    echo; echo -e "${GREEN}${BOLD}${project}${RESET}"
    echo "  dir:      ${dir}"
    echo "  postgres: ${pg} / service=${pg_service}"
    echo "  redis:    ${redis} / service=${redis_service}"
    echo "  apps:     ${apps}"
  done < <(detect_custom_projects)
  [[ "$found" -eq 0 ]] && msg WARN "Custom bot compose-проекты в /home не найдены"
}

select_custom_project() {
  mapfile -t projects < <(detect_custom_projects)
  [[ "${#projects[@]}" -gt 0 ]] || { msg ERR "Не найдено custom bot проектов в /home"; return 1; }
  if [[ "${#projects[@]}" -eq 1 ]]; then echo "${projects[0]}"; return 0; fi
  echo; echo -e "${GREEN}${BOLD}Выбери custom bot project:${RESET}"; echo
  local i=1 entry
  for entry in "${projects[@]}"; do IFS='|' read -r project dir pg pg_service redis redis_service apps <<< "$entry"; echo " ${i}. ${project} — ${dir}"; ((i++)); done
  echo; read -r -p "[?] Номер: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { msg ERR "Некорректный выбор"; return 1; }
  (( choice >= 1 && choice <= ${#projects[@]} )) || { msg ERR "Некорректный выбор"; return 1; }
  echo "${projects[$((choice - 1))]}"
}

write_profile_env() {
  local file="$1" project_name="$2" project_dir="$3" pg_container="$4" pg_service="$5" redis_container="$6" redis_service="$7" app_containers="$8" timestamp="$9"
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
  local TIMESTAMP SAFE_PROJECT WORK_DIR FINAL_ARCHIVE PROJECT_BASE
  TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
  SAFE_PROJECT="$(echo "$PROJECT_NAME" | tr -c 'A-Za-z0-9_.-' '_')"
  WORK_DIR="${FULL_BACKUP_DIR}/custom_bot_${SAFE_PROJECT}_${TIMESTAMP}"
  FINAL_ARCHIVE="${FULL_BACKUP_DIR}/custom_bot_${SAFE_PROJECT}_${TIMESTAMP}.tar.gz"
  PROJECT_BASE="$(basename "$PROJECT_DIR")"
  mkdir -p "$WORK_DIR"
  msg INFO "Backup custom bot: ${PROJECT_NAME}"
  msg INFO "Project dir: ${PROJECT_DIR}"
  msg INFO "PostgreSQL: ${POSTGRES_CONTAINER}"
  msg INFO "Redis: ${REDIS_CONTAINER}"
  [[ -d "$PROJECT_DIR" ]] || { msg ERR "Project dir не найден: ${PROJECT_DIR}"; return 1; }
  docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1 || { msg ERR "PostgreSQL container не найден: ${POSTGRES_CONTAINER}"; return 1; }
  docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1 || { msg ERR "Redis container не найден: ${REDIS_CONTAINER}"; return 1; }
  write_profile_env "$WORK_DIR/PROFILE.env" "$PROJECT_NAME" "$PROJECT_DIR" "$POSTGRES_CONTAINER" "$POSTGRES_SERVICE" "$REDIS_CONTAINER" "$REDIS_SERVICE" "$APP_CONTAINERS" "$TIMESTAMP"
  msg INFO "Сохраняю docker metadata..."
  docker ps -a > "$WORK_DIR/docker-ps-a.txt" 2>/dev/null || true
  docker volume ls > "$WORK_DIR/docker-volume-ls.txt" 2>/dev/null || true
  docker network ls > "$WORK_DIR/docker-network-ls.txt" 2>/dev/null || true
  for c in $APP_CONTAINERS "$POSTGRES_CONTAINER" "$REDIS_CONTAINER"; do docker inspect "$c" > "$WORK_DIR/inspect-${c}.json" 2>/dev/null || true; done
  msg INFO "Сохраняю compose metadata..."
  (cd "$PROJECT_DIR" && docker compose ps -a > "$WORK_DIR/docker-compose-ps-a.txt" 2>/dev/null || true && docker compose config --services > "$WORK_DIR/docker-compose-services.txt" 2>/dev/null || true && docker compose config > "$WORK_DIR/docker-compose-rendered.yaml" 2>/dev/null || true)
  msg INFO "Создаю PostgreSQL dump..."
  docker exec "$POSTGRES_CONTAINER" sh -lc 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; pg_dumpall -c -U "${POSTGRES_USER:-postgres}"' | gzip -9 > "$WORK_DIR/postgres_dump.sql.gz"
  msg INFO "Создаю Redis dump..."
  if docker exec "$REDIS_CONTAINER" sh -lc 'if [ -n "${REDIS_PASSWORD:-}" ]; then redis-cli -a "$REDIS_PASSWORD" --no-auth-warning SAVE; else redis-cli SAVE; fi' >/dev/null 2>&1; then
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
  tar --exclude='.git' --exclude='__pycache__' --exclude='.pytest_cache' --exclude='*.pyc' --exclude='*.log' --exclude='venv' --exclude='.venv' --exclude='node_modules' --exclude="${PROJECT_BASE}/volumes/pgdata" --exclude="${PROJECT_BASE}/volumes/redis" --exclude='*/volumes/pgdata' --exclude='*/volumes/redis' -czf "$WORK_DIR/project_dir.tar.gz" -C "$(dirname "$PROJECT_DIR")" "$PROJECT_BASE"
  if bool_true "$FULL_INCLUDE_EXTRA_CONFIGS"; then
    msg INFO "Сохраняю дополнительные конфиги Caddy/subscription, если есть..."
    mkdir -p "$WORK_DIR/extra_configs"
    [[ -d "/opt/remnawave/caddy" ]] && tar -czf "$WORK_DIR/extra_configs/caddy_config.tar.gz" -C /opt/remnawave caddy
    [[ -d "/opt/remnawave/subscription" ]] && tar -czf "$WORK_DIR/extra_configs/subscription_config.tar.gz" -C /opt/remnawave subscription
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

Project archive:
  project_dir.tar.gz

Excluded from project archive:
  volumes/pgdata
  volumes/redis
NOTES
  (cd "$WORK_DIR" && find . -type f -maxdepth 3 -print0 | xargs -0 sha256sum > SHA256SUMS 2>/dev/null || true)
  msg INFO "Создаю финальный архив..."
  (cd "$FULL_BACKUP_DIR" && tar -czf "$FINAL_ARCHIVE" "$(basename "$WORK_DIR")")
  rm -rf "$WORK_DIR"
  msg OK "Backup создан: ${FINAL_ARCHIVE}"
  du -h "$FINAL_ARCHIVE" || true
  upload_backup "$FINAL_ARCHIVE" "custom bot backup: ${PROJECT_NAME} ${TIMESTAMP}" || true
  cleanup_local_custom_backups
}

backup_custom_menu() { local entry; entry="$(select_custom_project)" || return 1; backup_custom_project_entry "$entry"; }
backup_custom_all() {
  local found=0 entry
  while IFS= read -r entry; do [[ -n "$entry" ]] || continue; found=1; backup_custom_project_entry "$entry"; done < <(detect_custom_projects)
  [[ "$found" -eq 1 ]] || { msg WARN "Custom bot проекты не найдены"; return 1; }
}

select_restore_archive() {
  mapfile -t archives < <(find "$FULL_BACKUP_DIR" -maxdepth 1 -type f -name 'custom_bot_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')
  echo; echo -e "${GREEN}${BOLD}Выбери архив для восстановления:${RESET}"; echo
  if [[ "${#archives[@]}" -gt 0 ]]; then
    local i=1 a
    for a in "${archives[@]}"; do echo " ${i}. $(basename "$a") — $(du -h "$a" | awk '{print $1}')"; ((i++)); done
    echo
  else msg WARN "Локальные custom_bot архивы не найдены в ${FULL_BACKUP_DIR}"; fi
  echo " 0. Указать путь вручную"; echo
  read -r -p "[?] Номер или 0: " choice
  if [[ "$choice" == "0" ]]; then read -r -p "Путь к архиву: " manual_archive; [[ -f "$manual_archive" ]] || { msg ERR "Файл не найден: ${manual_archive}"; return 1; }; echo "$manual_archive"; return 0; fi
  [[ "$choice" =~ ^[0-9]+$ ]] || { msg ERR "Некорректный выбор"; return 1; }
  (( choice >= 1 && choice <= ${#archives[@]} )) || { msg ERR "Некорректный выбор"; return 1; }
  echo "${archives[$((choice - 1))]}"
}

restore_custom_archive() {
  local archive="$1" assume_yes="${2:-no}"
  [[ -f "$archive" ]] || { msg ERR "Архив не найден: ${archive}"; return 1; }
  local restore_ts tmp_root extract_dir project_extract_dir
  restore_ts="$(date +%Y%m%d_%H%M%S)"
  tmp_root="/tmp/rw-custom-restore-${restore_ts}"
  extract_dir="${tmp_root}/outer"
  project_extract_dir="${tmp_root}/project"
  mkdir -p "$extract_dir" "$project_extract_dir"
  cleanup_restore_tmp() { rm -rf "$tmp_root"; }
  trap cleanup_restore_tmp RETURN
  msg INFO "Распаковываю архив: ${archive}"
  tar -xzf "$archive" -C "$extract_dir"
  local project_tar postgres_dump redis_dump profile_env project_top
  project_tar="$(find "$extract_dir" -type f -name 'project_dir.tar.gz' | head -n 1 || true)"
  postgres_dump="$(find "$extract_dir" -type f -name 'postgres_dump.sql.gz' | head -n 1 || true)"
  redis_dump="$(find "$extract_dir" -type f -name 'redis_dump.rdb' | head -n 1 || true)"
  profile_env="$(find "$extract_dir" -type f -name 'PROFILE.env' | head -n 1 || true)"
  [[ -n "$project_tar" ]] || { msg ERR "В архиве нет project_dir.tar.gz"; return 1; }
  [[ -n "$postgres_dump" ]] || { msg ERR "В архиве нет postgres_dump.sql.gz"; return 1; }
  [[ -n "$profile_env" ]] && safe_source "$profile_env"
  project_top="$(tar -tzf "$project_tar" | head -n 1 | cut -d/ -f1)"
  [[ -n "$project_top" ]] || { msg ERR "Не могу определить папку проекта внутри project_dir.tar.gz"; return 1; }
  PROJECT_NAME="${PROJECT_NAME:-$project_top}"
  PROJECT_DIR="${PROJECT_DIR:-/home/$project_top}"
  POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-vpn_postgres}"
  POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
  REDIS_CONTAINER="${REDIS_CONTAINER:-vpn_redis}"
  REDIS_SERVICE="${REDIS_SERVICE:-redis}"
  echo; echo -e "${YELLOW}${BOLD}Restore custom bot${RESET}"
  echo "  archive:            ${archive}"
  echo "  project in archive: ${project_top}"
  echo "  target dir:         ${PROJECT_DIR}"
  echo "  postgres:           ${POSTGRES_CONTAINER} / service=${POSTGRES_SERVICE}"
  echo "  redis:              ${REDIS_CONTAINER} / service=${REDIS_SERVICE}"
  echo
  if [[ "$assume_yes" != "yes" ]]; then read -r -p "Восстановить в ${PROJECT_DIR}? Напиши RESTORE: " confirm; [[ "$confirm" == "RESTORE" ]] || { msg WARN "Restore отменён"; return 1; }; fi
  local old_dir="${PROJECT_DIR}.before_restore_${restore_ts}"
  if [[ -d "$PROJECT_DIR" ]]; then
    msg INFO "Останавливаю текущий compose-проект..."
    if [[ -f "$PROJECT_DIR/docker-compose.yaml" || -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/compose.yaml" || -f "$PROJECT_DIR/compose.yml" ]]; then (cd "$PROJECT_DIR" && docker compose down || true); fi
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
  else msg WARN "redis_dump.rdb не найден, Redis восстановление пропущено"; fi
  cd "$PROJECT_DIR"
  msg INFO "Поднимаю PostgreSQL service: ${POSTGRES_SERVICE}"
  docker compose up -d "$POSTGRES_SERVICE"
  msg INFO "Жду готовности PostgreSQL..."
  local ready="no"
  for i in $(seq 1 60); do
    if docker exec "$POSTGRES_CONTAINER" sh -lc 'pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' >/dev/null 2>&1; then ready="yes"; break; fi
    echo "[INFO] PostgreSQL not ready: ${i}/60"; sleep 2
  done
  [[ "$ready" == "yes" ]] || { msg ERR "PostgreSQL не стал готовым"; docker logs "$POSTGRES_CONTAINER" --tail 100 || true; return 1; }
  msg INFO "Заливаю PostgreSQL dump..."
  gzip -dc "$postgres_dump" | docker exec -i "$POSTGRES_CONTAINER" sh -lc 'export PGPASSWORD="${POSTGRES_PASSWORD:-}"; psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d postgres'
  msg OK "PostgreSQL восстановлен"
  msg INFO "Поднимаю Redis service: ${REDIS_SERVICE}"
  docker compose up -d "$REDIS_SERVICE"
  sleep 3
  msg INFO "Поднимаю весь compose-проект..."
  docker compose up -d
  echo; docker compose ps -a; echo
  msg OK "Restore завершён"
  [[ -d "$old_dir" ]] && msg INFO "Старая папка сохранена: ${old_dir}"
}
restore_custom_menu() { local archive; archive="$(select_restore_archive)" || return 1; restore_custom_archive "$archive"; }

backup_all() { msg INFO "Запускаю Backup ALL"; run_original_panel_backup || msg WARN "Panel backup завершился с ошибкой или был пропущен"; backup_custom_all || msg WARN "Custom bot backup завершился с ошибкой или проекты не найдены"; msg OK "Backup ALL завершён"; }

set_full_config_var() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$FULL_CONFIG_FILE")"
  touch "$FULL_CONFIG_FILE"
  chmod 600 "$FULL_CONFIG_FILE" || true
  if grep -qE "^${key}=" "$FULL_CONFIG_FILE"; then sed -i -E "s|^${key}=.*|${key}=\"${value}\"|" "$FULL_CONFIG_FILE"; else printf '%s="%s"\n' "$key" "$value" >> "$FULL_CONFIG_FILE"; fi
}

configure_full_retention() {
  echo; echo -e "${GREEN}${BOLD}Настройка rw-backup-full retention и режима${RESET}"; echo
  echo "Текущие значения:"
  echo "  FULL_UPLOAD_METHOD=${FULL_UPLOAD_METHOD}"
  echo "  FULL_LOCAL_RETENTION_DAYS=${FULL_LOCAL_RETENTION_DAYS}"
  echo "  FULL_S3_RETENTION_DAYS=${FULL_S3_RETENTION_DAYS}"
  echo "  FULL_TIMER_MODE=${FULL_TIMER_MODE}"
  echo "  FULL_TIMER_INTERVAL_HOURS=${FULL_TIMER_INTERVAL_HOURS}"
  echo
  read -r -p "UPLOAD_METHOD для full [inherit/telegram/s3/both/local] (${FULL_UPLOAD_METHOD}): " v; [[ -n "$v" ]] && set_full_config_var "FULL_UPLOAD_METHOD" "$v"
  read -r -p "Локальное хранение custom backup, дней (${FULL_LOCAL_RETENTION_DAYS}): " v; [[ -n "$v" ]] && set_full_config_var "FULL_LOCAL_RETENTION_DAYS" "$v"
  read -r -p "S3 хранение custom backup, дней (${FULL_S3_RETENTION_DAYS}): " v; [[ -n "$v" ]] && set_full_config_var "FULL_S3_RETENTION_DAYS" "$v"
  read -r -p "Режим таймера [custom-backup/backup-all] (${FULL_TIMER_MODE}): " v; [[ -n "$v" ]] && set_full_config_var "FULL_TIMER_MODE" "$v"
  read -r -p "Интервал таймера, часов (${FULL_TIMER_INTERVAL_HOURS}): " v; [[ -n "$v" ]] && set_full_config_var "FULL_TIMER_INTERVAL_HOURS" "$v"
  load_config
  msg OK "Настройки сохранены в ${FULL_CONFIG_FILE}"
}

install_or_update_systemd_timer() {
  load_config
  local unit="${FULL_SYSTEMD_UNIT_NAME:-rw-backup-full}" mode="${FULL_TIMER_MODE:-custom-backup}" hours="${FULL_TIMER_INTERVAL_HOURS:-3}"
  if ! [[ "$hours" =~ ^[0-9]+$ ]] || (( hours <= 0 )); then msg WARN "Некорректный FULL_TIMER_INTERVAL_HOURS=${hours}, использую 3"; hours="3"; fi
  case "$mode" in custom-backup|backup-all) ;; *) msg WARN "Некорректный FULL_TIMER_MODE=${mode}, использую custom-backup"; mode="custom-backup" ;; esac
  msg INFO "Устанавливаю systemd timer: ${unit}.timer"
  msg INFO "Команда: /usr/local/bin/rw-backup-full ${mode}"
  msg INFO "Интервал: каждые ${hours} часа"
  cat > "/etc/systemd/system/${unit}.service" <<EOF_SERVICE
[Unit]
Description=rw-backup-full ${mode}
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rw-backup-full ${mode}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF_SERVICE
  cat > "/etc/systemd/system/${unit}.timer" <<EOF_TIMER
[Unit]
Description=Run rw-backup-full ${mode} every ${hours} hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=${hours}h
Persistent=true
Unit=${unit}.service

[Install]
WantedBy=timers.target
EOF_TIMER
  systemctl daemon-reload
  systemctl enable --now "${unit}.timer"
  msg OK "Timer включён: ${unit}.timer"
  systemctl list-timers "${unit}.timer" || true
}

remove_systemd_timer() { local unit="${FULL_SYSTEMD_UNIT_NAME:-rw-backup-full}"; systemctl disable --now "${unit}.timer" 2>/dev/null || true; rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service"; systemctl daemon-reload; msg OK "Timer удалён: ${unit}.timer"; }

systemd_timer_menu() {
  echo; echo -e "${GREEN}${BOLD}Systemd timer${RESET}"; echo
  echo "1. Установить/обновить timer"
  echo "2. Показать статус"
  echo "3. Удалить timer"
  echo "0. Назад"
  echo
  read -r -p "[?] Выбор: " c
  case "$c" in
    1) install_or_update_systemd_timer ;;
    2) systemctl status "${FULL_SYSTEMD_UNIT_NAME:-rw-backup-full}.timer" --no-pager || true; systemctl list-timers | grep rw-backup || true ;;
    3) remove_systemd_timer ;;
    0) return 0 ;;
    *) msg ERR "Некорректный выбор" ;;
  esac
}

show_config_summary() {
  echo; echo -e "${GREEN}${BOLD}Конфигурация${RESET}"; echo
  echo "Original config:           ${ORIGINAL_CONFIG_FILE}"
  echo "Full config:               ${FULL_CONFIG_FILE}"
  echo "Full backup dir:           ${FULL_BACKUP_DIR}"
  echo "Full upload method:        ${FULL_UPLOAD_METHOD} (effective: $(effective_upload_method))"
  echo "Full local retention days: ${FULL_LOCAL_RETENTION_DAYS}"
  echo "Full S3 retention days:    ${FULL_S3_RETENTION_DAYS}"
  echo "Timer mode:                ${FULL_TIMER_MODE}"
  echo "Timer interval hours:      ${FULL_TIMER_INTERVAL_HOURS}"
  echo "Original rw-backup:        $(original_rw_backup_available && echo found || echo missing)"
  echo
  echo "Telegram from original config:"
  echo "  TG_CHAT_ID:              ${TG_CHAT_ID:-not set}"
  echo "  TG_THREAD_ID:            ${TG_MESSAGE_THREAD_ID:-not set}"
  echo
  echo "S3 from original config:"
  echo "  S3_BUCKET:               ${S3_BUCKET:-not set}"
  echo "  S3_PREFIX:               ${S3_PREFIX:-not set}"
  echo "  S3_REGION:               ${S3_REGION:-not set}"
  echo "  S3_ENDPOINT:             ${S3_ENDPOINT:-not set}"
  echo
}

main_menu() {
  while true; do
    load_config
    clear
    echo -e "${GREEN}${BOLD}rw-backup-full${RESET}"
    echo
    echo " 1. Backup Remnawave panel через оригинальный rw-backup"
    echo " 2. Restore Remnawave panel через оригинальный rw-backup"
    echo " 3. Backup custom bot из /home"
    echo " 4. Restore custom bot из custom_bot архива"
    echo " 5. Backup ALL: panel + custom bot"
    echo " 6. Показать найденные custom bot проекты"
    echo " 7. Настроить full retention / режим / интервал"
    echo " 8. Установить/обновить systemd timer"
    echo " 9. Установить/обновить оригинальный rw-backup"
    echo "10. Показать настройки"
    echo "11. Открыть оригинальное меню rw-backup"
    echo
    echo " 0. Выход"
    echo
    read -r -p "[?] Выбор: " choice
    echo
    case "$choice" in
      1) run_original_panel_backup; pause ;;
      2) run_original_panel_restore; pause ;;
      3) backup_custom_menu; pause ;;
      4) restore_custom_menu; pause ;;
      5) backup_all; pause ;;
      6) print_custom_projects; pause ;;
      7) configure_full_retention; pause ;;
      8) systemd_timer_menu; pause ;;
      9) install_original_rw_backup; pause ;;
      10) show_config_summary; pause ;;
      11) run_original_rw_backup_cmd "" || true; pause ;;
      0) exit 0 ;;
      *) msg ERR "Некорректный выбор"; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<'USAGE'
Usage:
  rw-backup-full
  rw-backup-full menu
  rw-backup-full list
  rw-backup-full config
  rw-backup-full configure
  rw-backup-full install-rw-backup
  rw-backup-full install-timer
  rw-backup-full remove-timer
  rw-backup-full custom-backup
  rw-backup-full custom-restore
  rw-backup-full custom-restore-file /path/to/custom_bot_archive.tar.gz [--yes]
  rw-backup-full panel-backup
  rw-backup-full panel-restore
  rw-backup-full backup-all
  rw-backup-full s3-cleanup
  rw-backup-full local-cleanup
USAGE
}

load_config
ensure_tools
cmd="${1:-menu}"
case "$cmd" in
  menu) main_menu ;;
  list) print_custom_projects ;;
  config) show_config_summary ;;
  configure) configure_full_retention ;;
  install-rw-backup) install_original_rw_backup ;;
  install-timer) install_or_update_systemd_timer ;;
  remove-timer) remove_systemd_timer ;;
  custom-backup) ensure_original_rw_backup_if_required || true; backup_custom_all ;;
  custom-restore) restore_custom_menu ;;
  custom-restore-file)
    archive="${2:-}"; yes_flag="${3:-}"
    [[ -n "$archive" ]] || { usage; exit 1; }
    if [[ "$yes_flag" == "--yes" || "$yes_flag" == "-y" ]]; then restore_custom_archive "$archive" "yes"; else restore_custom_archive "$archive"; fi
    ;;
  panel-backup) run_original_panel_backup ;;
  panel-restore) run_original_panel_restore ;;
  backup-all) backup_all ;;
  s3-cleanup) cleanup_s3_custom_backups ;;
  local-cleanup) cleanup_local_custom_backups ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
