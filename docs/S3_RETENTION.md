# S3 retention

`rw-backup-full` cleans only custom bot backups:

```text
custom_bot_*.tar.gz
```

It does not delete original Remnawave panel backups:

```text
remnawave_backup_*.tar.gz
```

Configure retention:

```env
UPLOAD_METHOD="s3"
S3_RETENTION_DAYS=10
S3_RETAIN_DAYS=10
```

Manual cleanup:

```bash
sudo rw-backup-full s3-cleanup
```
