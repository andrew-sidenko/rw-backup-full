# Configuration split

`rw-backup-full` v3 intentionally keeps two different config files.

## Original config

```text
/opt/rw-backup-restore/config.env
```

Used by original `distillium/remnawave-backup-restore`.

Do not store `FULL_*` variables here.

## Full config

```text
/opt/rw-backup-restore/rw-backup-full.env
```

Stores only `rw-backup-full` settings:

- external S3 duplication;
- Telegram notifications;
- local/S3 retention;
- timer mode and interval;
- whether original rw-backup should be auto-installed.

External S3 in this file is independent from original rw-backup S3 settings.
