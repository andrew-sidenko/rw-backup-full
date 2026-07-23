#!/usr/bin/env bash
# wal-ship.sh <instance> — переносит WAL-сегменты из спула в локальный архив и S3.
#
# Запускается на хосте по таймеру rw-wal-ship@<instance>.timer (по умолчанию раз в минуту).
# Спул наполняет archive_command внутри контейнера postgres.
#
# Порядок для каждого сегмента:
#   1. сжать (zstd/gzip) во временный файл в локальном архиве
#   2. опционально зашифровать age
#   3. атомарный rename в локальный архив
#   4. upload в S3 (с ретраями)
#   5. только после успеха — удалить из спула
#
# Если S3 недоступен, сегмент остаётся в локальном архиве и в спуле;
# на следующем запуске отправка повторится. Локальная копия при этом уже есть,
# то есть даже полный отказ S3 не приводит к потере WAL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE="${1:-}"
[[ -n "$INSTANCE" ]] || { echo "Usage: wal-ship.sh <instance>" >&2; exit 1; }

wal_load_full_config
wal_load_instance "$INSTANCE"

truthy "${INST_ENABLED:-true}" || { msg INFO "[${INSTANCE}] отключён"; exit 0; }

wal_lock "ship-${INSTANCE}" || exit 0

wal_instance_dirs_init

SPOOL_IN="${INST_SPOOL_DIR}/incoming"
mkdir -p "$SPOOL_IN"

COMP_EXT="$(wal_comp_ext)"
ENC_EXT="$(wal_enc_ext)"
SUFFIX="${COMP_EXT}${ENC_EXT}"

shipped=0
failed=0
s3_failed=0

