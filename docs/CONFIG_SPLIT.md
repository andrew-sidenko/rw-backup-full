# Разделение конфигов

- `/opt/rw-backup-restore/config.env` — оригинальный config.env для distillium/remnawave-backup-restore.
- `/opt/rw-backup-restore/rw-backup-full.env` — параметры только rw-backup-full.

`rw-backup-full` читает из оригинального config.env только параметры доставки: Telegram/S3 и `UPLOAD_METHOD`, если `FULL_UPLOAD_METHOD=inherit`.

Так оригинальный скрипт можно обновлять отдельно, а параметры custom backup не смешиваются с его настройками.
