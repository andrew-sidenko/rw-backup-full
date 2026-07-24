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
#   verify-stack.sh <проект> [--source ID] [--keep] [--db-mode dump|base|pitr]
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

KEEP="false"; SRC="s3"; REMOTE_SOURCE=""; DB_MODE_FORCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)       KEEP="true"; shift ;;
    --from-s3)    SRC="s3"; shift ;;
    --from-local) SRC="local"; shift ;;
    --source)     REMOTE_SOURCE="$2"; shift 2 ;;
    # Ручной выбор способа подъёма БД; без него работает ротация
    # (см. verify-plan.sh): каждый новый дамп и базовый бэкап — по разу,
    # остальные прогоны — PITR на равномерные точки внутри WAL.
    --db-mode)    DB_MODE_FORCE="$2"; shift 2 ;;
    *) msg ERR "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done
case "${DB_MODE_FORCE:-}" in
  ""|dump|base|pitr) ;;
  *) msg ERR "--db-mode: допустимо dump | base | pitr"; exit 1 ;;
esac

wal_load_full_config
command -v jq >/dev/null 2>&1 || { msg ERR "Нужен jq"; exit 1; }
wal_lock "verify-stack-${PROJECT}" || exit 0

PROFILES_DIR="${PROFILES_DIR:-${INSTALL_DIR}/verify-profiles.d}"
# Проверка СОДЕРЖИМОГО восстановленной БД тем же профилем, что и в
# verify-fleet.sh (verify-profiles.d/<тип>.env): обязательные таблицы,
# минимум таблиц/строк. Без этого "стек поднялся" означало только "процессы
# запущены", а не "данные реально там".
load_profile() { # <kind>
  PROFILE_REQUIRED_TABLES=""; PROFILE_MIN_TABLES="1"; PROFILE_MIN_TOTAL_ROWS="1"
  local f="${PROFILES_DIR}/$1.env"
  if [[ -f "$f" ]]; then
    set +u; # shellcheck disable=SC1090
    source "$f"; set -u
  fi
}

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

  # Telegram — та же ошибка предположения "один хост": wal_notify по
  # умолчанию берёт FULL_TG_BOT_TOKEN/CHAT_ID из ЛОКАЛЬНОГО конфига
  # песочницы, который обычно пуст (уведомления настроены на самом
  # проекте). Манифест сервера уже несёт его собственные настройки —
  # переопределяем ими на время этого запуска.
  SRV_TG_TOKEN="$(jq -r '.telegram.token // ""' <<<"$SRV_JSON")"
  SRV_TG_CHAT="$(jq -r '.telegram.chat_id // ""' <<<"$SRV_JSON")"
  SRV_TG_THREAD="$(jq -r '.telegram.thread_id // ""' <<<"$SRV_JSON")"
  if [[ -n "$SRV_TG_TOKEN" && -n "$SRV_TG_CHAT" ]]; then
    FULL_TG_BOT_TOKEN="$SRV_TG_TOKEN"
    FULL_TG_CHAT_ID="$SRV_TG_CHAT"
    FULL_TG_MESSAGE_THREAD_ID="$SRV_TG_THREAD"
  else
    msg WARN "У сервера '${REMOTE_SOURCE}' не настроен Telegram в манифесте — уведомление о результате не уйдёт (только метрика и лог)"
  fi

  msg OK "Источник: ${RW_SOURCE_ID} (бэкенд $(jq -r .name <<<"$BJ"), реквизиты из манифеста)"

  # Тип инстанса и контрольные таблицы — для проверки СОДЕРЖИМОГО БД
  # (не только «контейнер жив»), тем же профилем, что использует verify-fleet.
  IJ="$(jq -c --arg n "$PROJECT" '.instances[]? | select(.name == $n)' <<<"$SRV_JSON" | head -n1)"
  [[ -n "$IJ" ]] && INST_KIND_REMOTE="$(jq -r '.kind // "bot"' <<<"$IJ")" || INST_KIND_REMOTE="$([[ "$PROJECT" == "panel" ]] && echo panel || echo bot)"
  [[ -n "$IJ" ]] && INST_VTABLES_REMOTE="$(jq -r '.verify_tables // ""' <<<"$IJ")" || INST_VTABLES_REMOTE=""
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

