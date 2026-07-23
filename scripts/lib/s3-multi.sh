#!/usr/bin/env bash
# s3-multi.sh — несколько внешних S3-хранилищ с индивидуальными настройками.
#
# Каждый бэкенд — файл /opt/rw-backup-restore/s3.d/<имя>.env:
#   B_ENDPOINT, B_BUCKET, B_ACCESS_KEY, B_SECRET_KEY, B_REGION, B_PREFIX
#   B_ENABLED=true
#   Что заливать:      B_UPLOAD_PANEL / B_UPLOAD_CUSTOM / B_UPLOAD_WAL (true/false)
#   Хранение (у каждого бэкенда СВОЁ):
#     B_RETENTION_PANEL_DAYS, B_RETENTION_CUSTOM_DAYS   — логические архивы, дней
#     B_BASEBACKUP_KEEP                                 — базовых бэкапов, штук
#     (WAL в бэкенде чистится по границе его же базовых бэкапов)
#   B_RETENTION_MIN_KEEP — минимум логических архивов, защищаемых от удаления
#
# Обратная совместимость: если s3.d пуст, а FULL_EXTERNAL_S3_BUCKET задан,
# синтезируется бэкенд "legacy" из старых FULL_EXTERNAL_S3_* переменных.

[[ -n "${__S3M_LOADED:-}" ]] && return 0
__S3M_LOADED=1

S3D_DIR="${S3D_DIR:-${INSTALL_DIR:-/opt/rw-backup-restore}/s3.d}"

# Идентификатор ИСТОЧНИКА бэкапов в схеме бакета:
#   <prefix>/<category>/<source>/...
# По умолчанию — hostname (полная совместимость с существующими данными).
# В контейнере/k8s задаётся явно: RW_SOURCE_ID=host-panel1 | k8s-prod-remnawave.
# Единая схема позволяет песочнице/дашборду видеть старую и новую
# инфраструктуру одинаково весь переходный период.
rw_source_id() {
  if [[ -n "${RW_SOURCE_ID:-}" ]]; then
    printf '%s' "$RW_SOURCE_ID"
  else
    hostname -s 2>/dev/null || hostname
  fi
}

s3m_backends() {
  local f any=0
  if [[ -d "$S3D_DIR" ]]; then
    for f in "$S3D_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      any=1
      basename "$f" .env
    done
  fi
  if (( any == 0 )) && [[ -n "${FULL_EXTERNAL_S3_BUCKET:-}" ]]; then
    echo "legacy"
  fi
}

# Загружает бэкенд в переменные B_*. return 1 если не найден/выключен без force.
s3m_load() {
  local name="$1"
  B_NAME="$name"; B_ENABLED="true"; B_ENDPOINT=""; B_BUCKET=""; B_ACCESS_KEY=""
  B_SECRET_KEY=""; B_REGION="us-east-1"; B_PREFIX="rw-backup-full"
  B_UPLOAD_PANEL="true"; B_UPLOAD_CUSTOM="true"; B_UPLOAD_WAL="true"
  B_RETENTION_PANEL_DAYS="10"; B_RETENTION_CUSTOM_DAYS="10"
  B_BASEBACKUP_KEEP="7"; B_RETENTION_MIN_KEEP="3"

  if [[ "$name" == "legacy" && ! -f "${S3D_DIR}/legacy.env" ]]; then
    B_ENDPOINT="${FULL_EXTERNAL_S3_ENDPOINT:-}"
    B_BUCKET="${FULL_EXTERNAL_S3_BUCKET:-}"
    B_ACCESS_KEY="${FULL_EXTERNAL_S3_ACCESS_KEY:-}"
    B_SECRET_KEY="${FULL_EXTERNAL_S3_SECRET_KEY:-}"
    B_REGION="${FULL_EXTERNAL_S3_REGION:-us-east-1}"
    B_PREFIX="${FULL_EXTERNAL_S3_PREFIX:-rw-backup-full}"
    B_UPLOAD_PANEL="${FULL_PANEL_EXTERNAL_S3_ENABLED:-true}"
    B_UPLOAD_CUSTOM="${FULL_CUSTOM_EXTERNAL_S3_ENABLED:-true}"
    B_UPLOAD_WAL="${FULL_WAL_S3_ENABLED:-true}"
    B_RETENTION_PANEL_DAYS="${FULL_EXTERNAL_S3_RETENTION_DAYS:-10}"
    B_RETENTION_CUSTOM_DAYS="${FULL_EXTERNAL_S3_RETENTION_DAYS:-10}"
    B_RETENTION_MIN_KEEP="${FULL_EXTERNAL_S3_RETENTION_MIN_KEEP:-3}"
  else
    [[ -f "${S3D_DIR}/${name}.env" ]] || { msg ERR "S3-бэкенд не найден: ${S3D_DIR}/${name}.env"; return 1; }
    set +u; # shellcheck disable=SC1090
    source "${S3D_DIR}/${name}.env"; set -u
    B_NAME="$name"
  fi
  [[ -n "$B_BUCKET" && -n "$B_ACCESS_KEY" && -n "$B_SECRET_KEY" ]] || {
    msg WARN "S3-бэкенд ${name}: не заполнены bucket/ключи"; return 1; }
  B_PREFIX="${B_PREFIX#/}"; B_PREFIX="${B_PREFIX%/}"
  return 0
}

