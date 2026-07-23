#!/usr/bin/env bash
# basebackup.sh <instance> [--no-s3] — полный базовый бэкап PostgreSQL.
#
# Используется штатный pg_basebackup, который УЖЕ есть в образе postgres.
# Никаких сторонних бинарников в контейнер не добавляется — важно, потому что
# образ панели (remnawave-db) обновляется upstream'ом и любые правки образа
# были бы потеряны при обновлении.
#
# Режим -X none: WAL в базовый бэкап не включается, он берётся из WAL-архива.
# Это и есть смысл всей схемы: базовый бэкап делается редко (раз в сутки),
# а точка восстановления двигается непрерывно за счёт WAL.
#
# Результат:
#   base_<timestamp>_<start_segment>.tar<comp>[.age]   — сам бэкап
#   base_<timestamp>_<start_segment>.meta             — метаданные для restore/retention

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE="${1:-}"
NO_S3="${2:-}"
[[ -n "$INSTANCE" ]] || { echo "Usage: basebackup.sh <instance> [--no-s3]" >&2; exit 1; }

wal_load_full_config
wal_load_instance "$INSTANCE"

truthy "${INST_ENABLED:-true}" || { msg INFO "[${INSTANCE}] отключён"; exit 0; }

wal_lock "basebackup-${INSTANCE}" || exit 0
wal_instance_dirs_init

started_at="$(date +%s)"

fail() {
  local reason="$1"
  msg ERR "[${INSTANCE}] базовый бэкап не выполнен: ${reason}"
  wal_metric_write "rw_basebackup_${INSTANCE}" <<EOF_M
# HELP rw_basebackup_last_success_timestamp_seconds Время последнего успешного базового бэкапа.
# TYPE rw_basebackup_last_success_timestamp_seconds gauge
rw_basebackup_last_success_timestamp_seconds{instance="${INSTANCE}"} $(cat "${INST_STATE_DIR}/last_success" 2>/dev/null || echo 0)
# HELP rw_basebackup_last_result Результат последнего запуска (1 — успех).
# TYPE rw_basebackup_last_result gauge
rw_basebackup_last_result{instance="${INSTANCE}"} 0
EOF_M
  wal_notify "❌ Базовый бэкап не выполнен
Инстанс: ${INSTANCE}
Хост: $(wal_hostname)
Причина: ${reason}"
  exit 1
}

wal_container_running || fail "контейнер ${INST_CONTAINER} не запущен"
wal_wait_pg_ready 60 || fail "PostgreSQL в ${INST_CONTAINER} не отвечает"

# Проверяем, что архивация вообще включена — иначе базовый бэкап без WAL бесполезен.
archive_mode="$(wal_psql "SHOW archive_mode" 2>/dev/null | head -n1 || echo off)"
if [[ "$archive_mode" != "on" && "$archive_mode" != "always" ]]; then
  fail "archive_mode=${archive_mode}; сначала выполните: rw-backup-full wal-enable ${INSTANCE}"
fi

# Сегмент ДО начала бэкапа. Консервативная нижняя граница: реальный старт
# бэкапа будет не раньше него, значит retention не удалит нужный WAL.
start_segment="$(wal_current_segment)"
[[ -n "$start_segment" ]] || fail "не удалось определить текущий WAL-сегмент"

timeline="${start_segment:0:8}"
pgver="$(wal_pg_version)"
ts="$(wal_ts)"

comp_ext="$(wal_comp_ext)"
enc_ext="$(wal_enc_ext)"
base_name="base_${ts}_${start_segment}"
out_file="${INST_BASEBACKUP_DIR}/${base_name}.tar${comp_ext}${enc_ext}"
meta_file="${INST_BASEBACKUP_DIR}/${base_name}.meta"
tmp_file="${INST_BASEBACKUP_DIR}/.${base_name}.tmp.$$"

msg INFO "[${INSTANCE}] базовый бэкап, стартовый сегмент ${start_segment}, PG ${pgver}"

# -Ft -D -  : tar-поток в stdout
# -X none   : WAL не включаем, он приедет из архива
# -c fast   : немедленный checkpoint, не ждём checkpoint_timeout
# --no-sync : мы не пишем в PGDATA контейнера, синхронизация не нужна
if ! docker exec -i "$INST_CONTAINER" \
      pg_basebackup \
        -h localhost \
        -U "$INST_PGUSER" \
        -D - \
        -Ft \
        -X none \
        -c fast \
        --no-sync \
        2>"${INST_STATE_DIR}/basebackup.err" \
      | wal_compress_stream \
      | wal_encrypt_stream \
      > "$tmp_file"; then
  err="$(tail -n 5 "${INST_STATE_DIR}/basebackup.err" 2>/dev/null | tr '\n' ' ')"
  rm -f "$tmp_file"
  fail "pg_basebackup: ${err}"
fi

[[ -s "$tmp_file" ]] || { rm -f "$tmp_file"; fail "получен пустой архив"; }

