#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
ORIGINAL_CONFIG_FILE="${ORIGINAL_CONFIG_FILE:-${INSTALL_DIR}/config.env}"
FULL_CONFIG_FILE="${FULL_CONFIG_FILE:-${INSTALL_DIR}/rw-backup-full.env}"
ORIGINAL_RW_BACKUP_BIN="${ORIGINAL_RW_BACKUP_BIN:-rw-backup}"
ORIGINAL_RW_BACKUP_SCRIPT="${ORIGINAL_RW_BACKUP_SCRIPT:-${INSTALL_DIR}/backup-restore.sh}"

RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
RESET=$'\e[0m'
BOLD=$'\e[1m'

ORIG_TG_BOT_TOKEN=""
ORIG_TG_CHAT_ID=""
ORIG_TG_MESSAGE_THREAD_ID=""
ORIG_TG_PROXY=""
ORIG_S3_BUCKET=""
ORIG_S3_ACCESS_KEY=""
ORIG_S3_SECRET_KEY=""
ORIG_S3_REGION=""
ORIG_S3_ENDPOINT=""
ORIG_S3_PREFIX=""
ORIG_UPLOAD_METHOD=""

FULL_LOCAL_RETENTION_DAYS="3"
FULL_EXTERNAL_S3_RETENTION_DAYS="10"
FULL_TIMER_INTERVAL_HOURS="3"
FULL_TIMER_MODE="backup-all"
FULL_AUTO_INSTALL_ORIGINAL_RW_BACKUP="false"
FULL_REQUIRE_ORIGINAL_RW_BACKUP="false"
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
FULL_EXTERNAL_S3_RETENTION_MIN_KEEP="3"
FULL_NOTIFY_ON_FAILURE="true"
FULL_VERIFY_MIN_ARCHIVE_BYTES="1024"
FULL_VERIFY_MIN_PGDUMP_BYTES="60"
FULL_AGE_ENABLED="false"
FULL_AGE_RECIPIENT=""
FULL_AGE_RECIPIENTS_FILE=""
FULL_AGE_IDENTITY_FILE=""

# Результат maybe_encrypt_for_upload / encrypt_archive_age и причина последней ошибки age
ENCRYPT_RESULT_FILE=""
AGE_LAST_ERROR=""
AGE_LAST_ERROR=""
ENCRYPT_RESULT_FILE=""

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

capture_original_vars() {
  ORIG_TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-${BOT_TOKEN:-}}}"
  ORIG_TG_CHAT_ID="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-${CHAT_ID:-}}}"
  ORIG_TG_MESSAGE_THREAD_ID="${TG_MESSAGE_THREAD_ID:-${TELEGRAM_MESSAGE_THREAD_ID:-${MESSAGE_THREAD_ID:-}}}"
  ORIG_TG_PROXY="${TG_PROXY:-${TELEGRAM_PROXY:-}}"

  ORIG_S3_BUCKET="${S3_BUCKET:-${AWS_S3_BUCKET:-}}"
  ORIG_S3_ACCESS_KEY="${S3_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}"
  ORIG_S3_SECRET_KEY="${S3_SECRET_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  ORIG_S3_REGION="${S3_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
  ORIG_S3_ENDPOINT="${S3_ENDPOINT:-${AWS_ENDPOINT_URL:-}}"
  ORIG_S3_PREFIX="${S3_PREFIX:-${AWS_S3_PREFIX:-}}"
  ORIG_UPLOAD_METHOD="${UPLOAD_METHOD:-${BACKUP_UPLOAD_METHOD:-}}"
}

