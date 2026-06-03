# rw-backup-full

`rw-backup-full` — надстройка над `distillium/remnawave-backup-restore` для проектов, где на одном сервере может быть:

- Remnawave panel;
- только custom Telegram/VPN bot без панели;
- Caddy;
- Remnawave subscription-page;
- несколько Docker Compose проектов в `/home`.

Скрипт не зависит от имени папки `/home/VPNNEW`, `/home/OneOkBotNew` или другого имени. Custom bot проекты находятся автоматически через Docker Compose labels.

## Что умеет

- Запускать оригинальный `rw-backup` для Remnawave panel.
- Делать backup custom Docker bot проектов из `/home`.
- Делать restore custom Docker bot проектов.
- Отправлять custom backup в Telegram, S3, оба направления или оставлять локально.
- Чистить локальные `custom_bot_*.tar.gz` по глубине хранения.
- Чистить S3 `custom_bot_*.tar.gz` по глубине хранения.
- Сохранять дополнительные конфиги `/opt/remnawave/caddy` и `/opt/remnawave/subscription`, если они есть.

## Логика custom bot backup

Для каждого найденного проекта в `/home`:

1. Находит Docker Compose project через labels.
2. Определяет рабочую директорию проекта.
3. Находит PostgreSQL контейнер.
4. Находит Redis/Valkey контейнер.
5. Делает `pg_dumpall` из PostgreSQL контейнера.
6. Делает `redis-cli SAVE` и забирает `dump.rdb`.
7. Архивирует папку проекта.
8. Исключает из архива live-каталоги:
   - `volumes/pgdata`
   - `volumes/redis`
9. Кладёт всё в итоговый архив `custom_bot_<project>_<timestamp>.tar.gz`.
10. Отправляет архив в Telegram или S3 согласно `config.env`.

## Условия для custom bot backup

На сервере должны быть:

- Docker;
- Docker Compose plugin;
- `tar`;
- `gzip`;
- `curl` для Telegram upload;
- `awscli` для S3 upload;
- Docker Compose проект в `/home/...`;
- PostgreSQL контейнер в этом compose-проекте;
- Redis или Valkey контейнер в этом compose-проекте.

Проект должен быть запущен через `docker compose up -d`, а не через одиночный `docker run`, потому что auto-detect использует Docker Compose labels:

- `com.docker.compose.project`
- `com.docker.compose.project.working_dir`
- `com.docker.compose.service`

## Установка

```bash
sudo apt-get update
sudo apt-get install -y curl tar gzip
```

Для S3:

```bash
sudo apt-get install -y awscli
```

Установка проекта:

```bash
git clone https://github.com/YOUR-ORG/rw-backup-full.git
cd rw-backup-full
sudo ./install.sh
```

Установщик:

- создаёт `/opt/rw-backup-restore/backup`;
- копирует `scripts/rw-backup-full.sh` в `/opt/rw-backup-restore/rw-backup-full.sh`;
- создаёт symlink `/usr/local/bin/rw-backup-full`;
- не перезаписывает существующий `/opt/rw-backup-restore/config.env`;
- если `config.env` уже есть, добавляет в конец блок настроек `rw-backup-full`.

## Настройка config.env

Файл:

```bash
sudo nano /opt/rw-backup-restore/config.env
```

Минимальный вариант для Telegram:

```env
UPLOAD_METHOD="telegram"

BOT_TOKEN="123456:xxxxxxxxxxxxxxxx"
CHAT_ID="-1001234567890"
MESSAGE_THREAD_ID="123"

RETAIN_BACKUPS_DAYS=3
S3_RETENTION_DAYS=10
```

Минимальный вариант для S3:

```env
UPLOAD_METHOD="s3"

S3_BUCKET="bucket-name"
S3_ACCESS_KEY="access-key"
S3_SECRET_KEY="secret-key"
S3_REGION="us-east-1"
S3_ENDPOINT="https://s3.example.com"
S3_PREFIX="rw-backup"

RETAIN_BACKUPS_DAYS=3
S3_RETENTION_DAYS=10
S3_RETAIN_DAYS=10
```

Оставлять только локально:

```env
UPLOAD_METHOD="local"
RETAIN_BACKUPS_DAYS=3
```

Отправлять и в Telegram, и в S3:

```env
UPLOAD_METHOD="both"
```

## Команды

Показать настройки:

```bash
sudo rw-backup-full config
```

Показать найденные custom bot проекты:

```bash
sudo rw-backup-full list
```

Backup только custom bots:

```bash
sudo rw-backup-full custom-backup
```

Backup Remnawave panel через оригинальный `rw-backup`:

```bash
sudo rw-backup-full panel-backup
```

Backup всего:

```bash
sudo rw-backup-full backup-all
```

Restore custom bot из меню:

```bash
sudo rw-backup-full custom-restore
```

Restore custom bot из конкретного архива:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_project_20260603_120000.tar.gz
```

Restore без подтверждения:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_project_20260603_120000.tar.gz --yes
```