NOTIFIED="false"
notify_failure() { # <причина>
  # Единая точка выхода для ЛЮБОГО отказа — и явного (fail()), и неожиданного
  # (перехваченного ERR trap'ом ниже). Раньше на неявных сбоях (например,
  # command not found, unbound variable, любая непроверенная команда под
  # set -e где-то в середине скрипта) выполнение обрывалось молча: без
  # сообщения в консоль, без Telegram, без метрики — только пустой возврат
  # в шелл. Гвард NOTIFIED защищает от двойного уведомления, если fail()
  # уже отчитался, а следом ещё сработает ERR trap на его же exit.
  [[ "$NOTIFIED" == "true" ]] && return
  NOTIFIED="true"
  local reason="$1"
  msg ERR "[${PROJECT}] ${reason}"
  write_metric 0
  wal_notify "🔴 Проверка полного стека ${PROJECT} — сбой
Хост: $(wal_hostname)
${reason}"
}

fail() { notify_failure "$1"; exit 1; }

# errtrace: ERR-ловушка должна срабатывать и внутри функций/подстановок,
# не только в теле скрипта верхнего уровня.
set -o errtrace
trap 'notify_failure "неожиданная ошибка (строка ${LINENO}, команда: ${BASH_COMMAND})"' ERR

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

# Исходный корень проекта нужен, чтобы перенаправить АБСОЛЮТНЫЕ bind-монты
# (не './относительные' — те и так резолвятся compose'ом относительно
# восстановленного каталога правильно сами) с боевых путей на копию.
#
# lib/discovery.sh ищет проект ЛОКАЛЬНО по running-контейнерам — при
# --source (обычный случай: песочница отдельная от прода) это ничего не
# найдёт и раньше молча подставляло неверный /opt/<project>. Для панели
# используем ту же конвенцию, что и panel-backup.sh (PANEL_ROOT_DIR); для
# ботов такой конвенции нет — путь можно узнать только с самого сервера,
# поэтому честно предупреждаем об ограничении, а не подставляем догадку.
if [[ "$PROJECT" == "panel" ]]; then
  ORIG_ROOT="${PANEL_ROOT_DIR:-/opt/remnawave}"
else
  ORIG_ROOT="$(grep -oE '^[^|]+\|[^|]+\|[^|]+' <<<"$(bash -c "source ${SCRIPT_DIR}/../lib/discovery.sh; disc_one '${PROJECT}'" 2>/dev/null)" | cut -d'|' -f3)"
  if [[ -z "$ORIG_ROOT" ]]; then
    if [[ -n "$REMOTE_SOURCE" ]]; then
      msg WARN "[${PROJECT}] исходный путь бота неизвестен в режиме --source — абсолютные bind-монты (если есть в compose, помимо ./относительных) не будут перенаправлены на восстановленную копию"
    fi
    ORIG_ROOT="/opt/${PROJECT}"
  fi
fi
msg INFO "[${PROJECT}] исходный каталог (для перенаправления bind-монтов): ${ORIG_ROOT}"

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
DB_PROFILE_FAIL=""
DB_MODE_DESC=""

# Общая проверка содержимого — одна и та же для любого способа восстановления
# (логический дамп / базовый бэкап / PITR), чтобы критерий "данные на месте"
# не зависел от того, каким путём БД подняли.
check_db_profile() { # <контейнер> <пользователь>
  local c="$1" u="$2" rows tables cnt tbl
  tables="$(docker exec "$c" psql -qtAX -U "$u" -d postgres -c 'SELECT count(*) FROM pg_stat_user_tables' 2>/dev/null || echo 0)"
  rows="$(docker exec "$c" psql -qtAX -U "$u" -d postgres -c 'SELECT coalesce(sum(n_live_tup),0)::bigint FROM pg_stat_user_tables' 2>/dev/null || echo 0)"
  load_profile "${INST_KIND_REMOTE:-$([[ "$PROJECT" == "panel" ]] && echo panel || echo bot)}"
  (( ${tables:-0} < ${PROFILE_MIN_TABLES:-1} )) && DB_PROFILE_FAIL+=" таблиц=${tables}<${PROFILE_MIN_TABLES}"
  (( ${rows:-0} < ${PROFILE_MIN_TOTAL_ROWS:-1} )) && DB_PROFILE_FAIL+=" строк=${rows}<${PROFILE_MIN_TOTAL_ROWS}"
  for tbl in ${INST_VTABLES_REMOTE:-} ${PROFILE_REQUIRED_TABLES:-}; do
    [[ -n "$tbl" ]] || continue
    cnt="$(docker exec "$c" psql -qtAX -U "$u" -d postgres -c "SELECT count(*) FROM ${tbl}" 2>/dev/null || echo FAIL)"
    if [[ "$cnt" == "FAIL" ]]; then DB_PROFILE_FAIL+=" ${tbl}:отсутствует"
    elif [[ "$cnt" == "0" ]]; then DB_PROFILE_FAIL+=" ${tbl}:пустая"; fi
  done
  msg INFO "[${PROJECT}] данные: таблиц=${tables}, строк ≈ ${rows}"
  if [[ -n "$DB_PROFILE_FAIL" ]]; then
    msg ERR "[${PROJECT}] проверка данных не прошла:${DB_PROFILE_FAIL}"
  else
    msg OK "[${PROJECT}] проверка данных пройдена (профиль ${INST_KIND_REMOTE:-panel})"
  fi
}

