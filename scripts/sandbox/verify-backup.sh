#!/usr/bin/env bash
# verify-backup.sh — автоматическая проверка бэкапов «на функциональность».
#
# Предназначен для запуска на ОТДЕЛЬНОМ сервере-песочнице (но работает и на
# проде с ключом --local). Серверу-песочнице нужны только: docker, awscli,
# доступ к S3-бакету на чтение и этот проект. Доступ к проду не нужен —
# проверяется именно то, что реально лежит в S3, то есть то, чем вы будете
# восстанавливаться в аварии.
#
# Что проверяется:
#   1. PITR-цепочка (basebackup + WAL): свежий базовый бэкап скачивается из S3,
#      проигрывается весь WAL, поднимается временный postgres, выполняются
#      контрольные запросы (INST_VERIFY_TABLES), pg_dumpall как smoke-тест.
#   2. Логические архивы (remnawave_backup_*.tar.gz, custom_bot_*.tar.gz):
#      дамп из архива заливается в чистый временный postgres.
#
# Результат: метрики в textfile collector + отчёт в Telegram.
#
# CLI:
#   verify-backup.sh                  # все инстансы из instances.d + логические архивы
#   verify-backup.sh --instance panel # только один инстанс
#   verify-backup.sh --skip-logical   # только PITR-цепочки
#   verify-backup.sh --local          # PITR из локального архива (запуск на проде)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

ONLY_INSTANCE=""
SKIP_LOGICAL="false"
SKIP_PITR="false"
FROM="s3"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)     ONLY_INSTANCE="$2"; shift 2 ;;
    --skip-logical) SKIP_LOGICAL="true"; shift ;;
    --skip-pitr)    SKIP_PITR="true"; shift ;;
    --local)        FROM="local"; shift ;;
    -h|--help)      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) msg ERR "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

wal_load_full_config
wal_lock "sandbox-verify" || exit 0

SANDBOX_WORK="${SANDBOX_WORK:-/var/lib/rw-wal/sandbox}"
mkdir -p "$SANDBOX_WORK"

REPORT=""
TOTAL=0
PASSED=0

add_result() {
  # add_result <ok|fail> <строка отчёта>
  TOTAL=$((TOTAL + 1))
  if [[ "$1" == "ok" ]]; then
    PASSED=$((PASSED + 1))
    REPORT+=$'\n'"✅ $2"
  else
    REPORT+=$'\n'"❌ $2"
  fi
}

cleanup_all() {
  # Гарантированная уборка временных контейнеров и каталогов этой сессии.
  docker ps -aq -f "label=rw-sandbox-session=$$" 2>/dev/null \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "${SANDBOX_WORK:?}/run_$$" 2>/dev/null || true
}
trap cleanup_all EXIT