mapfile -t WAL_BACKENDS < <(wal_s3_backends)
s3_enabled=false
(( ${#WAL_BACKENDS[@]} > 0 )) && s3_enabled=true

# --------------------------------------------------------------------------
# 1. Сегменты из спула -> локальный архив
# --------------------------------------------------------------------------
while IFS= read -r seg_path; do
  [[ -n "$seg_path" ]] || continue
  seg="$(basename "$seg_path")"

  # Пропускаем временные файлы archive_command и служебные маркеры.
  [[ "$seg" == .* ]] && continue
  [[ "$seg" == *.done ]] && continue

  dst="${INST_ARCHIVE_DIR}/${seg}${SUFFIX}"
  tmp="${INST_ARCHIVE_DIR}/.${seg}${SUFFIX}.tmp.$$"

  if [[ -f "$dst" ]]; then
    # Уже в локальном архиве — просто убираем из спула.
    rm -f "$seg_path"
    continue
  fi

  if ! wal_compress_stream < "$seg_path" | wal_encrypt_stream > "$tmp"; then
    msg ERR "[${INSTANCE}] ошибка сжатия сегмента ${seg}"
    rm -f "$tmp"
    failed=$((failed + 1))
    continue
  fi

  # Проверка целостности до того, как удалим оригинал.
  if [[ -z "$ENC_EXT" ]]; then
    if ! wal_decompress_stream "$dst" < "$tmp" > /dev/null 2>&1; then
      msg ERR "[${INSTANCE}] архив ${seg} не проходит проверку целостности"
      rm -f "$tmp"
      failed=$((failed + 1))
      continue
    fi
  fi

  if [[ ! -s "$tmp" ]]; then
    msg ERR "[${INSTANCE}] пустой архив для ${seg}"
    rm -f "$tmp"
    failed=$((failed + 1))
    continue
  fi

  mv -f "$tmp" "$dst"
  rm -f "$seg_path"
  shipped=$((shipped + 1))
done < <(find "$SPOOL_IN" -maxdepth 1 -type f -name '0*' 2>/dev/null | sort)

# --------------------------------------------------------------------------
# 2. Локальный архив -> S3 (всё, что ещё не отмечено как выгруженное)
# --------------------------------------------------------------------------
if [[ "$s3_enabled" == "true" ]]; then
  for backend in "${WAL_BACKENDS[@]}"; do
    wal_s3_select "$backend" || continue
    mkdir -p "${INST_STATE_DIR}/uploaded/${backend}"
    while IFS= read -r arc_path; do
      [[ -n "$arc_path" ]] || continue
      arc="$(basename "$arc_path")"
      [[ "$arc" == .* ]] && continue

      marker="${INST_STATE_DIR}/uploaded/${backend}/${arc}"
      [[ -f "$marker" ]] && continue

      ok=false
      for attempt in 1 2 3; do
        if wal_aws s3 cp "$arc_path" "$(wal_s3_uri "wal/${arc}")" --only-show-errors 2>/dev/null; then
          ok=true
          break
        fi
        sleep $((attempt * 3))
      done

      if [[ "$ok" == "true" ]]; then
        : > "$marker"
      else
        msg WARN "[${INSTANCE}] S3[${backend}]: не выгружен ${arc}, повтор на следующем запуске"
        s3_failed=$((s3_failed + 1))
      fi
    done < <(find "$INST_ARCHIVE_DIR" -maxdepth 1 -type f -name '0*' 2>/dev/null | sort)
  done
fi

# --------------------------------------------------------------------------
# 3. Метрики
# --------------------------------------------------------------------------
spool_count="$(find "$SPOOL_IN" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l | tr -d ' ')"
archive_count="$(find "$INST_ARCHIVE_DIR" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l | tr -d ' ')"
archive_bytes="$(du -sb "$INST_ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')"
archive_bytes="${archive_bytes:-0}"
pending_s3="$(( s3_failed ))"

wal_metric_write "rw_wal_ship_${INSTANCE}" <<EOF_METRICS
# HELP rw_wal_last_ship_timestamp_seconds Время последнего запуска шиппера WAL.
# TYPE rw_wal_last_ship_timestamp_seconds gauge
rw_wal_last_ship_timestamp_seconds{instance="${INSTANCE}"} $(date +%s)
# HELP rw_wal_shipped_segments Сегментов перенесено за последний запуск.
# TYPE rw_wal_shipped_segments gauge
rw_wal_shipped_segments{instance="${INSTANCE}"} ${shipped}
# HELP rw_wal_spool_files Сегментов в спуле (растёт, если шиппер не справляется).
# TYPE rw_wal_spool_files gauge
rw_wal_spool_files{instance="${INSTANCE}"} ${spool_count}
# HELP rw_wal_archive_files Сегментов в локальном архиве.
# TYPE rw_wal_archive_files gauge
rw_wal_archive_files{instance="${INSTANCE}"} ${archive_count}
# HELP rw_wal_archive_bytes Размер локального WAL-архива в байтах.
# TYPE rw_wal_archive_bytes gauge
rw_wal_archive_bytes{instance="${INSTANCE}"} ${archive_bytes}
# HELP rw_wal_ship_failures Ошибок обработки за последний запуск.
# TYPE rw_wal_ship_failures gauge
rw_wal_ship_failures{instance="${INSTANCE}"} ${failed}
# HELP rw_wal_s3_pending Сегментов, не выгруженных в S3.
# TYPE rw_wal_s3_pending gauge
rw_wal_s3_pending{instance="${INSTANCE}"} ${pending_s3}
EOF_METRICS

if (( shipped > 0 || failed > 0 || s3_failed > 0 )); then
  msg OK "[${INSTANCE}] WAL ship: перенесено=${shipped}, ошибок=${failed}, S3-ожидает=${pending_s3}, спул=${spool_count}"
fi

# Спул растёт — это ранний признак того, что что-то сломано.
if (( spool_count > 200 )); then
  wal_notify "⚠️ WAL спул растёт
Инстанс: ${INSTANCE}
Хост: $(wal_hostname)
Сегментов в спуле: ${spool_count}
Проверить: journalctl -u rw-wal-ship@${INSTANCE}.service -n 50"
fi

exit 0
