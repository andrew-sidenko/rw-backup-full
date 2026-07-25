#!/usr/bin/env bash
# verify-entry.sh — выбирает режим проверки песочницы:
#   есть fleet.json (веб-сервис управляет парком) -> verify-fleet.sh
#   иначе                                          -> verify-backup.sh (локальный legacy)
#
# Автопрогон (таймер) всегда с --ordered: сервер за сервером, внутри —
# инстанс за инстансом (как ручное меню «Проверка парка»).
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_FILE="${RW_FLEET_FILE:-${INSTALL_DIR:-/opt/rw-backup-restore}/fleet.json}"
if [[ -f "$FLEET_FILE" ]] && command -v jq >/dev/null 2>&1; then
  exec "${D}/verify-fleet.sh" --ordered "$@"
fi
exec "${D}/verify-backup.sh" "$@"