load_config() {
  mkdir -p "$BACKUP_DIR"

  if [[ -f "$ORIGINAL_CONFIG_FILE" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$ORIGINAL_CONFIG_FILE"
    set -u
    capture_original_vars
  fi

  if [[ -f "$FULL_CONFIG_FILE" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$FULL_CONFIG_FILE"
    set -u
  fi

  FULL_LOCAL_RETENTION_DAYS="${FULL_LOCAL_RETENTION_DAYS:-3}"
  FULL_EXTERNAL_S3_RETENTION_DAYS="${FULL_EXTERNAL_S3_RETENTION_DAYS:-10}"
  FULL_TIMER_INTERVAL_HOURS="${FULL_TIMER_INTERVAL_HOURS:-3}"
  FULL_TIMER_MODE="${FULL_TIMER_MODE:-backup-all}"
  FULL_AUTO_INSTALL_ORIGINAL_RW_BACKUP="${FULL_AUTO_INSTALL_ORIGINAL_RW_BACKUP:-false}"
  FULL_REQUIRE_ORIGINAL_RW_BACKUP="${FULL_REQUIRE_ORIGINAL_RW_BACKUP:-false}"
  FULL_INCLUDE_EXTRA_CONFIGS="${FULL_INCLUDE_EXTRA_CONFIGS:-true}"
  FULL_PANEL_EXTERNAL_S3_ENABLED="${FULL_PANEL_EXTERNAL_S3_ENABLED:-true}"
  FULL_CUSTOM_EXTERNAL_S3_ENABLED="${FULL_CUSTOM_EXTERNAL_S3_ENABLED:-true}"
  FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD="${FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD:-true}"
  FULL_TELEGRAM_IMPORT_FROM_ORIGINAL="${FULL_TELEGRAM_IMPORT_FROM_ORIGINAL:-true}"
  FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL="${FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL:-false}"
  FULL_EXTERNAL_S3_RETENTION_MIN_KEEP="${FULL_EXTERNAL_S3_RETENTION_MIN_KEEP:-3}"
  FULL_NOTIFY_ON_FAILURE="${FULL_NOTIFY_ON_FAILURE:-true}"
  FULL_VERIFY_MIN_ARCHIVE_BYTES="${FULL_VERIFY_MIN_ARCHIVE_BYTES:-1024}"
  FULL_VERIFY_MIN_PGDUMP_BYTES="${FULL_VERIFY_MIN_PGDUMP_BYTES:-60}"
  FULL_AGE_ENABLED="${FULL_AGE_ENABLED:-false}"
  FULL_AGE_RECIPIENT="${FULL_AGE_RECIPIENT:-}"
  FULL_AGE_RECIPIENTS_FILE="${FULL_AGE_RECIPIENTS_FILE:-}"
  FULL_AGE_IDENTITY_FILE="${FULL_AGE_IDENTITY_FILE:-}"

  if [[ "$FULL_TELEGRAM_IMPORT_FROM_ORIGINAL" == "true" ]]; then
    FULL_TG_BOT_TOKEN="${FULL_TG_BOT_TOKEN:-$ORIG_TG_BOT_TOKEN}"
    FULL_TG_CHAT_ID="${FULL_TG_CHAT_ID:-$ORIG_TG_CHAT_ID}"
    FULL_TG_MESSAGE_THREAD_ID="${FULL_TG_MESSAGE_THREAD_ID:-$ORIG_TG_MESSAGE_THREAD_ID}"
    FULL_TG_PROXY="${FULL_TG_PROXY:-$ORIG_TG_PROXY}"
  fi

  if [[ "$FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL" == "true" ]]; then
    FULL_EXTERNAL_S3_BUCKET="${FULL_EXTERNAL_S3_BUCKET:-$ORIG_S3_BUCKET}"
    FULL_EXTERNAL_S3_ACCESS_KEY="${FULL_EXTERNAL_S3_ACCESS_KEY:-$ORIG_S3_ACCESS_KEY}"
    FULL_EXTERNAL_S3_SECRET_KEY="${FULL_EXTERNAL_S3_SECRET_KEY:-$ORIG_S3_SECRET_KEY}"
    FULL_EXTERNAL_S3_REGION="${FULL_EXTERNAL_S3_REGION:-$ORIG_S3_REGION}"
    FULL_EXTERNAL_S3_ENDPOINT="${FULL_EXTERNAL_S3_ENDPOINT:-$ORIG_S3_ENDPOINT}"
    FULL_EXTERNAL_S3_PREFIX="${FULL_EXTERNAL_S3_PREFIX:-$ORIG_S3_PREFIX}"
  fi

  FULL_EXTERNAL_S3_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}"
  FULL_EXTERNAL_S3_PREFIX="${FULL_EXTERNAL_S3_PREFIX:-rw-backup-full}"
}

ensure_tools() {
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

original_s3_available() {
  # Есть ли в оригинальном config.env пригодные S3-настройки для копирования
  [[ -n "${ORIG_S3_BUCKET:-}" && -n "${ORIG_S3_ACCESS_KEY:-}" && -n "${ORIG_S3_SECRET_KEY:-}" ]]
}

copy_original_s3_to_full() {
  # Копирует bucket/keys/region/endpoint из оригинального rw-backup в FULL external S3.
  # FULL_EXTERNAL_S3_PREFIX намеренно НЕ трогаем: full-архивы остаются под своим
  # префиксом (rw-backup-full/...), и retention не заденет файлы оригинального скрипта.
  if ! original_s3_available; then
    msg ERR "В оригинальном config.env нет полных S3-настроек (bucket/access/secret)"
    return 1
  fi

  set_full_var FULL_EXTERNAL_S3_BUCKET "$ORIG_S3_BUCKET"
  set_full_var FULL_EXTERNAL_S3_ACCESS_KEY "$ORIG_S3_ACCESS_KEY"
  set_full_var FULL_EXTERNAL_S3_SECRET_KEY "$ORIG_S3_SECRET_KEY"
  set_full_var FULL_EXTERNAL_S3_REGION "${ORIG_S3_REGION:-us-east-1}"
  set_full_var FULL_EXTERNAL_S3_ENDPOINT "${ORIG_S3_ENDPOINT:-}"

  FULL_EXTERNAL_S3_BUCKET="$ORIG_S3_BUCKET"
  FULL_EXTERNAL_S3_ACCESS_KEY="$ORIG_S3_ACCESS_KEY"
  FULL_EXTERNAL_S3_SECRET_KEY="$ORIG_S3_SECRET_KEY"
  FULL_EXTERNAL_S3_REGION="${ORIG_S3_REGION:-us-east-1}"
  FULL_EXTERNAL_S3_ENDPOINT="${ORIG_S3_ENDPOINT:-}"

  msg OK "Скопировано из оригинального rw-backup: bucket=${FULL_EXTERNAL_S3_BUCKET}, region=${FULL_EXTERNAL_S3_REGION}"
  msg INFO "Prefix остаётся независимым: ${FULL_EXTERNAL_S3_PREFIX}"
}

ensure_awscli() {
  # Проверяет awscli; в интерактивном режиме предлагает установить.
  command -v aws >/dev/null 2>&1 && return 0

  if [[ ! -t 0 ]]; then
    msg WARN "awscli не найден (apt-get install -y awscli)"
    return 1
  fi

  read -r -p "awscli не найден. Установить сейчас через apt-get? [Y/n]: " ans
  case "${ans:-Y}" in
    y|Y|"")
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y awscli
        command -v aws >/dev/null 2>&1 && { msg OK "awscli установлен"; return 0; }
        msg ERR "Не удалось установить awscli"
      else
        msg ERR "apt-get не найден, установи awscli вручную"
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

ensure_external_s3_interactive() {
  # Вызывается перед backup'ом. Если external S3 включён, но не настроен:
  #   - интерактивно: предложить скопировать из оригинального rw-backup,
  #     заполнить вручную или продолжить без S3;
  #   - из таймера (нет TTY): только предупредить.
  # Возврат всегда 0 — отсутствие S3 не должно блокировать локальный backup.
  # Спрашиваем не более одного раза за запуск.
  if [[ "${S3_INTERACTIVE_CHECKED:-0}" == "1" ]]; then
    return 0
  fi
  S3_INTERACTIVE_CHECKED=1

  if full_s3_ready; then
    ensure_awscli || true
    return 0
  fi

  if ! truthy "${FULL_PANEL_EXTERNAL_S3_ENABLED:-true}" && ! truthy "${FULL_CUSTOM_EXTERNAL_S3_ENABLED:-true}"; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    msg WARN "External S3 не настроен — архивы останутся только локально (rw-backup-full configure-s3)"
    return 0
  fi

  echo
  msg WARN "External S3 (2-й S3 для дублирования) не настроен."
  echo
  if original_s3_available; then
    echo "  1. Скопировать настройки из оригинального rw-backup (bucket=${ORIG_S3_BUCKET})"
  else
    echo "  1. (недоступно: в оригинальном config.env нет S3-настроек)"
  fi
  echo "  2. Заполнить вручную"
  echo "  3. Продолжить без external S3 (только локальный backup)"
  echo

  read -r -p "[?] Выбор [3]: " choice
  case "${choice:-3}" in
    1)
      if copy_original_s3_to_full; then
        ensure_awscli || true
      fi
      ;;
    2)
      configure_external_s3
      ensure_awscli || true
      ;;
    *)
      msg INFO "Продолжаю без external S3"
      ;;
  esac

  return 0
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

  curl "${args[@]}" >/dev/null 2>&1
}

# --- Failure notifications -------------------------------------------------

notify_failure() {
  # notify_failure <короткое описание>
  # Шлёт Telegram об ошибке, если включено. Тихий отказ при недоступном TG.
  local text="$1"
  local host
  host="$(hostname -s 2>/dev/null || hostname)"

  msg ERR "$text"

  if truthy "${FULL_NOTIFY_ON_FAILURE:-true}"; then
    send_full_telegram_message "❌ rw-backup-full FAILURE
Host: ${host}
${text}" || true
  fi
}

# --- Archive verification ---------------------------------------------------

tar_member_size() {
  # tar_member_size <archive> <member-suffix>
  # Печатает размер первого члена, чьё имя оканчивается на suffix; -1 если нет.
  local archive="$1" suffix="$2"
  tar -tzvf "$archive" 2>/dev/null \
    | awk -v s="$suffix" 'index($NF, s) == length($NF) - length(s) + 1 {print $3; found=1; exit} END{if(!found) print -1}'
}

verify_custom_archive() {
  # Проверяет финальный custom_bot архив ДО загрузки в S3.
  # Ловит случай "архив создан, но битый/пустой" (например, упавший pg_dumpall).
  local archive="$1"

  if [[ ! -f "$archive" ]]; then
    msg ERR "verify: архив не найден: ${archive}"
    return 1
  fi

  local size
  size="$(stat -c '%s' "$archive" 2>/dev/null || echo 0)"
  if (( size < ${FULL_VERIFY_MIN_ARCHIVE_BYTES:-1024} )); then
    msg ERR "verify: архив подозрительно мал (${size} байт): ${archive}"
    return 1
  fi

  if ! gzip -t "$archive" 2>/dev/null; then
    msg ERR "verify: повреждён gzip-поток: ${archive}"
    return 1
  fi

  local listing
  if ! listing="$(tar -tzf "$archive" 2>/dev/null)"; then
    msg ERR "verify: повреждён tar (оглавление не читается): ${archive}"
    return 1
  fi

  # Члены лежат внутри подпапки custom_bot_<proj>_<ts>/, поэтому матчим по суффиксу.
  local member
  for member in "/project_dir.tar.gz" "/postgres_dump.sql.gz" "/PROFILE.env"; do
    if ! grep -q "${member}$" <<<"$listing"; then
      msg ERR "verify: в архиве нет обязательного файла ...${member}: ${archive}"
      return 1
    fi
  done

  if ! grep -q "/redis_dump.rdb$" <<<"$listing"; then
    msg WARN "verify: в архиве нет redis_dump.rdb (Redis dump не снялся)"
  fi

  local pg_size
  pg_size="$(tar_member_size "$archive" "/postgres_dump.sql.gz")"
  if (( pg_size < ${FULL_VERIFY_MIN_PGDUMP_BYTES:-60} )); then
    msg ERR "verify: postgres_dump.sql.gz слишком мал (${pg_size} байт) — дамп, вероятно, упал: ${archive}"
    return 1
  fi

  msg OK "verify: архив валиден (${size} байт): $(basename "$archive")"
  return 0
}

# --- Timestamp parsing for retention ----------------------------------------

parse_backup_timestamp_epoch() {
  # Извлекает timestamp из имени файла и печатает epoch (UTC).
  # Поддерживает оба формата проекта:
  #   remnawave_backup_YYYY-MM-DD_HH_MM_SS.tar.gz   (панель)
  #   custom_bot_<proj>_YYYYMMDD_HHMMSS.tar.gz      (боты)
  # Печатает пусто, если не распознано — такой файл retention НЕ трогает.
  local name ts
  name="$(basename "$1")"

  ts="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}' <<<"$name" | tail -n1 || true)"
  if [[ -n "$ts" ]]; then
    date -u -d "${ts:0:10} ${ts:11:2}:${ts:14:2}:${ts:17:2}" +%s 2>/dev/null || true
    return 0
  fi

  ts="$(grep -oE '[0-9]{8}_[0-9]{6}' <<<"$name" | tail -n1 || true)"
  if [[ -n "$ts" ]]; then
    date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null || true
    return 0
  fi
}

# --- age encryption ----------------------------------------------------------
# Асимметричное шифрование: на сервере хранится только ПУБЛИЧНЫЙ ключ (recipient).
# Приватный ключ (identity) нужен только при restore и должен храниться офлайн.
# Генерация пары на доверенной машине: age-keygen -o age-key.txt

age_recipient_args() {
  if [[ -n "${FULL_AGE_RECIPIENTS_FILE:-}" && -f "$FULL_AGE_RECIPIENTS_FILE" ]]; then
    echo "-R ${FULL_AGE_RECIPIENTS_FILE}"
  elif [[ -n "${FULL_AGE_RECIPIENT:-}" ]]; then
    echo "-r ${FULL_AGE_RECIPIENT}"
  fi
}

encrypt_archive_age() {
  # encrypt_archive_age <input> <keep_source: true|false>
  # Результат кладёт в глобальную ENCRYPT_RESULT_FILE.
  # Причина последней ошибки — в AGE_LAST_ERROR (для Telegram-уведомлений).
  local input="$1"
  local keep_source="${2:-false}"
  local output="${input}.age"

  AGE_LAST_ERROR=""

  if ! command -v age >/dev/null 2>&1; then
    AGE_LAST_ERROR="age не установлен (apt-get install -y age)"
    msg ERR "FULL_AGE_ENABLED=true, но ${AGE_LAST_ERROR}"
    return 1
  fi

  local rcpt
  rcpt="$(age_recipient_args)"
  if [[ -z "$rcpt" ]]; then
    AGE_LAST_ERROR="не задан FULL_AGE_RECIPIENT / FULL_AGE_RECIPIENTS_FILE в ${FULL_CONFIG_FILE}"
    msg ERR "FULL_AGE_ENABLED=true, но ${AGE_LAST_ERROR}"
    return 1
  fi

  local age_err
  # shellcheck disable=SC2086
  if age_err="$(age $rcpt -o "$output" "$input" 2>&1)"; then
    if ! truthy "$keep_source"; then
      rm -f "$input"
    fi
    msg OK "Зашифровано: $(basename "$output")"
    ENCRYPT_RESULT_FILE="$output"
    return 0
  fi

  rm -f "$output" 2>/dev/null || true
  AGE_LAST_ERROR="age: ${age_err}"
  msg ERR "Ошибка age-шифрования: ${input} — ${age_err}"
  return 1
}

maybe_encrypt_for_upload() {
  # maybe_encrypt_for_upload <file> <keep_source>
  # Результат кладёт в глобальную ENCRYPT_RESULT_FILE (без сабшелла, чтобы
  # сообщения об ошибках и AGE_LAST_ERROR были видны вызывающему коду).
  # Если age выключен — результат равен исходному пути.
  local file="$1"
  local keep_source="${2:-false}"

  ENCRYPT_RESULT_FILE="$file"

  if truthy "${FULL_AGE_ENABLED:-false}"; then
    encrypt_archive_age "$file" "$keep_source" || return 1
  fi

  return 0
}

decrypt_archive_age() {
  # decrypt_archive_age <input.age> <output>
  local input="$1"
  local output="$2"
  local identity="${FULL_AGE_IDENTITY_FILE:-}"

  if ! command -v age >/dev/null 2>&1; then
    msg ERR "Архив зашифрован, но age не установлен"
    return 1
  fi

  if [[ -z "$identity" || ! -f "$identity" ]]; then
    msg ERR "Для расшифровки нужен приватный ключ: задай FULL_AGE_IDENTITY_FILE в ${FULL_CONFIG_FILE}"
    return 1
  fi

  age -d -i "$identity" -o "$output" "$input"
}

full_s3_upload() {
  local file_path="$1"
  local category="$2"
  local label="$3"

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
  # full_s3_retention_cleanup [--dry-run]
  # Безопасный retention внешнего FULL S3:
  #   - возраст определяется по timestamp в ИМЕНИ файла (надёжнее LastModified);
  #   - файлы с нераспознанным timestamp не трогаются;
  #   - всегда сохраняются FULL_EXTERNAL_S3_RETENTION_MIN_KEEP свежайших копий
  #     в каждой категории (panel / custom-bot per project) — защита от полного сноса;
  #   - при ошибке листинга ничего не удаляется;
  #   - --dry-run только показывает, что было бы удалено.
  local dry_run="false"
  [[ "${1:-}" == "--dry-run" ]] && dry_run="true"

  if ! command -v aws >/dev/null 2>&1; then
    msg WARN "awscli не найден, external S3 retention cleanup пропущен"
    return 0
  fi

  if ! full_s3_ready; then
    msg WARN "FULL external S3 не настроен, retention cleanup пропущен"
    return 0
  fi

  local retention_days="${FULL_EXTERNAL_S3_RETENTION_DAYS:-10}"
  local min_keep="${FULL_EXTERNAL_S3_RETENTION_MIN_KEEP:-3}"

  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
    msg WARN "Некорректный FULL_EXTERNAL_S3_RETENTION_DAYS=${retention_days}, использую 10"
    retention_days="10"
  fi

  if ! [[ "$min_keep" =~ ^[0-9]+$ ]]; then
    min_keep="3"
  fi

  if (( retention_days <= 0 )); then
    msg WARN "External S3 retention выключен: ${retention_days}"
    return 0
  fi

  local endpoint_arg=()
  if [[ -n "${FULL_EXTERNAL_S3_ENDPOINT:-}" ]]; then
    endpoint_arg=(--endpoint-url "$FULL_EXTERNAL_S3_ENDPOINT")
  fi

  local prefix s3_path cutoff_epoch
  prefix="$(full_s3_prefix_normalized)"
  s3_path="s3://${FULL_EXTERNAL_S3_BUCKET}/${prefix}"
  cutoff_epoch="$(date -u -d "-${retention_days} days" +%s)"

  msg INFO "External S3 retention: ${retention_days} дней, min_keep=${min_keep}, dry_run=${dry_run}, path=${s3_path}"

  # 1) Листинг. При ошибке — выходим, НИЧЕГО не удаляя.
  local listing
  if ! listing="$(
    AWS_ACCESS_KEY_ID="$FULL_EXTERNAL_S3_ACCESS_KEY"     AWS_SECRET_ACCESS_KEY="$FULL_EXTERNAL_S3_SECRET_KEY"     AWS_DEFAULT_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}"     aws s3 ls "$s3_path" "${endpoint_arg[@]}" --recursive 2>&1
  )"; then
    msg ERR "Не удалось получить листинг external S3 — retention прерван, ничего не удалено"
    return 1
  fi

  # 2) Собираем "epoch|group|key" только для наших архивов с валидным timestamp.
  #    group = category/dirname ключа, чтобы min_keep считался отдельно
  #    для панели и для каждого бота на каждом хосте.
  local entries=()
  local file_key base_name file_epoch group

  while read -r _ _ _ file_key; do
    [[ -n "${file_key:-}" ]] || continue

    base_name="$(basename "$file_key")"

    # Чистим только архивы, созданные full-дублированием (включая зашифрованные .age).
    if [[ ! "$base_name" =~ ^custom_bot_.*\.tar\.gz(\.age)?$ && ! "$base_name" =~ ^remnawave_backup_.*\.tar\.gz(\.age)?$ ]]; then
      continue
    fi

    file_epoch="$(parse_backup_timestamp_epoch "$base_name")"
    if [[ -z "$file_epoch" ]]; then
      msg WARN "retention: timestamp не распознан, пропускаю: ${file_key}"
      continue
    fi

    # Группа для min_keep: папка + имя без timestamp. Так у каждого бота (и панели)
    # своя квота свежих копий — активный сосед не вытеснит копии остановившегося бота.
    group="$(dirname "$file_key")/$(sed -E 's/_?([0-9]{8}_[0-9]{6}|[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2})\.tar\.gz(\.age)?$//' <<<"$base_name")"
    entries+=("${file_epoch}|${group}|${file_key}")
  done <<< "$listing"

  if (( ${#entries[@]} == 0 )); then
    msg OK "External S3 retention: подходящих архивов не найдено"
    return 0
  fi

  # 3) Сортируем свежие -> старые и удаляем старше cutoff, пропуская min_keep свежих в каждой группе.
  local checked_count=0 deleted_count=0 kept_count=0
  local line epoch key
  declare -A group_seen=()

  while IFS= read -r line; do
    epoch="${line%%|*}"
    line="${line#*|}"
    group="${line%%|*}"
    key="${line#*|}"

    checked_count=$((checked_count + 1))
    group_seen["$group"]=$(( ${group_seen["$group"]:-0} + 1 ))

    if (( group_seen["$group"] <= min_keep )); then
      kept_count=$((kept_count + 1))
      continue
    fi

    if (( epoch < cutoff_epoch )); then
      if truthy "$dry_run"; then
        msg INFO "DRY-RUN: удалил бы ${key}"
        deleted_count=$((deleted_count + 1))
      else
        msg INFO "Удаляю старый external S3 backup: ${key}"

        if AWS_ACCESS_KEY_ID="$FULL_EXTERNAL_S3_ACCESS_KEY"            AWS_SECRET_ACCESS_KEY="$FULL_EXTERNAL_S3_SECRET_KEY"            AWS_DEFAULT_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}"            aws s3 rm "s3://${FULL_EXTERNAL_S3_BUCKET}/${key}" "${endpoint_arg[@]}" --quiet; then
          deleted_count=$((deleted_count + 1))
        else
          msg WARN "Не удалось удалить: ${key}"
        fi
      fi
    else
      kept_count=$((kept_count + 1))
    fi
  done < <(printf '%s
' "${entries[@]}" | sort -t'|' -k1,1nr)

  msg OK "External S3 retention complete: checked=${checked_count}, deleted=${deleted_count}, kept=${kept_count}, min_keep=${min_keep}, retention_days=${retention_days}"
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
    -maxdepth 1 \
    -type f \
    \( -name 'custom_bot_*.tar.gz' -o -name 'custom_bot_*.tar.gz.age' \) \
    -mtime "+${retention_days}" \
    -delete 2>/dev/null || true
}

original_rw_backup_available() {
  if command -v "$ORIGINAL_RW_BACKUP_BIN" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x "$ORIGINAL_RW_BACKUP_SCRIPT" ]]; then
    return 0
  fi

  return 1
}

