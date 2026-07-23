#!/usr/bin/env bash
# wal-timers.sh <instance> [--remove] — таймеры WAL инстанса с расписанием пользователя.
#
# Каждому из двух таймеров (базовый бэкап, отправка WAL) можно задать
# ЛИБО интервал, ЛИБО список конкретных времён (динамическое количество):
#
#   INST_BASEBACKUP_INTERVAL_HOURS="24"        # режим интервала
#   INST_BASEBACKUP_TIMES="03:00 15:30 23:45"  # режим расписания (приоритетнее)
#
#   INST_WAL_SHIP_INTERVAL_MIN="1"
#   INST_WAL_SHIP_TIMES=""                     # обычно пусто: WAL шлют по интервалу
#
#   INST_SCHEDULE_TZ=""       # пусто = локальная зона сервера; "UTC"; "Europe/Amsterdam"
#
# Формат времени HH:MM или HH:MM:SS, разделители — пробел/запятая.
# Если заданы и TIMES, и INTERVAL — используется TIMES.
#
# Реализация: шаблонный юнит + drop-in override на инстанс. daemon-reload и
# enable выполняются здесь же; после смены расписания просто перезапустите
# этот скрипт (rw-backup-full wal-timers <instance>).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

INSTANCE="${1:-}"
MODE="${2:-install}"
[[ -n "$INSTANCE" ]] || { echo "Usage: wal-timers.sh <instance> [--remove]" >&2; exit 1; }

if [[ "$MODE" == "--remove" ]]; then
  systemctl disable --now "rw-wal-ship@${INSTANCE}.timer" 2>/dev/null || true
  systemctl disable --now "rw-basebackup@${INSTANCE}.timer" 2>/dev/null || true
  rm -rf "/etc/systemd/system/rw-wal-ship@${INSTANCE}.timer.d" \
         "/etc/systemd/system/rw-basebackup@${INSTANCE}.timer.d"
  systemctl daemon-reload
  msg OK "[${INSTANCE}] таймеры WAL удалены"
  exit 0
fi

wal_load_full_config
wal_load_instance "$INSTANCE"

TZ_OPT="${INST_SCHEDULE_TZ:-}"

# render_dropin <файл> <times|""> <interval-строка systemd, напр. 24h> <desc>
# В режиме расписания сбрасываем OnBootSec и OnUnitActiveSec шаблона:
# запуск строго по календарю; Persistent=true в шаблоне добьёт пропущенные
# запуски после простоя сервера.
render_dropin() {
  local file="$1" times="$2" interval="$3" desc="$4"
  {
    echo "# managed-by: rw-backup-full (расписание из instances.d/${INSTANCE}.env)"
    echo "# ${desc}"
    echo "[Timer]"
    echo "OnUnitActiveSec="
    echo "OnBootSec="
    if [[ -n "$times" ]]; then
      echo "OnCalendar="
      wal_render_calendar_lines "$times" "$TZ_OPT"
    else
      # ЯКОРЬ ПЕРВОГО ЗАПУСКА. OnUnitActiveSec отсчитывается от последней
      # активности СЕРВИСА — если сервис ни разу не запускался, интервал
      # никогда не сработает (а OnBootSec шаблона к этому моменту давно
      # в прошлом: монотонные таймеры Persistent не догоняет).
      # OnActiveSec тикает от активации ТАЙМЕРА: срабатывает вскоре после
      # enable --now и после каждой загрузки, дальше ритм задаёт интервал.
      echo "OnActiveSec=45s"
      echo "OnUnitActiveSec=${interval}"
    fi
  } > "$file"
}

# --- базовый бэкап ---
base_h="${INST_BASEBACKUP_INTERVAL_HOURS:-24}"
[[ "$base_h" =~ ^[0-9]+$ ]] && (( base_h >= 1 )) || base_h=24
base_times=""
if [[ -n "${INST_BASEBACKUP_TIMES:-}" ]]; then
  base_times="$(wal_parse_times "$INST_BASEBACKUP_TIMES")" || {
    msg ERR "[${INSTANCE}] ошибка в INST_BASEBACKUP_TIMES"; exit 1; }
fi

# --- отправка WAL ---
ship_min="${INST_WAL_SHIP_INTERVAL_MIN:-1}"
[[ "$ship_min" =~ ^[0-9]+$ ]] && (( ship_min >= 1 )) || ship_min=1
ship_times=""
if [[ -n "${INST_WAL_SHIP_TIMES:-}" ]]; then
  ship_times="$(wal_parse_times "$INST_WAL_SHIP_TIMES")" || {
    msg ERR "[${INSTANCE}] ошибка в INST_WAL_SHIP_TIMES"; exit 1; }
  # Редкая отправка WAL увеличивает RPO: сегменты лежат в спуле до следующего
  # запуска шиппера. Предупредим, но не запретим — расписание задаёт пользователь.
  msg WARN "[${INSTANCE}] WAL-ship по расписанию (${ship_times}): пока шиппер не запущен, сегменты копятся в спуле и не защищены S3-копией"
fi

d1="/etc/systemd/system/rw-wal-ship@${INSTANCE}.timer.d"
d2="/etc/systemd/system/rw-basebackup@${INSTANCE}.timer.d"
mkdir -p "$d1" "$d2"

render_dropin "${d1}/override.conf" "$ship_times" "${ship_min}min" \
  "Отправка WAL: $([[ -n "$ship_times" ]] && echo "по времени: ${ship_times}${TZ_OPT:+ ($TZ_OPT)}" || echo "каждые ${ship_min} мин")"
render_dropin "${d2}/override.conf" "$base_times" "${base_h}h" \
  "Базовый бэкап: $([[ -n "$base_times" ]] && echo "по времени: ${base_times}${TZ_OPT:+ ($TZ_OPT)}" || echo "каждые ${base_h} ч")"

systemctl daemon-reload
# restart, а не только enable --now: активный таймер должен перечитать drop-in
# и заново взвести OnActiveSec-якорь.
systemctl enable "rw-wal-ship@${INSTANCE}.timer" >/dev/null 2>&1 || true
systemctl enable "rw-basebackup@${INSTANCE}.timer" >/dev/null 2>&1 || true
systemctl restart "rw-wal-ship@${INSTANCE}.timer"
systemctl restart "rw-basebackup@${INSTANCE}.timer"

msg OK "[${INSTANCE}] расписания применены:"
msg INFO "  WAL-ship:  $([[ -n "$ship_times" ]] && echo "${ship_times}${TZ_OPT:+ ($TZ_OPT)}" || echo "каждые ${ship_min} мин")"
msg INFO "  basebackup: $([[ -n "$base_times" ]] && echo "${base_times}${TZ_OPT:+ ($TZ_OPT)}" || echo "каждые ${base_h} ч")"
systemctl list-timers "rw-wal-ship@${INSTANCE}.timer" "rw-basebackup@${INSTANCE}.timer" --no-pager 2>/dev/null | head -n 5 || true
