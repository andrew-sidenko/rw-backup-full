#!/usr/bin/env bash
# config-track.sh — непрерывное отслеживание каталогов проектов целиком.
#
# ЗАЧЕМ. WAL закрывает базу непрерывно, но за пределами БД остаётся то, без
# чего восстановление с нуля невозможно: docker-compose, .env с секретами,
# сертификаты, а у ботов — ещё и исполняемый код, миграции, шаблоны, ресурсы.
# Периодический tar раз в несколько часов даёт по ним RPO в часы. Этот модуль
# доводит RPO по файлам до минут, оставаясь дешёвым по трафику и месту.
#
# МОДЕЛЬ — та же, что у WAL, намеренно:
#   git-репозиторий на хосте  ~ pg_wal        (история всех изменений)
#   полный bundle в S3        ~ basebackup    (точка, с которой можно начать)
#   инкрементальный bundle    ~ WAL-сегмент   (только новые коммиты)
# Retention такой же безопасный: приращения удаляются только до границы
# самого старого хранимого полного bundle — любая хранимая точка восстановима.
#
# ЧТО ОТСЛЕЖИВАЕТСЯ:
#   панель — PANEL_ROOT_DIR целиком (обычно /opt/remnawave)
#   боты   — каталог каждого compose-проекта из /home целиком
# Списки берутся из lib/discovery.sh — того же источника, что и бэкапы.
#
#   config-track.sh                # все проекты
#   config-track.sh panel          # один проект
#   config-track.sh --full         # принудительно новый полный bundle
#   config-track.sh --list         # что отслеживается и текущее состояние

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"
# shellcheck source=../lib/discovery.sh
source "${SCRIPT_DIR}/../lib/discovery.sh"

TRACK_ROOT="${TRACK_ROOT:-/var/lib/rw-config-track}"
ONLY=""
FORCE_FULL="false"
LIST_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)  FORCE_FULL="true"; shift ;;
    --list)  LIST_ONLY="true"; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)       ONLY="$1"; shift ;;
  esac
done

wal_load_full_config
require_component config-track
command -v git >/dev/null 2>&1 || { msg ERR "Нужен git (apt install git)"; exit 1; }

# Каталоги данных внутри проектов НЕ отслеживаем: там живут БД и кэши —
# они огромны, меняются постоянно и уже покрыты WAL/дампами. Попытка втянуть
# их сюда сделала бы трекер бесполезно тяжёлым и неконсистентным.
DEFAULT_EXCLUDES='
.git
*.log
*.log.*
node_modules
__pycache__
*.pyc
pgdata
pg_data
postgres_data
postgres-data
mysql_data
redis_data
*.rdb
*.sock
*.pid
.venv
venv
tmp
temp
'
TRACK_EXCLUDES="${TRACK_EXCLUDES:-}"
FULL_INTERVAL_HOURS="${TRACK_FULL_INTERVAL_HOURS:-168}"   # полный bundle раз в неделю
KEEP_FULL="${TRACK_KEEP_FULL:-4}"                          # хранить полных bundle

s3_base() { printf '%s/config/%s/%s' "$B_PREFIX" "$(rw_source_id)" "$1"; }

track_backends() {
  local n
  for n in $(s3m_backends); do
    s3m_load "$n" 2>/dev/null || continue
    truthy "$B_ENABLED" || continue
    # Конфиги едут туда же, куда логические архивы панели/ботов: отдельного
    # переключателя не заводим, чтобы не плодить настройки.
    truthy "$B_UPLOAD_PANEL" || truthy "$B_UPLOAD_CUSTOM" || continue
    echo "$n"
  done
}

