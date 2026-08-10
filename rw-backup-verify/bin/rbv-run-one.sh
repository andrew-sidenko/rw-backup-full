#!/usr/bin/env bash
# Один прогон экземпляра.
# Аргументы: <storage-id> <kind:panel|bot> <instance_id> <s3_key> [parent_dir]
#
# panel — как проверенный verify-stack dump-path: dump + remnawave_dir + isolate.
# bot   — по custom-restore: PROFILE.env + postgres dump + redis rdb + project_dir + isolate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

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
: > "$REPORT"

rep() { printf '%s\n' "$*" | tee -a "$REPORT" >&2; }
ok=true
fail_reasons=()

PG_CID=""
COMPOSE_FILE=""
NET_NAME=""
KEEP="${KEEP:-false}"
PROJ_DIR=""

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

ARCH_PATH="${RUN_DIR}/archive.tar.gz"
S3_URI="s3://${RBV_BUCKET}/${KEY}"
rep "download ${S3_URI}"
if ! rbv_aws s3 cp "$S3_URI" "$ARCH_PATH" --only-show-errors; then
  ok=false
  fail_reasons+=("download failed")
  rep "FAIL download"
fi

base_name="$(basename "$KEY")"
if [[ "$ok" == true && "$base_name" == *.age ]]; then
  need age
  AGE_ID="$(rbv_cfg '.age_identity // empty')"
  [[ -n "$AGE_ID" ]] || { ok=false; fail_reasons+=("age archive but age_identity unset"); }
  if [[ "$ok" == true ]]; then
    age -d -i "$AGE_ID" -o "${ARCH_PATH}.dec" "$ARCH_PATH"
    mv -f "${ARCH_PATH}.dec" "$ARCH_PATH"
  fi
fi

EXTRACT="${RUN_DIR}/extract"
mkdir -p "$EXTRACT"
if [[ "$ok" == true ]]; then
  if ! tar -xzf "$ARCH_PATH" -C "$EXTRACT" 2>"${RUN_DIR}/tar.err"; then
    ok=false
    fail_reasons+=("tar extract failed")
    rep "FAIL tar: $(tail -n2 "${RUN_DIR}/tar.err" | tr '\n' ' ')"
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
    # bot — как custom-restore
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
      rep "profile: PROJECT_NAME=${PROJECT_NAME:-?} POSTGRES_SERVICE=${POSTGRES_SERVICE} REDIS_SERVICE=${REDIS_SERVICE}"
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
      # Redis RDB до запуска (как в restore_custom_archive)
      if [[ -n "$REDIS_RDB" && -f "$REDIS_RDB" ]]; then
        mkdir -p "${PROJ_DIR}/volumes/redis"
        cp -f "$REDIS_RDB" "${PROJ_DIR}/volumes/redis/dump.rdb"
        chmod 644 "${PROJ_DIR}/volumes/redis/dump.rdb" || true
        rep "redis_dump → volumes/redis/dump.rdb"
      fi
    fi
  fi
  [[ -n "$SQL" ]] || { ok=false; fail_reasons+=("no sql dump in archive"); rep "FAIL no dump"; }
  rep "dump=$(basename "${SQL:-}") project_dir=${PROJ_DIR:-none}"
fi

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
    ok=false; fail_reasons+=("postgres not ready"); rep "FAIL pg_isready"
  else
    gzip -dc "$SQL" | docker exec -i "$PG_CID" \
      psql -q -U postgres -v ON_ERROR_STOP=0 >/dev/null 2>"${RUN_DIR}/psql.err" || true
    DB_TABLES="$(docker exec "$PG_CID" psql -U postgres -Atc \
      "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" \
      2>/dev/null || echo 0)"
    DB_TABLES="$(echo "$DB_TABLES" | tr -d '[:space:]')"
    [[ "$DB_TABLES" =~ ^[0-9]+$ ]] || DB_TABLES=0
    rep "db_tables=${DB_TABLES}"
    if (( DB_TABLES < 1 )); then
      ok=false; fail_reasons+=("no public tables after restore"); rep "FAIL empty schema"
    fi
  fi
fi

STACK_OK="skip"
STACK_DETAIL=""
SETTLE="$(rbv_cfg '.settle_seconds // 25')"

