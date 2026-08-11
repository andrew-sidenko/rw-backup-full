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

# Временный сбой (диск) — worker НЕ пишет в tested, можно повторить тот же key.
mark_retryable() {
  RBV_RETRYABLE=1
  [[ -n "${RUN_DIR:-}" ]] && mkdir -p "$RUN_DIR" && : >"${RUN_DIR}/.retryable"
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
RBV_RETRYABLE=0

cleanup() {
  if [[ "$KEEP" != "true" ]]; then
    if [[ -n "${COMPOSE_FILE}" && -f "${COMPOSE_FILE}" ]]; then
      docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    [[ -n "${NET_NAME}" ]] && docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    [[ -n "${PG_CID}" ]] && docker rm -f "$PG_CID" >/dev/null 2>&1 || true
    # освободить диск для следующего job: dump/extract убрать, report/compose оставить
    if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR}" ]]; then
      rbv_run_slim "$RUN_DIR"
    fi
  fi
}
trap cleanup EXIT

# не дать prune снести текущий run
export RBV_PROTECT_RUN="$RUN_DIR"

rep "=== rw-backup-verify ==="
rep "storage=${SID} kind=${KIND} instance=${INST}"
rep "key=${KEY} parent=${PARENT}"
rep "started=$(date -Is)"

CURR_ARCH_EPOCH="$(rbv_parse_archive_epoch "$(basename "$KEY")")"
BASELINE_JSON="$(rbv_baseline_load "$SID" "$INST")"
PREV_ARCH_EPOCH="$(jq -r '.archive_ts // 0' <<<"$BASELINE_JSON")"
PREV_USER_ROWS="$(jq -r '.user_rows // empty' <<<"$BASELINE_JSON")"

# --- preflight isolation (до download/restore/stack) ------------------------
# Если хост не умеет --internal без egress — все проверки бессмысленны.
_preflight_iso=true
v_pf="$(jq -r '.checks.preflight_isolation // .checks.default.preflight_isolation // true' "$RBV_CONFIG" 2>/dev/null || echo true)"
case "$v_pf" in false|FALSE|0|no|off) _preflight_iso=false ;; esac
if [[ "$_preflight_iso" == true ]]; then
  rep "preflight: isolation (Docker --internal без egress)…"
  set +e
  _pf_detail="$(rbv_preflight_isolation 2>/dev/null)"
  _pf_rc=$?
  set -e
  if [[ $_pf_rc -ne 0 ]]; then
    rbv_check_add isolation fail "preflight: ${_pf_detail:-fail}"
    fail_add "isolation preflight — тесты остановлены"
    rep "FAIL isolation preflight: ${_pf_detail}"
    rep "  исправьте Docker/firewall (сети --internal не должны иметь egress), затем повторите run"
  else
    rep "preflight: isolation OK (${_pf_detail})"
  fi
else
  rep "preflight: isolation пропущен (checks.preflight_isolation=false)"
fi

# --- download / extract -----------------------------------------------------
# Кэш архивов: work_dir/cache/archives/<sid>/<hash>.tar.gz — не качаем повторно.
# Перед скачиванием чистим старые runs/ (архивы уже в cache через hardlink).
if [[ "$ok" != true ]]; then
  rep "skip: download/restore/stack не запускаются (preflight fail)"
else
ARCH_PATH="${RUN_DIR}/archive.tar.gz"
S3_URI="s3://${RBV_BUCKET}/${KEY}"
_keep_runs="$(rbv_cfg '.runs_keep // 2')"
[[ "$_keep_runs" =~ ^[0-9]+$ ]] || _keep_runs=2
_pruned="$(rbv_runs_prune "$_keep_runs" "$RUN_DIR" || echo 0)"
_pruned="$(echo "$_pruned" | tr -d '[:space:]')"
[[ "$_pruned" =~ ^[0-9]+$ ]] || _pruned=0
if (( _pruned > 0 )); then
  rep "disk: удалено старых runs=${_pruned} (keep=${_keep_runs}; архивы в cache)"
