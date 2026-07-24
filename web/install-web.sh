#!/usr/bin/env bash
# install-web.sh — установка веб-сервиса управления парком (на песочнице).
# Идемпотентен; каждое системное действие — с подтверждением.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/rw-backup-restore"
WEB_DIR="${INSTALL_DIR}/web"
DATA_DIR="${INSTALL_DIR}/web-data"
ENV_FILE="/etc/rw-backup-web.env"

ask() { local a; echo; echo -e "\e[33m$1\e[0m"; read -r -p "Продолжить? [y/N]: " a; [[ "$a" == y || "$a" == Y ]]; }
[[ "$(id -u)" == 0 ]] || { echo "Нужен root"; exit 1; }
command -v python3 >/dev/null || { echo "Нужен python3"; exit 1; }

# venv требует ensurepip (пакет python3-venv). Проверяем ДО создания каталога,
# чтобы не оставить битый venv, который потом маскирует проблему.
if ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
  pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  echo "[ERR] Не установлен python3-venv (модуль ensurepip недоступен)."
  echo "      Установите и запустите установщик снова:"
  echo "        apt install python${pyver}-venv    # или: apt install python3-venv"
  exit 1
fi

echo "Будет установлено:"
echo "  - ${WEB_DIR}/app.py + venv (${WEB_DIR}/venv, pip: fastapi uvicorn pydantic)"
echo "  - SSH-ключ сервиса: ${DATA_DIR}/id_ed25519 (если нет)"
echo "  - юнит rw-backup-web.service (слушает 127.0.0.1:8787)"
echo "  - файл окружения ${ENV_FILE} (токен доступа)"
ask "Установить веб-сервис?" || exit 0

mkdir -p "$WEB_DIR" "$DATA_DIR"
install -m 0644 "${SRC_DIR}/app.py" "${WEB_DIR}/app.py"

# Валидный venv = есть работающий pip; каталог без pip — обломок неудачной
# установки, его нужно пересоздать, а не пропустить.
venv_ok="false"
[[ -x "${WEB_DIR}/venv/bin/pip" ]] && "${WEB_DIR}/venv/bin/pip" --version >/dev/null 2>&1 && venv_ok="true"

if [[ "$venv_ok" != "true" ]]; then
  if [[ -d "${WEB_DIR}/venv" ]]; then
    echo "[i] Обнаружен неполный venv (без pip) — остаток прерванной установки, будет пересоздан."
  fi
  ask "Создать venv и установить зависимости из PyPI (fastapi, uvicorn, pydantic)?" || exit 1
  # --clear очищает содержимое существующего каталога venv
  python3 -m venv --clear "${WEB_DIR}/venv"
  [[ -x "${WEB_DIR}/venv/bin/pip" ]] || { echo "[ERR] venv создан без pip — проверьте python3-venv"; exit 1; }
fi
"${WEB_DIR}/venv/bin/pip" install -q --upgrade fastapi uvicorn pydantic \
  || { echo "[ERR] pip install не удался (сеть/PyPI?). Повторите установку."; exit 1; }

if [[ ! -f "${DATA_DIR}/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -C "rw-backup-web" -f "${DATA_DIR}/id_ed25519" >/dev/null
  echo "[OK] Создан SSH-ключ сервиса. Публичный ключ:"
  cat "${DATA_DIR}/id_ed25519.pub"
  echo "     Добавьте его в ~/.ssh/authorized_keys на каждом управляемом сервере."
fi
chmod 600 "${DATA_DIR}/id_ed25519"

if [[ ! -f "$ENV_FILE" ]]; then
  tok="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  cat > "$ENV_FILE" <<EOF_ENV
WEB_TOKEN=${tok}
RW_WEB_HOST=127.0.0.1
RW_WEB_PORT=8787
EOF_ENV
  chmod 600 "$ENV_FILE"
  echo "[OK] Токен доступа создан в ${ENV_FILE}:"
  echo "     WEB_TOKEN=${tok}"
else
  echo "[OK] ${ENV_FILE} уже существует — не изменён"
fi

# ReadWritePaths ниже требует существования каталога В МОМЕНТ старта systemd —
# иначе mount namespace не строится и сервис падает с 226/NAMESPACE, даже не
# дойдя до Python. Каталог нужен только для чтения .prom-файлов песочницы
# (/api/sandbox/summary); node_exporter может быть не установлен на этом
# сервере вообще — тогда просто останется пустым, это не ошибка.
mkdir -p /var/lib/node_exporter/textfile_collector

unit=/etc/systemd/system/rw-backup-web.service
if [[ -f "$unit" ]]; then
  echo "[i] Юнит уже существует и будет перезаписан новой версией."
fi
ask "Записать юнит ${unit} и выполнить daemon-reload + enable --now (перезапуск сервиса)?" || exit 0
cat > "$unit" <<EOF_U
[Unit]
Description=rw-backup-full fleet web service
After=network-online.target
Wants=network-online.target
OnFailure=rw-notify-failure@%n.service

[Service]
EnvironmentFile=${ENV_FILE}
# "+" обязателен: без него ExecStartPre выполняется в ТОМ ЖЕ сандбоксе, что и
# сам процесс (включая уже применённый ReadWritePaths), и падение из-за
# отсутствующего каталога происходит ДО того, как этот mkdir успел бы его
# создать — "+" запускает команду вне сандбокса, каталог гарантированно
# появляется раньше, чем systemd строит mount namespace для основного процесса.
ExecStartPre=+/usr/bin/mkdir -p /var/lib/node_exporter/textfile_collector
ExecStart=${WEB_DIR}/venv/bin/python ${WEB_DIR}/app.py
Restart=on-failure
User=root
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} /var/lib/node_exporter

[Install]
WantedBy=multi-user.target
EOF_U
systemctl daemon-reload
systemctl enable --now rw-backup-web.service
sleep 1
if ! systemctl is-active --quiet rw-backup-web.service; then
  echo
  echo "[ERR] Сервис не поднялся. Последние строки лога:"
  journalctl -u rw-backup-web.service -n 15 --no-pager | sed 's/^/    /'
  echo "[ERR] Если видите '226/NAMESPACE' — проверьте, что все пути из ReadWritePaths"
  echo "      юнита (${unit}) существуют: cat ${unit} | grep ReadWritePaths"
  exit 1
fi
echo
echo "Готово: http://127.0.0.1:8787 (токен в ${ENV_FILE})."
echo "ВАЖНО: наружу — только через reverse-proxy с TLS или VPN. Порт наружу не открывать."