Запуск S3 cleanup вручную:

```bash
sudo rw-backup-full s3-cleanup
```

Запуск local cleanup вручную:

```bash
sudo rw-backup-full local-cleanup
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
7. Показать настройки
8. Открыть оригинальное меню rw-backup
0. Выход
```

## Cron каждые 3 часа

Сервер с панелью и ботом:

```bash
sudo crontab -e
```

```cron
0 */3 * * * /usr/local/bin/rw-backup-full backup-all >> /var/log/rw-backup-full.log 2>&1
```

Сервер только с ботом, без панели:

```cron
0 */3 * * * /usr/local/bin/rw-backup-full custom-backup >> /var/log/rw-backup-full.log 2>&1
```

## systemd timer

Сервер с панелью и ботом:

```bash
sudo cp systemd/rw-backup-full.service /etc/systemd/system/rw-backup-full.service
sudo cp systemd/rw-backup-full.timer /etc/systemd/system/rw-backup-full.timer
sudo systemctl daemon-reload
sudo systemctl enable --now rw-backup-full.timer
```

Сервер только с ботом:

```bash
sudo cp systemd/rw-backup-full-custom.service /etc/systemd/system/rw-backup-full-custom.service
sudo cp systemd/rw-backup-full-custom.timer /etc/systemd/system/rw-backup-full-custom.timer
sudo systemctl daemon-reload
sudo systemctl enable --now rw-backup-full-custom.timer
```

Проверка:

```bash
systemctl list-timers | grep rw-backup-full
journalctl -u rw-backup-full.service -n 100 --no-pager
journalctl -u rw-backup-full-custom.service -n 100 --no-pager
```

## Что будет внутри custom backup архива

Пример:

```text
custom_bot_vpnnew_20260603_120000.tar.gz
custom_bot_oneokbotnew_20260603_120000.tar.gz
```

Состав:

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

## Restore custom bot

Restore делает безопасно:

1. Распаковывает custom backup.
2. Читает `PROFILE.env`.
3. Останавливает текущий compose-проект, если он есть.
4. Старую папку проекта не удаляет, а переименовывает:

```text
/home/<project>.before_restore_YYYYMMDD_HHMMSS
```

5. Восстанавливает папку проекта из `project_dir.tar.gz`.
6. Кладёт `redis_dump.rdb` в `volumes/redis/dump.rdb` до запуска Redis.
7. Поднимает PostgreSQL service.
8. Заливает `postgres_dump.sql.gz` через `psql`.
9. Поднимает Redis service.
10. Поднимает весь compose-проект.

## S3 retention

Скрипт удаляет из S3 только custom backup файлы:

```text
custom_bot_*.tar.gz
```

Срок задаётся:

```env
S3_RETENTION_DAYS=10
```

Оригинальные архивы панели Remnawave не затрагиваются:

```text
remnawave_backup_*.tar.gz
```

## Диагностика структуры сервера

Скрипт:

```bash
sudo ./scripts/collect-bot-structure.sh
```

Он создаёт отчёт:

```text
/root/bot-structure-report-<hostname>-<timestamp>.txt
```

Отчёт маскирует пароли, токены, database URLs и JWT.

## Сценарии серверов

### Сервер с Remnawave panel + bot

Использовать:

```bash
sudo rw-backup-full backup-all
```

Cron:

```cron
0 */3 * * * /usr/local/bin/rw-backup-full backup-all >> /var/log/rw-backup-full.log 2>&1
```

### Сервер только с bot без panel

Использовать:

```bash
sudo rw-backup-full custom-backup
```

Cron:

```cron
0 */3 * * * /usr/local/bin/rw-backup-full custom-backup >> /var/log/rw-backup-full.log 2>&1
```

Отсутствие панели не блокирует custom backup.

### Сервер только с panel без bot

Использовать оригинальный `rw-backup` или:

```bash
sudo rw-backup-full panel-backup
```

## Проверка после установки

```bash
sudo bash -n /opt/rw-backup-restore/rw-backup-full.sh
sudo rw-backup-full config
sudo rw-backup-full list
sudo rw-backup-full custom-backup
```

Проверка последнего архива:

```bash
LATEST="$(ls -1t /opt/rw-backup-restore/backup/custom_bot_*.tar.gz | head -n 1)"
echo "$LATEST"
sudo tar -tzf "$LATEST" | head -100
sudo tar -tzf "$LATEST" | grep 'postgres_dump.sql.gz'
sudo tar -tzf "$LATEST" | grep 'redis_dump.rdb'
sudo tar -tzf "$LATEST" | grep 'project_dir.tar.gz'
```

## Безопасность

- Не публикуй реальный `/opt/rw-backup-restore/config.env` в GitHub.
- Не публикуй `.env` ботов.
- В GitHub должен попадать только `config.env.example`.
- Custom backup содержит секреты, потому что архивирует `.env`; хранить его нужно в закрытом Telegram topic или S3 bucket с ограниченными правами.
