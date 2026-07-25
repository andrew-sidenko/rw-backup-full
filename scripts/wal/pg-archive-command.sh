#!/bin/sh
# pg-archive-command.sh — выполняется ВНУТРИ контейнера postgres как archive_command.
#
# Монтируется read-only в /wal-spool/archive-command.sh
# archive_command = '/wal-spool/archive-command.sh %p %f'
#
# ПРИНЦИП: этот скрипт НИКОГДА не ходит в сеть.
# Он делает только атомарное копирование WAL-сегмента в спул на хосте.
# Если бы здесь был `wal-g wal-push` или `aws s3 cp`, то при недоступности S3
# archive_command начал бы падать, PostgreSQL перестал бы удалять сегменты
# из pg_wal и заполнил бы диск ноды. Отправкой в S3 занимается отдельный
# процесс на хосте (wal-ship.sh), который умеет ретраи и не блокирует БД.
#
# POSIX sh: в образе postgres нет bash-специфики, на которую можно рассчитывать.

set -eu

SPOOL_DIR="${WAL_SPOOL_DIR:-/wal-spool/incoming}"

src_path="${1:-}"
seg_name="${2:-}"

if [ -z "$src_path" ] || [ -z "$seg_name" ]; then
    echo "archive-command: usage: $0 %p %f" >&2
    exit 1
fi

if [ ! -f "$src_path" ]; then
    echo "archive-command: исходный файл отсутствует: $src_path" >&2
    exit 1
fi

mkdir -p "$SPOOL_DIR" 2>/dev/null || true

dst="${SPOOL_DIR}/${seg_name}"
tmp="${SPOOL_DIR}/.${seg_name}.tmp.$$"

# Идемпотентность: если сегмент уже в спуле или уже отправлен — успех.
# PostgreSQL может повторно вызвать archive_command после рестарта.
if [ -f "$dst" ] || [ -f "${dst}.done" ]; then
    exit 0
fi

# Копируем во временный файл, затем атомарный rename.
# Так wal-ship.sh никогда не увидит частично записанный сегмент.
if ! cp "$src_path" "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "archive-command: не удалось скопировать $seg_name в спул" >&2
    exit 1
fi

# fsync файла и каталога — без этого сегмент может потеряться при потере питания.
if command -v sync >/dev/null 2>&1; then
    sync "$tmp" 2>/dev/null || sync 2>/dev/null || true
fi

if ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "archive-command: не удалось переименовать $seg_name" >&2
    exit 1
fi

# Защита от переполнения спула: если хост-шиппер умер и сегментов накопилось
# слишком много, лучше начать падать ЯВНО и поднять алерт, чем молча
# копить гигабайты. Порог по умолчанию — 2000 сегментов (~32 ГБ при 16 МБ).
MAX_SPOOL="${WAL_SPOOL_MAX_FILES:-2000}"
count=$(find "$SPOOL_DIR" -maxdepth 1 -type f -name '0*' 2>/dev/null | wc -l)
if [ "$count" -gt "$MAX_SPOOL" ]; then
    echo "archive-command: спул переполнен ($count > $MAX_SPOOL), шиппер не работает" >&2
    exit 1
fi

exit 0
