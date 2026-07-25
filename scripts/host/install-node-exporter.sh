#!/usr/bin/env bash
# install-node-exporter.sh — устанавливает node_exporter с включённым
# textfile collector, указывающим на тот же каталог, куда rw-backup-full
# пишет свои метрики (/var/lib/node_exporter/textfile_collector).
#
# Архитектура — push-model, как в остальном парке: node_exporter только
# отдаёт /metrics локально на 127.0.0.1:9100, а забирает их ваш vmagent
# (настраивается отдельно, в этот скрипт не входит). Наружу порт не публикуется.
#
# Идемпотентен: повторный запуск обновляет версию/юнит, не трогая уже
# работающий сервис без необходимости; каждое системное действие — с
# подтверждением и описанием последствий.
#
#   sudo ./install-node-exporter.sh              # последняя версия с GitHub
#   sudo ./install-node-exporter.sh 1.9.1         # конкретная версия
set -euo pipefail

VERSION="${1:-}"
BIN=/usr/local/bin/node_exporter
UNIT=/etc/systemd/system/node_exporter.service
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
USER=node_exporter

[[ "$(id -u)" == 0 ]] || { echo "Запустите от root: sudo $0" >&2; exit 1; }

ask() {
  echo; echo -e "\e[33m\e[1m── $1 ──\e[0m"; echo -e "$2"
  local a; read -r -p "Выполнить? [y/N]: " a; [[ "$a" == y || "$a" == Y ]]
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "[ERR] Неподдерживаемая архитектура: ${ARCH}"; exit 1 ;;
esac

if [[ -z "$VERSION" ]]; then
  VERSION="$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest \
    | grep -oE '"tag_name": *"v[0-9.]+"' | grep -oE '[0-9.]+' | head -n1)"
  [[ -n "$VERSION" ]] || { echo "[ERR] Не удалось узнать последнюю версию (GitHub API недоступен). Укажите вручную: $0 1.9.1"; exit 1; }
fi

CUR_VER=""
[[ -x "$BIN" ]] && CUR_VER="$("$BIN" --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"

echo "node_exporter: целевая версия ${VERSION}, установленная: ${CUR_VER:-нет}"
if [[ "$CUR_VER" == "$VERSION" ]] && systemctl is-active --quiet node_exporter 2>/dev/null; then
  echo "[OK] Уже установлен и работает (v${CUR_VER}). Для переустановки удалите юнит вручную."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${GOARCH}.tar.gz"

if ask "Шаг 1: скачивание и проверка бинарника" \
"Будет скачано: ${URL}
Распаковано во временный каталог, оригинальный ${BIN} не тронут до успешной
проверки (node_exporter --version)."; then
  curl -fsSL "$URL" -o "${TMP}/ne.tar.gz" || { echo "[ERR] Скачивание не удалось"; exit 1; }
  tar -xzf "${TMP}/ne.tar.gz" -C "$TMP"
  NEW_BIN="$(find "$TMP" -maxdepth 2 -name node_exporter -type f | head -n1)"
  [[ -x "$NEW_BIN" ]] || { echo "[ERR] Бинарник не найден в архиве"; exit 1; }
  "$NEW_BIN" --version >/dev/null 2>&1 || { echo "[ERR] Скачанный бинарник не запускается (${ARCH}?)"; exit 1; }
  echo "[OK] Бинарник проверен: $("$NEW_BIN" --version 2>&1 | head -n1)"
else
  exit 0
fi

if ask "Шаг 2: системный пользователь и каталоги" \
"Будет сделано: useradd --system --no-create-home ${USER} (если ещё нет);
mkdir -p ${TEXTFILE_DIR} с владельцем ${USER}.
Последствия: node_exporter будет работать без прав root, читая только
метрики хоста и файлы из ${TEXTFILE_DIR}."; then
  id "$USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$USER"
  mkdir -p "$TEXTFILE_DIR"
  # rw-backup-full пишет .prom-файлы от root (cron/systemd от root) — читающему
  # node_exporter достаточно доступа на чтение, владельца каталога не трогаем
  # агрессивно, только гарантируем его существование и доступность на чтение.
  chmod 755 /var/lib/node_exporter "$TEXTFILE_DIR" 2>/dev/null || true
  echo "[OK] Пользователь ${USER}, каталог ${TEXTFILE_DIR} готовы"
fi

if ask "Шаг 3: установка бинарника и systemd-юнит" \
"Будет сделано:
  - install -m 0755 node_exporter -> ${BIN} (замена текущего, если был)
  - запись юнита ${UNIT} (слушает 127.0.0.1:9100, только textfile+стандартные коллекторы)
  - systemctl daemon-reload
Последствия: файл бинарника заменяется атомарно; текущий процесс (если
запущен) продолжает работать со старым файлом до рестарта на шаге 4."; then
  install -m 0755 "$NEW_BIN" "$BIN"
  cat > "$UNIT" <<EOF_UNIT
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=${USER}
Group=${USER}
Type=simple
ExecStart=${BIN} \\
  --web.listen-address=127.0.0.1:9100 \\
  --collector.textfile.directory=${TEXTFILE_DIR} \\
  --collector.systemd \\
  --no-collector.ipvs
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${TEXTFILE_DIR}

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
  echo "[OK] ${BIN} обновлён, юнит записан"
fi

if ask "Шаг 4: запуск сервиса" \
"Будет сделано: systemctl enable --now node_exporter.
Последствия: сервис слушает 127.0.0.1:9100/metrics (только localhost —
наружу не публикуется; заберите его вашим vmagent как обычно)."; then
  systemctl enable --now node_exporter
  sleep 1
  if systemctl is-active --quiet node_exporter; then
    echo "[OK] node_exporter активен"
    curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null | grep -c '^rw_' \
      | xargs -I{} echo "[OK] Метрик rw_backup_full сейчас в textfile collector: {}"
  else
    echo "[ERR] Сервис не поднялся:"
    journalctl -u node_exporter -n 15 --no-pager | sed 's/^/    /'
    exit 1
  fi
fi

echo
echo "Проверка: curl -s http://127.0.0.1:9100/metrics | grep rw_"
echo "Добавьте 127.0.0.1:9100 (или адрес хоста, если vmagent внешний) как scrape-таргет в vmagent."