install_original_rw_backup() {
  if original_rw_backup_available; then
    msg OK "Оригинальный rw-backup уже установлен"
    return 0
  fi

  msg INFO "Устанавливаю оригинальный remnawave-backup-restore в ${INSTALL_DIR}"
  mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh \
      -o "$ORIGINAL_RW_BACKUP_SCRIPT"
    chmod +x "$ORIGINAL_RW_BACKUP_SCRIPT"
    ln -sf "$ORIGINAL_RW_BACKUP_SCRIPT" /usr/local/bin/rw-backup
    msg OK "Оригинальный rw-backup установлен"
    return 0
  fi

  msg ERR "curl не найден, автоустановка невозможна"
  return 1
}

run_original_rw_backup_cmd() {
  local action="$1"

  if command -v "$ORIGINAL_RW_BACKUP_BIN" >/dev/null 2>&1; then
    "$ORIGINAL_RW_BACKUP_BIN" "$action"
    return $?
  fi

  if [[ -x "$ORIGINAL_RW_BACKUP_SCRIPT" ]]; then
    bash "$ORIGINAL_RW_BACKUP_SCRIPT" "$action"
    return $?
  fi

  if truthy "$FULL_AUTO_INSTALL_ORIGINAL_RW_BACKUP"; then
    install_original_rw_backup || return 1
    run_original_rw_backup_cmd "$action"
    return $?
  fi

  msg ERR "Оригинальный rw-backup не найден"
  return 1
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

  if truthy "$FULL_REQUIRE_ORIGINAL_RW_BACKUP" && ! original_rw_backup_available; then
    msg ERR "FULL_REQUIRE_ORIGINAL_RW_BACKUP=true, но оригинальный rw-backup не установлен"
    return 1
  fi

  local before_latest
  local after_latest

  before_latest="$(latest_panel_backup || true)"

  msg INFO "Запускаю оригинальный panel backup"
  run_original_rw_backup_cmd "backup"

  after_latest="$(latest_panel_backup || true)"

  if [[ -z "$after_latest" ]]; then
    msg WARN "После panel backup не найден remnawave_backup_*.tar.gz"
    return 0
  fi

  msg OK "Panel backup найден: ${after_latest}"

  if truthy "$FULL_PANEL_EXTERNAL_S3_ENABLED"; then
    if [[ "$after_latest" == "$before_latest" ]]; then
      msg WARN "Latest panel backup не изменился, но будет продублирован во внешний S3"
    fi

    # Шифруем только S3-дубль; локальный оригинал панели не трогаем (он принадлежит
    # оригинальному rw-backup), поэтому keep_source=true и временный .age удаляем после.
    local upload_file temp_encrypted="false"
    if ! maybe_encrypt_for_upload "$after_latest" "true"; then
      notify_failure "Panel backup encryption failed
File: $(basename "$after_latest")
Reason: ${AGE_LAST_ERROR:-unknown}"
      return 1
    fi
    upload_file="$ENCRYPT_RESULT_FILE"
    [[ "$upload_file" != "$after_latest" ]] && temp_encrypted="true"

    if ! full_s3_upload "$upload_file" "panel" "remnawave-panel"; then
      notify_failure "External S3 upload failed (panel)
File: $(basename "$upload_file")"
    fi

    truthy "$temp_encrypted" && rm -f "$upload_file"

    full_s3_retention_cleanup || true
  fi
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

  if ! docker exec "$POSTGRES_CONTAINER" sh -lc '
    export PGPASSWORD="${POSTGRES_PASSWORD:-}"
    pg_dumpall -c -U "${POSTGRES_USER:-postgres}"
  ' | gzip -9 > "$WORK_DIR/postgres_dump.sql.gz"; then
    notify_failure "PostgreSQL dump failed
Project: ${PROJECT_NAME}
Container: ${POSTGRES_CONTAINER}"
    rm -rf "$WORK_DIR"
    return 1
  fi

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

  # Верификация ДО загрузки: битый или неполный архив не уезжает в S3.
  if ! verify_custom_archive "$FINAL_ARCHIVE"; then
    notify_failure "Backup verification failed
Project: ${PROJECT_NAME}
Archive: $(basename "$FINAL_ARCHIVE")
Архив создан, но не прошёл проверку и НЕ будет загружен в S3."
    return 1
  fi

  # Опциональное шифрование (age). Дальше работаем с тем файлом, который вернулся.
  local upload_file
  if ! maybe_encrypt_for_upload "$FINAL_ARCHIVE" "false"; then
    notify_failure "Encryption failed
Project: ${PROJECT_NAME}
Archive: $(basename "$FINAL_ARCHIVE")
Reason: ${AGE_LAST_ERROR:-unknown}"
    return 1
  fi
  upload_file="$ENCRYPT_RESULT_FILE"

  if truthy "$FULL_CUSTOM_EXTERNAL_S3_ENABLED"; then
    if ! full_s3_upload "$upload_file" "custom-bot" "$PROJECT_NAME"; then
      notify_failure "External S3 upload failed
Project: ${PROJECT_NAME}
File: $(basename "$upload_file")"
    fi
    full_s3_retention_cleanup || true
  fi

  cleanup_local_custom_backups
}

