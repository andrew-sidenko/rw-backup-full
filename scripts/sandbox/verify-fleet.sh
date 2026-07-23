#!/usr/bin/env bash
# verify-fleet.sh — проверка бэкапов ВСЕГО ПАРКА: каждый подключенный сервер ×
# каждое его S3-хранилище × каждая категория — отдельной проверкой.
#
# Все параметры извлекаются из веб-сервиса автоматически (/api/fleet/manifest):
# реквизиты каждого хранилища, инстансы с типами, Telegram-настройки каждого
# сервера. На песочнице руками ничего не настраивается — добавили сервер в
# веб-интерфейсе, и его бэкапы проверяются со следующего прогона.
#
# Проверяемые параметры зависят от ТИПА БД (panel / bot / site / ...):
# профили в verify-profiles.d/<тип>.env (обязательные таблицы, минимумы,
# произвольные SQL-проверки, глубокие проверки).
#
# Сервер посвящён песочнице — ресурсы можно утилизировать:
#   settings.parallel  — сколько проверок одновременно
#   settings.depth     — quick | standard | deep
#   settings.history   — сколько последних архивов на источник (deep)
# Настройки живут в fleet.json (правятся через веб-API или напрямую).
#
# CLI: verify-fleet.sh [--server ID] [--backend NAME] [--depth quick|standard|deep]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

PROFILES_DIR="${PROFILES_DIR:-${INSTALL_DIR}/verify-profiles.d}"
WEB_ENV="${WEB_ENV:-/etc/rw-backup-web.env}"
WEB_URL="${RW_WEB_URL:-http://127.0.0.1:8787}"
SANDBOX_WORK="${SANDBOX_WORK:-/var/lib/rw-wal/fleet-verify}"
RESULTS_DIR="${SANDBOX_WORK}/results.$$"

ONLY_SERVER=""; ONLY_BACKEND=""; DEPTH_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)  ONLY_SERVER="$2"; shift 2 ;;
    --backend) ONLY_BACKEND="$2"; shift 2 ;;
    --depth)   DEPTH_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) msg ERR "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { msg ERR "Нужен jq (apt install jq)"; exit 1; }
command -v curl >/dev/null 2>&1 || { msg ERR "Нужен curl"; exit 1; }

