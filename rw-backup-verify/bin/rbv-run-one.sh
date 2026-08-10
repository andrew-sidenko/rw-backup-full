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
      docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" down -v --remove-orphans >/dev/null 2>&1 || true
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
ARCH_PATH="${RUN_DIR}/archive.tar.gz"
S3_URI="s3://${RBV_BUCKET}/${KEY}"
rep "download ${S3_URI}"
if ! rbv_aws s3 cp "$S3_URI" "$ARCH_PATH" --only-show-errors; then
  fail_add "download failed"
  rbv_check_add download fail "не скачался ${S3_URI}"
else
  rbv_check_add download ok "$(basename "$KEY")"
fi

base_name="$(basename "$KEY")"
if [[ "$ok" == true && "$base_name" == *.age ]]; then
  need age
  AGE_ID="$(rbv_cfg '.age_identity // empty')"
  if [[ -z "$AGE_ID" ]]; then
    fail_add "age identity unset"
  else
    age -d -i "$AGE_ID" -o "${ARCH_PATH}.dec" "$ARCH_PATH"
    mv -f "${ARCH_PATH}.dec" "$ARCH_PATH"
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
    fi
    if [[ -n "$DIR_TAR" ]]; then
      pe="${RUN_DIR}/project_extract"
      mkdir -p "$pe"
      tar -xzf "$DIR_TAR" -C "$pe"
      project_top="$(tar -tzf "$DIR_TAR" | head -n1 | cut -d/ -f1)"
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
    fi
  fi
  [[ -n "$SQL" ]] || fail_add "no sql dump"
fi

