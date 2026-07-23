#!/usr/bin/env bash
# metrics-exporter.sh — сводная выгрузка данных о бэкапах для Grafana.
#
# Пишет в textfile collector (/var/lib/node_exporter/textfile_collector),
# откуда метрики забирает node_exporter/vmagent и по push-модели уезжают
# в VictoriaMetrics — источник данных для дашборда Grafana.
#
# Что выгружается:
#   - свободное/общее место на разделах бэкапов и WAL
#   - размеры и количество локальных архивов по категориям (panel/custom/wal)
#   - возраст свежайшего архива каждой категории
#   - размеры данных в каждом S3-бэкенде по категориям (если FULL_METRICS_S3_SIZES=true;
#     это листинг бакета — на больших объёмах включайте осознанно)
#   - конфигурация: количество бэкендов, инстансов
# Событийные метрики (успех операций, длительность, результаты песочницы)
# пишут сами операции; экспортер дополняет их «инвентарными» данными.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

wal_load_full_config
require_component metrics
wal_lock "metrics-exporter" || exit 0

BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
HOST="$(wal_hostname)"
SRC="$(rw_source_id)"

out=""
emit() { out+="$1"$'\n'; }

emit "# HELP rw_exporter_last_run_timestamp_seconds Время последнего прогона экспортера."
emit "# TYPE rw_exporter_last_run_timestamp_seconds gauge"
emit "rw_exporter_last_run_timestamp_seconds $(date +%s)"
emit "# HELP rw_source_info Идентификатор источника бэкапов (host-* или k8s-*)."
emit "# TYPE rw_source_info gauge"
emit "rw_source_info{source=\"${SRC}\",kind=\"$([[ "$SRC" == k8s-* ]] && echo k8s || echo host)\"} 1"

# --- Диски ---
emit "# HELP rw_disk_free_bytes Свободное место на разделе (по пути назначения)."
emit "# TYPE rw_disk_free_bytes gauge"
emit "# HELP rw_disk_total_bytes Размер раздела."
emit "# TYPE rw_disk_total_bytes gauge"
for path_label in "${BACKUP_DIR}:backups" "${WAL_ROOT}:wal"; do
  path="${path_label%%:*}"; label="${path_label##*:}"
  [[ -d "$path" ]] || continue
  read -r total avail < <(df -B1 --output=size,avail "$path" 2>/dev/null | tail -n1)
  emit "rw_disk_free_bytes{path=\"${path}\",role=\"${label}\"} ${avail:-0}"
  emit "rw_disk_total_bytes{path=\"${path}\",role=\"${label}\"} ${total:-0}"
done

# --- Локальные архивы по категориям ---
emit "# HELP rw_local_archives_count Количество локальных архивов категории."
emit "# TYPE rw_local_archives_count gauge"
emit "# HELP rw_local_archives_bytes Суммарный размер локальных архивов категории."
emit "# TYPE rw_local_archives_bytes gauge"
emit "# HELP rw_local_latest_archive_age_seconds Возраст свежайшего архива категории."
emit "# TYPE rw_local_latest_archive_age_seconds gauge"

cat_stat() { # <category> <glob> <dir>
  local cat="$1" glob="$2" dir="$3" cnt bytes newest age=-1
  cnt="$(find "$dir" -maxdepth 1 -name "$glob" -type f 2>/dev/null | wc -l | tr -d ' ')"
  bytes="$(find "$dir" -maxdepth 1 -name "$glob" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  newest="$(find "$dir" -maxdepth 1 -name "$glob" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -n1)"
  [[ -n "$newest" ]] && age=$(( $(date +%s) - ${newest%.*} ))
  emit "rw_local_archives_count{category=\"${cat}\"} ${cnt}"
  emit "rw_local_archives_bytes{category=\"${cat}\"} ${bytes}"
  emit "rw_local_latest_archive_age_seconds{category=\"${cat}\"} ${age}"
}
cat_stat panel      'remnawave_backup_*.tar.gz' "$BACKUP_DIR"
cat_stat custom-bot 'custom_bot_*.tar.gz'       "$BACKUP_DIR"

# WAL-инстансы: локальные объёмы
emit "# HELP rw_wal_local_bytes Размер локального WAL-хранилища инстанса (архив+базовые)."
emit "# TYPE rw_wal_local_bytes gauge"
while IFS= read -r inst; do
  [[ -n "$inst" ]] || continue
  b="$(du -sb "${WAL_ROOT}/${inst}" 2>/dev/null | awk '{print $1}')"
  emit "rw_wal_local_bytes{instance=\"${inst}\"} ${b:-0}"
done < <(wal_list_instances)

# --- Конфигурация ---
n_backends=0; n_enabled=0
for n in $(s3m_backends); do
  n_backends=$((n_backends+1))
  s3m_load "$n" 2>/dev/null && truthy "$B_ENABLED" && n_enabled=$((n_enabled+1))
done
emit "# HELP rw_s3_backends_total Настроено S3-бэкендов."
emit "# TYPE rw_s3_backends_total gauge"
emit "rw_s3_backends_total ${n_backends}"
emit "rw_s3_backends_enabled ${n_enabled}"

# --- Размеры в S3 по бэкендам/категориям (опционально: листинг бакета) ---
if truthy "${FULL_METRICS_S3_SIZES:-true}" && command -v aws >/dev/null 2>&1; then
  emit "# HELP rw_s3_category_bytes Объём данных категории в S3-бэкенде (для этого хоста)."
  emit "# TYPE rw_s3_category_bytes gauge"
  emit "# HELP rw_s3_category_objects Количество объектов категории в S3-бэкенде."
  emit "# TYPE rw_s3_category_objects gauge"
  emit "# HELP rw_s3_backend_reachable Доступность бэкенда (1 — листинг успешен)."
  emit "# TYPE rw_s3_backend_reachable gauge"
  for n in $(s3m_backends); do
    s3m_load "$n" 2>/dev/null || continue
    truthy "$B_ENABLED" || continue
    reachable=0
    for pair in "panel:${B_PREFIX}/panel/${HOST}/" "custom-bot:${B_PREFIX}/custom-bot/${HOST}/" "wal:${B_PREFIX}/wal/${HOST}/"; do
      cat="${pair%%:*}"; pfx="${pair#*:}"
      s3m_category_enabled "$cat" || continue
      summ="$(s3m_aws s3 ls "s3://${B_BUCKET}/${pfx}" --recursive --summarize 2>/dev/null | tail -n2)"
      if [[ -n "$summ" ]]; then
        reachable=1
        objs="$(grep -oE 'Total Objects: [0-9]+' <<<"$summ" | grep -oE '[0-9]+' || echo 0)"
        bytes="$(grep -oE 'Total Size: [0-9]+' <<<"$summ" | grep -oE '[0-9]+' || echo 0)"
        emit "rw_s3_category_bytes{backend=\"${n}\",category=\"${cat}\"} ${bytes:-0}"
        emit "rw_s3_category_objects{backend=\"${n}\",category=\"${cat}\"} ${objs:-0}"
      fi
    done
    emit "rw_s3_backend_reachable{backend=\"${n}\"} ${reachable}"
  done
fi

wal_metric_write "rw_exporter" <<<"$out"
msg OK "Метрики выгружены в ${WAL_METRICS_DIR}/rw_exporter.prom ($(wc -l <<<"$out") строк)"
