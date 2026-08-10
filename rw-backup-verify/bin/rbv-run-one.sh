#!/usr/bin/env bash
# Один прогон экземпляра с расширенными проверками и TG-отчётом.
# <storage-id> <kind:panel|bot> <instance_id> <s3_key> [parent_dir]
set -euo pipefail
_self="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/checks.sh
source "${SCRIPT_DIR}/../lib/checks.sh"

SID="${1:?storage}"
KIND="${2:?kind}"
INST="${3:?instance}"
KEY="${4:?s3-key}"
PARENT="${5:-}"

rbv_load_config
need docker
need jq
need tar
need gzip

J="$(rbv_storage_json "$SID")"
rbv_aws_env "$J"
WD="$(rbv_work_dir)"
RUN_ID="$(date -u +%Y%m%d_%H%M%S)_$(printf '%s' "$INST" | tr '/:' '__' | cut -c1-80)"
RUN_DIR="${WD}/runs/${RUN_ID}"
# docker compose -p: только [a-z0-9_-], иначе "invalid project name"
COMPOSE_PROJECT="$(printf 'rbv_%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g' | cut -c1-60)"
mkdir -p "$RUN_DIR"
REPORT="${RUN_DIR}/report.txt"
CHECKS_JSON="${RUN_DIR}/checks.json"
: > "$REPORT"
rbv_checks_init "$CHECKS_JSON"

rep() { printf '%s\n' "$*" | tee -a "$REPORT" >&2; }
ok=true
fail_reasons=()

fail_add() {
  ok=false
  fail_reasons+=("$1")
  rep "FAIL $1"
}

PG_CID=""
COMPOSE_FILE=""
NET_NAME=""
KEEP="${KEEP:-false}"
PROJ_DIR=""
COMPOSE_RAW="${RUN_DIR}/compose.raw.json"
USER_ROWS=0
LAST_EVENT=0
CURR_ARCH_EPOCH=0
PREV_ARCH_EPOCH=0
BASELINE_JSON="{}"