if [[ "$ok" == true && -n "${PROJ_DIR:-}" ]]; then
  CF=""
  for c in "${PROJ_DIR}/docker-compose.yml" "${PROJ_DIR}/docker-compose.yaml" \
           "${PROJ_DIR}/compose.yml" "${PROJ_DIR}/compose.yaml"; do
    [[ -f "$c" ]] && { CF="$c"; break; }
  done
  if [[ -n "$CF" ]]; then
    rep "compose found: $CF — изоляция"
    NET_NAME="rbv_net_${RUN_ID}"
    docker network create --internal "$NET_NAME" >/dev/null
    COMPOSE_FILE="${RUN_DIR}/compose.isolated.yml"

    if docker compose -f "$CF" config --format json >"${RUN_DIR}/compose.raw.json" 2>"${RUN_DIR}/compose.cfg.err"; then
      # Убираем postgres-сервисы (БД = наш контейнер с алиасами).
      # Redis и apps оставляем — для бота redis уже с dump.rdb.
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
      ' "${RUN_DIR}/compose.raw.json" > "$COMPOSE_FILE"

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
        STACK_DETAIL="compose up rc=${up_rc}: $(tail -n3 "${RUN_DIR}/compose.up.err" | tr '\n' ' ')"
        rep "FAIL stack: $STACK_DETAIL"
        ok=false
        fail_reasons+=("stack up failed")
      else
        sleep "$SETTLE"
        running="$(docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
        total="$(docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" ps -q 2>/dev/null | wc -l | tr -d ' ')"
        STACK_DETAIL="containers ${running}/${total}"
        leak=""
        sample="$(docker compose -f "$COMPOSE_FILE" -p "rbv_${RUN_ID}" ps -q 2>/dev/null | head -n1 || true)"
        if [[ -n "$sample" ]]; then
          if docker exec "$sample" getent hosts api.telegram.org >/dev/null 2>&1; then
            leak="LEAK: external DNS resolved"
            ok=false
            fail_reasons+=("$leak")
          fi
        fi
        if [[ "${running:-0}" -lt 1 ]]; then
          STACK_OK="fail"
          ok=false
          fail_reasons+=("no running containers")
        else
          STACK_OK="ok"
        fi
        rep "stack=${STACK_OK} ${STACK_DETAIL}${leak:+ · $leak}"
      fi
    else
      STACK_OK="skip"
      STACK_DETAIL="compose config failed"
      rep "WARN stack skipped: $(tail -n2 "${RUN_DIR}/compose.cfg.err" | tr '\n' ' ')"
    fi
  else
    rep "compose not found — только DB smoke"
  fi
fi

ended="$(date -Is)"
rep "finished=${ended}"
rep "result=$([[ $ok == true ]] && echo OK || echo FAIL)"
[[ ${#fail_reasons[@]} -gt 0 ]] && rep "reasons: ${fail_reasons[*]}"

icon="🟢"; [[ "$ok" == true ]] || icon="🔴"
TG_LINE="$(rbv_tg_for_storage "$SID")"
IFS='|' read -r TOK CHAT THREAD <<<"$TG_LINE"

reasons_txt="${fail_reasons[*]-}"
dump_base="$(basename "${SQL:-unknown}")"
if [[ "$ok" == true ]]; then
  result_line="Результат: OK"
else
  result_line="Результат: FAIL — ${reasons_txt}"
fi
body="$(printf '%s\n' \
  "${icon} <b>verify</b> ${SID}" \
  "Экземпляр: <code>${INST}</code>" \
  "Вид: ${KIND} · архив: <code>$(basename "$KEY")</code>" \
  "БД: tables=${DB_TABLES} · dump=${dump_base}" \
  "Стек: ${STACK_OK}${STACK_DETAIL:+ (${STACK_DETAIL})}" \
  "${result_line}" \
  "Время: ${ended}")"

notify_ok="$(rbv_cfg '.notify_on_success // true')"
if [[ "$ok" != true ]] || [[ "$notify_ok" == "true" ]]; then
  rbv_tg_send "$TOK" "$CHAT" "$body" "$THREAD"
fi

reasons_json='[]'
if [[ ${#fail_reasons[@]} -gt 0 ]]; then
  reasons_json="$(printf '%s\n' "${fail_reasons[@]}" | jq -R . | jq -s .)"
fi
jq -n \
  --arg sid "$SID" --arg kind "$KIND" --arg inst "$INST" --arg key "$KEY" \
  --argjson ok "$ok" --arg stack "$STACK_OK" --arg detail "$STACK_DETAIL" \
  --argjson tables "${DB_TABLES:-0}" --argjson reasons "$reasons_json" \
  '{storage:$sid,kind:$kind,instance:$inst,archive:$key,ok:$ok,db_tables:$tables,stack:$stack,stack_detail:$detail,reasons:$reasons}' \
  > "${RUN_DIR}/summary.json"

[[ "$ok" == true ]]
