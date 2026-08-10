# rw-backup-verify — автономная проверка логических бэкапов

Отдельный проект для сервера-песочницы. **Не связан** с веб-парком, SSH на прод
и `fleet.json` из `rw-backup-full`.

## Как работает

1. Глобальное расписание (`verify.interval_hours` или `verify.times`) — одна частота на все хранилища.
2. В это время обходятся **все** S3-записи: глубокий рекурсивный обход prefix.
3. В любой вложенности ищутся архивы `remnawave_backup_*.tar.gz` и `custom_bot_*.tar.gz`.
4. В каждой папке экземпляры группируются по семейству имён (панель / каждый бот-проект).
5. Берётся **только latest** каждого экземпляра; если этот ключ уже в `tested/` — пропуск.
6. Очередь FIFO: все due-экземпляры выполняются **строго по одному**.
7. Подробный отчёт в Telegram.

`backup_hint` у хранилища — только подсказка, как часто бэкапы **создаются** на проде.

## Раскладка в S3 (гибкая)

Поддерживается и канон `rw-backup-full`, и произвольная вложенность:

```
s3://bucket/<prefix>/panel/<source>/remnawave_backup_….tar.gz
s3://bucket/<prefix>/custom-bot/<source>/custom_bot_<proj>_….tar.gz
s3://bucket/<prefix>/clients/acme/panel/remnawave_backup_….tar.gz
s3://bucket/<prefix>/clients/acme/bots/custom_bot_bot1_….tar.gz
s3://bucket/<prefix>/clients/acme/bots/custom_bot_bot2_….tar.gz
```

В одной папке могут лежать архивы с разных серверов/проектов — каждый
`custom_bot_<имя>_…` и `remnawave_backup_…` = отдельный экземпляр.

## Быстрый старт

```bash
sudo ./install.sh

rw-backup-verify storage add \
  --id cf-oneok --endpoint https://... --bucket oneok \
  --access-key ... --secret-key ... --prefix oneok-wal \
  --backup-hint "прод: ежедневно 03:00"

rw-backup-verify schedule set --interval-hours 12
# или: rw-backup-verify schedule set --times 06:30,18:30

rw-backup-verify telegram set --token <bot> --chat-id <id>
rw-backup-verify discover cf-oneok          # что будет тестироваться
rw-backup-verify run --storage cf-oneok     # сейчас
```

## Восстановление при тесте

| Вид | Основа | Шаги |
|---|---|---|
| **panel** | dump-path verify-stack | `dump_*.sql.gz` + `remnawave_dir_*.tar.gz` → PG + isolate compose |
| **bot** | `custom-restore` из rw-backup-full | `PROFILE.env` + `postgres_dump.sql.gz` + `redis_dump.rdb` → volumes/redis + `project_dir.tar.gz` → isolate (без postgres-сервиса, с алиасами БД) |

Изоляция: сеть `--internal`, без published ports / docker.sock / external nets.

## Команды

```
rw-backup-verify storage list|add|remove|show
rw-backup-verify schedule show|set
rw-backup-verify telegram set|show
rw-backup-verify discover <id> [--all]
rw-backup-verify run [--due] [--storage ID]
rw-backup-verify queue status|clear|work
rw-backup-verify tick
```

Конфиг: `/etc/rw-backup-verify/config.json`  
Состояние tested: `/var/lib/rw-backup-verify/tested/<storage>.json`
