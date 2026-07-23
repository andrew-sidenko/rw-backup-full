#!/usr/bin/env bash
# install.sh — установка/обновление rw-backup-full v5.
#
#   sudo ./install.sh              # прод-сервер
#   sudo ./install.sh --sandbox    # сервер-песочница (+ предложит веб-сервис)
#   sudo ./install.sh --yes        # без вопросов (для автоматизации), любые роли
#
# Принципы:
#   - ИДЕМПОТЕНТНОСТЬ: безопасен поверх v3/v4 и повторных запусков; пользовательские
#     конфиги не перезаписываются, заменяемые файлы бэкапятся.
#   - ИНФОРМИРОВАННОЕ СОГЛАСИЕ: перед каждым классом изменений показывается,
#     что именно будет сделано и какие последствия; без "y" шаг пропускается.
#     Никаких перезапусков сервисов и удалений без явного разрешения.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="${INSTALL_DIR}/backup"
FULL_CONFIG="${INSTALL_DIR}/rw-backup-full.env"
ORIGINAL_CONFIG="${INSTALL_DIR}/config.env"
STAMP="$(date +%Y%m%d_%H%M%S)"
KEEP_DIR="${INSTALL_DIR}/.install-backup/${STAMP}"
ROLE="prod"; ASSUME_YES="false"

for a in "$@"; do
  case "$a" in
    --sandbox) ROLE="sandbox" ;;
    --yes|-y)  ASSUME_YES="true" ;;
  esac
done
[[ "$(id -u)" == 0 ]] || { echo "Запустите от root: sudo ./install.sh" >&2; exit 1; }

C_Y=$'\e[33m'; C_B=$'\e[1m'; C_R=$'\e[0m'; C_C=$'\e[36m'
say() { echo -e "${C_C}[..]${C_R} $*"; }
ok()  { echo -e "\e[32m[OK]\e[0m $*"; }
warn(){ echo -e "${C_Y}[!!]${C_R} $*"; }

ask() {
  # ask "<заголовок>" "<многострочное описание действий и последствий>"
  [[ "$ASSUME_YES" == "true" ]] && { say "[auto-yes] $1"; return 0; }
  echo
  echo -e "${C_Y}${C_B}── $1 ──${C_R}"
  echo -e "$2"
  local a; read -r -p "Выполнить этот шаг? [y/N]: " a
  [[ "$a" == y || "$a" == Y ]]
}

# Установка файла с бэкапом заменяемой версии (только если содержимое меняется).
put() { # put <mode> <src> <dst>
  local mode="$1" src="$2" dst="$3"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then return 0; fi
  if [[ -f "$dst" ]]; then
    mkdir -p "${KEEP_DIR}$(dirname "$dst")"
    cp -a "$dst" "${KEEP_DIR}${dst}"
  fi
  install -m "$mode" "$src" "$dst"
}

# --------------------------------------------------------------------------
# Обзор и план
# --------------------------------------------------------------------------
V3_DETECTED="false"; [[ -f "${INSTALL_DIR}/rw-backup-full.sh" ]] && V3_DETECTED="true"
ORIG_DETECTED="false"; [[ -x "${INSTALL_DIR}/backup-restore.sh" || -x /usr/local/bin/rw-backup ]] && ORIG_DETECTED="true"

echo -e "${C_B}Установка rw-backup-full v5 (роль: ${ROLE})${C_R}"
echo "Обнаружено:"
echo "  предыдущая версия rw-backup-full: $([[ $V3_DETECTED == true ]] && echo 'ДА (обновление)' || echo 'нет (чистая установка)')"
echo "  оригинальный distillium rw-backup: $([[ $ORIG_DETECTED == true ]] && echo 'да' || echo 'нет')"
echo
echo "План (каждый шаг — с отдельным подтверждением):"
echo "  1. Проверка зависимостей (ничего не устанавливается автоматически)"
echo "  2. Копирование скриптов v5 в ${INSTALL_DIR} (заменяемые файлы -> ${KEEP_DIR})"
echo "  3. Конфиги: создание отсутствующих; существующие НЕ трогаются"
echo "  4. Миграция: единые настройки панели из config.env; legacy-S3 -> s3.d/"
echo "  5. systemd-юниты + daemon-reload (существующие таймеры не перезапускаются)"
[[ "$ROLE" == "sandbox" ]] && echo "  6. Песочница: таймер проверки; предложение веб-сервиса"
echo
if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Начать? [y/N]: " a0; [[ "$a0" == y || "$a0" == Y ]] || exit 0
fi

