#!/usr/bin/env bash
# wal-lib.sh — общая библиотека WAL-слоя rw-backup-full v4.
# Подключается через `source`. Не запускается напрямую.
#
# ВАЖНО: здесь нет `trap RETURN` — эта конструкция ломает вызывающий скрипт
# при использовании с source (известная проблема из v3, см. docs/ARCHITECTURE.md).

[[ -n "${__WAL_LIB_LOADED:-}" ]] && return 0
__WAL_LIB_LOADED=1

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
FULL_CONFIG_FILE="${FULL_CONFIG_FILE:-${INSTALL_DIR}/rw-backup-full.env}"
ORIGINAL_CONFIG_FILE="${ORIGINAL_CONFIG_FILE:-${INSTALL_DIR}/config.env}"
INSTANCES_DIR="${INSTANCES_DIR:-${INSTALL_DIR}/instances.d}"

# Корень WAL-данных на хосте.
WAL_ROOT="${WAL_ROOT:-/var/lib/rw-wal}"

# Точка монтирования спула ВНУТРИ контейнера postgres.
WAL_SPOOL_MOUNT="${WAL_SPOOL_MOUNT:-/wal-spool}"

# Prometheus textfile collector (push-модель мониторинга).
WAL_METRICS_DIR="${WAL_METRICS_DIR:-/var/lib/node_exporter/textfile_collector}"

if [[ -z "${RED:-}" ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  CYAN=$'\e[36m'; RESET=$'\e[0m'; BOLD=$'\e[1m'
fi

if ! declare -F msg >/dev/null 2>&1; then
  msg() {
    local type="$1" text="$2" color="$RESET"
    case "$type" in
      INFO) color="$CYAN" ;;
      OK)   color="$GREEN" ;;
      WARN) color="$YELLOW" ;;
      ERR)  color="$RED" ;;
    esac
    printf '%s[%s]%s %s\n' "$color" "$type" "$RESET" "$text" >&2
  }
fi

if ! declare -F truthy >/dev/null 2>&1; then
  truthy() {
    case "${1:-}" in
      true|TRUE|yes|YES|1|on|ON) return 0 ;;
      *) return 1 ;;
    esac
  }
fi

# Совпадает с rw_source_id из s3-multi: в контейнере/k8s задаётся RW_SOURCE_ID.
wal_hostname() {
  if [[ -n "${RW_SOURCE_ID:-}" ]]; then printf '%s' "$RW_SOURCE_ID"
  else hostname -s 2>/dev/null || hostname; fi
}

wal_ts() { date -u +%Y-%m-%d_%H_%M_%S; }

# --------------------------------------------------------------------------
# Конфигурация инстансов
# --------------------------------------------------------------------------

# Список имён инстансов (по файлам instances.d/*.env).
wal_list_instances() {
  local f name
  [[ -d "$INSTANCES_DIR" ]] || return 0
  for f in "$INSTANCES_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" .env)"
    printf '%s\n' "$name"
  done
}

# Загружает конфиг инстанса в переменные INST_*.
# Использование: wal_load_instance panel
wal_load_instance() {
  local name="$1"
  local file="${INSTANCES_DIR}/${name}.env"

  [[ -f "$file" ]] || { msg ERR "Инстанс не найден: ${file}"; return 1; }

  INST_NAME="$name"
  INST_KIND="bot"
  INST_ENABLED="true"
  INST_CONTAINER=""
  INST_COMPOSE_FILE=""
  INST_COMPOSE_SERVICE=""
  INST_PGUSER="postgres"
  INST_PGDATABASE="postgres"
  INST_ARCHIVE_TIMEOUT="300"
  INST_BASEBACKUP_INTERVAL_HOURS="24"
  INST_WAL_SHIP_INTERVAL_MIN="1"
  INST_LOCAL_BASEBACKUP_KEEP="3"
  INST_S3_BASEBACKUP_KEEP="10"
  INST_LOCAL_WAL_RETENTION_DAYS="3"
  INST_S3_WAL_RETENTION_DAYS="10"
  INST_VERIFY_TABLES=""
  INST_ENCRYPT="false"

  set +u
  # shellcheck disable=SC1090
  source "$file"
  set -u

  INST_NAME="$name"
  INST_SPOOL_DIR="${WAL_ROOT}/${name}/spool"
  INST_ARCHIVE_DIR="${WAL_ROOT}/${name}/archive"
  INST_BASEBACKUP_DIR="${WAL_ROOT}/${name}/basebackup"
  INST_STATE_DIR="${WAL_ROOT}/${name}/state"

  [[ -n "$INST_CONTAINER" ]] || { msg ERR "[${name}] INST_CONTAINER не задан"; return 1; }
  return 0
}

