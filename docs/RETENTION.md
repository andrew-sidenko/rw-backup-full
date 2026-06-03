# Retention

Локальная глубина хранения custom backup:

```env
FULL_LOCAL_RETENTION_DAYS="3"
```

S3 глубина хранения custom backup:

```env
FULL_S3_RETENTION_DAYS="10"
```

Команды:

```bash
sudo rw-backup-full local-cleanup
sudo rw-backup-full s3-cleanup
```

S3 cleanup удаляет только `custom_bot_*.tar.gz`, чтобы не затронуть оригинальные архивы `remnawave_backup_*.tar.gz`.