wal_lock "fleet-verify" || exit 0
mkdir -p "$RESULTS_DIR"
cleanup() {
  docker ps -aq -f "label=rw-fleet-session=$$" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "${SANDBOX_WORK:?}/work.$$" "$RESULTS_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Манифест парка из веб-сервиса
# --------------------------------------------------------------------------
TOKEN="${WEB_TOKEN:-}"
if [[ -z "$TOKEN" && -f "$WEB_ENV" ]]; then
  TOKEN="$(grep -E '^WEB_TOKEN=' "$WEB_ENV" | head -n1 | cut -d= -f2- || true)"
fi
[[ -n "$TOKEN" ]] || { msg ERR "WEB_TOKEN не найден (${WEB_ENV})"; exit 1; }

MANIFEST="$(curl -fsS -m 300 -H "x-token: ${TOKEN}" "${WEB_URL}/api/fleet/manifest?force=1")" \
  || { msg ERR "Веб-сервис недоступен: ${WEB_URL}. Песочница проверяет парк по его данным."; exit 1; }

DEPTH="${DEPTH_OVERRIDE:-$(jq -r '.settings.depth // "standard"' <<<"$MANIFEST")}"
PARALLEL="$(jq -r '.settings.parallel // 2' <<<"$MANIFEST")"
HISTORY="$(jq -r '.settings.history // 1' <<<"$MANIFEST")"
[[ "$PARALLEL" =~ ^[0-9]+$ ]] && (( PARALLEL >= 1 )) || PARALLEL=2
[[ "$HISTORY" =~ ^[0-9]+$ ]] && (( HISTORY >= 1 )) || HISTORY=1
[[ "$DEPTH" == "deep" && "$HISTORY" -lt 2 ]] && HISTORY=2

msg INFO "Fleet-verify: depth=${DEPTH}, parallel=${PARALLEL}, history=${HISTORY}"
msg INFO "Серверов в манифесте: $(jq '.servers | length' <<<"$MANIFEST")"

# --------------------------------------------------------------------------
# Профиль типа: загрузка в PROFILE_* (defaults для неизвестных типов)
# --------------------------------------------------------------------------
load_profile() { # <kind>
  PROFILE_REQUIRED_TABLES=""; PROFILE_MIN_TABLES="1"; PROFILE_MIN_TOTAL_ROWS="1"
  PROFILE_CHECK_QUERIES=""; PROFILE_DEEP_AMCHECK="false"
  local f="${PROFILES_DIR}/$1.env"
  if [[ -f "$f" ]]; then
    set +u; # shellcheck disable=SC1090
    source "$f"; set -u
  fi
}

# --------------------------------------------------------------------------
# aws в контексте бэкенда из манифеста (без файлов на диске)
# --------------------------------------------------------------------------
maws() { # maws <backend_json> <aws args...>
  local bj="$1"; shift
  local ep; ep="$(jq -r '.endpoint // ""' <<<"$bj")"
  local -a epa=(); [[ -n "$ep" ]] && epa=(--endpoint-url "$ep")
  AWS_ACCESS_KEY_ID="$(jq -r .access_key <<<"$bj")" \
  AWS_SECRET_ACCESS_KEY="$(jq -r .secret_key <<<"$bj")" \
  AWS_DEFAULT_REGION="$(jq -r '.region // "us-east-1"' <<<"$bj")" \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
  aws "$@" "${epa[@]}"
}

tg_send() { # tg_send <token> <chat> <text>
  [[ -n "$1" && -n "$2" ]] || return 0
  curl -sS -m 30 "https://api.telegram.org/bot$1/sendMessage" \
    -d "chat_id=$2" --data-urlencode "text=$3" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Проверка одного логического архива (восстановление + профиль типа)
# result-файл: OK|FAIL <строка отчёта>
# --------------------------------------------------------------------------
check_logical_archive() { # <src> <backend_json> <category> <kind> <s3key> <result_file>
  local src="$1" bj="$2" category="$3" kind="$4" key="$5" rf="$6"
  local bname bucket t0 t1
  bname="$(jq -r .name <<<"$bj")"; bucket="$(jq -r .bucket <<<"$bj")"
  t0="$(date +%s)"

  local wd="${SANDBOX_WORK}/work.$$/${src}_${bname}_${category}_$(basename "$key" | tr -c 'a-zA-Z0-9' '_')"
  mkdir -p "$wd"
  local fname; fname="$(basename "$key")"

  fail() { echo "FAIL [${src} × ${bname}] ${category}: $1" > "$rf"; rm -rf "$wd"; }

  maws "$bj" s3 cp "s3://${bucket}/${key}" "${wd}/${fname}" --only-show-errors 2>/dev/null \
    || { fail "не скачался ${fname}"; return; }

  if [[ "$fname" == *.age ]]; then
    if [[ -n "${SANDBOX_AGE_IDENTITY:-}" && -f "${SANDBOX_AGE_IDENTITY:-}" ]]; then
      age -d -i "$SANDBOX_AGE_IDENTITY" < "${wd}/${fname}" > "${wd}/${fname%.age}" \
        || { fail "ошибка расшифровки"; return; }
      fname="${fname%.age}"
    else
      fail "зашифрован, SANDBOX_AGE_IDENTITY не задан"; return
    fi
  fi

  gzip -t "${wd}/${fname}" 2>/dev/null || { fail "битый gzip"; return; }
  local x="${wd}/x"; mkdir -p "$x"
  tar -xzf "${wd}/${fname}" -C "$x" 2>/dev/null || { fail "не распаковался"; return; }
  local dump
  dump="$(find "$x" -maxdepth 1 \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1)"
  [[ -n "$dump" ]] || { fail "нет SQL-дампа в архиве"; return; }

  # Временный postgres
  local c="rw-fleet-$$-$(tr -dc a-z0-9 </dev/urandom | head -c6)"
  docker run -d --rm --name "$c" --label "rw-fleet-session=$$" \
    -e POSTGRES_PASSWORD=sandbox -e POSTGRES_HOST_AUTH_METHOD=trust \
    "postgres:${SANDBOX_PG_VERSION:-17}-alpine" >/dev/null 2>&1 \
    || { fail "sandbox-postgres не создался"; return; }
  local up=false
  for _ in $(seq 1 60); do
    docker exec "$c" pg_isready -U postgres >/dev/null 2>&1 && { up=true; break; }; sleep 1
  done
  [[ "$up" == true ]] || { docker rm -f "$c" >/dev/null 2>&1; fail "postgres не поднялся"; return; }
  sleep 2

  local errs
  errs="$(gzip -dc "$dump" | docker exec -i "$c" psql -q -U postgres -d postgres -v ON_ERROR_STOP=0 2>&1 \
    | grep -cE '^ERROR' || true)"

  # Целевая БД: где появились пользовательские таблицы
  local db="postgres" tables=0 rows=0 d
  for d in postgres $(docker exec "$c" psql -qtAX -U postgres -d postgres \
      -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname<>'postgres'" 2>/dev/null); do
    tables="$(docker exec "$c" psql -qtAX -U postgres -d "$d" -c "SELECT count(*) FROM pg_stat_user_tables" 2>/dev/null || echo 0)"
    if [[ "${tables:-0}" =~ ^[0-9]+$ ]] && (( tables > 0 )); then db="$d"; break; fi
  done
  rows="$(docker exec "$c" psql -qtAX -U postgres -d "$db" -c "SELECT coalesce(sum(n_live_tup),0)::bigint FROM pg_stat_user_tables" 2>/dev/null || echo 0)"

  # ---- Профиль типа ----
  load_profile "$kind"
  local prof_fail="" tbl cnt
  if (( tables < ${PROFILE_MIN_TABLES:-1} )); then prof_fail+=" таблиц=${tables}<${PROFILE_MIN_TABLES}"; fi
  if (( rows < ${PROFILE_MIN_TOTAL_ROWS:-1} )); then prof_fail+=" строк=${rows}<${PROFILE_MIN_TOTAL_ROWS}"; fi
  for tbl in ${PROFILE_REQUIRED_TABLES:-}; do
    cnt="$(docker exec "$c" psql -qtAX -U postgres -d "$db" -c "SELECT count(*) FROM ${tbl}" 2>/dev/null || echo FAIL)"
    if [[ "$cnt" == "FAIL" ]]; then prof_fail+=" ${tbl}:отсутствует"
    elif [[ "$cnt" == "0" ]]; then prof_fail+=" ${tbl}:пустая"; fi
  done
  local line qname sql qmin val
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    qname="${line%%::*}"; sql="${line#*::}"; qmin="${sql##*::}"; sql="${sql%::*}"
    val="$(docker exec "$c" psql -qtAX -U postgres -d "$db" -c "$sql" 2>/dev/null || echo FAIL)"
    if [[ "$val" == "FAIL" ]] || ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < qmin )); then
      prof_fail+=" ${qname}:${val}<${qmin}"
    fi
  done <<<"${PROFILE_CHECK_QUERIES:-}"

  # ---- Глубокие проверки ----
  local deep_note=""
  if [[ "$DEPTH" == "deep" ]]; then
    local dump_bytes
    dump_bytes="$(docker exec "$c" pg_dumpall -U postgres 2>/dev/null | wc -c || echo 0)"
    (( dump_bytes < 1024 )) && prof_fail+=" deep-dumpall:${dump_bytes}b"
    if truthy "${PROFILE_DEEP_AMCHECK:-false}" && docker exec "$c" sh -c 'command -v pg_amcheck' >/dev/null 2>&1; then
      docker exec "$c" pg_amcheck -U postgres -d "$db" >/dev/null 2>&1 \
        && deep_note+=" amcheck:ok" || prof_fail+=" amcheck:FAIL"
    fi
  fi

  docker rm -f "$c" >/dev/null 2>&1 || true
  rm -rf "$wd"
  t1="$(date +%s)"

  if [[ -z "$prof_fail" ]]; then
    echo "OK [${src} × ${bname}] ${category}(${kind}): $(basename "$key") — таблиц=${tables}, строк=${rows}, sql-err=${errs}${deep_note}, $((t1-t0))s" > "$rf"
  else
    echo "FAIL [${src} × ${bname}] ${category}(${kind}): $(basename "$key") —${prof_fail}" > "$rf"
  fi
}

# --------------------------------------------------------------------------
# Постановка задач: source × backend × category (× history)
# --------------------------------------------------------------------------
JOBS="${SANDBOX_WORK}/jobs.$$"; : > "$JOBS"
job_id=0

queue_check() { # <server_id> <src> <backend_json> <category> <kind>
  local sid="$1" src="$2" bj="$3" category="$4" kind="$5"
  local bname bucket prefix
  bname="$(jq -r .name <<<"$bj")"; bucket="$(jq -r .bucket <<<"$bj")"
  prefix="$(jq -r '.prefix // "rw-backup-full"' <<<"$bj")"; prefix="${prefix#/}"; prefix="${prefix%/}"

  local keys
  keys="$(maws "$bj" s3 ls "s3://${bucket}/${prefix}/${category}/${src}/" --recursive 2>/dev/null \
    | awk '{print $1" "$2" "$4}' | sort | tail -n "$HISTORY" | awk '{print $3}')"
  if [[ -z "$keys" ]]; then
    echo "FAIL [${src} × ${bname}] ${category}: архивов нет в этом хранилище" > "${RESULTS_DIR}/r$((job_id++))"
    return
  fi
  local key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$src" "$category" "$kind" "$key" "${RESULTS_DIR}/r$((job_id++))" "$bj" >> "$JOBS"
  done <<<"$keys"
}