# --------------------------------------------------------------------------
# Снимок одного проекта
# --------------------------------------------------------------------------
track_one() { # <name> <kind> <root_dir>
  local name="$1" kind="$2" root="$3"
  local repo="${TRACK_ROOT}/${name}/repo"
  local state="${TRACK_ROOT}/${name}/state"
  local out="${TRACK_ROOT}/${name}/bundles"

  [[ -d "$root" ]] || { msg WARN "[${name}] каталог отсутствует: ${root}"; return 0; }
  mkdir -p "$repo" "$state" "$out"

  if [[ ! -d "${repo}/.git" ]]; then
    git -C "$repo" init -q
    git -C "$repo" config user.email "rw-backup-full@$(rw_source_id)"
    git -C "$repo" config user.name  "rw-backup-full"
    git -C "$repo" config gc.auto 0
    msg OK "[${name}] инициализирован трекер: ${repo}"
  fi

  # Файл исключений — общий дефолт + пользовательские правила.
  { printf '%s\n' $DEFAULT_EXCLUDES; printf '%s\n' ${TRACK_EXCLUDES:-}; } \
    | grep -v '^$' > "${repo}/.gitignore"

  # Синхронизация дерева проекта в рабочую копию. rsync --delete отражает
  # удаления файлов; при его отсутствии — деградируем до cp (без удалений).
  if command -v rsync >/dev/null 2>&1; then
    local -a ex=()
    while read -r p; do [[ -n "$p" ]] && ex+=(--exclude="$p"); done < <(cat "${repo}/.gitignore")
    rsync -a --delete "${ex[@]}" --exclude='.git' "${root}/" "${repo}/" 2>/dev/null || true
  else
    cp -a "${root}/." "${repo}/" 2>/dev/null || true
  fi

  git -C "$repo" add -A >/dev/null 2>&1 || true
  if git -C "$repo" diff --cached --quiet 2>/dev/null; then
    [[ "$FORCE_FULL" == "true" ]] || { msg INFO "[${name}] изменений нет"; return 0; }
  else
    local changed
    changed="$(git -C "$repo" diff --cached --name-only | wc -l | tr -d ' ')"
    git -C "$repo" commit -q -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ) (${changed} файлов)" >/dev/null
    msg OK "[${name}] зафиксировано изменений: ${changed}"
  fi

  local head; head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$head" ]] || { msg WARN "[${name}] нет коммитов"; return 0; }

  # --- выгрузка в S3: полный bundle или приращение ---
  local backends; backends="$(track_backends)"
  [[ -n "$backends" ]] || { msg WARN "[${name}] нет S3-бэкендов — история только локальная"; return 0; }

  local b
  for b in $backends; do
    s3m_load "$b" || continue
    local base; base="$(s3_base "$name")"
    local last_sha_file="${state}/${b}.last_sha"
    local last_full_file="${state}/${b}.last_full_epoch"
    local last_sha=""; [[ -f "$last_sha_file" ]] && last_sha="$(cat "$last_sha_file")"
    local last_full=0; [[ -f "$last_full_file" ]] && last_full="$(cat "$last_full_file")"
    local now; now="$(date +%s)"

    local need_full="false"
    [[ -z "$last_sha" ]] && need_full="true"
    [[ "$FORCE_FULL" == "true" ]] && need_full="true"
    (( now - last_full > FULL_INTERVAL_HOURS * 3600 )) && need_full="true"
    # Приращение имеет смысл только если есть новые коммиты.
    if [[ "$need_full" != "true" && "$last_sha" == "$head" ]]; then
      continue
    fi

    local ts kind_tag bundle
    ts="$(date -u +%Y-%m-%d_%H_%M_%S)"
    if [[ "$need_full" == "true" ]]; then
      kind_tag="full"
      bundle="${out}/full_${ts}_${head:0:12}.bundle"
      git -C "$repo" bundle create "$bundle" --all >/dev/null 2>&1 \
        || { msg ERR "[${name}] не удалось создать полный bundle"; continue; }
    else
      kind_tag="inc"
      bundle="${out}/inc_${ts}_${last_sha:0:12}_${head:0:12}.bundle"
      if ! git -C "$repo" bundle create "$bundle" "${last_sha}..HEAD" HEAD >/dev/null 2>&1; then
        # Ссылка потерялась (например, репозиторий пересоздан) — падаем на полный.
        kind_tag="full"
        bundle="${out}/full_${ts}_${head:0:12}.bundle"
        git -C "$repo" bundle create "$bundle" --all >/dev/null 2>&1 \
          || { msg ERR "[${name}] не удалось создать bundle"; continue; }
      fi
    fi

    local send="$bundle" suffix=""
    if wal_compress_stream < "$bundle" > "${bundle}.z" 2>/dev/null; then
      send="${bundle}.z"; suffix="$(wal_comp_ext)"
    fi
    if truthy "${TRACK_ENCRYPT:-false}" && [[ -n "${FULL_AGE_RECIPIENT:-}" ]]; then
      wal_encrypt_stream < "$send" > "${send}.age" && { send="${send}.age"; suffix="${suffix}.age"; }
    fi

    local key
    key="${base}/$(basename "$bundle")${suffix}"
    local up_err; up_err="$(mktemp)"
    if s3m_aws s3 cp "$send" "s3://${B_BUCKET}/${key}" --only-show-errors 2>"$up_err"; then
      echo "$head" > "$last_sha_file"
      [[ "$kind_tag" == "full" ]] && echo "$now" > "$last_full_file"
      msg OK "[${name}] S3[${b}]: ${kind_tag} $(basename "$key") ($(du -h "$send" | awk '{print $1}'))"
      track_retention "$name" "$b"
    else
      msg ERR "[${name}] S3[${b}]: выгрузка не удалась. Причина (aws):"
      sed 's/^/    /' "$up_err" | tail -n 3 >&2
      msg ERR "Диагностика: rw-backup-full s3-test ${b}"
    fi
    rm -f "$up_err" "${bundle}.z" "${bundle}.z.age" 2>/dev/null || true
    # Локально bundle не храним: история уже в git-репозитории.
    rm -f "$bundle" 2>/dev/null || true
  done
}

