#!/usr/bin/env bash
# render-cron.sh — генерирует crontab для supercronic из ТЕХ ЖЕ конфигов,
# что использует systemd-вариант (единые настройки, ничего не дублируется):
#   - FULL_TIMER_INTERVAL_HOURS / FULL_TIMER_TIMES (+FULL_SCHEDULE_TZ)  — логические бэкапы
#   - INST_WAL_SHIP_INTERVAL_MIN / INST_WAL_SHIP_TIMES                  — WAL-шиппер
#   - INST_BASEBACKUP_INTERVAL_HOURS / INST_BASEBACKUP_TIMES            — базовые бэкапы
#   - SANDBOX_VERIFY_INTERVAL_HOURS / SANDBOX_VERIFY_TIMES              — песочница
#   - метрики: каждые 15 минут
#
# Списки конкретных времён (динамической длины) транслируются в отдельные
# cron-строки "M H * * *". Часовой пояс: supercronic использует TZ контейнера —
# задавайте TZ в compose равным FULL_SCHEDULE_TZ.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
INSTANCES_DIR="${INSTANCES_DIR:-${INSTALL_DIR}/instances.d}"
FULL_CONFIG_FILE="${FULL_CONFIG_FILE:-${INSTALL_DIR}/rw-backup-full.env}"
ROLE="${RW_ROLE:-host-agent}"
BIN="/usr/local/bin/rw-backup-full"

set +u
# shellcheck disable=SC1090
[[ -f "$FULL_CONFIG_FILE" ]] && source "$FULL_CONFIG_FILE"
set -u

# "03:00, 15:30" -> строки "30 15" / "0 3" (cron: M H)
times_to_cron() {
  local raw="${1//,/ }" t hh mm
  for t in $raw; do
    [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})(:[0-9]{2})?$ ]] || {
      echo "# ОШИБКА: некорректное время '$t' — строка пропущена" >&2; continue; }
    hh=$((10#${BASH_REMATCH[1]})); mm=$((10#${BASH_REMATCH[2]}))
    printf '%d %d * * *\n' "$mm" "$hh"
  done
}

emit_sched() { # <times> <interval_expr_cron> <command>
  local times="$1" fallback="$2" cmd="$3" line
  if [[ -n "$times" ]]; then
    while IFS= read -r line; do
      [[ "$line" == \#* ]] && { echo "$line"; continue; }
      echo "${line} ${cmd}"
    done < <(times_to_cron "$times")
  else
    echo "${fallback} ${cmd}"
  fi
}

echo "# rw-backup-full crontab (роль: ${ROLE}); сгенерировано $(date -u +%FT%TZ)"
echo "# Источник настроек: ${FULL_CONFIG_FILE} + ${INSTANCES_DIR}/*.env"

if [[ "$ROLE" == "host-agent" ]]; then
  # Логические бэкапы (панель + боты)
  th="${FULL_TIMER_INTERVAL_HOURS:-3}"; [[ "$th" =~ ^[0-9]+$ ]] || th=3
  emit_sched "${FULL_TIMER_TIMES:-}" "15 */${th} * * *" "${BIN} run-timer"

  # WAL: per-instance
  if [[ -d "$INSTANCES_DIR" ]]; then
    for f in "$INSTANCES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      inst="$(basename "$f" .env)"
      unset INST_WAL_SHIP_INTERVAL_MIN INST_WAL_SHIP_TIMES \
            INST_BASEBACKUP_INTERVAL_HOURS INST_BASEBACKUP_TIMES INST_ENABLED
      set +u; # shellcheck disable=SC1090
      source "$f"; set -u
      case "${INST_ENABLED:-true}" in false|no|0) continue ;; esac

      sm="${INST_WAL_SHIP_INTERVAL_MIN:-1}"; [[ "$sm" =~ ^[0-9]+$ ]] || sm=1
      emit_sched "${INST_WAL_SHIP_TIMES:-}" "*/${sm} * * * *" \
        "${INSTALL_DIR}/scripts/wal/wal-ship.sh ${inst}"

      bh="${INST_BASEBACKUP_INTERVAL_HOURS:-24}"; [[ "$bh" =~ ^[0-9]+$ ]] || bh=24
      if (( bh >= 24 )); then bfall="30 3 * * *"; else bfall="30 */${bh} * * *"; fi
      emit_sched "${INST_BASEBACKUP_TIMES:-}" "$bfall" \
        "${INSTALL_DIR}/scripts/wal/basebackup.sh ${inst}"
    done
  fi

  echo "*/15 * * * * ${INSTALL_DIR}/scripts/metrics/metrics-exporter.sh"
fi

if [[ "$ROLE" == "sandbox" ]]; then
  if [[ -n "${SANDBOX_VERIFY_TIMES:-}" ]]; then
    emit_sched "${SANDBOX_VERIFY_TIMES}" "" "${INSTALL_DIR}/scripts/sandbox/verify-backup.sh"
  elif [[ -n "${SANDBOX_VERIFY_INTERVAL_HOURS:-}" ]] && [[ "${SANDBOX_VERIFY_INTERVAL_HOURS}" =~ ^[0-9]+$ ]]; then
    echo "30 */${SANDBOX_VERIFY_INTERVAL_HOURS} * * * ${INSTALL_DIR}/scripts/sandbox/verify-backup.sh"
  else
    echo "30 5 * * * ${INSTALL_DIR}/scripts/sandbox/verify-backup.sh"
  fi
  echo "*/15 * * * * ${INSTALL_DIR}/scripts/metrics/metrics-exporter.sh"
fi