# --------------------------------------------------------------------------
# 1. Зависимости
# --------------------------------------------------------------------------
say "Шаг 1: зависимости"
miss=()
command -v docker >/dev/null || miss+=(docker)
command -v flock  >/dev/null || miss+=(util-linux)
if (( ${#miss[@]} )); then
  echo "Отсутствуют обязательные пакеты: ${miss[*]}"
  echo "Установите их и запустите инсталлятор снова (сам он пакеты не ставит)."
  exit 1
fi
command -v aws  >/dev/null || warn "awscli не найден — S3 работать не будет (apt install awscli)"
command -v zstd >/dev/null || warn "zstd не найден — сжатие через gzip (рекомендуется: apt install zstd)"
command -v age  >/dev/null || say  "age не найден — шифрование недоступно (нужно при INST_ENCRYPT=true)"
ok "Зависимости проверены"

# --------------------------------------------------------------------------
# 2. Файлы
# --------------------------------------------------------------------------
if ask "Шаг 2: копирование файлов v5" \
"Будет сделано:
  - скрипты -> ${INSTALL_DIR}/{rw-backup-full.sh, scripts/lib, scripts/wal, scripts/panel, scripts/metrics, scripts/sandbox}
  - симлинк /usr/local/bin/rw-backup-full
  - примеры конфигов -> ${INSTALL_DIR}/config-examples/
Последствия: код обновляется до v5. Каждый заменяемый файл предварительно
копируется в ${KEEP_DIR} (откат = копирование обратно). Конфиги, бэкапы,
инстансы, S3-бэкенды НЕ затрагиваются."; then
  mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "${INSTALL_DIR}/instances.d" "${INSTALL_DIR}/s3.d" \
           "${INSTALL_DIR}/scripts/lib" "${INSTALL_DIR}/scripts/wal" "${INSTALL_DIR}/scripts/panel" \
           "${INSTALL_DIR}/scripts/metrics" "${INSTALL_DIR}/scripts/sandbox" \
           "${INSTALL_DIR}/config-examples/instances.d" "${INSTALL_DIR}/config-examples/s3.d" \
           "${INSTALL_DIR}/grafana"
  put 0755 "$SRC_DIR/scripts/rw-backup-full.sh" "$INSTALL_DIR/rw-backup-full.sh"
  ln -sf "$INSTALL_DIR/rw-backup-full.sh" /usr/local/bin/rw-backup-full
  for f in "$SRC_DIR"/scripts/lib/*.sh;     do put 0644 "$f" "${INSTALL_DIR}/scripts/lib/$(basename "$f")"; done
  for f in "$SRC_DIR"/scripts/wal/*.sh;     do put 0755 "$f" "${INSTALL_DIR}/scripts/wal/$(basename "$f")"; done
  for f in "$SRC_DIR"/scripts/panel/*.sh;   do put 0755 "$f" "${INSTALL_DIR}/scripts/panel/$(basename "$f")"; done
  for f in "$SRC_DIR"/scripts/metrics/*.sh; do put 0755 "$f" "${INSTALL_DIR}/scripts/metrics/$(basename "$f")"; done
  put 0755 "$SRC_DIR/scripts/sandbox/verify-backup.sh" "${INSTALL_DIR}/scripts/sandbox/verify-backup.sh"
  [[ -f "$SRC_DIR/scripts/collect-bot-structure.sh" ]] && {
    put 0755 "$SRC_DIR/scripts/collect-bot-structure.sh" "$INSTALL_DIR/collect-bot-structure.sh"
    ln -sf "$INSTALL_DIR/collect-bot-structure.sh" /usr/local/bin/collect-bot-structure; }
  for f in "$SRC_DIR"/config/instances.d/*.example; do put 0644 "$f" "${INSTALL_DIR}/config-examples/instances.d/$(basename "$f")"; done
  for f in "$SRC_DIR"/config/s3.d/*.example;        do put 0644 "$f" "${INSTALL_DIR}/config-examples/s3.d/$(basename "$f")"; done
  put 0644 "$SRC_DIR/grafana/dashboard.json" "${INSTALL_DIR}/grafana/dashboard.json"
  ok "Файлы v5 установлены (резервные копии: ${KEEP_DIR})"
else
  warn "Шаг пропущен — код не обновлён"; exit 0
fi

# --------------------------------------------------------------------------
# 3. Конфиги
# --------------------------------------------------------------------------
say "Шаг 3: конфиги"
if [[ ! -f "$FULL_CONFIG" ]]; then
  install -m 0600 "$SRC_DIR/config/rw-backup-full.env.example" "$FULL_CONFIG"
  ok "Создан ${FULL_CONFIG}"
else
  ok "Существующий ${FULL_CONFIG} сохранён без изменений"
fi
[[ "$ROLE" == "prod" && ! -f "$ORIGINAL_CONFIG" && ! $ORIG_DETECTED == true ]] && \
  say "Оригинальный config.env отсутствует — не нужен: v5 делает panel-бэкап встроенным движком"

# --------------------------------------------------------------------------
# 4. Миграция (настройки не дублируются)
# --------------------------------------------------------------------------
if [[ -f "$ORIGINAL_CONFIG" ]] && ! grep -q '^PANEL_DB_USER=' "$FULL_CONFIG" 2>/dev/null; then
  # shellcheck disable=SC1090
  ORIG_DB_USER="$(grep -E '^DB_USER=' "$ORIGINAL_CONFIG" | head -n1 | cut -d'"' -f2 || true)"
  ORIG_ROOT="$(grep -E '^REMNALABS_ROOT_DIR=' "$ORIGINAL_CONFIG" | head -n1 | cut -d'"' -f2 || true)"
  if ask "Шаг 4а: импорт настроек панели из оригинального config.env" \
"Будет сделано: в ${FULL_CONFIG} ДОБАВЛЕНЫ строки
  PANEL_DB_USER=\"${ORIG_DB_USER:-postgres}\"
  PANEL_ROOT_DIR=\"${ORIG_ROOT:-/opt/remnawave}\"
Последствия: v5 будет использовать единый конфиг; оригинальный config.env
не изменяется и остаётся для совместимости со старым rw-backup."; then
    {
      echo ""
      echo "# --- v5: настройки панели (импортированы из config.env ${STAMP}) ---"
      echo "PANEL_DB_USER=\"${ORIG_DB_USER:-postgres}\""
      echo "PANEL_ROOT_DIR=\"${ORIG_ROOT:-/opt/remnawave}\""
    } >> "$FULL_CONFIG"
    ok "Настройки панели импортированы"
  fi
fi

if grep -qE '^FULL_EXTERNAL_S3_BUCKET="[^"]+"' "$FULL_CONFIG" 2>/dev/null \
   && ! ls "${INSTALL_DIR}/s3.d/"*.env >/dev/null 2>&1; then
  if ask "Шаг 4б: миграция одиночного внешнего S3 в мульти-бэкенды" \
"Обнаружены старые настройки FULL_EXTERNAL_S3_* в ${FULL_CONFIG}.
Будет сделано: создан файл ${INSTALL_DIR}/s3.d/default.env с теми же
реквизитами и текущими сроками хранения.
Последствия: S3-хранилищ теперь может быть несколько (s3.d/*.env), у каждого
свои настройки и retention. Старые переменные останутся в конфиге как
резервный fallback — их можно удалить после проверки."; then
    g(){ grep -E "^$1=" "$FULL_CONFIG" | head -n1 | cut -d'"' -f2; }
    cat > "${INSTALL_DIR}/s3.d/default.env" <<EOF_MIG
# Мигрировано из FULL_EXTERNAL_S3_* (${STAMP})
B_ENABLED="true"
B_ENDPOINT="$(g FULL_EXTERNAL_S3_ENDPOINT)"
B_BUCKET="$(g FULL_EXTERNAL_S3_BUCKET)"
B_ACCESS_KEY="$(g FULL_EXTERNAL_S3_ACCESS_KEY)"
B_SECRET_KEY="$(g FULL_EXTERNAL_S3_SECRET_KEY)"
B_REGION="$(g FULL_EXTERNAL_S3_REGION)"
B_PREFIX="$(g FULL_EXTERNAL_S3_PREFIX)"
B_UPLOAD_PANEL="$(g FULL_PANEL_EXTERNAL_S3_ENABLED)"
B_UPLOAD_CUSTOM="$(g FULL_CUSTOM_EXTERNAL_S3_ENABLED)"
B_UPLOAD_WAL="$(g FULL_WAL_S3_ENABLED)"
B_RETENTION_PANEL_DAYS="$(g FULL_EXTERNAL_S3_RETENTION_DAYS)"
B_RETENTION_CUSTOM_DAYS="$(g FULL_EXTERNAL_S3_RETENTION_DAYS)"
B_BASEBACKUP_KEEP="7"
B_RETENTION_MIN_KEEP="$(g FULL_EXTERNAL_S3_RETENTION_MIN_KEEP)"
EOF_MIG
    chmod 600 "${INSTALL_DIR}/s3.d/default.env"
    ok "Создан s3.d/default.env"
  fi
fi

# --------------------------------------------------------------------------
# 5. systemd
# --------------------------------------------------------------------------
UNITS_PROD=(rw-wal-ship@.service rw-wal-ship@.timer rw-basebackup@.service rw-basebackup@.timer \
            rw-metrics-export.service rw-metrics-export.timer)
UNITS_ALL=(rw-sandbox-verify.service rw-sandbox-verify.timer)
if ask "Шаг 5: systemd-юниты" \
"Будет сделано:
  - установка/обновление юнитов: $([[ $ROLE == prod ]] && echo "${UNITS_PROD[*]} ") ${UNITS_ALL[*]}
  - главный rw-backup-full.service/.timer: создаются только если ОТСУТСТВУЮТ
    (существующий таймер и его расписание не трогаются)
  - systemctl daemon-reload
Последствия: daemon-reload безопасен и не перезапускает работающие сервисы.
Никакие таймеры на этом шаге не включаются и не перезапускаются."; then
  if [[ "$ROLE" == "prod" ]]; then
    for u in "${UNITS_PROD[@]}"; do put 0644 "$SRC_DIR/systemd/$u" "/etc/systemd/system/$u"; done
    if [[ ! -f /etc/systemd/system/rw-backup-full.timer ]]; then
      put 0644 "$SRC_DIR/systemd/rw-backup-full.service" /etc/systemd/system/rw-backup-full.service
      put 0644 "$SRC_DIR/systemd/rw-backup-full.timer"   /etc/systemd/system/rw-backup-full.timer
      say "Созданы rw-backup-full.service/.timer (включение: rw-backup-full install-timer)"
    else
      ok "rw-backup-full.timer уже существует — расписание сохранено"
    fi
  fi
  for u in "${UNITS_ALL[@]}"; do put 0644 "$SRC_DIR/systemd/$u" "/etc/systemd/system/$u"; done
  systemctl daemon-reload
  ok "Юниты установлены, daemon-reload выполнен"

  if [[ "$ROLE" == "prod" ]]; then
    if ask "Шаг 5б: таймер экспорта метрик" \
"Будет сделано: systemctl enable --now rw-metrics-export.timer (каждые 15 мин).
Последствия: раз в 15 минут собираются метрики о бэкапах/дисках/S3 для Grafana.
Нагрузка минимальна; листинг S3 отключается FULL_METRICS_S3_SIZES=false."; then
      systemctl enable --now rw-metrics-export.timer
      ok "rw-metrics-export.timer включён"
    fi
  fi
fi

# --------------------------------------------------------------------------
# 6. Песочница
# --------------------------------------------------------------------------
if [[ "$ROLE" == "sandbox" ]]; then
  if ask "Шаг 6а: таймер проверки бэкапов" \
"Будет сделано: systemctl enable --now rw-sandbox-verify.timer (ежедневно ~05:30,
меняется через SANDBOX_VERIFY_TIMES + rw-backup-full sandbox-timer).
Последствия: песочница начнёт ежедневно скачивать бэкапы из S3 и проверять
их реальным восстановлением во временных контейнерах."; then
    systemctl enable --now rw-sandbox-verify.timer
    ok "Таймер песочницы включён"
  fi
  if [[ -f "$SRC_DIR/web/install-web.sh" ]]; then
    if ask "Шаг 6б: веб-сервис управления парком серверов" \
"Будет запущен отдельный установщик web/install-web.sh (свои подтверждения):
venv+FastAPI, SSH-ключ сервиса, юнит rw-backup-web.service на 127.0.0.1:8787.
Последствия: появится веб-интерфейс мониторинга/управления всеми серверами."; then
      cp -r "$SRC_DIR/web" "${INSTALL_DIR}/web-src"
      bash "${INSTALL_DIR}/web-src/install-web.sh"
    fi
  fi
fi

# --------------------------------------------------------------------------
echo
ok "Установка v5 завершена (роль: ${ROLE})."
echo "Резервные копии заменённых файлов: ${KEEP_DIR}"
echo
echo "Дальше:"
if [[ "$ROLE" == "prod" ]]; then
  cat <<'EOF_N'
  rw-backup-full                # единое меню (S3-бэкенды — п.16)
  rw-backup-full s3-add         # добавить внешние S3 (сколько нужно)
  rw-backup-full install-timer  # расписание логических бэкапов
  rw-backup-full wal-enable <инстанс>   # WAL-архивация (спросит про рестарт БД)
  Дашборд Grafana: /opt/rw-backup-restore/grafana/dashboard.json
EOF_N
else
  cat <<'EOF_N'
  nano /opt/rw-backup-restore/rw-backup-full.env   # S3-доступ на чтение
  scp prod:/opt/rw-backup-restore/instances.d/*.env /opt/rw-backup-restore/instances.d/
  rw-backup-full verify                            # пробная проверка
  Веб-интерфейс: http://127.0.0.1:8787 (токен в /etc/rw-backup-web.env)
EOF_N
fi
