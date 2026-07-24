#!/usr/bin/env bash
# migrate-to-container.sh — перевод хоста со скриптовой установки (systemd-таймеры)
# на контейнерный агент. Идемпотентен; каждый шаг — с информированным подтверждением.
#
#   sudo ./migrate-to-container.sh            # прод-хост
#   sudo ./migrate-to-container.sh --revert   # откат на systemd-таймеры
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_DIR="/opt/rw-backup-restore"
AGENT_DIR="${INSTALL_DIR}/agent"
IMAGE="${RW_IMAGE:-rw-backup-full:5.1.0}"
REVERT="false"; [[ "${1:-}" == "--revert" ]] && REVERT="true"
[[ "$(id -u)" == 0 ]] || { echo "Нужен root"; exit 1; }

ask() { local a; echo; echo -e "\e[33m\e[1m── $1 ──\e[0m"; echo -e "$2"
  read -r -p "Выполнить? [y/N]: " a; [[ "$a" == y || "$a" == Y ]]; }

TIMERS=(rw-backup-full.timer rw-metrics-export.timer)
mapfile -t WAL_TIMERS < <(systemctl list-units 'rw-wal-ship@*.timer' 'rw-basebackup@*.timer' \
  --no-legend --all 2>/dev/null | awk '{print $1}' | grep -E '^rw-' || true)

if [[ "$REVERT" == "true" ]]; then
  if ask "ОТКАТ на systemd-таймеры" \
"Будет сделано:
  - docker compose -f ${AGENT_DIR}/docker-compose.yml down (агент останавливается)
  - systemctl enable --now: ${TIMERS[*]} ${WAL_TIMERS[*]:-}
Последствия: расписания снова исполняет systemd; конфиги и данные не меняются."; then
    [[ -f "${AGENT_DIR}/docker-compose.yml" ]] && (cd "$AGENT_DIR" && docker compose down) || true
    for t in "${TIMERS[@]}" "${WAL_TIMERS[@]:-}"; do
      [[ -n "$t" ]] && systemctl enable --now "$t" 2>/dev/null || true
    done
    echo "[OK] Откат выполнен"
  fi
  exit 0
fi

echo -e "\e[1mМиграция на контейнерный агент (образ: ${IMAGE})\e[0m"
echo "Найдены systemd-таймеры для отключения: ${TIMERS[*]} ${WAL_TIMERS[*]:-—}"

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "[ERR] Образ ${IMAGE} не найден. Соберите или спуллите его:"
  echo "      docker build -t ${IMAGE} -f container/Dockerfile .   (из корня репо)"
  echo "      или: docker pull <registry>/${IMAGE} && docker tag ..."
  exit 1; }

if ask "Шаг 1: размещение compose-файла агента" \
"Будет сделано: копия deploy/host/docker-compose.yml + .env в ${AGENT_DIR}/
(RW_SOURCE_ID=$(hostname -s) — пути в S3 останутся прежними).
Последствия: только создание файлов, ничего не запускается."; then
  mkdir -p "$AGENT_DIR"
  cp "${SRC_DIR}/deploy/host/docker-compose.yml" "${AGENT_DIR}/docker-compose.yml"
  if [[ ! -f "${AGENT_DIR}/.env" ]]; then
    printf 'RW_SOURCE_ID=%s\nTZ=%s\n' "$(hostname -s)" "$(cat /etc/timezone 2>/dev/null || echo UTC)" > "${AGENT_DIR}/.env"
  fi
  sed -i "s|image: rw-backup-full:.*|image: ${IMAGE}|" "${AGENT_DIR}/docker-compose.yml"
  echo "[OK] ${AGENT_DIR}/ подготовлен (.env сохранён, если был)"
fi

if ask "Шаг 2: запуск агента" \
"Будет сделано: docker compose up -d в ${AGENT_DIR}.
Последствия: агент начнёт исполнять ТЕ ЖЕ расписания из ТЕХ ЖЕ конфигов
(${INSTALL_DIR}). Пока systemd-таймеры активны, задания могут запускаться
дважды — flock-блокировки не дадут им работать одновременно, но отключить
таймеры (шаг 3) стоит сразу после проверки."; then
  (cd "$AGENT_DIR" && docker compose up -d)
  sleep 2
  docker logs rw-backup-agent 2>&1 | tail -n 15
fi

if ask "Шаг 3: отключение systemd-таймеров" \
"Будет сделано: systemctl disable --now для: ${TIMERS[*]} ${WAL_TIMERS[*]:-}
Юниты НЕ удаляются — откат одной командой: ./migrate-to-container.sh --revert
Последствия: расписания исполняет только контейнерный агент."; then
  for t in "${TIMERS[@]}" "${WAL_TIMERS[@]:-}"; do
    [[ -n "$t" ]] && systemctl disable --now "$t" 2>/dev/null || true
  done
  echo "[OK] systemd-таймеры отключены"
fi

echo
echo "Готово. Проверка:"
echo "  docker exec rw-backup-agent rw-backup-full status --json"
echo "  docker logs -f rw-backup-agent      # задания и их вывод"
echo "Разовые операции: docker exec -it rw-backup-agent rw-backup-full   (меню)"