fi
# у старых runs убрать extract/sql — иначе после bot не хватит места на panel
rbv_slim_old_runs "$RUN_DIR"
rep "disk: $(rbv_disk_report "$WD")"
_avail_kb="$(rbv_disk_avail_kb "$WD")"
if [[ -n "$_avail_kb" && "$_avail_kb" =~ ^[0-9]+$ ]] && (( _avail_kb < 2097152 )); then
  rep "WARN: свободно <2GiB (${_avail_kb} KiB) — перед restore будет жёсткий prune"
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
      mark_retryable
      rep "  ${_err}"
      rep "  → rw-backup-verify runs prune --keep 0"
      rep "  → docker system prune -af"
    else
      fail_add "download failed"
      rbv_check_add download fail "не скачался ${S3_URI}"
      [[ -n "$_err" ]] && rep "  ${_err}"
    fi
    rm -f "$_cache" 2>/dev/null || true
    _cache=""
  else
    printf '%s\n' "$KEY" >"${_cache}.key"
    ln -f "$_cache" "$ARCH_PATH" 2>/dev/null || cp -f "$_cache" "$ARCH_PATH"
    rbv_check_add download ok "$(basename "$KEY")"
  fi
fi
# после любого удачного получения архива — в cache только latest (ручной = auto)
if [[ "$ok" == true && -n "${_cache:-}" && -s "${_cache:-}" && "${RBV_CACHE_LATEST:-true}" == true ]]; then
  _cn="$(rbv_cache_prune_latest "$SID" || echo 0)"
  _cn="$(echo "$_cn" | tr -d '[:space:]')"
  [[ "$_cn" =~ ^[0-9]+$ && "$_cn" -gt 0 ]] && rep "cache: prune latest — удалено старых=${_cn}"
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
  else
    # архив оставляем только в cache/ — из runs/ убрать сразу (ручной повтор = cache hit)
    if [[ -n "${_cache:-}" && -s "$_cache" ]]; then
      rm -f "$ARCH_PATH" 2>/dev/null || true
      rep "archive: только в cache (${_cache#"$WD"/}), из run удалён"
    fi
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

  # место под restore: ~4× .sql.gz, минимум 1.5 GiB (см. rbv_disk_need_for_sql)
  _sql_b=0
  [[ -n "${SQL:-}" && -f "${SQL:-}" ]] && _sql_b="$(stat -c%s "$SQL" 2>/dev/null || wc -c <"$SQL" | tr -d ' ')"
  _need_kb="$(rbv_disk_need_for_sql "${_sql_b:-0}")"
  [[ "$_need_kb" =~ ^[0-9]+$ ]] || _need_kb="$(rbv_disk_floor_kb)"
  if ! rbv_ensure_disk_kb "$_need_kb" "$RUN_DIR"; then
    _av="$(rbv_disk_avail_kb "$WD")"
    fail_add "мало места на диске (avail=${_av:-?}KiB need=${_need_kb}KiB)"
    rbv_check_add db_schema fail "ENOSPC: свободно ${_av:-?} KiB, нужно ≥${_need_kb}"
    mark_retryable
    rep "FAIL disk: $(rbv_disk_report "$WD") — НЕ в tested (retryable)"
    rep "  → rw-backup-verify runs prune --keep 0 && docker system prune -af"
  fi

  if [[ "$ok" == true ]] && rbv_pg_start init; then
    ready=true
    accept=true
  elif [[ "$ok" == true ]]; then
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
          rbv_ensure_disk_kb "$_need_kb" "$RUN_DIR" || true
          rep "psql restore: recreate PG и повтор…"
          rbv_pg_start "retry-${_attempt}" || true
          continue
        fi
        break
      fi
      if grep -qiE 'starting up|connection.*failed|server closed|the database system is shutting down|No space left|ENOSPC' \
           "${RUN_DIR}/psql.err" 2>/dev/null; then
        rep "psql restore: соединение/диск (попытка ${_attempt}/${_max_restore}) — recreate"
        rbv_pg_diag "conn-${_attempt}"
        if (( _attempt < _max_restore )); then
          rbv_ensure_disk_kb "$_need_kb" "$RUN_DIR" || true
          rbv_pg_start "retry-${_attempt}" || true
          continue
        fi
        break
      fi
      break
    done
    kill "$_hb" 2>/dev/null || true
    wait "$_hb" 2>/dev/null || true
    rep "psql restore: rc=${_psql_rc}"
    sql_errs="$(grep -cE '^ERROR' "${RUN_DIR}/psql.err" 2>/dev/null || true)"
    sql_errs="$(echo "${sql_errs:-0}" | tr -d '[:space:]')"
    [[ "$sql_errs" =~ ^[0-9]+$ ]] || sql_errs=0
    if (( sql_errs > 0 )); then
      rep "psql restore: ERROR-строк=${sql_errs} (см. ${RUN_DIR}/psql.err)"
    fi

    if rbv_pg_alive; then
      DB_TABLES="$(rbv_select_app_db "${RBV_PG_DB_HINT}")"
      DB_TABLES="$(echo "$DB_TABLES" | tr -d '[:space:]')"
      [[ "$DB_TABLES" =~ ^[0-9]+$ ]] || DB_TABLES=0
    else
      DB_TABLES=0
      RBV_PG_DB="postgres"
      rbv_pg_diag "post-restore-dead"
    fi

    # много ERROR + пустая схема часто = ENOSPC/обрыв — один полный retry
    if (( DB_TABLES < 1 )) && (( sql_errs > 20 || _psql_rc != 0 )) && rbv_ensure_disk_kb "$_need_kb" "$RUN_DIR"; then
      rep "psql restore: schema пуста (errors=${sql_errs}) — полный retry на чистом PG"
      if rbv_pg_start "schema-retry"; then
        : >"${RUN_DIR}/psql.err"
        set +e
        gzip -dc "$SQL" | docker exec -i "$PG_CID" \
          psql -q -U postgres -d postgres -v ON_ERROR_STOP=0 >/dev/null 2>"${RUN_DIR}/psql.err"
        _psql_rc=$?
        set -e
        rep "psql restore retry: rc=${_psql_rc}"
        sql_errs="$(grep -cE '^ERROR' "${RUN_DIR}/psql.err" 2>/dev/null || true)"
        sql_errs="$(echo "${sql_errs:-0}" | tr -d '[:space:]')"
        [[ "$sql_errs" =~ ^[0-9]+$ ]] || sql_errs=0
        if rbv_pg_alive; then
          DB_TABLES="$(rbv_select_app_db "${RBV_PG_DB_HINT}")"
          DB_TABLES="$(echo "$DB_TABLES" | tr -d '[:space:]')"
          [[ "$DB_TABLES" =~ ^[0-9]+$ ]] || DB_TABLES=0
        fi
        rep "psql restore retry: ERROR-строк=${sql_errs} tables=${DB_TABLES}"
      fi
    fi

    rep "db_schema: db=${RBV_PG_DB:-postgres} user_tables=${DB_TABLES}"
    if (( DB_TABLES < 1 )); then
      dbs="?"
      if rbv_pg_alive; then
        dbs="$(docker exec "$PG_CID" psql -U postgres -d postgres -Atc \
          "SELECT string_agg(datname, ',') FROM pg_database WHERE NOT datistemplate" 2>/dev/null || echo "?")"
      else
        rbv_pg_diag "empty-schema-dead"
      fi
      _extra=""
      [[ ${_psql_rc:-1} -eq 137 ]] && _extra=" OOM/SIGKILL(rc=137)"
      grep -qiE 'No space left|ENOSPC' "${RUN_DIR}/psql.err" 2>/dev/null && _extra="${_extra} ENOSPC"
      _av="$(rbv_disk_avail_kb "$WD")"
      fail_add "empty schema (dbs=${dbs} sql_errors=${sql_errs}${_extra})"
      rbv_check_add db_schema fail "user tables=0 (dbs=${dbs}, sql_errors=${sql_errs}${_extra}, disk=${_av:-?}KiB)"
      if [[ -s "${RUN_DIR}/psql.err" ]]; then
        rep "----- psql.err (tail) -----"
        tail -n 15 "${RUN_DIR}/psql.err" | while IFS= read -r _line; do rep "  ${_line}"; done
        rep "----- end -----"
      fi
      rep "disk now: $(rbv_disk_report "$WD")"
    else
      rbv_check_add db_schema ok "db=${RBV_PG_DB} tables=${DB_TABLES}"
    fi

    # user_rows: не пусто + ≥ предыдущей проверки (один toggle)
    # bot → строго public.users; panel → эвристика.
    if rbv_check_enabled "$KIND" user_rows; then
      utbl="$(rbv_find_users_table "$KIND" || true)"
      if [[ -z "$utbl" ]]; then
        if [[ "$KIND" == "bot" ]]; then
          rbv_check_add user_rows fail "таблица public.users не найдена"
          fail_add "users table missing"
          rep "user_rows: FAIL — нет public.users; поля таблиц users / payment_webhook_events:"
          while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
            [[ -n "${_line:-}" ]] && rep "  ${_line}"
          done < <(rbv_dump_table_fields users; rbv_dump_table_fields payment_webhook_events)
        else
          rbv_check_add user_rows skip "таблица users не найдена"
          rep "user_rows: skip (нет таблицы)"
        fi
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
    # bot → даты из payment_webhook_events; panel → users/nodes.
    if rbv_check_enabled "$KIND" event_freshness; then
      _ev_out="$(rbv_max_event_epoch "$KIND" | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      _ev_src=""
      LAST_EVENT=0
      case "$_ev_out" in
        missing|nofields)
          if [[ "$KIND" == "bot" ]]; then
            rbv_check_add event_freshness fail \
              "payment_webhook_events: ${_ev_out} (нет таблицы или timestamp-полей)"
            fail_add "event_freshness: ${_ev_out}"
            rep "event_freshness: FAIL (${_ev_out}) — поля таблиц users / payment_webhook_events:"
            while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
              [[ -n "${_line:-}" ]] && rep "  ${_line}"
            done < <(rbv_dump_table_fields users; rbv_dump_table_fields payment_webhook_events)
          else
            rbv_check_add event_freshness skip "нет timestamp-колонок событий"
          fi
          ;;
        *)
          LAST_EVENT="${_ev_out%%|*}"
          if [[ "$_ev_out" == *"|"* ]]; then
            _ev_src="${_ev_out#*|}"
          fi
          [[ "$LAST_EVENT" =~ ^[0-9]+$ ]] || LAST_EVENT=0
          skew="$(rbv_skew_sec)"
          if [[ "${LAST_EVENT:-0}" -eq 0 ]]; then
            if [[ "$KIND" == "bot" ]]; then
              rbv_check_add event_freshness skip \
                "payment_webhook_events пуста / без дат (src=${_ev_src:-?})"
              rep "event_freshness: skip — таблица есть, но дат нет (src=${_ev_src:-?}); поля:"
              while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
                [[ -n "${_line:-}" ]] && rep "  ${_line}"
              done < <(rbv_dump_table_fields payment_webhook_events)
            else
              rbv_check_add event_freshness skip "нет timestamp-колонок событий"
            fi
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
                "событие вне окна [prev−skew … curr+skew] (skew=${skew}s, src=${_ev_src:-?})" \
                "$(date -u -d "@${PREV_ARCH_EPOCH}" +%F_%T 2>/dev/null || echo "$PREV_ARCH_EPOCH")" \
                "event=$(date -u -d "@${LAST_EVENT}" +%F_%T 2>/dev/null || echo "$LAST_EVENT"); arch=$(date -u -d "@${CURR_ARCH_EPOCH}" +%F_%T 2>/dev/null || echo "$CURR_ARCH_EPOCH")"
              fail_add "event_freshness out of window"
            else
              rbv_check_add event_freshness ok \
                "событие в окне бекапов (±${skew}s TZ lag, src=${_ev_src:-?})" \
                "prev_arch=${PREV_ARCH_EPOCH}" "event=${LAST_EVENT}/arch=${CURR_ARCH_EPOCH}"
            fi
          fi
          ;;
      esac
      rep "event_freshness: last_event=${LAST_EVENT:-0} src=${_ev_src:-?} raw=${_ev_out}"
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
    # всё равно покажем, что лежит в бэкапе
    {
      echo "# search compose under PROJ_DIR=${PROJ_DIR:-?}"
      find "${PROJ_DIR:-/nonexistent}" -maxdepth 4 \( \
        -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' \
      \) 2>/dev/null | sort || true
    } >"${RUN_DIR}/compose.files.txt" || true
    if [[ -s "${RUN_DIR}/compose.files.txt" ]]; then
      rep "----- compose search in backup -----"
      while IFS= read -r _line; do rep "  ${_line}"; done <"${RUN_DIR}/compose.files.txt"
      rep "----- end -----"
    fi
  else
    rep "stack: compose=${CF}"
    rep "stack: project_dir=${PROJ_DIR}"
    rep "stack: compose project=${COMPOSE_PROJECT}"

    # --- дамп compose из бэкапа (оригинал) + вспомогательные файлы ---
    rep_file() {
      # rep_file <title> <path> [max_lines]
      local title="$1" path="$2" max="${3:-120}"
      local lines=0
      rep "----- ${title} (${path}) -----"
      if [[ ! -f "$path" ]]; then
        rep "  (нет файла)"
        rep "----- end ${title} -----"
        return 0
      fi
      lines="$(wc -l <"$path" 2>/dev/null | tr -d ' ' || echo 0)"
      head -n "$max" "$path" | while IFS= read -r _line || [[ -n "$_line" ]]; do
        rep "  ${_line}"
      done
      if [[ "$lines" =~ ^[0-9]+$ ]] && (( lines > max )); then
        rep "  … (+$((lines - max)) строк; полный файл: ${path})"
      fi
      rep "----- end ${title} -----"
    }

    # копия оригинального compose из архива
    _bext="yml"
    [[ "$CF" == *.yaml ]] && _bext="yaml"
    BACKUP_COMPOSE_COPY="${RUN_DIR}/compose.from-backup.${_bext}"
    cp -f "$CF" "$BACKUP_COMPOSE_COPY"
    rep_file "compose FROM BACKUP (raw)" "$BACKUP_COMPOSE_COPY" 200

    {
      echo "# infra files in project_dir (compose / env / Dockerfile)"
      find "$PROJ_DIR" -maxdepth 3 \( \
        -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' \
        -o -name '.env' -o -name '.env.*' -o -name 'Dockerfile*' \
        -o -name '*.override.yml' -o -name '*.override.yaml' \
      \) 2>/dev/null | sort
    } >"${RUN_DIR}/compose.files.txt" || true
    rep_file "compose.files" "${RUN_DIR}/compose.files.txt" 80

    if [[ -f "${PROJ_DIR}/.env" ]]; then
      # ключи без значений
      awk -F= '
        /^[[:space:]]*#/ {next}
        NF && $1 !~ /^[[:space:]]*$/ {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
          if ($1 != "") print $1
        }
      ' "${PROJ_DIR}/.env" 2>/dev/null | head -n 120 >"${RUN_DIR}/compose.env.keys.txt" || true
      # .env с маскированными значениями (для ручной правки инфры)
      awk -F= '
        /^[[:space:]]*#/ || NF==0 {print; next}
        {
          k=$1; sub(/^[^=]*=/, "")
          v=$0
          if (k ~ /(PASS|SECRET|TOKEN|KEY|URL|URI|DSN)/) {
            if (v ~ /:\/\//) {
              gsub(/:\/\/[^@\/]+@/, "://***@", v)
              gsub(/:[^:@\/]+@/, ":***@", v)
            } else if (length(v) > 0) { v="***" }
          }
          print k "=" v
        }
      ' "${PROJ_DIR}/.env" 2>/dev/null | rbv_mask_secrets >"${RUN_DIR}/compose.env.masked" || true
      if [[ -s "${RUN_DIR}/compose.env.keys.txt" ]]; then
        rep "stack: .env keys ($(wc -l <"${RUN_DIR}/compose.env.keys.txt" | tr -d ' ')): $(tr '\n' ',' <"${RUN_DIR}/compose.env.keys.txt" | head -c 500)"
      fi
      rep_file "compose.env.masked (from backup)" "${RUN_DIR}/compose.env.masked" 80
    fi

    NET_NAME="${COMPOSE_PROJECT}_net"
    docker network create --internal "$NET_NAME" >/dev/null
    COMPOSE_FILE="${RUN_DIR}/compose.isolated.yml"

    # .env + stub для ${BACKEND_IMAGE:?…} и т.п. (swarm/bot часто без image в архиве)
    COMPOSE_ENV="${RUN_DIR}/compose.env.effective"
    STUB_VARS="$(rbv_compose_prepare_env "$PROJ_DIR" "$CF" "$COMPOSE_ENV" | tr -d '\n')"
    if [[ -n "${STUB_VARS// }" ]]; then
      rep "stack: WARN stub env (нет в бэкапе): ${STUB_VARS}"
      rep "  → образы задаются при деплое; stack up будет skip, если image=rbv-missing/*"
    fi
    rbv_mask_secrets <"$COMPOSE_ENV" >"${RUN_DIR}/compose.env.effective.masked" 2>/dev/null || true

    # Резолв compose из каталога проекта
    set +e
    (
      cd "$PROJ_DIR" || exit 1
      cf_arg="$CF"
      case "$CF" in
        "$PROJ_DIR"/*) cf_arg="${CF#"$PROJ_DIR"/}" ;;
      esac
      docker compose --env-file "$COMPOSE_ENV" -f "$cf_arg" config --format json
    ) >"$COMPOSE_RAW" 2>"${RUN_DIR}/compose.cfg.err"
    cfg_rc=$?
    set -e

    # resolved YAML из бэкапа
    set +e
    (
      cd "$PROJ_DIR" || exit 1
      cf_arg="$CF"
      case "$CF" in
        "$PROJ_DIR"/*) cf_arg="${CF#"$PROJ_DIR"/}" ;;
      esac
      docker compose --env-file "$COMPOSE_ENV" -f "$cf_arg" config
    ) >"${RUN_DIR}/compose.from-backup.resolved.yml" 2>>"${RUN_DIR}/compose.cfg.err"
    set -e
    if [[ -s "${RUN_DIR}/compose.from-backup.resolved.yml" ]]; then
      rbv_mask_secrets <"${RUN_DIR}/compose.from-backup.resolved.yml" \
        >"${RUN_DIR}/compose.from-backup.resolved.masked.yml"
      rep_file "compose FROM BACKUP (resolved+masked)" "${RUN_DIR}/compose.from-backup.resolved.masked.yml" 200
    fi

    if [[ $cfg_rc -ne 0 || ! -s "$COMPOSE_RAW" ]]; then
      rbv_check_add stack fail "compose config failed"
      fail_add "compose config"
      rep "stack: compose config failed — см. ${RUN_DIR}/compose.cfg.err"
      if [[ -s "${RUN_DIR}/compose.cfg.err" ]]; then
        rep_file "compose.cfg.err" "${RUN_DIR}/compose.cfg.err" 40
      fi
      rep "stack: оригинал из бэкапа: ${BACKUP_COMPOSE_COPY}"
      rep "stack: effective env: ${COMPOSE_ENV}"
      rep "stack: править инфру → скопируйте compose/env из ${RUN_DIR}/ и перезапустите"
    else
      # Убираем postgres-сервис (его заменяет наш PG_CID) и переписываем
      # DATABASE_URL/DB_HOST/REDIS_HOST → sandbox.
      jq --arg net "$NET_NAME" --arg pgsvc "${POSTGRES_SERVICE}" --arg pgdb "${RBV_PG_DB:-postgres}" '
        def fix_pg_url:
          if type != "string" then .
          elif (test("(?i)^postgres(ql)?://") | not) then .
          elif test("@") then
            (capture("(?<pre>.*://[^/@]+@)[^/?#]+(?::(?<port>[0-9]+))?(?:/(?<db>[^/?#]*))?(?<q>[?#].*)?") // null) as $m
            | if $m then "\($m.pre)remnawave-db:5432/\($pgdb)\($m.q // "")" else . end
          else
            (capture("(?<pre>.*://)[^/?#]+(?::(?<port>[0-9]+))?(?:/(?<db>[^/?#]*))?(?<q>[?#].*)?") // null) as $m
            | if $m then "\($m.pre)remnawave-db:5432/\($pgdb)\($m.q // "")" else . end
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
              elif (.key | test("(?i)^(POSTGRES_DB|PGDATABASE|DB_NAME|DATABASE_NAME)$"))
              then .value = $pgdb
              elif (.key | test("(?i)^(REDIS_HOST|REDIS_URL)$"))
              then .value = (if (.key|test("URL")) then ("redis://remnawave-redis:6379") else "remnawave-redis" end)
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
                  elif ($k | test("(?i)^(POSTGRES_DB|PGDATABASE|DB_NAME|DATABASE_NAME)$"))
                  then "\($k)=\($pgdb)"
                  elif ($k | test("(?i)^REDIS_HOST$"))
                  then "\($k)=remnawave-redis"
                  elif ($k | test("(?i)^REDIS_URL$"))
                  then "\($k)=redis://remnawave-redis:6379"
                  else .
                  end)
              else . end
            )
          else . end;
        .networks = {"rbv": {"name": $net, "external": true}}
        | .services = (.services | to_entries | map(
            .value |= (
              del(.ports, .container_name, .env_file, .network_mode, .links, .deploy)
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

      # Сводка сервисов: backup vs isolated
      jq -r '
        .services // {} | to_entries[] |
        "\(.key)\timage=\(.value.image // "-")\tports=\((.value.ports // [])|tostring)"
      ' "$COMPOSE_RAW" 2>/dev/null >"${RUN_DIR}/compose.services.backup.txt" || true
      jq -r '
        .services // {} | to_entries[] |
        "\(.key)\timage=\(.value.image // "-")"
      ' "$COMPOSE_FILE" 2>/dev/null >"${RUN_DIR}/compose.services.isolated.txt" || true
      rep_file "services FROM BACKUP" "${RUN_DIR}/compose.services.backup.txt" 40
      rep_file "services ISOLATED (sandbox)" "${RUN_DIR}/compose.services.isolated.txt" 40

      # человекочитаемый isolated YAML
      set +e
      docker compose -f "$COMPOSE_FILE" config \
        >"${RUN_DIR}/compose.isolated.resolved.yml" 2>"${RUN_DIR}/compose.isolated.cfg.err"
      set -e
      if [[ -s "${RUN_DIR}/compose.isolated.resolved.yml" ]]; then
        rbv_mask_secrets <"${RUN_DIR}/compose.isolated.resolved.yml" \
          >"${RUN_DIR}/compose.isolated.masked.yml"
        rep_file "compose ISOLATED (resolved+masked)" "${RUN_DIR}/compose.isolated.masked.yml" 200
      else
        rep_file "compose ISOLATED (json)" "$COMPOSE_FILE" 120
      fi
      rep "stack: файлы для правки: ${RUN_DIR}/compose.from-backup* ${RUN_DIR}/compose.isolated*"

      # Показать, куда ушли DB URL (без пароля)
      db_urls="$(jq -r '
        .services // {} | to_entries[] | .value.environment
        | if type=="object" then to_entries[] | select(.key|test("(?i)DATABASE_URL|DIRECT_URL|DB_HOST|REDIS_HOST")) | "\(.key)=\(.value)"
          elif type=="array" then .[] | select(test("(?i)^(DATABASE_URL|DIRECT_URL|DB_HOST|REDIS_HOST)="))
          else empty end
      ' "$COMPOSE_FILE" 2>/dev/null | rbv_mask_secrets | head -n 12 || true)"
      if [[ -n "$db_urls" ]]; then
        rep "stack: DB/Redis env после rewrite:"
        while IFS= read -r _line; do [[ -n "$_line" ]] && rep "  ${_line}"; done <<<"$db_urls"
      else
        rep "stack: WARN — DATABASE_URL/DB_HOST не найдены в compose environment (проверьте env_file)"
      fi

      # Нет реальных образов (BACKEND_IMAGE не в бэкапе) → stack skip, не fail
      _missing_img="$(jq -r '.services // {} | to_entries[] | .value.image // empty' "$COMPOSE_FILE" 2>/dev/null \
        | grep -E 'rbv-missing' || true)"
      if [[ -n "$_missing_img" ]]; then
        STACK_OK="skip"
        STACK_DETAIL="нет образов в бэкапе (stubs: ${STUB_VARS:-?})"
        rbv_check_add stack skip "$STACK_DETAIL"
        rep "stack: SKIP compose up — в архиве нет BACKEND_IMAGE/CABINET_IMAGE (задаются при деплое)"
        rep "stack: stub images:"
        while IFS= read -r _line; do [[ -n "$_line" ]] && rep "  ${_line}"; done <<<"$_missing_img"
        rep "stack: data-проверки (schema/users) уже пройдены; для stack положите image tags в .env бэкапа"
        if rbv_check_enabled "$KIND" isolation; then
          rbv_check_add isolation skip "нет stack up"
        fi
        if rbv_check_enabled "$KIND" backend_ports; then
          rbv_check_add backend_ports skip "нет stack up"
        fi
      else
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
        >"${RUN_DIR}/compose.up.out" 2>"${RUN_DIR}/compose.up.err"
      up_rc=$?
      set -e
      if [[ -s "${RUN_DIR}/compose.up.out" ]]; then
        rep_file "compose up stdout" "${RUN_DIR}/compose.up.out" 40
      fi
      if [[ $up_rc -ne 0 ]]; then
        STACK_OK="fail"
        STACK_DETAIL="compose up rc=${up_rc}"
        err_snip="$(tail -n 8 "${RUN_DIR}/compose.up.err" 2>/dev/null | tr '\n' ' ' | head -c 500)"
        rbv_check_add stack fail "$STACK_DETAIL: ${err_snip}"
        fail_add "stack up failed: ${err_snip}"
        rep "stack up FAILED — полный лог: ${RUN_DIR}/compose.up.err"
        rep_file "compose.up.err" "${RUN_DIR}/compose.up.err" 40
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

        # всегда пишем ps + логи в run dir и в отчёт (для ручной корректировки)
        docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -a \
          >"${RUN_DIR}/compose.ps.txt" 2>&1 || true
        rep_file "compose ps" "${RUN_DIR}/compose.ps.txt" 40
        {
          echo "=== compose ps ==="
          cat "${RUN_DIR}/compose.ps.txt" 2>/dev/null || true
          echo
          while IFS= read -r _cid; do
            [[ -n "$_cid" ]] || continue
            _name="$(docker inspect -f '{{.Name}}' "$_cid" 2>/dev/null | sed 's#^/##')"
            echo "=== logs: ${_name} (tail 60) ==="
            docker logs --tail 60 "$_cid" 2>&1 || true
            echo
          done < <(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -aq 2>/dev/null || true)
        } >"${RUN_DIR}/compose.logs.txt" 2>&1 || true
        rep_file "compose logs (tail)" "${RUN_DIR}/compose.logs.txt" 100

        if [[ "${running:-0}" -lt 1 ]]; then
          STACK_OK="fail"
          rbv_check_add stack fail "после up: $STACK_DETAIL"
          fail_add "no running containers"
        else
          STACK_OK="ok"
          # isolation СРАЗУ после up/settle — до stability (180с) и ports
          if rbv_check_enabled "$KIND" isolation; then
            rep "check isolation (до stability)…"
            if ! rbv_check_isolation "$SAMPLE_CID"; then
              STACK_OK="fail"
              fail_add "isolation leak — дальнейшие stack-тесты остановлены"
              rbv_check_add stack skip "остановлено: isolation fail"
              if rbv_check_enabled "$KIND" backend_ports; then
                rbv_check_add backend_ports skip "остановлено: isolation fail"
              fi
            fi
          else
            rbv_check_add isolation skip "отключено"
          fi

          if [[ "$STACK_OK" == "ok" ]]; then
            stab="$(rbv_stability_sec)"
            rep "stack: stability window ${stab}с…"
            if ! rbv_check_stability "${COMPOSE_PROJECT}" "$COMPOSE_FILE" "$stab"; then
              STACK_OK="fail"
              fail_add "stack stability"
              {
                echo "=== compose ps (after stability fail) ==="
                docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -a 2>&1 || true
                echo
                while IFS= read -r _cid; do
                  [[ -n "$_cid" ]] || continue
                  _name="$(docker inspect -f '{{.Name}}' "$_cid" 2>/dev/null | sed 's#^/##')"
                  echo "=== logs: ${_name} (tail 80) ==="
                  docker logs --tail 80 "$_cid" 2>&1 || true
                  echo
                done < <(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -aq 2>/dev/null || true)
              } >"${RUN_DIR}/compose.logs.txt" 2>&1 || true
              rep_file "compose logs after fail" "${RUN_DIR}/compose.logs.txt" 120
            fi
          fi

          if [[ "$STACK_OK" == "ok" ]] && rbv_check_enabled "$KIND" backend_ports; then
            rep "check backend_ports…"
            if ! rbv_check_backend_ports "$NET_NAME" "$COMPOSE_RAW" "${COMPOSE_PROJECT}"; then
              fail_add "backend_ports"
            fi
          elif [[ "$STACK_OK" == "ok" ]] && ! rbv_check_enabled "$KIND" backend_ports; then
            rbv_check_add backend_ports skip "отключено"
          fi
        fi
      fi
      fi  # missing images vs real up
    fi
  fi
elif ! rbv_check_enabled "$KIND" stack; then
  rbv_check_add stack skip "отключено"
  rep "stack: отключено в checks"
fi

fi  # ok after preflight — download/restore/stack

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

if [[ "$ok" == true ]]; then
  exit 0
fi
# 75 = EX_TEMPFAIL: worker не помечает tested (можно повторить тот же архив)
if [[ "${RBV_RETRYABLE:-0}" == "1" || -f "${RUN_DIR}/.retryable" ]]; then
  exit 75
fi
exit 1