# Восстановление БД из базового бэкапа + WAL (режимы base/pitr). Поднимается
# в ТОЙ ЖЕ изолированной сети и с теми же сетевыми алиасами, что и при
# логическом дампе, — приложение стека не видит разницы.
restore_db_from_wal() { # <meta-файл в S3> <target-time|"">
  local meta_name="$1" target_time="$2"
  local wal_base="${B_PREFIX}/wal/$(rw_source_id)/${PROJECT}"
  local pgdata="${WORK}/pgdata" walstage="${WORK}/walstage"
  mkdir -p "$pgdata" "$walstage"

  s3m_aws s3 cp "s3://${B_BUCKET}/${wal_base}/basebackup/${meta_name}" "${WORK}/backup.meta" \
    --only-show-errors 2>/dev/null || { msg ERR "не скачался ${meta_name}"; return 1; }

  local BACKUP_NAME FILE SHA256 START_SEGMENT PG_VERSION_NUM ENCRYPTED
  set +u; # shellcheck disable=SC1090
  source "${WORK}/backup.meta"; set -u

  if truthy "${ENCRYPTED:-false}" && [[ -z "${SANDBOX_AGE_IDENTITY:-}" || ! -f "${SANDBOX_AGE_IDENTITY:-}" ]]; then
    msg ERR "базовый бэкап зашифрован, SANDBOX_AGE_IDENTITY не задан"; return 1
  fi

  s3m_aws s3 cp "s3://${B_BUCKET}/${wal_base}/basebackup/${FILE}" "${WORK}/${FILE}" \
    --only-show-errors 2>/dev/null || { msg ERR "не скачался ${FILE}"; return 1; }
  local actual; actual="$(sha256sum "${WORK}/${FILE}" | awk '{print $1}')"
  [[ "$actual" == "$SHA256" ]] || { msg ERR "SHA256 базового бэкапа не совпадает"; return 1; }

  unpack_one() { # <имя файла>
    local n="$1" b="$1"
    if [[ "$b" == *.age ]]; then
      b="${b%.age}"; age -d -i "$SANDBOX_AGE_IDENTITY" | wal_decompress_stream "$b"
    else
      wal_decompress_stream "$b"
    fi
  }

  unpack_one "$FILE" < "${WORK}/${FILE}" | tar -xf - -C "$pgdata" 2>/dev/null
  [[ -f "${pgdata}/PG_VERSION" ]] || { msg ERR "после распаковки нет PG_VERSION"; return 1; }

  # Стейджинг WAL. .backup-файлы исключаются явно: их первые 24 символа
  # совпадают с именем сегмента, и без фильтра backup-label подменял бы
  # собой настоящий 16-МБ сегмент (см. CHANGELOG v5.2.0).
  local staged=0 key seg is_hist
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    [[ "$key" == *.backup* ]] && continue
    seg="${key:0:24}"; is_hist="false"
    [[ "$key" == *.history* ]] && { is_hist="true"; seg="${key%%.history*}.history"; }
    # shellcheck disable=SC2071
    if [[ "$is_hist" == "true" ]] || [[ "$seg" > "$START_SEGMENT" ]] || [[ "$seg" == "$START_SEGMENT" ]]; then
      [[ -f "${walstage}/${seg}" ]] && continue
      if s3m_aws s3 cp "s3://${B_BUCKET}/${wal_base}/wal/${key}" - --only-show-errors 2>/dev/null \
           | unpack_one "$key" > "${walstage}/${seg}.part" 2>/dev/null; then
        mv -f "${walstage}/${seg}.part" "${walstage}/${seg}"
        staged=$((staged + 1))
      fi
    fi
  done < <(s3m_aws s3 ls "s3://${B_BUCKET}/${wal_base}/wal/" 2>/dev/null | awk '{print $4}' | sort)

  local uid
  uid="$(docker run --rm --entrypoint id "$DB_IMAGE" -u postgres 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || uid=999
  chown -R "${uid}:${uid}" "$pgdata" "$walstage" 2>/dev/null || true
  chmod 0700 "$pgdata"

  {
    echo ""
    echo "archive_mode = 'off'"
    echo "archive_command = ''"
    echo "restore_command = 'cp /wal-archive/%f %p'"
    echo "recovery_target_action = 'promote'"
    [[ -n "$target_time" ]] && echo "recovery_target_time = '${target_time}'"
  } >> "${pgdata}/postgresql.auto.conf"
  touch "${pgdata}/recovery.signal"
  rm -f "${pgdata}/postmaster.pid"

  docker run -d --name "$DB_C" --label "rw-sandbox-stack=${SID}" \
    --network "$NET" "${db_aliases[@]}" \
    -v "${pgdata}:/var/lib/postgresql/data" \
    -v "${walstage}:/wal-archive:ro" \
    -e POSTGRES_PASSWORD="$DB_PASS" \
    "$DB_IMAGE" -c listen_addresses='*' >/dev/null 2>&1 \
    || { msg ERR "контейнер БД не создался"; return 1; }

  local recovered=false in_rec
  for _ in $(seq 1 300); do
    if docker exec "$DB_C" pg_isready -h localhost -U "$DB_USER" >/dev/null 2>&1; then
      in_rec="$(docker exec "$DB_C" psql -h localhost -U "$DB_USER" -d postgres -qtAX \
        -c 'SELECT pg_is_in_recovery()' 2>/dev/null | tr -d ' ' || echo t)"
      [[ "$in_rec" == "f" ]] && { recovered=true; break; }
    fi
    docker ps -q -f "name=${DB_C}" | grep -q . || break
    sleep 2
  done

  if [[ "$recovered" != "true" ]]; then
    msg ERR "восстановление не завершилось. Логи БД:"
    docker logs "$DB_C" --tail 20 2>&1 | sed 's/^/    /' >&2
    return 1
  fi
  msg OK "[${PROJECT}] БД восстановлена: ${BACKUP_NAME} + ${staged} WAL-сегментов${target_time:+ на момент ${target_time}}"
  return 0
}

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

  bname="$(s3m_backends | head -n1)"
  if [[ -z "$bname" ]] || ! s3m_load "$bname"; then
    msg WARN "[${PROJECT}] S3-бэкенд недоступен — стек поднимется с пустой базой"
    PLAN_MODE="none"
  elif [[ -n "$DB_MODE_FORCE" ]]; then
    # Ручной выбор режима имеет приоритет над ротацией.
    PLAN_MODE="$DB_MODE_FORCE"
    if [[ "$PLAN_MODE" == "dump" ]]; then
      PLAN_KEY="$(s3m_aws s3 ls "s3://${B_BUCKET}/${B_PREFIX}/$([[ "$PROJECT" == "panel" ]] && echo panel || echo custom-bot)/$(rw_source_id)/" --recursive 2>/dev/null \
        | awk '{print $1" "$2" "$4}' | sort | tail -n1 | awk '{print $3}')"
    else
      PLAN_META="$(s3m_aws s3 ls "s3://${B_BUCKET}/${B_PREFIX}/wal/$(rw_source_id)/${PROJECT}/basebackup/" 2>/dev/null \
        | awk '{print $4}' | grep -E '^base_.*\.meta$' | sort | tail -n1)"
      PLAN_TARGET=""
    fi
  else
    # Ротация: каждый новый дамп и каждый новый базовый бэкап проверяются
    # по разу, остальные прогоны — PITR на равномерные точки внутри WAL.
    PLAN="$(AWS_ACCESS_KEY_ID="$B_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$B_SECRET_KEY" \
            AWS_DEFAULT_REGION="${B_REGION:-us-east-1}" \
            AWS_ENDPOINT_URL="${B_ENDPOINT:-}" \
            "${SCRIPT_DIR}/verify-plan.sh" "$PROJECT" "$(rw_source_id)" "$B_BUCKET" "$B_PREFIX" 2>/dev/null || true)"
    PLAN_MODE="$(grep -oE 'MODE=[a-z]+' <<<"$PLAN" | cut -d= -f2 || true)"
    PLAN_KEY="$(grep -oE 'KEY=[^ ]+' <<<"$PLAN" | cut -d= -f2 || true)"
    PLAN_META="$(grep -oE 'META=[^ ]+' <<<"$PLAN" | cut -d= -f2 || true)"
    PLAN_TARGET="$(sed -n 's/.*TARGET_TIME=\(.*\) SLOT=.*/\1/p' <<<"$PLAN")"
    PLAN_SLOT="$(grep -oE 'SLOT=[0-9]+/[0-9]+' <<<"$PLAN" | cut -d= -f2 || true)"
    [[ -n "$PLAN" ]] && msg INFO "[${PROJECT}] план проверки: ${PLAN}"
  fi

  case "${PLAN_MODE:-none}" in
    dump)
      DB_MODE_DESC="логический дамп"
      msg INFO "[${PROJECT}] поднимаю БД из логического дампа..."
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
      if [[ -n "${PLAN_KEY:-}" ]]; then
        s3m_aws s3 cp "s3://${B_BUCKET}/${PLAN_KEY}" "${WORK}/dump.tar.gz" --only-show-errors 2>/dev/null || true
        if [[ -f "${WORK}/dump.tar.gz" ]]; then
          mkdir -p "${WORK}/dump" && tar -xzf "${WORK}/dump.tar.gz" -C "${WORK}/dump" 2>/dev/null || true
          sql="$(find "${WORK}/dump" -maxdepth 1 \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1)"
          if [[ -n "$sql" ]]; then
            gzip -dc "$sql" | docker exec -i "$DB_C" psql -q -U "$DB_USER" -d postgres -v ON_ERROR_STOP=0 >/dev/null 2>&1 || true
            msg OK "[${PROJECT}] база залита из $(basename "$PLAN_KEY")"
            DB_MODE_DESC="логический дамп $(basename "$PLAN_KEY")"
          else
            DB_PROFILE_FAIL+=" в архиве нет SQL-дампа"
          fi
        else
          DB_PROFILE_FAIL+=" дамп не скачался"
        fi
      else
        msg WARN "[${PROJECT}] логический дамп в S3 не найден — база пустая"
      fi
      check_db_profile "$DB_C" "$DB_USER"
      ;;
    base|pitr)
      if [[ -z "${PLAN_META:-}" ]]; then
        msg WARN "[${PROJECT}] базовых бэкапов в S3 нет — стек поднимется с пустой базой"
        DB_MODE_DESC="без БД"
      else
        DB_MODE_DESC="базовый бэкап${PLAN_TARGET:+ + WAL до ${PLAN_TARGET}}${PLAN_SLOT:+ (слот ${PLAN_SLOT})}"
        msg INFO "[${PROJECT}] поднимаю БД из базового бэкапа + WAL${PLAN_TARGET:+ (PITR на ${PLAN_TARGET})}..."
        if restore_db_from_wal "$PLAN_META" "${PLAN_TARGET:-}"; then
          check_db_profile "$DB_C" "$DB_USER"
        else
          DB_PROFILE_FAIL+=" восстановление из WAL не удалось"
        fi
      fi
      ;;
    *)
      msg WARN "[${PROJECT}] нечего восстанавливать — стек поднимется без БД"
      DB_MODE_DESC="без БД"
      ;;
  esac
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

