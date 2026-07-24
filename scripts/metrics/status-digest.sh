#!/usr/bin/env bash
# status-digest.sh — краткая сводка состояния в 09:00 и 21:00.
#
# Содержимое: события/результаты за период, занятое и свободное место,
# актуальность бэкапов, ошибки. На прод-сервере уходит в Telegram ЭТОГО
# сервера. На песочнице — сводка парка + рассылка общих итогов по TG
# реквизитам всех серверов из манифеста.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

wal_load_full_config
# Сводка полезна и при metrics, и на песочнице (sandbox/web).
if ! component_enabled metrics && ! component_enabled sandbox && ! component_enabled web; then
  msg INFO "Компоненты metrics/sandbox/web выключены — сводка пропущена"
  exit 0
fi
wal_lock "status-digest" || exit 0

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
  read -r size avail < <(df -B1 --output=size,avail "$path" 2>/dev/null | tail -n1)
  size="${size:-0}"; avail="${avail:-0}"
  used=$(( size - avail ))
  if (( size > 0 )); then usedp=$(( used * 100 / size )); else usedp=0; fi
  echo "  ${label}: занято $(human_bytes "$used") / свободно $(human_bytes "$avail") (${usedp}% used)"
}

age_of() {
  local f="$1" ts age
  [[ -f "$f" ]] || { echo "нет"; return; }
  ts="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  age=$(( $(date +%s) - ts ))
  if (( age < 3600 )); then echo "$((age/60))м назад"
  elif (( age < 86400 )); then echo "$((age/3600))ч назад"
  else echo "$((age/86400))д назад"; fi
}

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

echo "$BODY"
wal_notify "$BODY"

# На песочнице: общие итоги — во все TG серверов парка (если веб доступен).
if component_enabled sandbox || component_enabled web; then
  WEB_ENV="${WEB_ENV:-/etc/rw-backup-web.env}"
  WEB_URL="${RW_WEB_URL:-http://127.0.0.1:8787}"
  TOKEN="${WEB_TOKEN:-}"
  [[ -z "$TOKEN" && -f "$WEB_ENV" ]] && TOKEN="$(grep -E '^WEB_TOKEN=' "$WEB_ENV" | head -n1 | cut -d= -f2- || true)"
  if [[ -n "$TOKEN" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    MANIFEST="$(curl -fsS -m 45 -H "x-token: ${TOKEN}" "${WEB_URL}/api/fleet/manifest" 2>/dev/null || true)"
    if [[ -n "$MANIFEST" ]]; then
      FLEET_NOTE="📋 Сводка песочницы ${HOST}
${NOW_H}
$(echo "$BODY" | sed -n '1,20p')
— общее событие парка —"
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