# --- DB restore + data checks -----------------------------------------------
DB_TABLES=0
if [[ "$ok" == true ]]; then
  PG_CID="rbv_pg_${RUN_ID}"
  docker rm -f "$PG_CID" >/dev/null 2>&1 || true
  docker run -d --name "$PG_CID" -e POSTGRES_HOST_AUTH_METHOD=trust \
    "postgres:${PG_VER}-alpine" >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$PG_CID" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker exec "$PG_CID" pg_isready -U postgres >/dev/null 2>&1; then
    fail_add "postgres not ready"
  else
    gzip -dc "$SQL" | docker exec -i "$PG_CID" \
      psql -q -U postgres -v ON_ERROR_STOP=0 >/dev/null 2>"${RUN_DIR}/psql.err" || true
    DB_TABLES="$(rbv_psql "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")"
    DB_TABLES="$(echo "$DB_TABLES" | tr -d '[:space:]')"
    [[ "$DB_TABLES" =~ ^[0-9]+$ ]] || DB_TABLES=0
    if (( DB_TABLES < 1 )); then
      fail_add "empty schema"
      rbv_check_add db_schema fail "public tables=0"
    else
      rbv_check_add db_schema ok "tables=${DB_TABLES}"
    fi

    # user_rows: не пусто + ≥ предыдущей проверки (один toggle)
    if rbv_check_enabled "$KIND" user_rows; then
      utbl="$(rbv_find_users_table)"
      if [[ -z "$utbl" ]]; then
        rbv_check_add user_rows skip "таблица users не найдена"
      else
        USER_ROWS="$(rbv_count_table "$utbl")"
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
  else
    NET_NAME="rbv_net_${RUN_ID}"
    docker network create --internal "$NET_NAME" >/dev/null
    COMPOSE_FILE="${RUN_DIR}/compose.isolated.yml"

    if docker compose -f "$CF" config --format json >"$COMPOSE_RAW" 2>"${RUN_DIR}/compose.cfg.err"; then
      jq --arg net "$NET_NAME" --arg pgsvc "${POSTGRES_SERVICE}" '
        .networks = {"rbv": {"name": $net, "external": true}}
        | .services = (.services | to_entries | map(
            .value |= (
              del(.ports, .container_name)
              | .networks = {"rbv": {}}
              | .restart = "no"
              | if .volumes then
                  .volumes |= map(select(
                    (type=="object" and ((.source // "") | contains("docker.sock") | not))
                    or (type=="string" and (contains("docker.sock") | not))
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

      docker network disconnect "$NET_NAME" "$PG_CID" 2>/dev/null || true
      docker network connect \
        --alias db --alias postgres --alias remnawave-db --alias postgresql \
        --alias "${POSTGRES_SERVICE}" \
        "$NET_NAME" "$PG_CID" 2>/dev/null \
        || docker network connect "$NET_NAME" "$PG_CID" || true

      set +e
      docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" up -d --no-build \
        2>"${RUN_DIR}/compose.up.err"
      up_rc=$?
      set -e
      if [[ $up_rc -ne 0 ]]; then
        STACK_OK="fail"
        STACK_DETAIL="compose up rc=${up_rc}"
        rbv_check_add stack fail "$STACK_DETAIL: $(tail -n2 "${RUN_DIR}/compose.up.err" | tr '\n' ' ')"
        fail_add "stack up failed"
      else
        sleep "$SETTLE"
        running="$(docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
        total="$(docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" ps -q 2>/dev/null | wc -l | tr -d ' ')"
        STACK_DETAIL="containers ${running}/${total}"
        SAMPLE_CID="$(docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" ps -q 2>/dev/null | head -n1 || true)"
        if [[ "${running:-0}" -lt 1 ]]; then
          STACK_OK="fail"
          rbv_check_add stack fail "после up: $STACK_DETAIL"
          fail_add "no running containers"
        else
          STACK_OK="ok"
          # подъём + окно без падений — одна проверка stack
          stab="$(rbv_stability_sec)"
          if ! rbv_check_stability "rbv_${RUN_ID}" "$COMPOSE_FILE" "$stab"; then
            STACK_OK="fail"
            fail_add "stack stability"
          fi
        fi

        if rbv_check_enabled "$KIND" isolation; then
          if ! rbv_check_isolation "$SAMPLE_CID"; then
            fail_add "isolation leak"
          fi
        else
          rbv_check_add isolation skip "отключено"
        fi

        if [[ "$STACK_OK" == "ok" ]] && rbv_check_enabled "$KIND" backend_ports; then
          if ! rbv_check_backend_ports "$NET_NAME" "$COMPOSE_RAW" "rbv_${RUN_ID}"; then
            fail_add "backend_ports"
          fi
        elif ! rbv_check_enabled "$KIND" backend_ports; then
          rbv_check_add backend_ports skip "отключено"
        fi
      fi
    else
      rbv_check_add stack fail "compose config failed"
      fail_add "compose config"
    fi
  fi
elif ! rbv_check_enabled "$KIND" stack; then
  rbv_check_add stack skip "отключено"
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

notify_ok="$(rbv_cfg '.notify_on_success // true')"
if [[ "$ok" != true ]] || [[ "$notify_ok" == "true" ]]; then
  rbv_tg_send_long "$TOK" "$CHAT" "$body" "$THREAD"
  if [[ "$ok" != true && -n "${COMPOSE_FILE}" && -f "${COMPOSE_FILE}" ]]; then
    rbv_tg_send_logs "$TOK" "$CHAT" "$THREAD" "rbv_${RUN_ID}" "$COMPOSE_FILE"
  fi
fi

cp -f "$CHECKS_JSON" "${RUN_DIR}/checks.json"
jq -n \
  --arg sid "$SID" --arg kind "$KIND" --arg inst "$INST" --arg key "$KEY" \
  --argjson ok "$ok" --argjson tables "${DB_TABLES:-0}" --argjson users "${USER_ROWS:-0}" \
  --slurpfile checks "$CHECKS_JSON" \
  '{storage:$sid,kind:$kind,instance:$inst,archive:$key,ok:$ok,db_tables:$tables,user_rows:$users,checks:$checks[0]}' \
  > "${RUN_DIR}/summary.json"

[[ "$ok" == true ]]