wal_instance_dirs_init() {
  install -d -m 0750 "$INST_ARCHIVE_DIR" "$INST_BASEBACKUP_DIR" "$INST_STATE_DIR"
  # Спул пишет postgres из контейнера (uid 999 в официальном образе),
  # поэтому права шире и владелец выставляется по uid контейнера.
  install -d -m 0770 "$INST_SPOOL_DIR"
  local uid
  uid="$(docker inspect -f '{{.Config.User}}' "$INST_CONTAINER" 2>/dev/null || true)"
  uid="${uid%%:*}"
  [[ "$uid" =~ ^[0-9]+$ ]] || uid="999"
  chown "${uid}:${uid}" "$INST_SPOOL_DIR" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Работа с PostgreSQL в контейнере
# --------------------------------------------------------------------------

wal_container_running() {
  local c="${1:-$INST_CONTAINER}"
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)" == "true" ]]
}

# Выполняет psql внутри контейнера. Всегда через явный TCP на localhost:
# pg_isready/psql через unix-сокет могут отвечать раньше, чем БД реально готова.
wal_psql() {
  docker exec -i "$INST_CONTAINER" \
    psql -h localhost -U "$INST_PGUSER" -d "$INST_PGDATABASE" \
    -qtAX -v ON_ERROR_STOP=1 -c "$1"
}

wal_pg_ready() {
  docker exec "$INST_CONTAINER" \
    pg_isready -h localhost -U "$INST_PGUSER" >/dev/null 2>&1
}

wal_wait_pg_ready() {
  local timeout="${1:-120}" i=0
  while (( i < timeout )); do
    if wal_pg_ready && wal_psql "SELECT 1" >/dev/null 2>&1; then
      # Запас: TCP уже отвечает, но recovery/сокет могут догоняться.
      sleep 2
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wal_pg_version() {
  wal_psql "SHOW server_version_num" 2>/dev/null | head -n1
}

# Имя WAL-сегмента для текущей позиции. Берётся ДО базового бэкапа —
# консервативно (сегмент <= фактического начала), значит WAL не удалится раньше времени.
wal_current_segment() {
  wal_psql "SELECT pg_walfile_name(pg_current_wal_lsn())" 2>/dev/null | head -n1
}

wal_switch_segment() {
  wal_psql "SELECT pg_switch_wal()" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Сжатие / шифрование
# --------------------------------------------------------------------------

wal_compressor() {
  if command -v zstd >/dev/null 2>&1; then echo "zstd"; else echo "gzip"; fi
}

wal_comp_ext() {
  [[ "$(wal_compressor)" == "zstd" ]] && echo ".zst" || echo ".gz"
}

# stdin -> stdout, сжатие
wal_compress_stream() {
  if [[ "$(wal_compressor)" == "zstd" ]]; then
    zstd -q -T0 -3 -c
  else
    gzip -6 -c
  fi
}

wal_decompress_stream() {
  case "$1" in
    *.zst) zstd -q -d -c ;;
    *.gz)  gzip -d -c ;;
    *)     cat ;;
  esac
}

# Шифрование age (только публичный ключ на сервере — приватный никогда не хранится).
wal_encrypt_stream() {
  if truthy "${INST_ENCRYPT:-false}" && [[ -n "${FULL_AGE_RECIPIENT:-}" ]]; then
    age -r "$FULL_AGE_RECIPIENT"
  else
    cat
  fi
}