backup_custom_menu() {
  ensure_external_s3_interactive

  local entry
  entry="$(select_custom_project)" || return 1
  backup_custom_project_entry "$entry"
}

backup_custom_all() {
  ensure_external_s3_interactive

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
  mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'custom_bot_*.tar.gz' -o -name 'custom_bot_*.tar.gz.age' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')

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

  # Зашифрованный архив (.age) сначала расшифровываем во временный файл.
  if [[ "$archive" == *.age ]]; then
    msg INFO "Архив зашифрован (age), расшифровываю..."
    local decrypted="${tmp_root}/$(basename "${archive%.age}")"
    if ! decrypt_archive_age "$archive" "$decrypted"; then
      msg ERR "Не удалось расшифровать архив"
      return 1
    fi
    archive="$decrypted"
  fi

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

  ensure_external_s3_interactive

  run_panel_backup || msg WARN "Panel backup завершился с ошибкой или был пропущен"
  backup_custom_all || msg WARN "Custom bot backup завершился с ошибкой или проекты не найдены"

  msg OK "Backup ALL завершён"
}

backup_panel_only() {
  ensure_external_s3_interactive
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

  if original_s3_available; then
    read -r -p "Скопировать S3-настройки из оригинального rw-backup (bucket=${ORIG_S3_BUCKET})? [y/N]: " copy_ans
    case "${copy_ans:-N}" in
      y|Y)
        copy_original_s3_to_full || return 1

        read -r -p "Prefix [${FULL_EXTERNAL_S3_PREFIX}]: " prefix
        prefix="${prefix:-$FULL_EXTERNAL_S3_PREFIX}"
        set_full_var FULL_EXTERNAL_S3_PREFIX "$prefix"
        set_full_var FULL_EXTERNAL_S3_IMPORT_FROM_ORIGINAL "false"
        FULL_EXTERNAL_S3_PREFIX="$prefix"

        msg OK "External S3 настройки обновлены"
        return 0
        ;;
    esac
    echo
  fi

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

  read -r -p "Интервал, часов [${FULL_TIMER_INTERVAL_HOURS}]: " hours
  hours="${hours:-$FULL_TIMER_INTERVAL_HOURS}"

  if ! [[ "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 )); then
    msg ERR "Интервал должен быть числом >= 1"
    return 1
  fi

  set_full_var FULL_TIMER_MODE "$mode"
  set_full_var FULL_TIMER_INTERVAL_HOURS "$hours"

  FULL_TIMER_MODE="$mode"
  FULL_TIMER_INTERVAL_HOURS="$hours"

  install_timer
}

install_timer() {
  local hours="${FULL_TIMER_INTERVAL_HOURS:-3}"

  if ! [[ "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 )); then
    hours="3"
  fi

  case "${FULL_TIMER_MODE:-backup-all}" in
    backup-all|panel-backup|custom-backup) ;;
    *)
      msg ERR "Некорректный FULL_TIMER_MODE='${FULL_TIMER_MODE}', timer не установлен"
      return 1
      ;;
  esac

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
# Страховка от зависшего бэкапа
TimeoutStartSec=2h
EOF_SERVICE

  cat > /etc/systemd/system/rw-backup-full.timer <<EOF_TIMER
[Unit]
Description=Run rw-backup-full every ${hours} hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=${hours}h
Persistent=true
# Разброс, чтобы парк серверов не бил в S3 одновременно
RandomizedDelaySec=5min
Unit=rw-backup-full.service

[Install]
WantedBy=timers.target
EOF_TIMER

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
  echo "ORIGINAL_CONFIG_FILE:               ${ORIGINAL_CONFIG_FILE}"
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
  echo "ORIG_UPLOAD_METHOD:                 ${ORIG_UPLOAD_METHOD:-not set}"
  echo "ORIG_S3_BUCKET:                     ${ORIG_S3_BUCKET:-not set}"
  echo "ORIG_TG_CHAT_ID:                    ${ORIG_TG_CHAT_ID:-not set}"
  echo
}

main_menu() {
  while true; do
    load_config
    clear

    echo -e "${GREEN}${BOLD}rw-backup-full${RESET}"
    echo
    echo " 1. Backup panel через оригинальный rw-backup + duplicate to FULL external S3"
    echo " 2. Backup custom bot из /home + duplicate to FULL external S3"
    echo " 3. Backup ALL: panel + custom bot"
    echo " 4. Restore custom bot"
    echo " 5. Показать найденные custom bot проекты"
    echo " 6. Настроить retention local/S3"
    echo " 7. Настроить FULL external S3"
    echo " 8. Настроить Telegram уведомления FULL"
    echo " 9. Установить/обновить systemd timer"
    echo "10. Показать конфигурацию"
    echo "11. Установить оригинальный rw-backup"
    echo "12. External S3 retention cleanup сейчас"
    echo
    echo " 0. Выход"
    echo

    read -r -p "[?] Выбор: " choice
    echo

    case "$choice" in
      1) backup_panel_only; pause ;;
      2) backup_custom_menu; pause ;;
      3) backup_all; pause ;;
      4) restore_custom_menu; pause ;;
      5) print_custom_projects; pause ;;
      6) configure_retention; pause ;;
      7) configure_external_s3; pause ;;
      8) configure_telegram; pause ;;
      9) configure_timer; pause ;;
      10) show_config_summary; pause ;;
      11) install_original_rw_backup; pause ;;
      12) full_s3_retention_cleanup; pause ;;
      0) exit 0 ;;
      *) msg ERR "Некорректный выбор"; sleep 1 ;;
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
  rw-backup-full install-original
  rw-backup-full s3-cleanup [--dry-run]

Encryption (optional, see config FULL_AGE_*):
  Archives can be encrypted with age before external S3 upload.
  Restore accepts both .tar.gz and .tar.gz.age archives.
EOF_USAGE
}

load_config
ensure_tools

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
  install-original) install_original_rw_backup ;;
  s3-cleanup) full_s3_retention_cleanup "${2:-}" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
