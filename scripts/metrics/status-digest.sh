#!/usr/bin/env bash
# status-digest.sh — краткая сводка состояния в 09:00 и 21:00.
#
# Содержимое: события/результаты за период, занятое и свободное место,
# актуальность бэкапов, ошибки. На прод-сервере уходит в Telegram ЭТОГО
# сервера. На песочнице — сводка парка по КАЖДОМУ серверу (🟢/🔴) +
# рассылка общих итогов по TG реквизитам всех серверов из манифеста.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

# Пороги «по графику» (сек). Переопределяются в rw-backup-full.env.
DIGEST_WAL_STALE_SEC="${DIGEST_WAL_STALE_SEC:-3600}"          # WAL не свежее 1ч → 🔴
DIGEST_BASE_STALE_SEC="${DIGEST_BASE_STALE_SEC:-129600}"      # база >36ч → 🔴
DIGEST_PANEL_STALE_SEC="${DIGEST_PANEL_STALE_SEC:-129600}"    # panel-backup >36ч → 🔴
DIGEST_VERIFY_STALE_SEC="${DIGEST_VERIFY_STALE_SEC:-86400}"   # fleet-verify >24ч → ⚠
NOW_TS="$(date +%s)"

# Юнит-режим: не трогаем lock/telegram (test/unit_digest_verdict.sh).
if [[ "${1:-}" == "--verdict-test" ]]; then
  DIGEST_VERDICT_TEST=1
else
  wal_load_full_config
  if ! component_enabled metrics && ! component_enabled sandbox && ! component_enabled web; then
    msg INFO "Компоненты metrics/sandbox/web выключены — сводка пропущена"
    exit 0
  fi
  wal_lock "status-digest" || exit 0
fi

BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
HOST="$(wal_hostname)"
SRC="$(rw_source_id)"
NOW_H="$(date '+%Y-%m-%d %H:%M %Z')"
COMPS="${FULL_COMPONENTS:-panel-backup custom-backup wal config-track metrics}"

human_bytes() {
  local b="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "${b}B"
  else awk -v b="$b" 'BEGIN{
    split("B KiB MiB GiB TiB",u," "); for(i=1;b>=1024 && i<5;i++) b/=1024;
    printf "%.1f%s\n", b, u[i]
  }'
  fi
}

disk_line() {
  local path="$1" label="$2"
  [[ -d "$path" ]] || { echo "  ${label}: (нет ${path})"; return; }
  local size avail usedp used
  read -r size avail < <(df -B1 --output=size,avail "$path" 2>/dev/null | tail -n1 || true) || true
  size="${size:-0}"; avail="${avail:-0}"
  used=$(( size - avail ))
  if (( size > 0 )); then usedp=$(( used * 100 / size )); else usedp=0; fi
  echo "  ${label}: занято $(human_bytes "$used") / свободно $(human_bytes "$avail") (${usedp}% used)"
}

age_of() {
  local f="$1" ts
  [[ -f "$f" ]] || { echo "нет"; return; }
  ts="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  age_ts "$ts"
}

age_ts() {
  local ts="${1:-0}" age
  [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )) || { echo "нет"; return; }
  age=$(( NOW_TS - ts ))
  (( age < 0 )) && age=0
  if (( age < 3600 )); then echo "$((age/60))м назад"
  elif (( age < 86400 )); then echo "$((age/3600))ч назад"
  else echo "$((age/86400))д назад"; fi
}

