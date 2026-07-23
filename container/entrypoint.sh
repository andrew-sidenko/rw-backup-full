#!/usr/bin/env bash
# entrypoint.sh — точка входа образа rw-backup-full.
#
#   run              роль из RW_ROLE (host-agent|sandbox|web), по умолчанию host-agent
#   host-agent       расписания прод-хоста (supercronic)
#   sandbox          расписания песочницы (supercronic)
#   web              веб-сервис управления парком
#   menu             интерактивное меню rw-backup-full
#   cron-preview     показать сгенерированный crontab и выйти
#   <любая команда>  проброс в rw-backup-full (status --json, panel-backup, ...)
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
export PATH="${INSTALL_DIR}/scripts:${PATH}"

cmd="${1:-run}"
[[ "$cmd" == "run" ]] && cmd="${RW_ROLE:-host-agent}"

case "$cmd" in
  host-agent|sandbox)
    echo "[entrypoint] роль: ${cmd}; генерирую расписание из конфигов..."
    RW_ROLE="$cmd" "${INSTALL_DIR}/scripts/container/render-cron.sh" > /tmp/rw-crontab
    echo "[entrypoint] crontab:"
    sed 's/^/  /' /tmp/rw-crontab
    exec supercronic -json-logging=false /tmp/rw-crontab
    ;;
  web)
    : "${WEB_TOKEN:?WEB_TOKEN обязателен для роли web}"
    exec /opt/webvenv/bin/python "${INSTALL_DIR}/web/app.py"
    ;;
  menu)
    exec rw-backup-full
    ;;
  cron-preview)
    RW_ROLE="${RW_ROLE:-host-agent}" exec "${INSTALL_DIR}/scripts/container/render-cron.sh"
    ;;
  *)
    exec rw-backup-full "$cmd" "${@:2}"
    ;;
esac