# --------------------------------------------------------------------------
# Функциональная проверка сервисов: мало того, что процесс запущен — важно,
# что приложение реально обслуживает запросы и достучалось до БД.
# Для remnawave это HTTP-порт панели (3000/3001 из compose): любой валидный
# HTTP-ответ, включая 401/404, доказывает, что сервер поднялся и отвечает,
# — конкретные эндпоинты панели намеренно не зашиваются, чтобы проверка не
# ломалась от версии к версии.
# --------------------------------------------------------------------------
svc_problems=""
svc_checked=0

# Порты приложений берём из ОРИГИНАЛЬНОГО compose (в изолированном стеке
# published-порты вырезаны, но target-порты сервисов остались прежними).
while IFS='|' read -r svc port; do
  [[ -n "$svc" && -n "$port" ]] || continue
  [[ "$svc" == "$DB_SERVICE" ]] && continue
  svc_checked=$((svc_checked + 1))

  # Проверяем ИЗ изолированной сети, обращаясь к сервису по его имени —
  # ровно так, как это делают соседние контейнеры стека.
  probe="$(docker run --rm --network "$NET" --label "rw-sandbox-stack=${SID}" \
    busybox:stable sh -c "wget -q -S -T 8 -O /dev/null http://${svc}:${port}/ 2>&1 | head -1" 2>/dev/null || true)"

  if grep -qE 'HTTP/[0-9.]+ [0-9]{3}' <<<"$probe"; then
    code="$(grep -oE 'HTTP/[0-9.]+ [0-9]{3}' <<<"$probe" | grep -oE '[0-9]{3}$')"
    msg OK "[${PROJECT}] сервис ${svc}:${port} отвечает по HTTP (код ${code})"
  else
    # HTTP не ответил — проверяем хотя бы TCP, чтобы отличить "порт закрыт"
    # от "порт открыт, но это не HTTP" (например, gRPC или сырой протокол).
    if docker run --rm --network "$NET" --label "rw-sandbox-stack=${SID}" \
         busybox:stable sh -c "nc -z -w 5 ${svc} ${port}" >/dev/null 2>&1; then
      msg OK "[${PROJECT}] сервис ${svc}:${port} слушает TCP (не HTTP — это нормально для не-HTTP сервисов)"
    else
      svc_problems+=" ${svc}:${port}:не отвечает"
    fi
  fi