wal_enc_ext() {
  if truthy "${INST_ENCRYPT:-false}" && [[ -n "${FULL_AGE_RECIPIENT:-}" ]]; then
    echo ".age"
  else
    echo ""
  fi
}

# --------------------------------------------------------------------------
# S3: мульти-бэкенды (s3.d/*.env) через lib/s3-multi.sh
# --------------------------------------------------------------------------
# shellcheck source=./s3-multi.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/s3-multi.sh"

# Бэкенды, в которые включена категория WAL.
wal_s3_backends() {
  local n
  for n in $(s3m_backends); do
    s3m_load "$n" 2>/dev/null || continue
    truthy "$B_ENABLED" || continue
    s3m_category_enabled wal || continue
    echo "$n"
  done
}

# Есть ли хотя бы один WAL-бэкенд.
wal_s3_ready() {
  command -v aws >/dev/null 2>&1 || return 1
  [[ -n "$(wal_s3_backends | head -n1)" ]]
}

# Совместимый интерфейс для скриптов, работающих с ОДНИМ выбранным бэкендом:
# wal_s3_select <name> загружает его; wal_aws/wal_s3_uri действуют в его контексте.
wal_s3_select() { s3m_load "$1"; }

wal_aws() { s3m_aws "$@"; }

wal_s3_uri() {
  printf 's3://%s/%s/%s' "$B_BUCKET" "$(s3m_wal_base "$INST_NAME")" "$1"
}

# --------------------------------------------------------------------------
# Метрики для VictoriaMetrics через node_exporter textfile collector
# --------------------------------------------------------------------------

# wal_metric_write <файл-без-пути> <строки метрик через stdin>
wal_metric_write() {
  local name="$1" tmp
  [[ -d "$WAL_METRICS_DIR" ]] || return 0
  tmp="$(mktemp "${WAL_METRICS_DIR}/.${name}.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "${WAL_METRICS_DIR}/${name}.prom"
}

# --------------------------------------------------------------------------
# Telegram (переиспользует настройки FULL из rw-backup-full.env)
# --------------------------------------------------------------------------