# --------------------------------------------------------------------------
# Проверка PITR-цепочки одного инстанса
# --------------------------------------------------------------------------
verify_pitr_instance() {
  local inst="$1"
  local t0 t1 rows_report=""
  t0="$(date +%s)"

  msg INFO "=== PITR-проверка: ${inst} (источник: ${FROM}) ==="

  if ! wal_load_instance "$inst"; then
    add_result fail "PITR ${inst}: конфиг инстанса не загрузился"
    return
  fi

  local wd="${SANDBOX_WORK}/run_$$/${inst}"
  mkdir -p "$wd"

  # pitr-restore.sh делает всё: скачивание, распаковку, проверку SHA256,
  # стейджинг WAL, временный контейнер, ожидание конца recovery.
  local -a args=("$inst" --target latest --work-dir "$wd" --keep-running)
  [[ "$FROM" == "s3" ]] && args+=(--from s3)
  if [[ -n "${SANDBOX_AGE_IDENTITY:-}" && -f "${SANDBOX_AGE_IDENTITY:-}" ]]; then
    args+=(--age-identity "$SANDBOX_AGE_IDENTITY")
  fi

  if ! "${SCRIPT_DIR}/../wal/pitr-restore.sh" "${args[@]}" > "${wd}/restore.log" 2>&1; then
    add_result fail "PITR ${inst}: восстановление не удалось ($(tail -n 2 "${wd}/restore.log" | head -n 1 | cut -c1-120))"
    wal_metric_pitr "$inst" 0 0
    return
  fi

  local container port
  container="$(cat "${wd}/container" 2>/dev/null || true)"
  port="$(cat "${wd}/port" 2>/dev/null || true)"
  docker update --label-add "rw-sandbox-session=$$" "$container" >/dev/null 2>&1 || \
    docker container update "$container" >/dev/null 2>&1 || true

  if [[ -z "$container" ]] || ! docker ps -q -f "name=${container}" | grep -q .; then
    add_result fail "PITR ${inst}: контейнер восстановления не запущен"
    wal_metric_pitr "$inst" 0 0
    return
  fi

  local q_ok=true

  # 1. Базовая живость и консистентность
  if ! docker exec "$container" psql -h localhost -U "$INST_PGUSER" -d "$INST_PGDATABASE" \
      -qtAX -c "SELECT 1" >/dev/null 2>&1; then
    q_ok=false
    rows_report+=" SELECT1:fail"
  fi

  # 2. Контрольные таблицы: count(*) по каждой из INST_VERIFY_TABLES
  local tbl cnt
  for tbl in ${INST_VERIFY_TABLES:-}; do
    cnt="$(docker exec "$container" psql -h localhost -U "$INST_PGUSER" -d "$INST_PGDATABASE" \
      -qtAX -c "SELECT count(*) FROM ${tbl}" 2>/dev/null || echo FAIL)"
    if [[ "$cnt" == "FAIL" ]]; then
      q_ok=false
      rows_report+=" ${tbl}:fail"
    else
      rows_report+=" ${tbl}=${cnt}"
      # Пустая ключевая таблица — подозрительно: бэкап «поднялся», но данных нет.
      if [[ "$cnt" == "0" ]]; then
        rows_report+="(ПУСТО!)"
        q_ok=false
      fi
    fi
  done

  # 3. Полный логический проход: pg_dumpall всей восстановленной БД.
  #    Ловит битые страницы/каталоги, которые не видны через count(*).
  local dump_bytes=0
  dump_bytes="$(docker exec "$container" pg_dumpall -h localhost -U "$INST_PGUSER" 2>/dev/null | wc -c || echo 0)"
  if (( dump_bytes < 1024 )); then
    q_ok=false
    rows_report+=" dumpall:${dump_bytes}b(fail)"
  else
    rows_report+=" dumpall:$((dump_bytes / 1024))KB"
  fi

  # 4. Возраст точки восстановления: насколько «свежий» WAL доехал.
  local last_replay age_h="?"
  last_replay="$(docker exec "$container" psql -h localhost -U "$INST_PGUSER" -d "$INST_PGDATABASE" \
    -qtAX -c "SELECT extract(epoch FROM now() - pg_postmaster_start_time())::int" 2>/dev/null || true)"
  # Более полезная метрика — время создания базового бэкапа из meta:
  if [[ -f "${wd}/backup.meta" ]]; then
    local created
    created="$(grep -E '^CREATED_EPOCH=' "${wd}/backup.meta" | cut -d'"' -f2)"
    [[ -n "$created" ]] && age_h="$(( ($(date +%s) - created) / 3600 ))"
  fi

  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$wd"

  t1="$(date +%s)"
  if [[ "$q_ok" == "true" ]]; then
    add_result ok "PITR ${inst}: восстановление+WAL за $((t1 - t0))s, базовому бэкапу ${age_h}ч;${rows_report}"
    wal_metric_pitr "$inst" 1 "$((t1 - t0))"
  else
    add_result fail "PITR ${inst}:${rows_report}"
    wal_metric_pitr "$inst" 0 "$((t1 - t0))"
  fi
}

wal_metric_pitr() {
  local inst="$1" ok="$2" dur="$3"
  wal_metric_write "rw_sandbox_pitr_${inst}" <<EOF_M
# HELP rw_sandbox_pitr_last_ok Результат последней PITR-проверки (1 — успех).
# TYPE rw_sandbox_pitr_last_ok gauge
rw_sandbox_pitr_last_ok{instance="${inst}"} ${ok}
# HELP rw_sandbox_pitr_last_timestamp_seconds Время последней PITR-проверки.
# TYPE rw_sandbox_pitr_last_timestamp_seconds gauge
rw_sandbox_pitr_last_timestamp_seconds{instance="${inst}"} $(date +%s)
# HELP rw_sandbox_pitr_duration_seconds Длительность последней PITR-проверки.
# TYPE rw_sandbox_pitr_duration_seconds gauge
rw_sandbox_pitr_duration_seconds{instance="${inst}"} ${dur}
EOF_M
}