servers_json="$(jq -c '.servers[]' <<<"$MANIFEST")"
while IFS= read -r srv; do
  sid="$(jq -r .id <<<"$srv")"
  [[ -n "$ONLY_SERVER" && "$sid" != "$ONLY_SERVER" ]] && continue
  if [[ "$(jq -r .reachable <<<"$srv")" != "true" ]]; then
    echo "FAIL [${sid}] сервер недоступен: $(jq -r '.error // "?"' <<<"$srv")" > "${RESULTS_DIR}/r$((job_id++))"
    continue
  fi
  src="$(jq -r .source <<<"$srv")"

  # Типы инстансов сервера: panel-инстанс задаёт тип панельных архивов,
  # прочие типы применяются к архивам ботов (custom-bot).
  bot_kind="$(jq -r '[.instances[] | select(.kind != "panel") | .kind] | first // "bot"' <<<"$srv")"

  while IFS= read -r bj; do
    [[ -n "$bj" ]] || continue
    bname="$(jq -r .name <<<"$bj")"
    [[ -n "$ONLY_BACKEND" && "$bname" != "$ONLY_BACKEND" ]] && continue
    [[ "$(jq -r .enabled <<<"$bj")" == "true" ]] || continue
    [[ "$(jq -r .panel  <<<"$bj")" == "true" ]] && queue_check "$sid" "$src" "$bj" "panel" "panel"
    [[ "$(jq -r .custom <<<"$bj")" == "true" ]] && queue_check "$sid" "$src" "$bj" "custom-bot" "$bot_kind"
  done < <(jq -c '.backends[]?' <<<"$srv")