# Проверка целостности до того, как объявим бэкап годным.
# Для зашифрованных архивов распаковку проверить нельзя (приватного ключа
# на сервере нет по дизайну) — проверяем только размер.
if [[ -z "$enc_ext" ]]; then
  if ! wal_decompress_stream "$out_file" < "$tmp_file" | tar -tf - >/dev/null 2>&1; then
    rm -f "$tmp_file"
    fail "архив не проходит проверку tar"
  fi
  if ! wal_decompress_stream "$out_file" < "$tmp_file" | tar -tf - 2>/dev/null | grep -q 'PG_VERSION'; then
    rm -f "$tmp_file"
    fail "в архиве нет PG_VERSION — структура повреждена"
  fi
fi

mv -f "$tmp_file" "$out_file"

# Принудительно закрываем текущий сегмент, чтобы всё нужное для восстановления
# этого бэкапа гарантированно попало в архив, а не осталось в pg_wal.
wal_switch_segment
sleep 3
end_segment="$(wal_current_segment || echo "$start_segment")"

size_bytes="$(stat -c %s "$out_file")"
sha="$(sha256sum "$out_file" | awk '{print $1}')"
duration=$(( $(date +%s) - started_at ))

cat > "$meta_file" <<EOF_META
BACKUP_NAME="${base_name}"
INSTANCE="${INSTANCE}"
HOST="$(wal_hostname)"
CONTAINER="${INST_CONTAINER}"
KIND="${INST_KIND}"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CREATED_EPOCH="$(date +%s)"
PG_VERSION_NUM="${pgver}"
TIMELINE="${timeline}"
START_SEGMENT="${start_segment}"
END_SEGMENT="${end_segment}"
FILE="$(basename "$out_file")"
SIZE_BYTES="${size_bytes}"
SHA256="${sha}"
COMPRESSION="$(wal_compressor)"
ENCRYPTED="$([[ -n "$enc_ext" ]] && echo true || echo false)"
DURATION_SECONDS="${duration}"
EOF_META

echo "$(date +%s)" > "${INST_STATE_DIR}/last_success"

msg OK "[${INSTANCE}] базовый бэкап готов: $(basename "$out_file") ($(numfmt --to=iec "$size_bytes" 2>/dev/null || echo "${size_bytes}B"), ${duration}s)"

# --------------------------------------------------------------------------
# Выгрузка в S3
# --------------------------------------------------------------------------
s3_ok="skipped"
if [[ "$NO_S3" != "--no-s3" ]] && wal_s3_ready && truthy "${FULL_WAL_S3_ENABLED:-true}"; then
  s3_ok="failed"
  for attempt in 1 2 3; do
    if wal_aws s3 cp "$out_file" "$(wal_s3_uri "basebackup/$(basename "$out_file")")" --only-show-errors 2>/dev/null &&
       wal_aws s3 cp "$meta_file" "$(wal_s3_uri "basebackup/$(basename "$meta_file")")" --only-show-errors 2>/dev/null; then
      s3_ok="ok"
      break
    fi
    sleep $((attempt * 5))
  done

  if [[ "$s3_ok" == "ok" ]]; then
    msg OK "[${INSTANCE}] выгружено в S3: $(wal_s3_uri "basebackup/$(basename "$out_file")")"
  else
    msg WARN "[${INSTANCE}] выгрузка базового бэкапа в S3 не удалась"
  fi
fi

wal_metric_write "rw_basebackup_${INSTANCE}" <<EOF_M
# HELP rw_basebackup_last_success_timestamp_seconds Время последнего успешного базового бэкапа.
# TYPE rw_basebackup_last_success_timestamp_seconds gauge
rw_basebackup_last_success_timestamp_seconds{instance="${INSTANCE}"} $(date +%s)
# HELP rw_basebackup_last_result Результат последнего запуска (1 — успех).
# TYPE rw_basebackup_last_result gauge
rw_basebackup_last_result{instance="${INSTANCE}"} 1
# HELP rw_basebackup_size_bytes Размер последнего базового бэкапа.
# TYPE rw_basebackup_size_bytes gauge
rw_basebackup_size_bytes{instance="${INSTANCE}"} ${size_bytes}
# HELP rw_basebackup_duration_seconds Длительность последнего базового бэкапа.
# TYPE rw_basebackup_duration_seconds gauge
rw_basebackup_duration_seconds{instance="${INSTANCE}"} ${duration}
# HELP rw_basebackup_s3_ok Успешность выгрузки в S3 (1 — да).
# TYPE rw_basebackup_s3_ok gauge
rw_basebackup_s3_ok{instance="${INSTANCE}"} $([[ "$s3_ok" == "ok" ]] && echo 1 || echo 0)
EOF_M

wal_notify "✅ Базовый бэкап PostgreSQL
Инстанс: ${INSTANCE} (${INST_KIND})
Хост: $(wal_hostname)
Файл: $(basename "$out_file")
Размер: $(numfmt --to=iec "$size_bytes" 2>/dev/null || echo "${size_bytes}B")
Стартовый WAL: ${start_segment}
Длительность: ${duration}s
S3: ${s3_ok}"

# Retention запускаем сразу после успешного бэкапа: только в этот момент
# безопасно двигать границу удаления WAL.
"${SCRIPT_DIR}/wal-retention.sh" "$INSTANCE" || true

exit 0