# --------------------------------------------------------------------------
# Проверка логического архива (remnawave_backup_* / custom_bot_*)
# --------------------------------------------------------------------------
verify_logical_archive() {
  local category="$1"   # panel | custom-bot
  local t0 t1
  t0="$(date +%s)"

  # Первый включённый бэкенд с этой категорией.
  local backend="" n
  for n in $(s3m_backends); do
    s3m_load "$n" 2>/dev/null || continue
    truthy "$B_ENABLED" || continue
    s3m_category_enabled "$category" && { backend="$n"; break; }
  done
  if [[ -z "$backend" ]]; then
    add_result fail "Логический ${category}: нет S3-бэкенда с этой категорией"
    return
  fi

  # Свежий архив категории по всем хостам.
  local latest_key
  latest_key="$(s3m_aws s3 ls "s3://${B_BUCKET}/${B_PREFIX}/${category}/" --recursive 2>/dev/null \
    | awk '{print $1" "$2" "$4}' | sort | tail -n1 | awk '{print $3}')"

  if [[ -z "$latest_key" ]]; then
    add_result fail "Логический ${category}: в S3 нет архивов"
    return
  fi

  local wd="${SANDBOX_WORK}/run_$$/logical_${category}"
  mkdir -p "$wd"
  local fname; fname="$(basename "$latest_key")"

  msg INFO "=== Логическая проверка: ${fname} ==="

  if ! s3m_aws s3 cp "s3://${B_BUCKET}/${latest_key}" "${wd}/${fname}" --only-show-errors; then
    add_result fail "Логический ${category}: не скачался ${fname}"
    return
  fi

  local work="${wd}/x"; mkdir -p "$work"
  local dump=""

  if [[ "$fname" == *.age ]]; then
    if [[ -n "${SANDBOX_AGE_IDENTITY:-}" && -f "${SANDBOX_AGE_IDENTITY:-}" ]]; then
      age -d -i "$SANDBOX_AGE_IDENTITY" < "${wd}/${fname}" > "${wd}/${fname%.age}" || {
        add_result fail "Логический ${category}: ошибка расшифровки ${fname}"; return; }
      fname="${fname%.age}"
    else
      add_result fail "Логический ${category}: ${fname} зашифрован, SANDBOX_AGE_IDENTITY не задан"
      return
    fi
  fi

  tar -xzf "${wd}/${fname}" -C "$work" 2>/dev/null || {
    add_result fail "Логический ${category}: ${fname} не распаковался"; return; }

  # Дамп: у панели dump_*.sql.gz, у бота postgres_dump.sql.gz
  dump="$(find "$work" -maxdepth 1 \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1)"
  [[ -n "$dump" ]] || { add_result fail "Логический ${category}: в ${fname} нет SQL-дампа"; return; }

  gzip -t "$dump" 2>/dev/null || { add_result fail "Логический ${category}: дамп в ${fname} повреждён (gzip)"; return; }

  # Чистый контейнер под заливку дампа.
  local pgimg="postgres:${SANDBOX_PG_VERSION:-17}-alpine"
  local c="rw-sandbox-logical-$$"
  docker run -d --rm --name "$c" --label "rw-sandbox-session=$$" \
    -e POSTGRES_PASSWORD=sandbox -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$pgimg" >/dev/null

  local up=false
  for _ in $(seq 1 60); do
    docker exec "$c" pg_isready -U postgres >/dev/null 2>&1 && { up=true; break; }
    sleep 1
  done
  [[ "$up" == "true" ]] || { add_result fail "Логический ${category}: sandbox-postgres не поднялся"; return; }
  sleep 2

  # Заливка. ON_ERROR_STOP=0: dumpall содержит DROP ROLE postgres и подобное,
  # безвредные ошибки допустимы — важен итог.
  local errs
  errs="$(gzip -dc "$dump" | docker exec -i "$c" psql -q -U postgres -d postgres -v ON_ERROR_STOP=0 2>&1 \
    | grep -cE '^ERROR' || true)"

  # Итог: есть ли непустые пользовательские таблицы.
  local tables user_rows
  tables="$(docker exec "$c" psql -qtAX -U postgres -d postgres -c \
    "SELECT count(*) FROM pg_stat_user_tables" 2>/dev/null || echo 0)"
  user_rows="$(docker exec "$c" psql -qtAX -U postgres -d postgres -c \
    "SELECT coalesce(sum(n_live_tup),0) FROM pg_stat_user_tables" 2>/dev/null || echo 0)"

  # Дампы ботов могут разворачиваться в отдельные БД — проверим и их.
  if [[ "${tables:-0}" == "0" ]]; then
    local db
    for db in $(docker exec "$c" psql -qtAX -U postgres -d postgres -c \
        "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'" 2>/dev/null); do
      tables="$(docker exec "$c" psql -qtAX -U postgres -d "$db" -c \
        "SELECT count(*) FROM pg_stat_user_tables" 2>/dev/null || echo 0)"
      user_rows="$(docker exec "$c" psql -qtAX -U postgres -d "$db" -c \
        "SELECT coalesce(sum(n_live_tup),0) FROM pg_stat_user_tables" 2>/dev/null || echo 0)"
      [[ "${tables:-0}" != "0" ]] && break
    done
  fi

  docker rm -f "$c" >/dev/null 2>&1 || true
  rm -rf "$wd"
  t1="$(date +%s)"

  local ok=1
  if [[ "${tables:-0}" =~ ^[0-9]+$ ]] && (( tables > 0 )); then
    add_result ok "Логический ${category}: $(basename "$latest_key") — таблиц=${tables}, строк≈${user_rows}, sql-ошибок=${errs}, $((t1 - t0))s"
  else
    ok=0
    add_result fail "Логический ${category}: $(basename "$latest_key") — после restore нет пользовательских таблиц"
  fi

  wal_metric_write "rw_sandbox_logical_${category//-/_}" <<EOF_M
