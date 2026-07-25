#!/usr/bin/env bash
# wal-retention.sh <instance> [--dry-run] — очистка базовых бэкапов и WAL.
#
# ГЛАВНОЕ ПРАВИЛО ЭТОГО СКРИПТА:
# WAL-сегмент нельзя удалять по возрасту. Его можно удалить только тогда,
# когда он старше стартового сегмента САМОГО СТАРОГО базового бэкапа,
# который мы ещё храним. Иначе получится набор бэкапов, ни один из которых
# невозможно восстановить — классический способ обнаружить, что бэкапов нет,
# в момент аварии.
#
# Границы считаются раздельно для локального хранилища и для S3,
# потому что глубина хранения у них разная.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE="${1:-}"
DRY_RUN="${2:-}"
[[ -n "$INSTANCE" ]] || { echo "Usage: wal-retention.sh <instance> [--dry-run]" >&2; exit 1; }

wal_load_full_config
wal_load_instance "$INSTANCE"
wal_lock "retention-${INSTANCE}" || exit 0
wal_instance_dirs_init

dry() { [[ "$DRY_RUN" == "--dry-run" ]]; }

do_rm() {
  if dry; then
    msg INFO "[dry-run] rm $1"
  else
    rm -f "$1"
  fi
}

do_s3_rm() {
  if dry; then
    msg INFO "[dry-run] s3 rm $1"
  else
    wal_aws s3 rm "$1" --only-show-errors 2>/dev/null || true
  fi
}

# Имя WAL-сегмента из имени файла архива: 000000010000000000000007.zst.age -> 000000010000000000000007
seg_of() {
  local b; b="$(basename "$1")"
  echo "${b:0:24}"
}

# --------------------------------------------------------------------------
# ЛОКАЛЬНО: базовые бэкапы
# --------------------------------------------------------------------------
keep_local="${INST_LOCAL_BASEBACKUP_KEEP:-3}"
[[ "$keep_local" =~ ^[0-9]+$ ]] || keep_local=3
(( keep_local >= 1 )) || keep_local=1

mapfile -t local_metas < <(find "$INST_BASEBACKUP_DIR" -maxdepth 1 -type f -name 'base_*.meta' 2>/dev/null | sort -r)