done <<<"$servers_json"

total_jobs="$(wc -l < "$JOBS" | tr -d ' ')"
msg INFO "Проверок в очереди: ${total_jobs} (+ $(ls "$RESULTS_DIR" 2>/dev/null | wc -l) мгновенных отказов)"

# --------------------------------------------------------------------------
# Параллельное исполнение
# --------------------------------------------------------------------------
export -f check_logical_archive load_profile maws truthy msg
export SANDBOX_WORK RESULTS_DIR PROFILES_DIR DEPTH SANDBOX_PG_VERSION="${SANDBOX_PG_VERSION:-17}" \
       SANDBOX_AGE_IDENTITY="${SANDBOX_AGE_IDENTITY:-}"

run_one_job() {
  local line="$1" src category kind key rf bj
  IFS=$'\t' read -r src category kind key rf bj <<<"$line"
  check_logical_archive "$src" "$bj" "$category" "$kind" "$key" "$rf"
}
export -f run_one_job

if (( total_jobs > 0 )); then
  # -d '\n': строка задания передаётся аргументом целиком, кавычки JSON не съедаются
  # shellcheck disable=SC2016
  xargs -d '\n' -P "$PARALLEL" -I{} -a "$JOBS" bash -c 'run_one_job "$1"' _ {} || true
fi