# aws с реквизитами загруженного бэкенда (после s3m_load)
s3m_aws() {
  local -a ep=()
  [[ -n "$B_ENDPOINT" ]] && ep=(--endpoint-url "$B_ENDPOINT")
  AWS_ACCESS_KEY_ID="$B_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$B_SECRET_KEY" \
  AWS_DEFAULT_REGION="$B_REGION" \
  AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}" \
  aws "$@" "${ep[@]}"
}

s3m_category_enabled() {  # <category: panel|custom-bot|wal>
  case "$1" in
    panel)      truthy "$B_UPLOAD_PANEL" ;;
    custom-bot) truthy "$B_UPLOAD_CUSTOM" ;;
    wal)        truthy "$B_UPLOAD_WAL" ;;
    *)          return 1 ;;
  esac
}

# Ключ логических архивов: <prefix>/<category>/<host>/<file>
s3m_logical_key() { printf '%s/%s/%s/%s' "$B_PREFIX" "$1" "$(rw_source_id)" "$2"; }
# База WAL-слоя: <prefix>/wal/<host>/<instance>
s3m_wal_base()    { printf '%s/wal/%s/%s' "$B_PREFIX" "$(rw_source_id)" "$1"; }

# Загрузка файла во ВСЕ включённые бэкенды категории.
# Возврат: 0 если хотя бы один успех ИЛИ нет ни одного включённого; 1 если все упали.
s3m_upload_all() {
  local category="$1" file="$2" label="${3:-}"
  local name ok=0 targeted=0 fname size
  fname="$(basename "$file")"
  size="$(du -h "$file" 2>/dev/null | awk '{print $1}')"
  command -v aws >/dev/null 2>&1 || { msg WARN "awscli не найден — S3-выгрузка пропущена"; return 0; }

  for name in $(s3m_backends); do
    s3m_load "$name" || continue
    truthy "$B_ENABLED" || continue
    s3m_category_enabled "$category" || continue
    targeted=$((targeted+1))
    local key uri attempt done=false
    key="$(s3m_logical_key "$category" "$fname")"
    uri="s3://${B_BUCKET}/${key}"
    for attempt in 1 2 3; do
      if s3m_aws s3 cp "$file" "$uri" --only-show-errors 2>/dev/null; then done=true; break; fi
      sleep $((attempt*3))
    done
    if [[ "$done" == "true" ]]; then
      ok=$((ok+1)); msg OK "S3[${name}]: ${uri}"
      if truthy "${FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD:-false}" && declare -F send_full_telegram_message >/dev/null; then
        send_full_telegram_message "✅ S3 [${name}]: ${label:-$category}
Файл: ${fname} (${size})
${uri}" || true
      fi
    else
      msg ERR "S3[${name}]: не удалось загрузить ${fname}"
    fi
  done
  (( targeted == 0 )) && return 0
  (( ok > 0 ))
}

# Ретенция логических архивов по всем бэкендам (у каждого — свои дни/min-keep).
# Использует timestamp из имени файла; нераспознанные не трогает.
s3m_retention_logical_all() {
  local name
  for name in $(s3m_backends); do
    s3m_load "$name" || continue
    truthy "$B_ENABLED" || continue
    s3m_category_enabled panel      && s3m_retention_one "$name" panel      "$B_RETENTION_PANEL_DAYS"
    s3m_category_enabled custom-bot && s3m_retention_one "$name" custom-bot "$B_RETENTION_CUSTOM_DAYS"
  done
}

s3m_retention_one() {  # <backend> <category> <days>
  local name="$1" category="$2" days="$3"
  [[ "$days" =~ ^[0-9]+$ ]] || return 0
  local host prefix cutoff now keep_min
  host="$(rw_source_id)"
  prefix="${B_PREFIX}/${category}/${host}/"
  now="$(date +%s)"; cutoff=$(( now - days*86400 ))
  keep_min="${B_RETENTION_MIN_KEEP:-3}"

  local listing
  listing="$(s3m_aws s3 ls "s3://${B_BUCKET}/${prefix}" 2>/dev/null | awk '{print $4}' | grep -E '\.(tar\.gz|age)$' | sort)" || return 0
  [[ -n "$listing" ]] || return 0
  local total; total="$(wc -l <<<"$listing")"
  local deletable=$(( total - keep_min )); (( deletable < 0 )) && deletable=0

  local f ts epoch removed=0
  while IFS= read -r f; do
    (( removed >= deletable )) && break
    # timestamp: YYYY-MM-DD_HH_MM_SS или YYYYMMDD_HHMMSS
    if [[ "$f" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})_([0-9]{2}) ]]; then
      ts="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    elif [[ "$f" =~ ([0-9]{8})_([0-9]{6}) ]]; then
      ts="${BASH_REMATCH[1]:0:4}-${BASH_REMATCH[1]:4:2}-${BASH_REMATCH[1]:6:2} ${BASH_REMATCH[2]:0:2}:${BASH_REMATCH[2]:2:2}:${BASH_REMATCH[2]:4:2}"
    else
      continue
    fi
    epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
    (( epoch > 0 && epoch < cutoff )) || continue
    s3m_aws s3 rm "s3://${B_BUCKET}/${prefix}${f}" --only-show-errors 2>/dev/null && removed=$((removed+1))
  done <<<"$listing"
  (( removed > 0 )) && msg OK "S3[${name}] ${category}: удалено ${removed} архивов старше ${days} дн."
  return 0
}