done < <(jq -r --arg db "$DB_SERVICE" '
  .services | to_entries[]
  | select(.key != $db)
  | .key as $k
  | (.value.ports // [])[]?
  | "\($k)|\(.target)"' "$RESOLVED" 2>/dev/null | sort -u)

# Фатальные ошибки в логах приложений — например, приложение стартовало,
# но не смогло подключиться к БД и крутится в цикле ретраев.
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  cname="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>/dev/null || echo "$c")"
  if docker logs "$c" --tail 200 2>&1 | grep -qiE 'ECONNREFUSED|connection refused|FATAL:|password authentication failed|could not connect to server'; then
    svc_problems+=" ${cname}:ошибки-подключения-в-логах"
  fi
done < <(docker compose -p "$CPROJ" -f "${WORK}/stack.json" ps -q 2>/dev/null)

(( svc_checked == 0 )) && msg INFO "[${PROJECT}] в compose нет сервисов с портами — функциональная проверка пропущена"

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
elif [[ -n "$problems" ]] || [[ -n "$leak" ]] || [[ -n "$DB_PROFILE_FAIL" ]] || [[ -n "$svc_problems" ]]; then
  msg ERR "[${PROJECT}] стек ${running}/${total}:${problems}${svc_problems}${leak}${DB_PROFILE_FAIL:+ данные:${DB_PROFILE_FAIL}}"
  write_metric 0
  wal_notify "🔴 Проверка полного стека ${PROJECT} (изолированно)
Хост: $(wal_hostname)
Контейнеров живо: ${running}/${total}
${problems}${svc_problems}${leak}${DB_PROFILE_FAIL:+
Данные: ${DB_PROFILE_FAIL}}"
  exit 1
else
  msg OK "[${PROJECT}] стек поднялся полностью: ${running}/${total} контейнеров, сервисов проверено ${svc_checked}, данные проверены, изоляция подтверждена"
  msg INFO "Контейнеры и сеть уже убраны (без --keep убирается всегда, включая успешный прогон) — для ручного разбора: --keep"
  write_metric 1
  wal_notify "🟢 Полное восстановление ${PROJECT} проверено (изолированно)
Хост: $(wal_hostname)
Каталог из трекера + БД (${DB_MODE_DESC:-?}) + ${running}/${total} контейнеров, сервисов отвечает ${svc_checked}"
fi