# HELP rw_sandbox_logical_last_ok Результат проверки логического архива (1 — успех).
# TYPE rw_sandbox_logical_last_ok gauge
rw_sandbox_logical_last_ok{category="${category}"} ${ok}
# HELP rw_sandbox_logical_last_timestamp_seconds Время последней проверки.
# TYPE rw_sandbox_logical_last_timestamp_seconds gauge
rw_sandbox_logical_last_timestamp_seconds{category="${category}"} $(date +%s)
EOF_M
}

# --------------------------------------------------------------------------
# Основной цикл
# --------------------------------------------------------------------------
if [[ "$FROM" == "s3" ]] && [[ -z "$(s3m_backends | head -n1)" ]]; then
  msg ERR "Ни одного S3-бэкенда (s3.d/*.env или FULL_EXTERNAL_S3_*) — песочнице нечего проверять"
  exit 1
fi

if [[ "$SKIP_PITR" != "true" ]]; then
  if [[ -n "$ONLY_INSTANCE" ]]; then
    verify_pitr_instance "$ONLY_INSTANCE"
  else
    found=0
    while IFS= read -r inst; do
      [[ -n "$inst" ]] || continue
      found=1
      verify_pitr_instance "$inst"
    done < <(wal_list_instances)
    (( found == 1 )) || msg WARN "instances.d пуст — PITR-проверки пропущены"
  fi
fi

if [[ "$SKIP_LOGICAL" != "true" && -z "$ONLY_INSTANCE" && "$FROM" == "s3" ]]; then
  truthy "${SANDBOX_VERIFY_PANEL_LOGICAL:-true}" && verify_logical_archive "panel"
  truthy "${SANDBOX_VERIFY_CUSTOM_LOGICAL:-true}" && verify_logical_archive "custom-bot"
fi

# --------------------------------------------------------------------------
# Отчёт
# --------------------------------------------------------------------------
status_icon="🟢"
(( PASSED < TOTAL )) && status_icon="🔴"
(( TOTAL == 0 )) && { status_icon="⚪"; REPORT+=$'\n'"Проверять нечего: нет инстансов и архивов"; }

summary="${status_icon} Проверка бэкапов в песочнице
Хост: $(wal_hostname)
Результат: ${PASSED}/${TOTAL}
${REPORT}"

echo "----------------------------------------"
echo "$summary"
echo "----------------------------------------"

wal_metric_write "rw_sandbox_summary" <<EOF_M
# HELP rw_sandbox_checks_total Всего проверок за последний прогон.
# TYPE rw_sandbox_checks_total gauge
rw_sandbox_checks_total ${TOTAL}
# HELP rw_sandbox_checks_passed Успешных проверок за последний прогон.
# TYPE rw_sandbox_checks_passed gauge
rw_sandbox_checks_passed ${PASSED}
# HELP rw_sandbox_last_run_timestamp_seconds Время последнего прогона песочницы.
# TYPE rw_sandbox_last_run_timestamp_seconds gauge
rw_sandbox_last_run_timestamp_seconds $(date +%s)
EOF_M

# Telegram: при провале — всегда; при успехе — если не отключено.
if (( PASSED < TOTAL )) || truthy "${SANDBOX_NOTIFY_ON_SUCCESS:-true}"; then
  wal_notify "$summary"
fi

(( PASSED == TOTAL && TOTAL > 0 )) && exit 0 || exit 1