# Приращения удаляются только до границы самого старого хранимого полного
# bundle — тот же принцип, что в wal-retention.sh.
track_retention() { # <name> <backend>
  local name="$1" b="$2"
  local base; base="$(s3_base "$name")"
  local fulls
  fulls="$(s3m_aws s3 ls "s3://${B_BUCKET}/${base}/" 2>/dev/null | awk '{print $4}' | grep '^full_' | sort)"
  [[ -n "$fulls" ]] || return 0
  local total; total="$(wc -l <<<"$fulls")"
  (( total > KEEP_FULL )) || return 0

  local drop=$(( total - KEEP_FULL ))
  local horizon f i=0
  horizon="$(sed -n "$((drop + 1))p" <<<"$fulls")"
  while IFS= read -r f; do
    (( i++ >= drop )) && break
    s3m_aws s3 rm "s3://${B_BUCKET}/${base}/${f}" --only-show-errors 2>/dev/null || true
  done <<<"$fulls"

  # Приращения старше границы больше не нужны: восстановление начинается
  # с самого старого хранимого полного bundle.
  local hz_ts="${horizon#full_}"; hz_ts="${hz_ts:0:19}"
  local k
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    local k_ts="${k#inc_}"; k_ts="${k_ts:0:19}"
    [[ "$k_ts" < "$hz_ts" ]] && s3m_aws s3 rm "s3://${B_BUCKET}/${base}/${k}" --only-show-errors 2>/dev/null || true
  done < <(s3m_aws s3 ls "s3://${B_BUCKET}/${base}/" 2>/dev/null | awk '{print $4}' | grep '^inc_' | sort)
}

# --------------------------------------------------------------------------
# Основной цикл
# --------------------------------------------------------------------------
if [[ "$LIST_ONLY" == "true" ]]; then
  echo -e "${BOLD}Отслеживаемые каталоги:${RESET}"
  while IFS='|' read -r name kind root _rest; do
    [[ -n "$name" ]] || continue
    dir_size="$(du -sh "$root" 2>/dev/null | awk '{print $1}')"
    commits="$(git -C "${TRACK_ROOT}/${name}/repo" rev-list --count HEAD 2>/dev/null || echo 0)"
    echo "  ● ${name} (${kind}) ${root} — ${dir_size:-?}, снимков: ${commits}"
  done < <(disc_all)
  exit 0
fi

wal_lock "config-track" || exit 0

tracked=0
while IFS='|' read -r name kind root _rest; do
  [[ -n "$name" ]] || continue
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  track_one "$name" "$kind" "$root"
  tracked=$((tracked + 1))
done < <(disc_all)

(( tracked > 0 )) || msg WARN "Проекты не найдены (панель и compose-проекты в /home отсутствуют)"

wal_metric_write "rw_config_track" <<EOF_M
# HELP rw_config_track_last_run_timestamp_seconds Время последнего прогона трекера конфигов.
# TYPE rw_config_track_last_run_timestamp_seconds gauge
rw_config_track_last_run_timestamp_seconds $(date +%s)
# HELP rw_config_track_projects Количество отслеживаемых проектов.
# TYPE rw_config_track_projects gauge
rw_config_track_projects ${tracked}
EOF_M