wal_notify() {
  local text="$1"
  [[ -n "${FULL_TG_BOT_TOKEN:-}" && -n "${FULL_TG_CHAT_ID:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local -a proxy=()
  [[ -n "${FULL_TG_PROXY:-}" ]] && proxy=(--proxy "$FULL_TG_PROXY")

  local -a form=(-F "chat_id=${FULL_TG_CHAT_ID}" -F "text=${text}")
  [[ -n "${FULL_TG_MESSAGE_THREAD_ID:-}" ]] &&
    form+=(-F "message_thread_id=${FULL_TG_MESSAGE_THREAD_ID}")

  # Разовые сетевые сбои (curl exit 56/28/7 — сброс соединения, таймаут)
  # не должны стоить пропущенного уведомления: 3 попытки с нарастающей паузой,
  # как и для выгрузок в S3.
  local attempt
  for attempt in 1 2 3; do
    curl -sS -m 25 "${proxy[@]}" \
      "https://api.telegram.org/bot${FULL_TG_BOT_TOKEN}/sendMessage" \
      "${form[@]}" >/dev/null 2>&1 && return 0
    sleep $((attempt * 3))
  done
  return 0
}

# Отправка в конкретный чат (токен/чат сервера-источника события).
wal_notify_to() { # <token> <chat_id> <text> [thread_id]
  local token="$1" chat="$2" text="$3" thread="${4:-}"
  [[ -n "$token" && -n "$chat" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local -a form=(-F "chat_id=${chat}" -F "text=${text}")
  [[ -n "$thread" ]] && form+=(-F "message_thread_id=${thread}")
  local attempt
  for attempt in 1 2 3; do
    curl -sS -m 25 "https://api.telegram.org/bot${token}/sendMessage" \
      "${form[@]}" >/dev/null 2>&1 && return 0
    sleep $((attempt * 3))
  done
  return 0
}

# --------------------------------------------------------------------------
# Загрузка общей конфигурации
# --------------------------------------------------------------------------

wal_load_full_config() {
  if [[ -f "$ORIGINAL_CONFIG_FILE" ]]; then
    set +u; # shellcheck disable=SC1090
    source "$ORIGINAL_CONFIG_FILE"; set -u
  fi
  if [[ -f "$FULL_CONFIG_FILE" ]]; then
    set +u; # shellcheck disable=SC1090
    source "$FULL_CONFIG_FILE"; set -u
  fi
  FULL_EXTERNAL_S3_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}"
  FULL_EXTERNAL_S3_PREFIX="${FULL_EXTERNAL_S3_PREFIX:-rw-backup-full}"
}

# --------------------------------------------------------------------------
# Расписания (интервал ИЛИ список конкретных времён)
# --------------------------------------------------------------------------

# wal_parse_times "03:00, 15:30 21:45:30" -> "03:00:00 15:30:00 21:45:30"
# Разделители: пробел и/или запятая. Формат: HH:MM или HH:MM:SS (24ч).
# Количество значений не ограничено. Код возврата 1 + сообщение при ошибке.
wal_parse_times() {
  local raw="$1" out="" t hh mm ss
  raw="${raw//,/ }"
  for t in $raw; do
    if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$ ]]; then
      hh="${BASH_REMATCH[1]}"; mm="${BASH_REMATCH[2]}"; ss="${BASH_REMATCH[4]:-00}"
      if (( 10#$hh > 23 || 10#$mm > 59 || 10#$ss > 59 )); then
        msg ERR "Некорректное время: ${t} (часы 0-23, минуты/секунды 0-59)"
        return 1
      fi
      out+="$(printf '%02d:%s:%s' "$((10#$hh))" "$mm" "$ss") "
    else
      msg ERR "Некорректный формат времени: '${t}' (ожидается HH:MM или HH:MM:SS)"
      return 1
    fi
  done
  [[ -n "$out" ]] || { msg ERR "Пустой список времён"; return 1; }
  printf '%s\n' "${out% }"
}

# wal_render_calendar_lines "03:00:00 15:30:00" ["UTC"|"Europe/Amsterdam"]
# -> строки OnCalendar= для drop-in (по одной на каждое время).
wal_render_calendar_lines() {
  local times="$1" tz="${2:-}" t suffix=""
  [[ -n "$tz" ]] && suffix=" ${tz}"
  for t in $times; do
    printf 'OnCalendar=*-*-* %s%s\n' "$t" "$suffix"
  done
}

# --------------------------------------------------------------------------
# Компоненты: что включено на этом сервере
# --------------------------------------------------------------------------
# Все серверы разные: где-то только логические бэкапы, где-то полный набор
# с WAL и трекером. Неиспользуемые компоненты не должны ни занимать таймеры,
# ни сыпать ошибками — поэтому каждая задача проверяет себя перед работой.
component_enabled() { # <имя компонента>
  local list="${FULL_COMPONENTS:-panel-backup custom-backup wal config-track metrics}"
  [[ " ${list} " == *" $1 "* ]]
}

# Ранний выход для скрипта, чей компонент выключен.
require_component() { # <имя> [тихо]
  if ! component_enabled "$1"; then
    [[ "${2:-}" == "quiet" ]] || msg INFO "Компонент '$1' выключен (FULL_COMPONENTS) — пропуск"
    exit 0
  fi
}

# --------------------------------------------------------------------------
# Блокировки
# --------------------------------------------------------------------------

# wal_lock <имя> — берёт эксклюзивную блокировку или выходит с кодом 0.
# Использование: wal_lock "ship-${INST_NAME}" || exit 0
wal_lock() {
  local name="$1"
  local lockfile="/run/rw-wal-${name}.lock"
  exec {__WAL_LOCK_FD}>"$lockfile" || return 1
  flock -n "$__WAL_LOCK_FD" || {
    msg WARN "Уже выполняется: ${name}, пропускаю"
    return 1
  }
  return 0
}
