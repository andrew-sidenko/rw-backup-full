#!/usr/bin/env bash
# fleet-pack.sh — перенос сервера песочницы/управления одним компактным файлом.
# Бэкап этого сервера не предполагается: ВСЁ его состояние — это fleet.json
# (серверы + настройки проверок), SSH-ключ сервиса и токен веб-интерфейса.
# Реквизиты хранилищ и параметры серверов сюда НЕ входят — они извлекаются
# с серверов автоматически при каждой проверке.
#
#   fleet-pack.sh pack   [файл.tgz]   — собрать (по умолчанию ./rw-fleet-<host>-<дата>.tgz)
#   fleet-pack.sh unpack <файл.tgz>   — развернуть на новом сервере (с подтверждением)
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-restore}"
FLEET_FILE="${RW_FLEET_FILE:-${INSTALL_DIR}/fleet.json}"
DATA_DIR="${RW_WEB_DATA:-${INSTALL_DIR}/web-data}"
WEB_ENV="/etc/rw-backup-web.env"

case "${1:-}" in
  pack)
    out="${2:-./rw-fleet-$(hostname -s)-$(date +%Y%m%d).tgz}"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    mkdir -p "${tmp}/fleet"
    [[ -f "$FLEET_FILE" ]] && cp "$FLEET_FILE" "${tmp}/fleet/fleet.json"
    [[ -f "${DATA_DIR}/id_ed25519" ]] && cp "${DATA_DIR}/id_ed25519" "${DATA_DIR}/id_ed25519.pub" "${tmp}/fleet/" 2>/dev/null
    [[ -f "$WEB_ENV" ]] && cp "$WEB_ENV" "${tmp}/fleet/rw-backup-web.env"
    tar -czf "$out" -C "$tmp" fleet
    chmod 600 "$out"
    echo "[OK] Состояние упаковано: $out ($(du -h "$out" | awk '{print $1}'))"
    echo "     Внутри: fleet.json, SSH-ключ сервиса, токен веб-интерфейса."
    echo "     Файл содержит секреты — храните как секрет."
    ;;
  unpack)
    src="${2:?Укажите файл .tgz}"
    [[ -f "$src" ]] || { echo "[ERR] Нет файла: $src"; exit 1; }
    echo "Будет развёрнуто на этом сервере:"
    tar -tzf "$src" | sed 's/^/  /'
    echo "Существующие fleet.json / SSH-ключ / токен будут ЗАМЕНЕНЫ."
    read -r -p "Продолжить? [y/N]: " a; [[ "$a" == y || "$a" == Y ]] || exit 0
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    tar -xzf "$src" -C "$tmp"
    mkdir -p "$INSTALL_DIR" "$DATA_DIR"
    [[ -f "${tmp}/fleet/fleet.json" ]] && install -m 600 "${tmp}/fleet/fleet.json" "$FLEET_FILE"
    [[ -f "${tmp}/fleet/id_ed25519" ]] && install -m 600 "${tmp}/fleet/id_ed25519" "${DATA_DIR}/id_ed25519"
    [[ -f "${tmp}/fleet/id_ed25519.pub" ]] && install -m 644 "${tmp}/fleet/id_ed25519.pub" "${DATA_DIR}/id_ed25519.pub"
    [[ -f "${tmp}/fleet/rw-backup-web.env" ]] && install -m 600 "${tmp}/fleet/rw-backup-web.env" "$WEB_ENV"
    echo "[OK] Развёрнуто. Дальше: установить/запустить веб-сервис и таймер песочницы —"
    echo "     весь парк и настройки проверок подхватятся автоматически."
    ;;
  *)
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
