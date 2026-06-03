# rw-backup-full

`rw-backup-full` — надстройка над оригинальным `distillium/remnawave-backup-restore` для серверов Remnawave/VPN, где кроме панели есть самописные Docker Telegram-боты в `/home`.

## Что делает

- Не заменяет оригинальный `rw-backup`, а использует его для backup/restore Remnawave panel.
- Хранит настройки `rw-backup-full` отдельно в `/opt/rw-backup-restore/rw-backup-full.env`.
- Читает Telegram/S3 параметры из оригинального `/opt/rw-backup-restore/config.env`.
- Автоматически находит custom Docker-ботов в `/home` через Docker Compose labels.
- Делает backup custom bot: `pg_dumpall` PostgreSQL + `dump.rdb` Redis + архив папки проекта без live DB-каталогов.
- Поддерживает restore custom bot.
- Поддерживает отправку custom backup в Telegram/S3/both/local.
- Имеет отдельную глубину хранения custom backup локально и в S3.
- Имеет пункт меню установки systemd timer.

## Конфиги

### Оригинальный конфиг

```text
/opt/rw-backup-restore/config.env
```

Используется оригинальным `rw-backup`. `rw-backup-full` читает оттуда только параметры доставки:

```env
UPLOAD_METHOD="s3"
BOT_TOKEN=""
CHAT_ID=""
MESSAGE_THREAD_ID=""
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION="us-east-1"
S3_ENDPOINT=""
S3_PREFIX="rw-backup"
```

### Конфиг full

```text
/opt/rw-backup-restore/rw-backup-full.env
```

Тут хранятся только параметры надстройки:

```env
FULL_UPLOAD_METHOD="inherit"
FULL_BACKUP_DIR="/opt/rw-backup-restore/backup"
FULL_LOCAL_RETENTION_DAYS="3"
FULL_S3_RETENTION_DAYS="10"
FULL_TIMER_MODE="custom-backup"
FULL_TIMER_INTERVAL_HOURS="3"
FULL_AUTO_INSTALL_RW_BACKUP="true"
FULL_REQUIRE_ORIGINAL_RW_BACKUP="true"
FULL_INCLUDE_EXTRA_CONFIGS="true"
FULL_SYSTEMD_UNIT_NAME="rw-backup-full"
```

`FULL_UPLOAD_METHOD=inherit` означает: взять `UPLOAD_METHOD` из оригинального `config.env`.

## Установка

```bash
sudo apt-get update
sudo apt-get install -y curl tar gzip docker.io docker-compose-plugin
```

```bash
git clone https://github.com/YOUR-USER/rw-backup-full.git
cd rw-backup-full
sudo ./install.sh
```

Установщик:

1. Кладёт `rw-backup-full.sh` в `/opt/rw-backup-restore/rw-backup-full.sh`.
2. Создаёт symlink `/usr/local/bin/rw-backup-full`.
3. Не перезаписывает существующий `/opt/rw-backup-restore/config.env`.
4. Создаёт `/opt/rw-backup-restore/rw-backup-full.env`, если его нет.
5. Если оригинальный `rw-backup` отсутствует — скачивает `/opt/rw-backup-restore/backup-restore.sh` и создаёт `/usr/local/bin/rw-backup`.

## Проверка

```bash
sudo rw-backup-full config
sudo rw-backup-full list
```

Для найденного бота вывод будет примерно таким:

```text
oneokbotnew
  dir:      /home/OneOkBotNew
  postgres: vpn_postgres / service=postgres
  redis:    vpn_redis / service=redis
  apps:     vpn_api vpn_bot vpn_user_cabinet
```

## Меню

```bash
sudo rw-backup-full
```

Пункты меню:

```text
1. Backup Remnawave panel через оригинальный rw-backup
2. Restore Remnawave panel через оригинальный rw-backup
3. Backup custom bot из /home
4. Restore custom bot из custom_bot архива
5. Backup ALL: panel + custom bot
6. Показать найденные custom bot проекты
7. Настроить full retention / режим / интервал
8. Установить/обновить systemd timer
9. Установить/обновить оригинальный rw-backup
10. Показать настройки
11. Открыть оригинальное меню rw-backup
```

## Backup только ботов

```bash
sudo rw-backup-full custom-backup
```

## Backup panel + bots

```bash
sudo rw-backup-full backup-all
```

Если панели на сервере нет, panel backup будет пропущен, а custom backup ботов выполнится.

## Restore custom bot

```bash
sudo rw-backup-full custom-restore
```

Или из конкретного файла:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_oneokbotnew_20260603_120000.tar.gz
```

Без подтверждения:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_oneokbotnew_20260603_120000.tar.gz --yes
```

## Systemd timer раз в 3 часа

Через меню:

```bash
sudo rw-backup-full
# пункт 8
```

Или напрямую:

```bash
sudo rw-backup-full install-timer
```

Проверка:

```bash
systemctl list-timers | grep rw-backup
sudo journalctl -u rw-backup-full.service -n 100 --no-pager
```

Настройки таймера хранятся в `rw-backup-full.env`:

```env
FULL_TIMER_MODE="custom-backup"
FULL_TIMER_INTERVAL_HOURS="3"
```

Для сервера только с ботами используйте:

```env
FULL_TIMER_MODE="custom-backup"
```

Для сервера с панелью и ботом:

```env
FULL_TIMER_MODE="backup-all"
```

## Retention

Настройка через меню:

```bash
sudo rw-backup-full configure
```

Или вручную:

```env
FULL_LOCAL_RETENTION_DAYS="3"
FULL_S3_RETENTION_DAYS="10"
```

S3 cleanup удаляет только:

```text
custom_bot_*.tar.gz
```

и не трогает оригинальные:

```text
remnawave_backup_*.tar.gz
```

## Диагностика структуры сервера

```bash
sudo scripts/collect-bot-structure.sh
```

Отчёт будет создан в `/root/bot-structure-report-<host>-<date>.txt`.

## Условия для custom bot backup

- Бот запущен через `docker compose`.
- Рабочая папка проекта находится в `/home/...`.
- В compose-проекте есть PostgreSQL контейнер или сервис `postgres`.
- В compose-проекте есть Redis контейнер или сервис `redis`.
- Для Telegram установлен `curl`.
- Для S3 установлен `awscli`.

## Что внутри custom backup

```text
PROFILE.env
postgres_dump.sql.gz
redis_dump.rdb
project_dir.tar.gz
docker-compose-rendered.yaml
docker-compose-services.txt
docker-compose-ps-a.txt
docker-ps-a.txt
docker-volume-ls.txt
docker-network-ls.txt
volumes-tree.txt
volumes-size.txt
extra_configs/caddy_config.tar.gz
extra_configs/subscription_config.tar.gz
BACKUP_NOTES.txt
SHA256SUMS
```

`project_dir.tar.gz` исключает live-каталоги:

```text
volumes/pgdata
volumes/redis
```

Потому что PostgreSQL восстанавливается из `postgres_dump.sql.gz`, а Redis — из `redis_dump.rdb`.
