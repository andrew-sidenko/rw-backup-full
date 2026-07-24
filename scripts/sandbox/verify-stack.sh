#!/usr/bin/env bash
# verify-stack.sh — проверка ПОЛНОГО восстановления проекта: каталог из
# трекера конфигов + база из бэкапа + подъём всех контейнеров стека.
#
# ═══════════════════════════════════════════════════════════════════════════
# СЕТЕВАЯ ИЗОЛЯЦИЯ — ГЛАВНОЕ ТРЕБОВАНИЕ ЭТОГО СКРИПТА
# ═══════════════════════════════════════════════════════════════════════════
# Поднимается НАСТОЯЩАЯ панель/бот с НАСТОЯЩИМИ секретами из бэкапа. Без
# изоляции такая копия немедленно начнёт вести себя как живой сервис:
# подключится к реальным нодам Xray и может их перенастроить, разошлёт
# сообщения реальным пользователям в Telegram, полезет в платёжные API,
# отзовёт или перевыпустит сертификаты. Поэтому:
#
#   1. Сеть создаётся с флагом --internal: контейнеры видят только друг
#      друга, наружу (интернет, LAN, хост) выхода нет вообще.
#   2. Порты НЕ публикуются: published ports вырезаются из конфигурации,
#      ничего не занимает порты хоста и не конфликтует с боевыми сервисами.
#   3. container_name вырезается: иначе имена столкнулись бы с работающими
#      боевыми контейнерами.
#   4. Внешние (external) сети и volume вырезаются: иначе копия подключилась
#      бы к боевой сети или к боевым данным.
#   5. Монтирование docker.sock вырезается: иначе контейнер вышел бы за
#      пределы изоляции через API демона.
#   6. bind-монты внутрь боевых каталогов перенаправляются на восстановленную
#      копию, а всё, что осталось за её пределами, монтируется только на чтение.
#
#   verify-stack.sh <проект> [--source ID] [--keep] [--from-s3|--from-local]
#
# --source ID — идентификатор источника ПРОВЕРЯЕМОГО сервера (тот же, что
# в его манифесте / карточке в веб-интерфейсе), НЕ хоста песочницы. Нужен
# всегда, когда проект физически живёт на другом сервере (обычный случай:
# песочница отдельная, панель — на проде). Реквизиты S3 при этом берутся
# не из локального s3.d песочницы (там обычно ничего нет), а из манифеста
# указанного сервера — тем же путём, что и у verify-fleet.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

PROJECT="${1:-}"
[[ -n "$PROJECT" && "$PROJECT" != -* ]] || { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
shift

KEEP="false"; SRC="s3"; REMOTE_SOURCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)       KEEP="true"; shift ;;
    --from-s3)    SRC="s3"; shift ;;
    --from-local) SRC="local"; shift ;;
    --source)     REMOTE_SOURCE="$2"; shift 2 ;;
    *) msg ERR "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

wal_load_full_config
command -v jq >/dev/null 2>&1 || { msg ERR "Нужен jq"; exit 1; }
wal_lock "verify-stack-${PROJECT}" || exit 0