# --------------------------------------------------------------------------
# Итоги: per-server отчёты (в TG каждого сервера) + сводка + метрики
# --------------------------------------------------------------------------
TOTAL=0; PASSED=0; SUMMARY=""
declare -A SRV_REPORT SRV_FAIL

for rf in "$RESULTS_DIR"/r*; do
  [[ -e "$rf" ]] || continue
  line="$(cat "$rf")"
  TOTAL=$((TOTAL+1))
  src_tag="$(sed -n 's/^[A-Z]* \[\([^ ×]*\).*/\1/p' <<<"$line")"
  if [[ "$line" == OK* ]]; then
    PASSED=$((PASSED+1)); SUMMARY+=$'\n'"✅ ${line#OK }"
    SRV_REPORT[$src_tag]+=$'\n'"✅ ${line#OK }"
  else
    SUMMARY+=$'\n'"❌ ${line#FAIL }"
    SRV_REPORT[$src_tag]+=$'\n'"❌ ${line#FAIL }"
    SRV_FAIL[$src_tag]=1
  fi
done

# Метрики: матрица source×backend×category
{
  echo "# HELP rw_fleet_verify_ok Результат проверки (1 — успех) по серверу×хранилищу×категории."
  echo "# TYPE rw_fleet_verify_ok gauge"
  for rf in "$RESULTS_DIR"/r*; do
    [[ -e "$rf" ]] || continue
    line="$(cat "$rf")"
    v=0; [[ "$line" == OK* ]] && v=1
    if [[ "$line" == *"×"* ]]; then
      src_l="$(sed -n 's/^[A-Z]* \[\([^ ]*\) ×.*/\1/p' <<<"$line")"
      b_l="$(sed -n 's/^[A-Z]* \[[^×]*× \([^]]*\)\].*/\1/p' <<<"$line")"
      c_l="$(sed -n 's/^[A-Z]* \[[^]]*\] \([a-z-]*\).*/\1/p' <<<"$line")"
      echo "rw_fleet_verify_ok{source=\"${src_l:-?}\",backend=\"${b_l:-?}\",category=\"${c_l:-?}\"} ${v}"
    else
      srv_l="$(sed -n 's/^[A-Z]* \[\([^]]*\)\].*/\1/p' <<<"$line")"
      echo "rw_fleet_server_reachable{server=\"${srv_l:-?}\"} ${v}"
    fi
  done
  echo "# HELP rw_fleet_verify_checks_total Всего проверок за прогон."
  echo "# TYPE rw_fleet_verify_checks_total gauge"
  echo "rw_fleet_verify_checks_total ${TOTAL}"
  echo "rw_fleet_verify_checks_passed ${PASSED}"
  echo "rw_fleet_verify_last_run_timestamp_seconds $(date +%s)"
} | wal_metric_write "rw_fleet_verify"

status_icon="🟢"; (( PASSED < TOTAL )) && status_icon="🔴"
(( TOTAL == 0 )) && status_icon="⚪"
head_line="${status_icon} Fleet-verify: ${PASSED}/${TOTAL} (depth=${DEPTH})"

echo "========================================"
echo "${head_line}"
echo "${SUMMARY}"
echo "========================================"

# Персональные отчёты — в Telegram каждого сервера (настройки из манифеста)
while IFS= read -r srv; do
  src="$(jq -r '.source // .id' <<<"$srv")"
  [[ -n "${SRV_REPORT[$src]:-}" ]] || continue
  tgt="$(jq -r '.telegram.token // ""' <<<"$srv")"
  tgc="$(jq -r '.telegram.chat_id // ""' <<<"$srv")"
  icon="🟢"; [[ -n "${SRV_FAIL[$src]:-}" ]] && icon="🔴"
  tg_send "$tgt" "$tgc" "${icon} Проверка бэкапов ${src} (песочница)${SRV_REPORT[$src]}"
done <<<"$servers_json"

# Сводка — в TG песочницы (fleet.json settings.tg_summary)
sum_t="$(jq -r '.settings.tg_summary.token // ""' <<<"$MANIFEST")"
sum_c="$(jq -r '.settings.tg_summary.chat_id // ""' <<<"$MANIFEST")"
tg_send "$sum_t" "$sum_c" "${head_line}${SUMMARY}"

(( TOTAL > 0 && PASSED == TOTAL ))