cleanup() {
  if [[ "$KEEP" != "true" ]]; then
    if [[ -n "${COMPOSE_FILE}" && -f "${COMPOSE_FILE}" ]]; then
      docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    [[ -n "${NET_NAME}" ]] && docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    [[ -n "${PG_CID}" ]] && docker rm -f "$PG_CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rep "=== rw-backup-verify ==="
rep "storage=${SID} kind=${KIND} instance=${INST}"
rep "key=${KEY} parent=${PARENT}"
rep "started=$(date -Is)"

CURR_ARCH_EPOCH="$(rbv_parse_archive_epoch "$(basename "$KEY")")"
BASELINE_JSON="$(rbv_baseline_load "$SID" "$INST")"
PREV_ARCH_EPOCH="$(jq -r '.archive_ts // 0' <<<"$BASELINE_JSON")"
PREV_USER_ROWS="$(jq -r '.user_rows // empty' <<<"$BASELINE_JSON")"

# --- download / extract -----------------------------------------------------
# Кэш архивов: work_dir/cache/archives/<sid>/<hash>.tar.gz — не качаем повторно.
# Перед скачиванием чистим старые runs/ (архивы уже в cache через hardlink).
ARCH_PATH="${RUN_DIR}/archive.tar.gz"
S3_URI="s3://${RBV_BUCKET}/${KEY}"
_keep_runs="$(rbv_cfg '.runs_keep // 2')"
[[ "$_keep_runs" =~ ^[0-9]+$ ]] || _keep_runs=2
_pruned="$(rbv_runs_prune "$_keep_runs" || echo 0)"
_pruned="$(echo "$_pruned" | tr -d '[:space:]')"
[[ "$_pruned" =~ ^[0-9]+$ ]] || _pruned=0
if (( _pruned > 0 )); then
  rep "disk: удалено старых runs=${_pruned} (keep=${_keep_runs}; архивы в cache)"
fi
rep "disk: $(rbv_disk_report "$WD")"
_avail_kb="$(rbv_disk_avail_kb "$WD")"
if [[ -n "$_avail_kb" && "$_avail_kb" =~ ^[0-9]+$ ]] && (( _avail_kb < 1048576 )); then
  rep "WARN: свободно <1GiB (${_avail_kb} KiB) — restore/PG могут упасть (ENOSPC)"
  rep "  подсказка: rw-backup-verify runs prune --keep 0 && docker system prune -af"
fi

_cache=""
set +e
_cache="$(rbv_cache_ensure "$SID" "$KEY")"
_ce_rc=$?
set -e
if [[ $_ce_rc -eq 0 && -n "$_cache" && -s "$_cache" ]]; then
  rep "download: cache hit $(basename "$KEY") ← ${_cache#"$WD"/}"
  ln -f "$_cache" "$ARCH_PATH" 2>/dev/null || cp -f "$_cache" "$ARCH_PATH"
  if [[ -s "$ARCH_PATH" ]]; then
    rbv_check_add download ok "$(basename "$KEY") (cache)"
  else
    fail_add "download failed (cache copy)"
    rbv_check_add download fail "cache → run copy failed"
  fi
else
  rep "download ${S3_URI}"
  _cache="$(rbv_archive_cache_path "$SID" "$KEY")"
  set +e
  rbv_aws s3 cp "$S3_URI" "$_cache" --only-show-errors 2>"${RUN_DIR}/download.err"
  _dl_rc=$?
  set -e
  if [[ $_dl_rc -ne 0 || ! -s "$_cache" ]]; then
    _err="$(tr '\n' ' ' <"${RUN_DIR}/download.err" 2>/dev/null | head -c 300)"
    if grep -qiE 'No space left|ENOSPC|errno 28' "${RUN_DIR}/download.err" 2>/dev/null; then
      fail_add "download failed: диск заполнен (ENOSPC)"
      rbv_check_add download fail "ENOSPC — runs prune / docker prune"
      rep "  ${_err}"
      rep "  → rw-backup-verify runs prune --keep 0"
      rep "  → docker system prune -af"
    else
      fail_add "download failed"
      rbv_check_add download fail "не скачался ${S3_URI}"
      [[ -n "$_err" ]] && rep "  ${_err}"
    fi
    rm -f "$_cache" 2>/dev/null || true
  else
    printf '%s\n' "$KEY" >"${_cache}.key"
    ln -f "$_cache" "$ARCH_PATH" 2>/dev/null || cp -f "$_cache" "$ARCH_PATH"
    rbv_check_add download ok "$(basename "$KEY")"
  fi
fi

base_name="$(basename "$KEY")"
if [[ "$ok" == true && "$base_name" == *.age ]]; then
  need age
  AGE_ID="$(rbv_cfg '.age_identity // empty')"
  if [[ -z "$AGE_ID" || "$AGE_ID" == "null" ]]; then
    fail_add "age identity unset"
    rbv_check_add decrypt fail "age_identity не задан в конфиге"
  elif ! age -d -i "$AGE_ID" -o "${ARCH_PATH}.dec" "$ARCH_PATH" 2>"${RUN_DIR}/age.err"; then
    fail_add "age decrypt failed"
    rbv_check_add decrypt fail "age -d: $(tr '\n' ' ' <"${RUN_DIR}/age.err" | head -c 200)"
  else
    mv -f "${ARCH_PATH}.dec" "$ARCH_PATH"
    rbv_check_add decrypt ok "age"
  fi
fi

EXTRACT="${RUN_DIR}/extract"
mkdir -p "$EXTRACT"
if [[ "$ok" == true ]]; then
  if ! tar -xzf "$ARCH_PATH" -C "$EXTRACT" 2>"${RUN_DIR}/tar.err"; then
    fail_add "tar extract failed"
  fi
fi

SQL=""
REDIS_RDB=""
PROFILE_ENV=""
PG_VER="$(rbv_cfg '.pg_version // "17"')"
POSTGRES_SERVICE="postgres"
REDIS_SERVICE="redis"
RBV_PG_DB_HINT=""
RBV_PG_DB="postgres"

if [[ "$ok" == true ]]; then
  if [[ "$KIND" == "panel" ]]; then
    SQL="$(find "$EXTRACT" -type f \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1 || true)"
    DIR_TAR="$(find "$EXTRACT" -type f -name 'remnawave_dir_*.tar.gz' | head -n1 || true)"
    if [[ -n "$DIR_TAR" ]]; then
      PROJ_DIR="${RUN_DIR}/project"
      mkdir -p "$PROJ_DIR"
      tar -xzf "$DIR_TAR" -C "$PROJ_DIR" || true
      if [[ "$(find "$PROJ_DIR" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]; then
        inner="$(find "$PROJ_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
        [[ -n "$inner" ]] && PROJ_DIR="$inner"
      fi
    fi
  else
    SQL="$(find "$EXTRACT" -type f -name 'postgres_dump.sql.gz' | head -n1 || true)"
    [[ -n "$SQL" ]] || SQL="$(find "$EXTRACT" -type f -name 'dump_*.sql.gz' | head -n1 || true)"
    REDIS_RDB="$(find "$EXTRACT" -type f -name 'redis_dump.rdb' | head -n1 || true)"
    PROFILE_ENV="$(find "$EXTRACT" -type f -name 'PROFILE.env' | head -n1 || true)"
    DIR_TAR="$(find "$EXTRACT" -type f -name 'project_dir.tar.gz' | head -n1 || true)"
    if [[ -n "$PROFILE_ENV" ]]; then
      set +u
      # shellcheck disable=SC1090
      source "$PROFILE_ENV"
      set -u
      POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
      REDIS_SERVICE="${REDIS_SERVICE:-redis}"
      RBV_PG_DB_HINT="${POSTGRES_DB:-${DB_NAME:-${POSTGRES_DATABASE:-}}}"
      [[ -n "$RBV_PG_DB_HINT" ]] && rep "PROFILE: POSTGRES_DB hint=${RBV_PG_DB_HINT}"
    fi
    if [[ -n "$DIR_TAR" ]]; then
      pe="${RUN_DIR}/project_extract"
      mkdir -p "$pe"
      rep "extract project_dir.tar.gz…"
      tar -xzf "$DIR_TAR" -C "$pe"
      # pipefail+head → SIGPIPE(141) у tar; || true обязателен
      project_top="$(tar -tzf "$DIR_TAR" 2>/dev/null | head -n1 | cut -d/ -f1 || true)"
      if [[ -n "$project_top" && -d "$pe/$project_top" ]]; then
        PROJ_DIR="$pe/$project_top"
      else
        PROJ_DIR="$pe"
      fi
      if [[ -n "$REDIS_RDB" && -f "$REDIS_RDB" ]]; then
        mkdir -p "${PROJ_DIR}/volumes/redis"
        cp -f "$REDIS_RDB" "${PROJ_DIR}/volumes/redis/dump.rdb"
        chmod 644 "${PROJ_DIR}/volumes/redis/dump.rdb" || true
      fi
      rep "project_dir=${PROJ_DIR}"
    fi
  fi
  [[ -n "$SQL" ]] || fail_add "no sql dump"
  [[ -n "$SQL" ]] && rep "sql_dump=$(basename "$SQL") size=$(du -h "$SQL" 2>/dev/null | awk '{print $1}')"
fi

# --- DB restore + data checks -----------------------------------------------
# Большие dump (200–500M gz) на узком хосте часто ловят OOM (rc=137) /
# «server closed». Soft-retry в ту же полумёртвую БД бесполезен — только recreate.
rbv_pg_alive() {
  [[ -n "${PG_CID:-}" ]] || return 1
  docker inspect -f '{{.State.Running}}' "$PG_CID" 2>/dev/null | grep -qx true
}

rbv_pg_diag() {
  local tag="${1:-diag}"
  rep "postgres[${tag}]: --- состояние ---"
  if [[ -n "${PG_CID:-}" ]]; then
    docker inspect -f 'status={{.State.Status}} running={{.State.Running}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}} error={{.State.Error}}' \
      "$PG_CID" 2>/dev/null | while IFS= read -r _line; do rep "  ${_line}"; done || rep "  (inspect недоступен)"
    if docker logs "$PG_CID" >/dev/null 2>&1; then
      rep "  ----- docker logs (tail 25) -----"
      docker logs --tail 25 "$PG_CID" 2>&1 | while IFS= read -r _line; do rep "  ${_line}"; done || true
      rep "  ----- end logs -----"
    fi
  fi
  # память/диск — частая причина 137 / «not ready»
  if command -v free >/dev/null 2>&1; then
    rep "  mem: $(free -m | awk '/Mem:/{printf "avail=%sMi total=%sMi", $7, $2}')"
  fi
  df -h /var/lib/docker 2>/dev/null | tail -n1 | while IFS= read -r _line; do rep "  disk docker: ${_line}"; done || true
}

rbv_pg_start() {
  # $1 — причина (init|retry)
  local why="${1:-init}"
  local wait_s=120
  docker rm -f "$PG_CID" >/dev/null 2>&1 || true
  # чужие rbv_pg_* после OOM/crash занимают RAM
  while IFS= read -r _old; do
    [[ -n "$_old" && "$_old" != "$PG_CID" ]] || continue
    docker rm -f "$_old" >/dev/null 2>&1 || true
  done < <(docker ps -aq --filter "name=rbv_pg_" 2>/dev/null || true)

  rep "postgres: pull/start image=postgres:${PG_VER}-alpine name=${PG_CID} (${why})"
  set +e
  # shm: крупные COPY/CREATE INDEX в restore без --shm-size часто падают
  docker run -d --name "$PG_CID" --shm-size=512m \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    "postgres:${PG_VER}-alpine" >/dev/null
  local run_rc=$?
  set -e
  if [[ $run_rc -ne 0 ]]; then
    rep "postgres: docker run rc=${run_rc}"
    rbv_pg_diag "run-fail"
    return 1
  fi
  if ! rbv_pg_alive; then
    rep "postgres: контейнер сразу не Running"
    rbv_pg_diag "not-running"
    return 1
  fi

  rep "postgres: жду pg_isready (до ${wait_s}с)…"
  local i ready=false
  for i in $(seq 1 "$wait_s"); do
    if docker exec "$PG_CID" pg_isready -U postgres >/dev/null 2>&1; then
      ready=true
      rep "postgres: ready (${i}с)"
      break
    fi
    if ! rbv_pg_alive; then
      rep "postgres: контейнер умер на ожидании ready (${i}с)"
      rbv_pg_diag "died-wait"
      return 1
    fi
    if (( i % 15 == 0 )); then
      rep "postgres: ещё не ready (${i}/${wait_s}с)…"
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    rbv_pg_diag "not-ready"
    return 1
  fi

  rep "postgres: жду SELECT 1…"
  local accept=false
  for i in $(seq 1 60); do
    if docker exec "$PG_CID" psql -U postgres -d postgres -Atc 'SELECT 1' >/dev/null 2>&1; then
      accept=true
      rep "postgres: accepts connections (${i}с)"
      break
    fi
    if ! rbv_pg_alive; then
      rep "postgres: контейнер умер на SELECT 1"
      rbv_pg_diag "died-select"
      return 1
    fi
    sleep 1
  done
  if [[ "$accept" != true ]]; then
    rbv_pg_diag "no-select"
    return 1
  fi
  return 0
}

DB_TABLES=0
if [[ "$ok" == true ]]; then
  PG_CID="rbv_pg_${RUN_ID}"
  ready=false
  accept=false
  if rbv_pg_start init; then
    ready=true
    accept=true
  else
    fail_add "postgres not ready"
  fi

  if [[ "$ok" == true && "$ready" == true && "$accept" == true ]]; then
    sql_sz="$(du -h "$SQL" 2>/dev/null | awk '{print $1}')"
    rep "psql restore: $(basename "$SQL") (${sql_sz}) — может занять минуты"
    (
      t=0
      while sleep 15; do
        t=$((t + 15))
        printf '%s\n' "psql restore: ещё работает… ${t}с" | tee -a "$REPORT" >&2
      done
    ) &
    _hb=$!
    _psql_rc=1
    _max_restore=3
    for _attempt in $(seq 1 "$_max_restore"); do
      if ! rbv_pg_alive; then
        rep "psql restore: PG мёртв перед попыткой ${_attempt}/${_max_restore} — recreate"
        if ! rbv_pg_start "retry-${_attempt}"; then
          _psql_rc=137
          break
        fi
      fi
      : >"${RUN_DIR}/psql.err"
      set +e
      gzip -dc "$SQL" | docker exec -i "$PG_CID" \
        psql -q -U postgres -d postgres -v ON_ERROR_STOP=0 >/dev/null 2>"${RUN_DIR}/psql.err"
      _psql_rc=$?
      set -e

      _oom=false
      docker inspect -f '{{.State.OOMKilled}}' "$PG_CID" 2>/dev/null | grep -qx true && _oom=true
      if [[ $_psql_rc -eq 137 ]] || [[ "$_oom" == true ]] || ! rbv_pg_alive; then
        rep "psql restore: OOM/SIGKILL/dead rc=${_psql_rc} oom=${_oom} (попытка ${_attempt}/${_max_restore})"
        rbv_pg_diag "oom-${_attempt}"
        if (( _attempt < _max_restore )); then
          rep "psql restore: recreate PG и повтор…"
          rbv_pg_start "retry-${_attempt}" || true
          continue
        fi
        break
      fi
      if grep -qiE 'starting up|connection.*failed|server closed|the database system is shutting down' \
           "${RUN_DIR}/psql.err" 2>/dev/null; then
        rep "psql restore: соединение оборвалось (попытка ${_attempt}/${_max_restore}) — recreate"
        rbv_pg_diag "conn-${_attempt}"
        if (( _attempt < _max_restore )); then
          rbv_pg_start "retry-${_attempt}" || true
          continue
        fi
        break
      fi
      # успех или «обычные» ERROR в дампе (DROP ROLE и т.п.) — не ретраим
      break
    done
    kill "$_hb" 2>/dev/null || true
    wait "$_hb" 2>/dev/null || true
    rep "psql restore: rc=${_psql_rc}"
    # grep -c → 0 + exit 1; НЕ делать «|| echo 0» (склеит 00)
    sql_errs="$(grep -cE '^ERROR' "${RUN_DIR}/psql.err" 2>/dev/null || true)"
    sql_errs="$(echo "${sql_errs:-0}" | tr -d '[:space:]')"
    [[ "$sql_errs" =~ ^[0-9]+$ ]] || sql_errs=0
    if (( sql_errs > 0 )); then
      rep "psql restore: ERROR-строк=${sql_errs} (см. ${RUN_DIR}/psql.err)"
    fi

    # Дампы ботов часто создают отдельную БД — ищем таблицы везде
    if rbv_pg_alive; then
      DB_TABLES="$(rbv_select_app_db "${RBV_PG_DB_HINT}")"
      DB_TABLES="$(echo "$DB_TABLES" | tr -d '[:space:]')"
      [[ "$DB_TABLES" =~ ^[0-9]+$ ]] || DB_TABLES=0
    else
      DB_TABLES=0
      RBV_PG_DB="postgres"
      rbv_pg_diag "post-restore-dead"
    fi
    rep "db_schema: db=${RBV_PG_DB:-postgres} user_tables=${DB_TABLES}"
    if (( DB_TABLES < 1 )); then
      dbs="?"
      if rbv_pg_alive; then
        dbs="$(docker exec "$PG_CID" psql -U postgres -d postgres -Atc \
          "SELECT string_agg(datname, ',') FROM pg_database WHERE NOT datistemplate" 2>/dev/null || echo "?")"
      fi
      _extra=""
      [[ ${_psql_rc:-1} -eq 137 ]] && _extra=" OOM/SIGKILL(rc=137)"
      fail_add "empty schema (dbs=${dbs} sql_errors=${sql_errs}${_extra})"
      rbv_check_add db_schema fail "user tables=0 (dbs=${dbs}, sql_errors=${sql_errs}${_extra})"
      if [[ -s "${RUN_DIR}/psql.err" ]]; then
        rep "----- psql.err (tail) -----"
        tail -n 15 "${RUN_DIR}/psql.err" | while IFS= read -r _line; do rep "  ${_line}"; done
        rep "----- end -----"
      fi
    else
      rbv_check_add db_schema ok "db=${RBV_PG_DB} tables=${DB_TABLES}"
    fi

    # user_rows: не пусто + ≥ предыдущей проверки (один toggle)
    if rbv_check_enabled "$KIND" user_rows; then
      utbl="$(rbv_find_users_table || true)"
      if [[ -z "$utbl" ]]; then
        rbv_check_add user_rows skip "таблица users не найдена"
        rep "user_rows: skip (нет таблицы)"
      else
        USER_ROWS="$(rbv_count_table "$utbl" || true)"
        [[ "$USER_ROWS" =~ ^[0-9]+$ ]] || USER_ROWS=0
        if (( USER_ROWS < 1 )); then
          rbv_check_add user_rows fail "users(${utbl})=0" "${PREV_USER_ROWS:-}" "$USER_ROWS"
          fail_add "users empty"
        elif [[ -n "$PREV_USER_ROWS" && "$PREV_USER_ROWS" =~ ^[0-9]+$ ]]; then
          if (( USER_ROWS < PREV_USER_ROWS )); then
            rbv_check_add user_rows fail \
              "users меньше предыдущей проверки" "$PREV_USER_ROWS" "$USER_ROWS"
            fail_add "user_rows ${USER_ROWS}<${PREV_USER_ROWS}"
          else
            rbv_check_add user_rows ok \
              "users(${utbl})=${USER_ROWS} ≥ prev" "$PREV_USER_ROWS" "$USER_ROWS"
          fi
        else
          rbv_check_add user_rows ok \
            "users(${utbl})=${USER_ROWS} (первый baseline)" "" "$USER_ROWS"
        fi
        rep "user_rows=${USER_ROWS} table=${utbl:-?}"
      fi
    fi

    # event freshness (relative to backup window + skew)
    if rbv_check_enabled "$KIND" event_freshness; then
      LAST_EVENT="$(rbv_max_event_epoch)"
      skew="$(rbv_skew_sec)"
      if [[ "${LAST_EVENT:-0}" -eq 0 ]]; then
        rbv_check_add event_freshness skip "нет timestamp-колонок событий"
      elif [[ "${CURR_ARCH_EPOCH:-0}" -eq 0 ]]; then
        rbv_check_add event_freshness skip "не разобрать TS архива"
      else
        if [[ "${PREV_ARCH_EPOCH:-0}" -gt 0 ]]; then
          local_lo=$(( PREV_ARCH_EPOCH - skew ))
        else
          local_lo=$(( CURR_ARCH_EPOCH - skew - 86400*30 ))
        fi
        local_hi=$(( CURR_ARCH_EPOCH + skew ))
        if (( LAST_EVENT < local_lo || LAST_EVENT > local_hi )); then
          rbv_check_add event_freshness fail \
            "событие вне окна [prev−skew … curr+skew] (skew=${skew}s)" \
            "$(date -u -d "@${PREV_ARCH_EPOCH}" +%F_%T 2>/dev/null || echo "$PREV_ARCH_EPOCH")" \
            "event=$(date -u -d "@${LAST_EVENT}" +%F_%T 2>/dev/null || echo "$LAST_EVENT"); arch=$(date -u -d "@${CURR_ARCH_EPOCH}" +%F_%T 2>/dev/null || echo "$CURR_ARCH_EPOCH")"
          fail_add "event_freshness out of window"
        else
          rbv_check_add event_freshness ok \
            "событие в окне бекапов (±${skew}s TZ lag)" \
            "prev_arch=${PREV_ARCH_EPOCH}" "event=${LAST_EVENT}/arch=${CURR_ARCH_EPOCH}"
        fi
      fi
      rep "event_freshness: last_event=${LAST_EVENT:-0}"
    fi
  fi
fi

# --- stack (= up + stability) + isolation / ports ---------------------------
STACK_OK="skip"
STACK_DETAIL=""
SETTLE="$(rbv_cfg '.settle_seconds // 25')"
SAMPLE_CID=""

if [[ "$ok" == true && -n "${PROJ_DIR:-}" ]] && rbv_check_enabled "$KIND" stack; then
  CF=""
  for c in "${PROJ_DIR}/docker-compose.yml" "${PROJ_DIR}/docker-compose.yaml" \
           "${PROJ_DIR}/compose.yml" "${PROJ_DIR}/compose.yaml"; do
    [[ -f "$c" ]] && { CF="$c"; break; }
  done
  if [[ -z "$CF" ]]; then
    rbv_check_add stack skip "compose не найден"
    rep "stack: compose не найден — skip"
  else
    rep "stack: compose=${CF}"
    NET_NAME="${COMPOSE_PROJECT}_net"
    docker network create --internal "$NET_NAME" >/dev/null
    COMPOSE_FILE="${RUN_DIR}/compose.isolated.yml"

    # Резолв compose из каталога проекта (.env рядом) — иначе «compose config failed»
    set +e
    (
      cd "$PROJ_DIR" || exit 1
      cfg=(docker compose)
      [[ -f .env ]] && cfg+=(--env-file .env)
      cf_arg="$CF"
      case "$CF" in
        "$PROJ_DIR"/*) cf_arg="${CF#"$PROJ_DIR"/}" ;;
      esac
      "${cfg[@]}" -f "$cf_arg" config --format json
    ) >"$COMPOSE_RAW" 2>"${RUN_DIR}/compose.cfg.err"
    cfg_rc=$?
    set -e

    if [[ $cfg_rc -ne 0 || ! -s "$COMPOSE_RAW" ]]; then
      rbv_check_add stack fail "compose config failed"
      fail_add "compose config"
      rep "stack: compose config failed — см. ${RUN_DIR}/compose.cfg.err"
      if [[ -s "${RUN_DIR}/compose.cfg.err" ]]; then
        rep "----- compose.cfg.err (tail) -----"
        tail -n 30 "${RUN_DIR}/compose.cfg.err" | while IFS= read -r _line; do rep "  ${_line}"; done
        rep "----- end -----"
      fi
    else
      # Убираем postgres-сервис (его заменяет наш PG_CID) и переписываем
      # DATABASE_URL/DIRECT_URL/POSTGRES_HOST → remnawave-db:5432 (sandbox).
      jq --arg net "$NET_NAME" --arg pgsvc "${POSTGRES_SERVICE}" '
        def fix_pg_url:
          if type != "string" then .
          elif (test("(?i)^postgres(ql)?://") | not) then .
          elif test("@") then
            (capture("(?<pre>.*://[^/@]+@)[^/?#]+(?<post>.*)") // null) as $m
            | if $m then "\($m.pre)remnawave-db:5432\($m.post)" else . end
          else
            (capture("(?<pre>.*://)[^/?#]+(?<post>.*)") // null) as $m
            | if $m then "\($m.pre)remnawave-db:5432\($m.post)" else . end
          end;
        def fix_env:
          if type == "object" then
            with_entries(
              if (.key | test("(?i)^(DATABASE_URL|DIRECT_URL|POSTGRES_URL|SQLALCHEMY_DATABASE_URL|DATABASE_URI)$"))
              then .value |= fix_pg_url
              elif (.key | test("(?i)^(POSTGRES_HOST|PGHOST|DB_HOST|DATABASE_HOST)$"))
              then .value = "remnawave-db"
              elif (.key | test("(?i)^(POSTGRES_PORT|PGPORT|DB_PORT|DATABASE_PORT)$"))
              then .value = "5432"
              else . end
            )
          elif type == "array" then
            map(
              if type == "string" and test("=") then
                (index("=") as $i | .[0:$i] as $k | .[$i+1:] as $v |
                  if ($k | test("(?i)^(DATABASE_URL|DIRECT_URL|POSTGRES_URL|SQLALCHEMY_DATABASE_URL|DATABASE_URI)$"))
                  then "\($k)=\($v | fix_pg_url)"
                  elif ($k | test("(?i)^(POSTGRES_HOST|PGHOST|DB_HOST|DATABASE_HOST)$"))
                  then "\($k)=remnawave-db"
                  elif ($k | test("(?i)^(POSTGRES_PORT|PGPORT|DB_PORT|DATABASE_PORT)$"))
                  then "\($k)=5432"
                  else .
                  end)
              else . end
            )
          else . end;
        .networks = {"rbv": {"name": $net, "external": true}}
        | .services = (.services | to_entries | map(
            .value |= (
              # env_file/.env с продовым DATABASE_URL иначе перебьёт rewrite
              del(.ports, .container_name, .env_file, .network_mode, .links)
              | .networks = {"rbv": {}}
              | .restart = "no"
              | if .environment then .environment |= fix_env else . end
              | if .volumes then
                  .volumes |= map(select(
                    (type=="object" and ((.source // "") | contains("docker.sock") | not)
                      and ((.source // "") | test("(^|/)\\.env$") | not))
                    or (type=="string" and (contains("docker.sock") | not)
                      and (test("(^|:)/\\.env$|\\.env:") | not))
                  ))
                else . end
            )
            | {key: .key, value: .value}
          ) | from_entries)
        | .services |= with_entries(
            select(
              (.key != $pgsvc)
              and ((.value.image // "") | test("postgres"; "i") | not)
            )
          )
        | if .volumes then
            .volumes |= with_entries(select(.value.external != true))
          else . end
      ' "$COMPOSE_RAW" > "$COMPOSE_FILE"

      # Показать, куда ушли DB URL (без пароля)
      db_urls="$(jq -r '
        .services // {} | to_entries[] | .value.environment
        | if type=="object" then to_entries[] | select(.key|test("(?i)DATABASE_URL|DIRECT_URL")) | "\(.key)=\(.value)"
          elif type=="array" then .[] | select(test("(?i)^(DATABASE_URL|DIRECT_URL)="))
          else empty end
      ' "$COMPOSE_FILE" 2>/dev/null | sed -E 's#(://[^:/@]+:)[^@/]+@#\1***@#g' | head -n 8 || true)"
      if [[ -n "$db_urls" ]]; then
        rep "stack: DB env после rewrite:"
        while IFS= read -r _line; do [[ -n "$_line" ]] && rep "  ${_line}"; done <<<"$db_urls"
      else
        rep "stack: WARN — DATABASE_URL/DIRECT_URL не найдены в compose (проверьте .env)"
      fi

      docker network disconnect "$NET_NAME" "$PG_CID" 2>/dev/null || true
      docker network connect \
        --alias db --alias postgres --alias remnawave-db --alias postgresql \
        --alias remnawave_db --alias database \
        --alias "${POSTGRES_SERVICE}" \
        "$NET_NAME" "$PG_CID" 2>/dev/null \
        || docker network connect "$NET_NAME" "$PG_CID" || true

      rep "stack: compose up -d (project=${COMPOSE_PROJECT}, сеть ${NET_NAME})…"
      set +e
      docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" up -d --no-build \
        2>"${RUN_DIR}/compose.up.err"
      up_rc=$?
      set -e
      if [[ $up_rc -ne 0 ]]; then
        STACK_OK="fail"
        STACK_DETAIL="compose up rc=${up_rc}"
        err_snip="$(tail -n 8 "${RUN_DIR}/compose.up.err" 2>/dev/null | tr '\n' ' ' | head -c 500)"
        rbv_check_add stack fail "$STACK_DETAIL: ${err_snip}"
        fail_add "stack up failed: ${err_snip}"
        rep "stack up FAILED — полный лог: ${RUN_DIR}/compose.up.err"
        if [[ -s "${RUN_DIR}/compose.up.err" ]]; then
          rep "----- compose.up.err (tail) -----"
          tail -n 20 "${RUN_DIR}/compose.up.err" | while IFS= read -r _line; do rep "  ${_line}"; done
          rep "----- end -----"
        fi
      else
        rep "stack: settle ${SETTLE}с…"
        _left="$SETTLE"
        while (( _left > 0 )); do
          _step=5
          (( _left < _step )) && _step=$_left
          sleep "$_step"
          _left=$((_left - _step))
          if (( _left > 0 )); then
            rep "stack: settle, осталось ~${_left}с"
          fi
        done
        running="$(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
        total="$(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -q 2>/dev/null | wc -l | tr -d ' ')"
        STACK_DETAIL="containers ${running}/${total}"
        SAMPLE_CID="$(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -q 2>/dev/null | head -n1 || true)"
        # предпочитаем app-контейнер (не redis) для isolation sample
        while IFS= read -r _cid; do
          [[ -n "$_cid" ]] || continue
          _svc="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$_cid" 2>/dev/null || true)"
          if [[ "$_svc" != *redis* && "$_svc" != *valkey* ]]; then
            SAMPLE_CID="$_cid"
            break
          fi
        done < <(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -q 2>/dev/null || true)
        rep "stack: после settle ${STACK_DETAIL}"
        if [[ "${running:-0}" -lt 1 ]]; then
          STACK_OK="fail"
          rbv_check_add stack fail "после up: $STACK_DETAIL"
          fail_add "no running containers"
        else
          STACK_OK="ok"
          stab="$(rbv_stability_sec)"
          rep "stack: stability window ${stab}с…"
          if ! rbv_check_stability "${COMPOSE_PROJECT}" "$COMPOSE_FILE" "$stab"; then
            STACK_OK="fail"
            fail_add "stack stability"
          fi
        fi

        if rbv_check_enabled "$KIND" isolation; then
          rep "check isolation…"
          if ! rbv_check_isolation "$SAMPLE_CID"; then
            fail_add "isolation leak"
          fi
        else
          rbv_check_add isolation skip "отключено"
        fi

        if [[ "$STACK_OK" == "ok" ]] && rbv_check_enabled "$KIND" backend_ports; then
          rep "check backend_ports…"
          if ! rbv_check_backend_ports "$NET_NAME" "$COMPOSE_RAW" "${COMPOSE_PROJECT}"; then
            fail_add "backend_ports"
          fi
        elif ! rbv_check_enabled "$KIND" backend_ports; then
          rbv_check_add backend_ports skip "отключено"
        fi
      fi
    fi
  fi
elif ! rbv_check_enabled "$KIND" stack; then
  rbv_check_add stack skip "отключено"
  rep "stack: отключено в checks"
fi

# --- save baseline (только при успехе данных) ------------------------------
if [[ "$ok" == true || "$USER_ROWS" -gt 0 ]]; then
  new_base="$(jq -n \
    --argjson ur "${USER_ROWS:-0}" \
    --argjson at "${CURR_ARCH_EPOCH:-0}" \
    --argjson le "${LAST_EVENT:-0}" \
    --arg key "$KEY" \
    --argjson ts "$(date +%s)" \
    --argjson tables "${DB_TABLES:-0}" \
    '{user_rows:$ur, archive_ts:$at, last_event_epoch:$le, archive_key:$key, tested_at:$ts, db_tables:$tables}')"
  # обновляем baseline всегда при успешном DB restore (даже если stack fail) —
  # иначе монотонность users не сдвинется после починки стека
  if [[ "${DB_TABLES:-0}" -gt 0 ]]; then
    rbv_baseline_save "$SID" "$INST" "$new_base"
  fi
fi

ended="$(date -Is)"
rep "finished=${ended} result=$([[ $ok == true ]] && echo OK || echo FAIL)"

# --- Telegram ---------------------------------------------------------------
TG_LINE="$(rbv_tg_for_storage "$SID")"
IFS='|' read -r TOK CHAT THREAD <<<"$TG_LINE"
body="$(rbv_format_tg_report "$SID" "$KIND" "$INST" "$KEY" "$ok")"
body+=$'\n'"⏱ ${ended}"
if [[ -n "$TOK" && -n "$CHAT" ]]; then
  rep "telegram: отправка в chat=${CHAT} thread=${THREAD:-—}"
else
  rep "telegram: ПРОПУСК — нет token/chat_id (rw-backup-verify telegram show)"
fi

notify_ok="$(rbv_cfg '.notify_on_success // true')"
if [[ "$ok" != true ]] || [[ "$notify_ok" == "true" ]]; then
  rbv_tg_send_long "$TOK" "$CHAT" "$body" "$THREAD"
  if [[ "$ok" != true && -n "${COMPOSE_FILE}" && -f "${COMPOSE_FILE}" ]]; then
    rbv_tg_send_logs "$TOK" "$CHAT" "$THREAD" "${COMPOSE_PROJECT}" "$COMPOSE_FILE"
  fi
fi

# CHECKS_JSON уже = ${RUN_DIR}/checks.json — не cp сам в себя
jq -n \
  --arg sid "$SID" --arg kind "$KIND" --arg inst "$INST" --arg key "$KEY" \
  --argjson ok "$ok" --argjson tables "${DB_TABLES:-0}" --argjson users "${USER_ROWS:-0}" \
  --slurpfile checks "$CHECKS_JSON" \
  '{storage:$sid,kind:$kind,instance:$inst,archive:$key,ok:$ok,db_tables:$tables,user_rows:$users,checks:$checks[0]}' \
  > "${RUN_DIR}/summary.json"

[[ "$ok" == true ]]