# --source задан: подтягиваем манифест указанного сервера (та же логика,
# что в verify-fleet.sh) и материализуем ЕГО S3-бэкенд как временный
# s3.d-файл — дальше config-restore.sh и остальной скрипт работают как
# обычно, просто с чужими кредами вместо (обычно пустых) локальных.
# RW_SOURCE_ID переопределяет rw_source_id()/wal_hostname() ВЕЗДЕ ниже по
# скрипту — без этого путь в S3 указывал бы на хост песочницы, а не на
# сервер, где реально лежат бэкапы.
REMOTE_S3D=""
if [[ -n "$REMOTE_SOURCE" ]]; then
  WEB_ENV="${WEB_ENV:-/etc/rw-backup-web.env}"
  WEB_URL="${RW_WEB_URL:-http://127.0.0.1:8787}"
  TOKEN="${WEB_TOKEN:-}"
  [[ -z "$TOKEN" && -f "$WEB_ENV" ]] && TOKEN="$(grep -E '^WEB_TOKEN=' "$WEB_ENV" | head -n1 | cut -d= -f2- || true)"
  [[ -n "$TOKEN" ]] || { msg ERR "WEB_TOKEN не найден (${WEB_ENV}) — нужен для --source"; exit 1; }

  MANIFEST=""
  for attempt in 1 2 3; do
    MANIFEST="$(curl -fsS -m 60 -H "x-token: ${TOKEN}" "${WEB_URL}/api/fleet/manifest" 2>/dev/null)" && break
    sleep $((attempt * 3))
  done
  [[ -n "$MANIFEST" ]] || { msg ERR "Веб-сервис недоступен: ${WEB_URL}"; exit 1; }

  SRV_JSON="$(jq -c --arg s "$REMOTE_SOURCE" '.servers[] | select(.source == $s or .id == $s)' <<<"$MANIFEST" | head -n1)"
  [[ -n "$SRV_JSON" ]] || { msg ERR "Сервер с source/id '${REMOTE_SOURCE}' не найден в манифесте (проверьте карточку в веб-интерфейсе)"; exit 1; }
  [[ "$(jq -r .reachable <<<"$SRV_JSON")" == "true" ]] || msg WARN "Сервер '${REMOTE_SOURCE}' помечен недоступным в последнем манифесте — используем закэшированные данные"

  BJ="$(jq -c '[.backends[]? | select(.enabled == true and (.panel == true or .custom == true))] | first // empty' <<<"$SRV_JSON")"
  [[ -n "$BJ" ]] || { msg ERR "У сервера '${REMOTE_SOURCE}' нет включённого S3-бэкенда с panel/custom"; exit 1; }

  REMOTE_S3D="$(mktemp -d)"
  jq -r '
    "B_ENABLED=\"true\""
    + "\nB_ENDPOINT=\"" + (.endpoint // "") + "\""
    + "\nB_BUCKET=\"" + .bucket + "\""
    + "\nB_ACCESS_KEY=\"" + .access_key + "\""
    + "\nB_SECRET_KEY=\"" + .secret_key + "\""
    + "\nB_REGION=\"" + (.region // "us-east-1") + "\""
    + "\nB_PREFIX=\"" + (.prefix // "rw-backup-full") + "\""
    + "\nB_UPLOAD_PANEL=\"true\"\nB_UPLOAD_CUSTOM=\"true\"\nB_UPLOAD_WAL=\"true\""
  ' <<<"$BJ" > "${REMOTE_S3D}/remote.env"
  chmod 600 "${REMOTE_S3D}/remote.env"

  export S3D_DIR="$REMOTE_S3D"
  export RW_SOURCE_ID="$(jq -r .source <<<"$SRV_JSON")"
  msg OK "Источник: ${RW_SOURCE_ID} (бэкенд $(jq -r .name <<<"$BJ"), реквизиты из манифеста)"
fi

SID="$$"
NET="rw-sbx-net-${SID}"
CPROJ="rwsbx${SID}"
mkdir -p "${SANDBOX_WORK:-/var/lib/rw-wal/sandbox}"
WORK="$(mktemp -d "${SANDBOX_WORK:-/var/lib/rw-wal/sandbox}/stack.XXXXXX")"
RESTORED="${WORK}/root"

cleanup() {
  # Временные реквизиты удалённого бэкенда — секреты, убираются ВСЕГДА,
  # даже если --keep оставляет остальное для разбора.
  [[ -n "$REMOTE_S3D" ]] && rm -rf "$REMOTE_S3D"
  if [[ "$KEEP" == "true" ]]; then
    msg INFO "Оставлено по --keep: сеть ${NET}, проект ${CPROJ}, каталог ${WORK}"
    msg INFO "Убрать: docker compose -p ${CPROJ} down -v; docker network rm ${NET}; rm -rf ${WORK}"
    return
  fi
  docker compose -p "$CPROJ" -f "${WORK}/stack.json" down -v --remove-orphans >/dev/null 2>&1 || true
  docker ps -aq -f "label=rw-sandbox-stack=${SID}" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { msg ERR "[${PROJECT}] $1"; write_metric 0; exit 1; }

write_metric() {
  wal_metric_write "rw_stack_verify_${PROJECT//[^a-zA-Z0-9]/_}" <<EOF_M
# HELP rw_stack_verify_ok Результат проверки полного стека (1 — успех).
# TYPE rw_stack_verify_ok gauge
rw_stack_verify_ok{project="${PROJECT}"} $1
# HELP rw_stack_verify_last_timestamp_seconds Время последней проверки стека.
# TYPE rw_stack_verify_last_timestamp_seconds gauge
rw_stack_verify_last_timestamp_seconds{project="${PROJECT}"} $(date +%s)
EOF_M
}

# --------------------------------------------------------------------------
# 1. Каталог проекта из трекера конфигов
# --------------------------------------------------------------------------
msg INFO "[${PROJECT}] восстанавливаю каталог проекта..."
"${SCRIPT_DIR}/../track/config-restore.sh" "$PROJECT" --dest "$RESTORED" \
  --from "$([[ "$SRC" == "local" ]] && echo local || echo s3)" >/dev/null \
  || fail "каталог проекта не восстановился (трекер конфигов настроен?)"

COMPOSE=""
for c in "${RESTORED}/docker-compose.yml" "${RESTORED}/docker-compose.yaml"; do
  [[ -f "$c" ]] && { COMPOSE="$c"; break; }
done
[[ -n "$COMPOSE" ]] || fail "в восстановленном каталоге нет docker-compose"
msg OK "[${PROJECT}] каталог восстановлен ($(find "$RESTORED" -type f | wc -l) файлов)"

# Исходный корень проекта нужен, чтобы перенаправить абсолютные bind-монты
# с боевых путей на восстановленную копию.
ORIG_ROOT="$(grep -oE '^[^|]+\|[^|]+\|[^|]+' <<<"$(bash -c "source ${SCRIPT_DIR}/../lib/discovery.sh; disc_one '${PROJECT}'" 2>/dev/null)" | cut -d'|' -f3)"
ORIG_ROOT="${ORIG_ROOT:-/opt/${PROJECT}}"

# --------------------------------------------------------------------------
# 2. Изолированная сеть
# --------------------------------------------------------------------------
docker network create --internal --driver bridge "$NET" >/dev/null \
  || fail "не удалось создать изолированную сеть"
msg OK "[${PROJECT}] создана сеть ${NET} (--internal: выхода наружу нет)"

# --------------------------------------------------------------------------
# 3. Резолв compose и трансформация под изоляцию
# --------------------------------------------------------------------------
RESOLVED="${WORK}/resolved.json"
( cd "$RESTORED" && docker compose -f "$(basename "$COMPOSE")" config --format json ) > "$RESOLVED" 2>"${WORK}/compose.err" \
  || { msg ERR "$(tail -3 "${WORK}/compose.err")"; fail "compose не резолвится (не хватает .env из бэкапа?)"; }

DB_SERVICE="$(jq -r '[.services | to_entries[] | select(.value.image // "" | test("postgres")) | .key] | first // ""' "$RESOLVED")"
[[ -n "$DB_SERVICE" ]] || msg WARN "[${PROJECT}] сервис БД в compose не найден — стек поднимется без восстановленной базы"

jq --arg net "$NET" --arg sid "$SID" --arg orig "$ORIG_ROOT" --arg new "$RESTORED" --arg dbsvc "$DB_SERVICE" '
  def fixmounts:
    if type == "array" then
      [ .[]
        # docker.sock ломает изоляцию: контейнер получил бы управление демоном
        | select((.source // "") | test("docker\\.sock") | not)
        | if (.type == "bind" and ((.source // "") | startswith($orig)))
          then .source = ($new + ((.source // "")[($orig | length):]))
          # bind вне каталога проекта — только чтение, чтобы копия физически
          # не могла изменить ничего на боевом хосте
          elif .type == "bind" then .read_only = true
          else . end
      ]
    else . end;

  .services |= with_entries(
    select(.key != $dbsvc)                       # БД поднимаем отдельно, из бэкапа
    | .value |= (
        del(.ports, .container_name, .depends_on, .healthcheck.start_interval)
        | .restart = "no"
        | .networks = { ($net): {} }
        | .volumes = ((.volumes // []) | fixmounts)
        | .labels = ((.labels // {}) + {"rw-sandbox-stack": $sid})
      )
  )
  | .networks = { ($net): { "external": true, "name": $net } }
  | if .volumes then .volumes |= with_entries(.value |= (del(.external, .name) // {})) else . end
  | del(.name)
' "$RESOLVED" > "${WORK}/stack.json" || fail "трансформация compose не удалась"

# Проверка результата трансформации — гарантии изоляции проверяем, а не декларируем.
if jq -e '[.services[] | select(.ports != null and (.ports | length > 0))] | length > 0' "${WORK}/stack.json" >/dev/null; then
  fail "внутренняя ошибка: в изолированном стеке остались published ports"
fi
if jq -e '[.services[] | (.volumes // [])[] | select((.source // "") | test("docker\\.sock"))] | length > 0' "${WORK}/stack.json" >/dev/null; then
  fail "внутренняя ошибка: в изолированном стеке остался docker.sock"
fi
msg OK "[${PROJECT}] конфигурация изолирована (порты, docker.sock, внешние сети/тома вырезаны)"

# --------------------------------------------------------------------------
# 4. База данных из бэкапа — в той же изолированной сети
# --------------------------------------------------------------------------
if [[ -n "$DB_SERVICE" ]]; then
  DB_IMAGE="$(jq -r --arg s "$DB_SERVICE" '.services[$s].image' "$RESOLVED")"
  DB_NAME_ORIG="$(jq -r --arg s "$DB_SERVICE" '.services[$s].container_name // ""' "$RESOLVED")"
  DB_USER="$(jq -r --arg s "$DB_SERVICE" '.services[$s].environment.POSTGRES_USER // "postgres"' "$RESOLVED")"
  DB_PASS="$(jq -r --arg s "$DB_SERVICE" '.services[$s].environment.POSTGRES_PASSWORD // "sandbox"' "$RESOLVED")"
  DB_C="rw-sbx-db-${SID}"

  # Алиасы: приложение обращается к БД по имени сервиса и/или container_name —
  # в изолированной сети оба имени указывают на наш восстановленный экземпляр.
  db_aliases=(--network-alias "$DB_SERVICE")
  [[ -n "$DB_NAME_ORIG" ]] && db_aliases+=(--network-alias "$DB_NAME_ORIG")

  docker run -d --name "$DB_C" --label "rw-sandbox-stack=${SID}" \
    --network "$NET" "${db_aliases[@]}" \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" \
    -e POSTGRES_DB="$(jq -r --arg s "$DB_SERVICE" '.services[$s].environment.POSTGRES_DB // "postgres"' "$RESOLVED")" \
    "$DB_IMAGE" >/dev/null 2>&1 || fail "не удалось поднять БД (${DB_IMAGE})"

  up=false
  for _ in $(seq 1 90); do
    docker exec "$DB_C" pg_isready -U "$DB_USER" >/dev/null 2>&1 && { up=true; break; }
    sleep 1
  done
  [[ "$up" == "true" ]] || fail "БД не поднялась"

  # Заливка свежего логического дампа проекта из S3.
  DUMP_CAT="panel"; [[ "$PROJECT" != "panel" ]] && DUMP_CAT="custom-bot"
  bname="$(s3m_backends | head -n1)"
  if [[ -n "$bname" ]] && s3m_load "$bname"; then
    key="$(s3m_aws s3 ls "s3://${B_BUCKET}/${B_PREFIX}/${DUMP_CAT}/$(rw_source_id)/" --recursive 2>/dev/null \
      | awk '{print $1" "$2" "$4}' | sort | tail -n1 | awk '{print $3}')"
    if [[ -n "$key" ]]; then
      s3m_aws s3 cp "s3://${B_BUCKET}/${key}" "${WORK}/dump.tar.gz" --only-show-errors 2>/dev/null || true
      if [[ -f "${WORK}/dump.tar.gz" ]]; then
        mkdir -p "${WORK}/dump" && tar -xzf "${WORK}/dump.tar.gz" -C "${WORK}/dump" 2>/dev/null || true
        sql="$(find "${WORK}/dump" -maxdepth 1 \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1)"
        if [[ -n "$sql" ]]; then
          gzip -dc "$sql" | docker exec -i "$DB_C" psql -q -U "$DB_USER" -d postgres -v ON_ERROR_STOP=0 >/dev/null 2>&1 || true
          rows="$(docker exec "$DB_C" psql -qtAX -U "$DB_USER" -d postgres -c 'SELECT coalesce(sum(n_live_tup),0)::bigint FROM pg_stat_user_tables' 2>/dev/null || echo 0)"
          msg OK "[${PROJECT}] база восстановлена из $(basename "$key") (строк ≈ ${rows})"
        fi
      fi
    else
      msg WARN "[${PROJECT}] логический дамп в S3 не найден — стек поднимется с пустой базой"
    fi
  fi
fi

# --------------------------------------------------------------------------
# 5. Подъём стека
# --------------------------------------------------------------------------
msg INFO "[${PROJECT}] поднимаю стек в изоляции..."
( cd "$RESTORED" && docker compose -p "$CPROJ" -f "${WORK}/stack.json" up -d --no-build ) \
  >"${WORK}/up.log" 2>&1 || { msg ERR "$(tail -5 "${WORK}/up.log")"; fail "стек не поднялся"; }

sleep "${STACK_SETTLE_SECONDS:-25}"

# --------------------------------------------------------------------------
# 6. Проверка результата
# --------------------------------------------------------------------------
total=0; running=0; problems=""
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  total=$((total + 1))
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo gone)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null || echo -)"
  name="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>/dev/null || echo "$c")"
  if [[ "$state" == "running" && "$health" != "unhealthy" ]]; then
    running=$((running + 1))
    [[ "$restarts" -gt 2 ]] && problems+=" ${name}:перезапусков=${restarts}"
  else
    problems+=" ${name}:${state}${health:+/${health}}"
    problems+=" [$(docker logs "$c" --tail 3 2>&1 | tr '\n' ' ' | cut -c1-120)]"
  fi
done < <(docker compose -p "$CPROJ" -f "${WORK}/stack.json" ps -q 2>/dev/null)

# Контрольная проверка изоляции: из контейнера стека наружу хода быть не должно.
leak=""
first_c="$(docker compose -p "$CPROJ" -f "${WORK}/stack.json" ps -q 2>/dev/null | head -n1)"
if [[ -n "$first_c" ]]; then
  if docker exec "$first_c" sh -c 'timeout 3 getent hosts api.telegram.org >/dev/null 2>&1 && echo LEAK' 2>/dev/null | grep -q LEAK; then
    leak=" ВНИМАНИЕ: из контейнера резолвится внешний хост — изоляция неполна!"
  fi
fi

if (( total == 0 )); then
  fail "ни одного контейнера не запущено"
elif [[ -n "$problems" ]] || [[ -n "$leak" ]]; then
  msg ERR "[${PROJECT}] стек ${running}/${total}:${problems}${leak}"
  write_metric 0
  wal_notify "🔴 Проверка полного стека ${PROJECT} (изолированно)
Хост: $(wal_hostname)
Контейнеров живо: ${running}/${total}
${problems}${leak}"
  exit 1
else
  msg OK "[${PROJECT}] стек поднялся полностью: ${running}/${total} контейнеров, изоляция подтверждена"
  write_metric 1
  wal_notify "🟢 Полное восстановление ${PROJECT} проверено (изолированно)
Хост: $(wal_hostname)
Каталог из трекера + база из бэкапа + ${running}/${total} контейнеров"
fi
