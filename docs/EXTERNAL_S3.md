# External S3 duplication

`rw-backup-full` can duplicate panel and custom bot archives to a second S3 storage independent from original rw-backup.

Relevant variables:

```env
FULL_PANEL_EXTERNAL_S3_ENABLED="true"
FULL_CUSTOM_EXTERNAL_S3_ENABLED="true"
FULL_EXTERNAL_S3_BUCKET=""
FULL_EXTERNAL_S3_ACCESS_KEY=""
FULL_EXTERNAL_S3_SECRET_KEY=""
FULL_EXTERNAL_S3_REGION="us-east-1"
FULL_EXTERNAL_S3_ENDPOINT=""
FULL_EXTERNAL_S3_PREFIX="rw-backup-full"
FULL_EXTERNAL_S3_RETENTION_DAYS="10"
```

Each successful upload can trigger Telegram notification:

```env
FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD="true"
```
