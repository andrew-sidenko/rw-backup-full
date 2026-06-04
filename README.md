# rw-backup-full v3

`rw-backup-full` is an extension wrapper for `distillium/remnawave-backup-restore`.
It adds automatic backups for custom Docker bots in `/home`, independent external S3 duplication, and Telegram notifications for every archive saved to the external S3.

## Main idea

There are two separate configurations:

```text
/opt/rw-backup-restore/config.env
```

Original `rw-backup` config. It remains untouched and is used by the original Remnawave panel backup.

```text
/opt/rw-backup-restore/rw-backup-full.env
```

`rw-backup-full` config. It stores only full-specific settings:

- timer mode and interval;
- local custom backup retention;
- external S3 retention;
- independent external S3 credentials;
- Telegram notifications for external S3 uploads;
- whether panel/custom archives are duplicated to external S3.

## Supported server types

### Panel only

The server has a local Remnawave panel and original `rw-backup` installed.

Use:

```bash
sudo rw-backup-full panel-backup
```

or timer mode:

```env
FULL_TIMER_MODE="panel-backup"
```

The script runs original `rw-backup backup`, finds the newest `remnawave_backup_*.tar.gz`, and duplicates it to `FULL external S3`.

### Custom bot only

The server has a custom bot project in `/home/...` with Docker Compose, PostgreSQL, and Redis.

Use:

```bash
sudo rw-backup-full custom-backup
```

or timer mode:

```env
FULL_TIMER_MODE="custom-backup"
```

### Panel + custom bot

Use:

```bash
sudo rw-backup-full backup-all
```

or timer mode:

```env
FULL_TIMER_MODE="backup-all"
```

## Custom bot detection

The script detects Docker Compose projects in `/home` using Docker labels:

- `com.docker.compose.project`
- `com.docker.compose.project.working_dir`
- `com.docker.compose.service`

It then looks for PostgreSQL and Redis containers inside the same compose project.

This means the backup does not depend on folder names such as `/home/VPNNEW` or `/home/OneOkBotNew`.

## Custom bot backup contents

For each detected bot:

- `postgres_dump.sql.gz` — PostgreSQL dump via `pg_dumpall`;
- `redis_dump.rdb` — Redis dump via `redis-cli SAVE`;
- `project_dir.tar.gz` — project directory archive;
- Docker/Compose metadata;
- optional Caddy/subscription-page configs.

Live database folders are excluded from the project archive:

- `volumes/pgdata`
- `volumes/redis`

## External S3 duplication

`rw-backup-full` can duplicate both panel and custom bot backups to an S3 bucket independent from the original `rw-backup` storage.

External S3 keys look like this:

```text
rw-backup-full/panel/<hostname>/remnawave_backup_YYYY-MM-DD_HH_MM_SS.tar.gz
rw-backup-full/custom-bot/<hostname>/custom_bot_<project>_YYYYMMDD_HHMMSS.tar.gz
```

For every successfully uploaded file, a separate Telegram message is sent if enabled.

## Installation

```bash
git clone https://github.com/YOUR-USER/rw-backup-full.git
cd rw-backup-full
sudo ./install.sh
```

Check:

```bash
sudo rw-backup-full config
sudo rw-backup-full list
```

## Configure external S3

Interactive:

```bash
sudo rw-backup-full configure-s3
```

Manual config:

```bash
sudo nano /opt/rw-backup-restore/rw-backup-full.env
```

Example:

```env
FULL_EXTERNAL_S3_BUCKET="my-backup-bucket"
FULL_EXTERNAL_S3_ACCESS_KEY="access-key"
FULL_EXTERNAL_S3_SECRET_KEY="secret-key"
FULL_EXTERNAL_S3_REGION="us-east-1"
FULL_EXTERNAL_S3_ENDPOINT="https://s3.example.com"
FULL_EXTERNAL_S3_PREFIX="rw-backup-full"
FULL_EXTERNAL_S3_RETENTION_DAYS="10"
```

## Configure Telegram notifications

Interactive:

```bash
sudo rw-backup-full configure-telegram
```

If this is enabled, empty FULL_TG values are imported from original `/opt/rw-backup-restore/config.env`:

```env
FULL_TELEGRAM_IMPORT_FROM_ORIGINAL="true"
```

Or set independent Telegram credentials:

```env
FULL_TELEGRAM_IMPORT_FROM_ORIGINAL="false"
FULL_TG_BOT_TOKEN="123456:xxxx"
FULL_TG_CHAT_ID="-1001234567890"
FULL_TG_MESSAGE_THREAD_ID="123"
```

## Configure retention

```bash
sudo rw-backup-full configure-retention
```

Manual:

```env
FULL_LOCAL_RETENTION_DAYS="3"
FULL_EXTERNAL_S3_RETENTION_DAYS="10"
```

S3 retention deletes only archives under the FULL external S3 prefix that match:

- `custom_bot_*.tar.gz`
- `remnawave_backup_*.tar.gz`

It does not touch unrelated files.

## Configure timer

```bash
sudo rw-backup-full install-timer
```

The menu lets you choose:

- `backup-all`
- `panel-backup`
- `custom-backup`

and interval in hours.

Manual timer status:

```bash
systemctl list-timers | grep rw-backup-full
sudo journalctl -u rw-backup-full.service -n 100 --no-pager
```

## Menu

```bash
sudo rw-backup-full
```

Menu includes:

1. Backup panel via original rw-backup + duplicate to FULL external S3
2. Backup custom bot from `/home` + duplicate to FULL external S3
3. Backup ALL
4. Restore custom bot
5. Show detected custom bot projects
6. Configure local/S3 retention
7. Configure FULL external S3
8. Configure Telegram notifications
9. Install/update systemd timer
10. Show configuration
11. Install original rw-backup
12. Run external S3 retention cleanup now

## Restore custom bot

```bash
sudo rw-backup-full custom-restore
```

Or from a specific local archive:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_project_YYYYMMDD_HHMMSS.tar.gz
```

The old project directory is not deleted; it is moved to:

```text
/home/<project>.before_restore_YYYYMMDD_HHMMSS
```

## Requirements

- Docker
- Docker Compose v2
- tar/gzip
- curl for Telegram notifications
- awscli for external S3 upload

Install awscli:

```bash
sudo apt-get update
sudo apt-get install -y awscli curl
```