if (( ${#local_metas[@]} == 0 )); then
  msg WARN "[${INSTANCE}] базовых бэкапов нет — WAL не трогаю"
  exit 0
fi

local_horizon=""
idx=0
for meta in "${local_metas[@]}"; do
  idx=$((idx + 1))
  if (( idx <= keep_local )); then
    # shellcheck disable=SC1090
    seg="$(grep -E '^START_SEGMENT=' "$meta" | head -n1 | cut -d'"' -f2)"
    if [[ -n "$seg" ]]; then
      # shellcheck disable=SC2071  # имена WAL-сегментов — hex-строки, сравнение лексикографическое
      if [[ -z "$local_horizon" || "$seg" < "$local_horizon" ]]; then
        local_horizon="$seg"
      fi
    fi
  else
    base="$(basename "$meta" .meta)"
    msg INFO "[${INSTANCE}] удаляю старый локальный базовый бэкап: ${base}"
    while IFS= read -r f; do do_rm "$f"; done < <(find "$INST_BASEBACKUP_DIR" -maxdepth 1 -name "${base}.*" 2>/dev/null)
  fi
done

if [[ -z "$local_horizon" ]]; then
  msg WARN "[${INSTANCE}] не удалось определить границу WAL локально — WAL не трогаю"
else
  msg INFO "[${INSTANCE}] локальная граница WAL: ${local_horizon}"

  deleted=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    seg="$(seg_of "$f")"
    [[ ${#seg} -eq 24 ]] || continue
    # shellcheck disable=SC2071
    if [[ "$seg" < "$local_horizon" ]]; then
      do_rm "$f"
      do_rm "${INST_STATE_DIR}/uploaded/$(basename "$f")"
      deleted=$((deleted + 1))
    fi
  done < <(find "$INST_ARCHIVE_DIR" -maxdepth 1 -type f -name '0*' 2>/dev/null | sort)

  msg OK "[${INSTANCE}] локальный WAL: удалено ${deleted} сегментов до ${local_horizon}"
fi

# Дополнительный предохранитель: если локальный архив всё ещё больше лимита
# по объёму, сообщаем — но НЕ удаляем WAL сверх границы.
if [[ -n "${INST_LOCAL_WAL_MAX_GB:-}" ]]; then
  cur_gb=$(( $(du -sb "$INST_ARCHIVE_DIR" 2>/dev/null | awk '{print $1}') / 1073741824 ))
  if (( cur_gb > INST_LOCAL_WAL_MAX_GB )); then
    wal_notify "⚠️ Локальный WAL-архив превысил лимит
Инстанс: ${INSTANCE}
Хост: $(wal_hostname)
Размер: ${cur_gb} ГБ, лимит: ${INST_LOCAL_WAL_MAX_GB} ГБ
WAL не удалён: он нужен для восстановления имеющихся базовых бэкапов.
Решение: уменьшить INST_LOCAL_BASEBACKUP_KEEP или чаще делать базовый бэкап."
  fi
fi

# --------------------------------------------------------------------------
# S3: базовые бэкапы и WAL
# --------------------------------------------------------------------------
if ! wal_s3_ready; then
  msg INFO "[${INSTANCE}] S3-бэкенды с WAL не настроены, S3-retention пропущен"
  exit 0
fi

s3_backends_total=0
while IFS= read -r __backend; do
  [[ -n "$__backend" ]] || continue
  s3_backends_total=$((s3_backends_total + 1))
  wal_s3_select "$__backend" || continue
  msg INFO "[${INSTANCE}] S3-retention: бэкенд ${__backend}"

  # keep берётся из настроек БЭКЕНДА; INST_S3_BASEBACKUP_KEEP — общий fallback.
  keep_s3="${B_BASEBACKUP_KEEP:-${INST_S3_BASEBACKUP_KEEP:-10}}"
  [[ "$keep_s3" =~ ^[0-9]+$ ]] || keep_s3=10
  (( keep_s3 >= 1 )) || keep_s3=1

  s3_base_prefix="$(wal_s3_uri "basebackup/")"

mapfile -t s3_metas < <(
  wal_aws s3 ls "$s3_base_prefix" 2>/dev/null \
    | awk '{print $4}' | grep -E '^base_.*\.meta$' | sort -r || true
)

if (( ${#s3_metas[@]} == 0 )); then
  msg WARN "[${INSTANCE}] S3[${__backend}]: нет базовых бэкапов — WAL не трогаю"
  continue
fi

tmpdir="$(mktemp -d)"
cleanup_tmp() { rm -rf "$tmpdir"; }
# Намеренно НЕ используем `trap RETURN` — только EXIT, скрипт самостоятельный.
trap cleanup_tmp EXIT

s3_horizon=""
idx=0
for meta_name in "${s3_metas[@]}"; do
  idx=$((idx + 1))
  base="${meta_name%.meta}"

  if (( idx <= keep_s3 )); then
    if wal_aws s3 cp "${s3_base_prefix}${meta_name}" "${tmpdir}/${meta_name}" --only-show-errors 2>/dev/null; then
      seg="$(grep -E '^START_SEGMENT=' "${tmpdir}/${meta_name}" | head -n1 | cut -d'"' -f2)"
      if [[ -n "$seg" ]]; then
        # shellcheck disable=SC2071
        if [[ -z "$s3_horizon" || "$seg" < "$s3_horizon" ]]; then
          s3_horizon="$seg"
        fi
      fi
    else
      msg WARN "[${INSTANCE}] не удалось прочитать ${meta_name} из S3 — считаю границу консервативно"
      s3_horizon="000000000000000000000000"
    fi
  else
    msg INFO "[${INSTANCE}] удаляю старый базовый бэкап из S3: ${base}"
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      do_s3_rm "${s3_base_prefix}${key}"
    done < <(wal_aws s3 ls "${s3_base_prefix}${base}" 2>/dev/null | awk '{print $4}')
  fi
done

if [[ -z "$s3_horizon" ]]; then
  msg WARN "[${INSTANCE}] S3[${__backend}]: граница WAL не определена — WAL не трогаю"
  continue
fi

msg INFO "[${INSTANCE}] граница WAL в S3: ${s3_horizon}"

s3_wal_prefix="$(wal_s3_uri "wal/")"
s3_deleted=0
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  seg="${key:0:24}"
  [[ ${#seg} -eq 24 ]] || continue
  # shellcheck disable=SC2071
  if [[ "$seg" < "$s3_horizon" ]]; then
    do_s3_rm "${s3_wal_prefix}${key}"
    s3_deleted=$((s3_deleted + 1))
  fi
done < <(wal_aws s3 ls "$s3_wal_prefix" 2>/dev/null | awk '{print $4}' | sort)

  msg OK "[${INSTANCE}] S3[${__backend}] WAL: удалено ${s3_deleted} сегментов до ${s3_horizon}"
done < <(wal_s3_backends)

wal_metric_write "rw_wal_retention_${INSTANCE}" <<EOF_M
# HELP rw_wal_retention_last_run_timestamp_seconds Время последнего прогона retention.
# TYPE rw_wal_retention_last_run_timestamp_seconds gauge
rw_wal_retention_last_run_timestamp_seconds{instance="${INSTANCE}"} $(date +%s)
# HELP rw_basebackup_count Количество хранимых базовых бэкапов.
# TYPE rw_basebackup_count gauge
rw_basebackup_count{instance="${INSTANCE}",location="local"} ${#local_metas[@]}
rw_basebackup_count{instance="${INSTANCE}",location="s3"} ${#s3_metas[@]}
EOF_M

exit 0
