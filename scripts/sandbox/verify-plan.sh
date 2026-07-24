#!/usr/bin/env bash
# verify-plan.sh — выбирает, ЧТО проверять в этом прогоне.
#
# ЗАЧЕМ. Проверять каждый раз одно и то же (свежий логический дамп) —
# значит никогда не узнать, восстановима ли WAL-цепочка и базовый бэкап.
# Но и гонять всё подряд на каждый запуск избыточно. Правило ротации:
#
#   • каждый НОВЫЙ логический дамп  — проверяется один раз;
#   • каждый НОВЫЙ базовый бэкап    — проверяется один раз (restore до
#     точки самого бэкапа, target=immediate);
#   • все остальные прогоны в промежутке — PITR на точки, равномерно
#     распределённые по доступному диапазону WAL, чтобы за период
#     проверить цепочку в разных местах, а не только на её краю.
#
# Состояние (что уже проверено) хранится маркерами, поэтому ротация
# переживает перезапуски и не зависит от того, по таймеру запуск или руками.
#
# Вывод (одна строка, для eval/чтения вызывающим):
#   MODE=dump   KEY=<s3-ключ логического архива>
#   MODE=base   META=<имя meta-файла базового бэкапа>
#   MODE=pitr   META=<meta> TARGET_TIME=<ISO-время>  SLOT=<n>/<всего>
#   MODE=none   REASON=<текст>
#
# Использование: verify-plan.sh <проект> <источник> <bucket> <prefix>
# (реквизиты S3 — через окружение AWS_*, как их выставляет вызывающий)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

PROJECT="${1:?проект}"
SOURCE_ID="${2:?источник}"
BUCKET="${3:?bucket}"
PREFIX="${4:?prefix}"

STATE_DIR="${VERIFY_PLAN_STATE:-/var/lib/rw-wal/verify-plan}/${SOURCE_ID}/${PROJECT}"
mkdir -p "$STATE_DIR"

# Режим просмотра: показать, что будет проверяться, НЕ сдвигая ротацию.
# Иначе простой взгляд на план съедал бы слот и искажал покрытие.
DRYRUN="${VERIFY_PLAN_DRYRUN:-}"
mark() { [[ -n "$DRYRUN" ]] || : > "$1"; }
save() { [[ -n "$DRYRUN" ]] || echo "$1" > "$2"; }

# Сколько PITR-точек размазывать между базовыми бэкапами. Больше — плотнее
# покрытие цепочки, но и больше прогонов. По умолчанию 4: при суточном
# базовом бэкапе и 6 проверках в сутки получается ~каждые 4-6 часов.
PITR_SLOTS="${VERIFY_PITR_SLOTS:-4}"

aws_ls() { aws s3 ls "$@" 2>/dev/null || true; }

DUMP_CAT="panel"; [[ "$PROJECT" != "panel" ]] && DUMP_CAT="custom-bot"

# --- 1. Новый логический дамп? -------------------------------------------
latest_dump="$(aws_ls "s3://${BUCKET}/${PREFIX}/${DUMP_CAT}/${SOURCE_ID}/" --recursive \
  | awk '{print $1" "$2" "$4}' | sort | tail -n1 | awk '{print $3}')"

if [[ -n "$latest_dump" ]]; then
  marker="${STATE_DIR}/dump_$(basename "$latest_dump" | tr -c 'a-zA-Z0-9' '_')"
  if [[ ! -f "$marker" ]]; then
    mark "$marker"
    echo "MODE=dump KEY=${latest_dump}"
    exit 0
  fi
fi

# --- 2. Новый базовый бэкап? ---------------------------------------------
wal_base="${PREFIX}/wal/${SOURCE_ID}/${PROJECT}"
latest_meta="$(aws_ls "s3://${BUCKET}/${wal_base}/basebackup/" \
  | awk '{print $4}' | grep -E '^base_.*\.meta$' | sort | tail -n1)"

if [[ -z "$latest_meta" ]]; then
  if [[ -n "$latest_dump" ]]; then
    # WAL не настроен — ротировать нечего, продолжаем проверять дамп.
    echo "MODE=dump KEY=${latest_dump}"
  else
    echo "MODE=none REASON=нет ни логических архивов, ни базовых бэкапов"
  fi
  exit 0
fi

base_marker="${STATE_DIR}/base_$(echo "$latest_meta" | tr -c 'a-zA-Z0-9' '_')"
if [[ ! -f "$base_marker" ]]; then
  mark "$base_marker"
  # Счётчик PITR-слотов сбрасывается на каждом новом базовом бэкапе:
  # ротация идёт внутри интервала между базовыми бэкапами.
  save 0 "${STATE_DIR}/pitr_slot"
  echo "MODE=base META=${latest_meta}"
  exit 0
fi

# --- 3. PITR на равномерно распределённую точку ---------------------------
# Диапазон: от времени базового бэкапа до времени самого свежего WAL-сегмента.
base_epoch="$(aws_ls "s3://${BUCKET}/${wal_base}/basebackup/${latest_meta}" \
  | awk '{print $1" "$2}' | tail -n1)"
base_epoch="$(date -d "${base_epoch} UTC" +%s 2>/dev/null || echo 0)"

last_wal_ts="$(aws_ls "s3://${BUCKET}/${wal_base}/wal/" \
  | awk '{print $1" "$2}' | sort | tail -n1)"
last_wal_epoch="$(date -d "${last_wal_ts} UTC" +%s 2>/dev/null || echo 0)"

if (( base_epoch == 0 || last_wal_epoch <= base_epoch )); then
  # WAL после базового бэкапа ещё не накопился — проверяем сам базовый.
  echo "MODE=base META=${latest_meta}"
  exit 0
fi

slot="$(cat "${STATE_DIR}/pitr_slot" 2>/dev/null || echo 0)"
[[ "$slot" =~ ^[0-9]+$ ]] || slot=0
slot=$(( slot % PITR_SLOTS + 1 ))
save "$slot" "${STATE_DIR}/pitr_slot"

# Точка слота n из N: base + (last-base) * n/N. Последний слот чуть раньше
# конца диапазона (-30с), чтобы не упереться в ещё не доехавший сегмент.
span=$(( last_wal_epoch - base_epoch ))
target_epoch=$(( base_epoch + span * slot / PITR_SLOTS ))
(( slot == PITR_SLOTS )) && target_epoch=$(( target_epoch - 30 ))

echo "MODE=pitr META=${latest_meta} TARGET_TIME=$(date -u -d "@${target_epoch}" '+%Y-%m-%d %H:%M:%S+00') SLOT=${slot}/${PITR_SLOTS}"
