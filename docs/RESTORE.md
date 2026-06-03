# Restore custom bot

## Restore from local archive

```bash
sudo rw-backup-full custom-restore
```

Or direct path:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_project_YYYYMMDD_HHMMSS.tar.gz
```

Without prompt:

```bash
sudo rw-backup-full custom-restore-file /opt/rw-backup-restore/backup/custom_bot_project_YYYYMMDD_HHMMSS.tar.gz --yes
```

## What happens

1. Existing compose project is stopped.
2. Existing project directory is renamed to `.before_restore_YYYYMMDD_HHMMSS`.
3. Project directory is restored from `project_dir.tar.gz`.
4. Redis `dump.rdb` is copied before Redis starts.
5. PostgreSQL service is started.
6. `postgres_dump.sql.gz` is restored using `psql`.
7. Redis service is started.
8. Full compose project is started.

## Verify

```bash
cd /home/<project>
docker compose ps -a
docker logs vpn_bot --tail 100
```