# ---------------------------------------------------------------------------
# Вердикт одного сервера по JSON status --json (+ метрики verify).
# Печатает многострочный блок; код возврата 0 = 🟢, 1 = 🔴.
# ---------------------------------------------------------------------------
digest_server_verdict() { # <card_id> <source_id> <reachable 0|1> <status_json|{}> <verify_fails> <error>
  # НЕ писать ${4:-{}} — лишняя } прилипает к JSON (bash закрывает ${} на первой }).
  local card="$1" source="$2" reach="$3" st="${4:-}" vfails="${5:-0}" err="${6:-}"
  local problems=() ok_bits=() line icon
  local now="$NOW_TS"
  [[ -n "$st" && "$st" != "-" && "$st" != "null" ]] || st='{}'

  if [[ "$reach" != "1" ]]; then
    problems+=("недоступен по SSH: ${err:-нет ответа}")
  else
    # errors из status
    local nerr
    nerr="$(jq -r '.errors // 0' <<<"$st" 2>/dev/null || echo 0)"
    [[ "$nerr" =~ ^[0-9]+$ ]] || nerr=0
    (( nerr > 0 )) && problems+=("ошибок в метриках хоста: ${nerr}")

    # panel backup freshness
    local pts
    pts="$(jq -r '.panel.last_backup_ts // 0' <<<"$st" 2>/dev/null || echo 0)"
    [[ "$pts" =~ ^[0-9]+$ ]] || pts=0
    if (( pts > 0 )); then
      if (( now - pts > DIGEST_PANEL_STALE_SEC )); then
        problems+=("panel-backup устарел ($(age_ts "$pts"), порог $((DIGEST_PANEL_STALE_SEC/3600))ч)")
      else
        ok_bits+=("panel $(age_ts "$pts")")
      fi
    else
      # Не все хосты — panel; если компонент есть в status.components
      if jq -e '.components | test("panel-backup")' <<<"$st" >/dev/null 2>&1; then
        problems+=("panel-backup: нет ни одного архива")
      fi
    fi

    # WAL instances
    local wal_n wname wts bbts timer running spool
    wal_n="$(jq -r '.wal_instances // [] | length' <<<"$st" 2>/dev/null || true)"
    [[ "$wal_n" =~ ^[0-9]+$ ]] || wal_n=0
    if (( wal_n == 0 )); then
      if jq -e '.components | test("\\bwal\\b")' <<<"$st" >/dev/null 2>&1; then
        problems+=("WAL: инстансы не настроены")
      fi
    else
      while IFS=$'\t' read -r wname wts bbts timer running spool; do
        [[ -n "$wname" ]] || continue
        [[ "$wts" =~ ^[0-9]+$ ]] || wts=0
        [[ "$bbts" =~ ^[0-9]+$ ]] || bbts=0
        if [[ "$timer" != "true" ]]; then
          problems+=("WAL ${card}-${wname}: таймер ship не active")
        fi
        if (( wts <= 0 )); then
          problems+=("WAL ${card}-${wname}: нет архивных сегментов")
        elif (( now - wts > DIGEST_WAL_STALE_SEC )); then
          problems+=("WAL ${card}-${wname}: поток стоит с $(age_ts "$wts") (порог $((DIGEST_WAL_STALE_SEC/60))м)")
        else
          ok_bits+=("WAL ${card}-${wname} $(age_ts "$wts")")
        fi
        if (( bbts > 0 && now - bbts > DIGEST_BASE_STALE_SEC )); then
          problems+=("WAL ${card}-${wname}: basebackup устарел ($(age_ts "$bbts"))")
        elif (( bbts <= 0 )); then
          problems+=("WAL ${card}-${wname}: нет basebackup")
        fi
        if [[ "$running" != "true" ]]; then
          problems+=("WAL ${card}-${wname}: контейнер БД не running")
        fi
      done < <(jq -r '.wal_instances[]? | [.name, (.last_wal_ts//0), (.last_basebackup_ts//0), (.timer_active|tostring), (.running|tostring), (.spool//0)] | @tsv' <<<"$st" 2>/dev/null || true)
    fi

    # S3 backends
    while IFS=$'\t' read -r bname en reachb; do
      [[ -n "$bname" ]] || continue
      [[ "$en" == "true" ]] || continue
      if [[ "$reachb" == "false" ]]; then
        problems+=("S3 ${bname}: недоступен")
      else
        ok_bits+=("S3 ${bname}")
      fi
    done < <(jq -r '.s3_backends[]? | [.name, (.enabled|tostring), (.reachable|tostring)] | @tsv' <<<"$st" 2>/dev/null || true)
  fi

  [[ "$vfails" =~ ^[0-9]+$ ]] || vfails=0
  if (( vfails > 0 )); then
    problems+=("проверки песочницы: ${vfails} сбой(ев) — см. историю/метрики")
  else
    ok_bits+=("проверки без ошибок")
  fi

  if (( ${#problems[@]} > 0 )); then
    icon="🔴"
  else
    icon="🟢"
  fi
  line="${icon} ${card}"
  [[ -n "$source" && "$source" != "$card" ]] && line+=" (source=${source})"
  printf '%s\n' "$line"
  if (( ${#ok_bits[@]} > 0 )) && (( ${#problems[@]} == 0 )); then
    printf '   ок: %s\n' "$(IFS=', '; echo "${ok_bits[*]}")"
  fi
  local p
  for p in "${problems[@]}"; do
    printf '   ✗ %s\n' "$p"
  done
  (( ${#problems[@]} > 0 )) && return 1
  return 0
}

# Собрать блок «Парк» через /api/fleet/overview (+ детали fail из prom).
digest_fleet_block() {
  local web_env="${WEB_ENV:-/etc/rw-backup-web.env}"
  local url="${RW_WEB_URL:-http://127.0.0.1:8787}"
  local token="${WEB_TOKEN:-}" overview
  [[ -z "$token" && -f "$web_env" ]] && token="$(grep -E '^WEB_TOKEN=' "$web_env" | head -n1 | cut -d= -f2- || true)"
  [[ -n "$token" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
    echo "(нет WEB_TOKEN/curl/jq — блок парка пропущен)"
    return 0
  }
  overview="$(curl -fsS -m 120 -H "x-token: ${token}" "${url}/api/fleet/overview" 2>/dev/null || true)"
  [[ -n "$overview" ]] || {
    echo "(веб недоступен — блок парка пропущен)"
    return 0
  }

  local tot pass last_run green=0 red=0
  tot="$(jq -r '.fleet_checks_total // empty' <<<"$overview" 2>/dev/null || true)"
  pass="$(jq -r '.fleet_checks_passed // empty' <<<"$overview" 2>/dev/null || true)"
  last_run="$(jq -r '.fleet_last_run // 0' <<<"$overview" 2>/dev/null || true)"
  [[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0

  local out="" hdr
  hdr="Парк:"
  if [[ -n "$tot" ]]; then
    hdr+=" fleet-verify ${pass:-?}/${tot}"
    if (( last_run > 0 )); then
      hdr+=" · последний прогон $(age_ts "$last_run")"
      if (( NOW_TS - last_run > DIGEST_VERIFY_STALE_SEC )); then
        hdr+=" ⚠ прогон старше $((DIGEST_VERIFY_STALE_SEC/3600))ч"
      fi
    fi
  fi
  out+="${hdr}"$'\n'

  local srv sid src reach stjson vfails err rc_one
  while IFS= read -r srv; do
    [[ -n "$srv" ]] || continue
    sid="$(jq -r '.id // empty' <<<"$srv")"
    [[ -n "$sid" ]] || continue
    stjson="$(jq -c '.status // {}' <<<"$srv" 2>/dev/null || echo '{}')"
    [[ "$stjson" == "null" || -z "$stjson" ]] && stjson="{}"
    src="$(jq -r '.status.host // .id' <<<"$srv" 2>/dev/null || echo "$sid")"
    if jq -e '.reachable == true' <<<"$srv" >/dev/null 2>&1; then reach=1; else reach=0; fi
    vfails="$(jq -r '.verify_fails // 0' <<<"$srv")"
    err="$(jq -r '.error // empty' <<<"$srv")"
    # Детали failed metrics для этого source
    local fail_details=""
    if [[ -d "${WAL_METRICS_DIR:-}" ]]; then
      fail_details="$(grep -hE 'rw_fleet_verify_ok\{.*\} 0$' "${WAL_METRICS_DIR}"/rw_*.prom 2>/dev/null \
        | grep -F "source=\"${src}\"" \
        | sed -E 's/^rw_fleet_verify_ok\{//;s/\} 0$//' \
        | tr '\n' '; ' | head -c 400 || true)"
    fi
    set +e
    block="$(digest_server_verdict "$sid" "$src" "$reach" "$stjson" "$vfails" "$err")"
    rc_one=$?
    set -e
    if (( rc_one == 0 )); then green=$((green+1)); else red=$((red+1)); fi
    out+="${block}"$'\n'
    if [[ -n "$fail_details" && "$rc_one" -ne 0 ]]; then
      out+="   детали: ${fail_details}"$'\n'
    fi
  done < <(jq -c '.servers[]?' <<<"$overview" 2>/dev/null || true)

  local nservers
  nservers="$(jq -r '.servers|length' <<<"$overview" 2>/dev/null || echo 0)"
  out+=$'\n'"Итого: 🟢 ${green} · 🔴 ${red} · серверов ${nservers}"
  printf '%s\n' "$out"
}

# Юнит-режим: только вердикт, без TG/дисков/веб.
if [[ "${DIGEST_VERDICT_TEST:-}" == "1" ]]; then
  shift || true
  digest_server_verdict "$@"
  exit $?
fi

BODY="📋 Сводка rw-backup-full
Хост: ${HOST} (${SRC})
Время: ${NOW_H}
Компоненты: ${COMPS}
"
BODY+=$'\nДиски:\n'
BODY+="$(disk_line "$BACKUP_DIR" "бэкапы")"$'\n'
BODY+="$(disk_line "${WAL_ROOT}" "WAL")"$'\n'

if component_enabled panel-backup || component_enabled custom-backup; then
  BODY+=$'\nБэкапы:\n'
  local_panel="$(find "$BACKUP_DIR" -maxdepth 1 -name 'remnawave_backup_*.tar.gz' -type f 2>/dev/null | sort | tail -n1 || true)"
  local_custom="$(find "$BACKUP_DIR" -maxdepth 1 -name 'custom_bot_*.tar.gz' -type f 2>/dev/null | sort | tail -n1 || true)"
  BODY+="  panel: $(basename "${local_panel:-—}") ($(age_of "${local_panel:-}"))"$'\n'
  BODY+="  bots:  $(basename "${local_custom:-—}") ($(age_of "${local_custom:-}"))"$'\n'
fi

if component_enabled wal && [[ -d "$INSTANCES_DIR" ]]; then
  BODY+=$'\nWAL:\n'
  for f in "$INSTANCES_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" .env)"
    spool="$(find "${WAL_ROOT}/${name}/spool/incoming" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l | tr -d ' ' || true)"
    bb="$(find "${WAL_ROOT}/${name}/basebackup" -maxdepth 1 -name 'base_*.meta' 2>/dev/null | wc -l | tr -d ' ' || true)"
    BODY+="  ${name}: spool=${spool:-0} basebackups=${bb:-0}"$'\n'
  done
fi

METRICS_DIR="${WAL_METRICS_DIR}"
if [[ -d "$METRICS_DIR" ]]; then
  prom_notes=""
  if [[ -f "${METRICS_DIR}/rw_fleet_verify.prom" ]]; then
    tot="$(grep -E '^rw_fleet_verify_checks_total ' "${METRICS_DIR}/rw_fleet_verify.prom" 2>/dev/null | awk '{print $2}' || true)"
    pass="$(grep -E '^rw_fleet_verify_checks_passed ' "${METRICS_DIR}/rw_fleet_verify.prom" 2>/dev/null | awk '{print $2}' || true)"
    [[ -n "$tot" ]] && prom_notes+="  fleet-verify: ${pass:-?}/${tot}"$'\n'
  fi
  if [[ -f "${METRICS_DIR}/rw_sandbox_summary.prom" ]]; then
    tot="$(grep -E '^rw_sandbox_checks_total ' "${METRICS_DIR}/rw_sandbox_summary.prom" 2>/dev/null | awk '{print $2}' || true)"
    pass="$(grep -E '^rw_sandbox_checks_passed ' "${METRICS_DIR}/rw_sandbox_summary.prom" 2>/dev/null | awk '{print $2}' || true)"
    [[ -n "$tot" ]] && prom_notes+="  sandbox: ${pass:-?}/${tot}"$'\n'
  fi
  fails="$(grep -hE 'rw_.*_last_result 0$|rw_fleet_verify_ok\{.*\} 0$' "$METRICS_DIR"/rw_*.prom 2>/dev/null | wc -l | tr -d ' ' || true)"
  (( fails > 0 )) && prom_notes+="  ⚠ метрик с ошибкой: ${fails}"$'\n'
  [[ -n "$prom_notes" ]] && BODY+=$'\nПроверки:\n'"$prom_notes"
fi

# Объём, занятый бэкапами этого хоста в каждом S3-хранилище. Метрики собирает
# metrics-exporter (rw_exporter.prom, если FULL_METRICS_S3_SIZES=true) — парсим
# их без обращения к сети. Портируемый разбор на bash (без gawk-расширений).
EXPORTER_PROM="${METRICS_DIR}/rw_exporter.prom"
if [[ -f "$EXPORTER_PROM" ]]; then
  # =() обязателен: под set -u пустой `declare -A x` даёт
  # «x: unbound variable» на ${#x[@]} (сводка «сейчас» / 09:00/21:00).
  declare -A _s3_bytes=() _s3_objs=() _s3_reach=()
  while IFS= read -r line; do
    case "$line" in
      'rw_s3_category_bytes{'*)
        b="${line#*backend=\"}"; b="${b%%\"*}"; v="${line##* }"
        [[ "$v" =~ ^[0-9]+$ ]] && _s3_bytes["$b"]=$(( ${_s3_bytes["$b"]:-0} + v )) ;;
      'rw_s3_category_objects{'*)
        b="${line#*backend=\"}"; b="${b%%\"*}"; v="${line##* }"
        [[ "$v" =~ ^[0-9]+$ ]] && _s3_objs["$b"]=$(( ${_s3_objs["$b"]:-0} + v )) ;;
      'rw_s3_backend_reachable{'*)
        b="${line#*backend=\"}"; b="${b%%\"*}"; v="${line##* }"
        _s3_reach["$b"]="$v" ;;
    esac
  done < "$EXPORTER_PROM"
  if (( ${#_s3_bytes[@]} > 0 || ${#_s3_reach[@]} > 0 )); then
    BODY+=$'\nS3-хранилища (объём этого хоста):\n'
    # Ключи — объединение bytes∪reach (бэкенд мог попасть только в один тип метрик).
    declare -A _s3_names=()
    for b in "${!_s3_bytes[@]}"; do _s3_names["$b"]=1; done
    for b in "${!_s3_reach[@]}"; do _s3_names["$b"]=1; done
    for b in "${!_s3_names[@]}"; do
      warn=""; [[ "${_s3_reach[$b]:-}" == "0" ]] && warn=" ⚠ недоступен"
      BODY+="  ${b}: занято $(human_bytes "${_s3_bytes[$b]:-0}") (${_s3_objs[$b]:-0} объектов)${warn}"$'\n'
    done
  fi
fi

# На песочнице — главный блок: все серверы парка с 🟢/🔴.
FLEET_BLOCK=""
if component_enabled sandbox || component_enabled web; then
  FLEET_BLOCK="$(digest_fleet_block)"
  BODY+=$'\n'"${FLEET_BLOCK}"
fi

echo "$BODY"
wal_notify "$BODY"

# На песочнице: полная сводка парка — во все TG серверов (не обрезаем до 20 строк).
if [[ -n "$FLEET_BLOCK" ]]; then
  WEB_ENV="${WEB_ENV:-/etc/rw-backup-web.env}"
  WEB_URL="${RW_WEB_URL:-http://127.0.0.1:8787}"
  TOKEN="${WEB_TOKEN:-}"
  [[ -z "$TOKEN" && -f "$WEB_ENV" ]] && TOKEN="$(grep -E '^WEB_TOKEN=' "$WEB_ENV" | head -n1 | cut -d= -f2- || true)"
  if [[ -n "$TOKEN" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    MANIFEST="$(curl -fsS -m 45 -H "x-token: ${TOKEN}" "${WEB_URL}/api/fleet/manifest" 2>/dev/null || true)"
    if [[ -n "$MANIFEST" ]]; then
      FLEET_NOTE="📋 Сводка парка ${HOST}
${NOW_H}

${FLEET_BLOCK}"
      # Telegram лимит ~4096; если длинно — режем аккуратно.
      if (( ${#FLEET_NOTE} > 3900 )); then
        FLEET_NOTE="${FLEET_NOTE:0:3900}
…(обрезано)"
      fi
      while IFS= read -r srv; do
        tok="$(jq -r '.telegram.token // empty' <<<"$srv")"
        chat="$(jq -r '.telegram.chat_id // empty' <<<"$srv")"
        [[ -n "$tok" && -n "$chat" ]] || continue
        wal_notify_to "$tok" "$chat" "$FLEET_NOTE"
      done < <(jq -c '.servers[]? | select(.reachable==true)' <<<"$MANIFEST")
    fi
  fi
fi

exit 0
