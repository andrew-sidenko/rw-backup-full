# External S3 storages (multi-backend)

`rw-backup-full` (v5) duplicates panel backups, custom-bot backups, WAL segments
and base backups to **any number of independent S3 storages** — one `.env` file
per storage under `s3.d/`. Each backend has its own credentials, endpoint,
categories and retention, so you can diversify across providers (e.g. one bucket
on provider A, another on provider B) and lose no backups if one provider fails.

## Configuring backends

One file per backend: `s3.d/<name>.env`. Manage them via the CLI (no hand-editing
needed):

```bash
rw-backup-full s3-add        # add a backend interactively
rw-backup-full s3-backends   # list configured backends
rw-backup-full s3-test       # connectivity / read-write probe
```

Each `s3.d/<name>.env` (see `config/s3.d/example.env.example`):

```env
B_ENABLED="true"
B_ENDPOINT="https://s3.example.com"   # empty for AWS S3
B_BUCKET="my-backups"
B_ACCESS_KEY=""
B_SECRET_KEY=""
B_REGION="us-east-1"
B_PREFIX="rw-backup-full"

# Which categories this backend receives:
B_UPLOAD_PANEL="true"
B_UPLOAD_CUSTOM="true"
B_UPLOAD_WAL="true"

# Retention (per backend):
B_RETENTION_PANEL_DAYS="14"
B_RETENTION_CUSTOM_DAYS="14"
B_RETENTION_MIN_KEEP="3"     # never delete fewer than N newest logical archives
B_BASEBACKUP_KEEP="7"        # base backups kept; WAL is pruned to the oldest kept base
```

## Behaviour

- **Fan-out:** every enabled backend whose category flag matches receives the
  archive. One backend failing does not abort the others (the job succeeds if at
  least one backend accepted the copy; see the note on strict mode below).
- **Journals:** each backup/verify uploads a `.txt` journal next to the archive
  with the same stem name (e.g. `custom_bot_x_2026-07-24_....txt`). The journal is
  deleted together with its archive during retention.
- **Object layout:** `<B_PREFIX>/<category>/<source-id>/<file>` for logical
  archives and `<B_PREFIX>/wal/<source-id>/<instance>/...` for WAL. `source-id` is
  `RW_SOURCE_ID` (defaults to the short hostname).
- **Providers:** any S3-compatible storage (AWS, MinIO, Backblaze B2, Wasabi,
  Cloudflare R2, …). Selection is purely via `B_ENDPOINT`/credentials — no
  provider-specific code.

## Legacy single-backend fallback

If `s3.d/` is empty but the older `FULL_EXTERNAL_S3_*` variables are set in
`rw-backup-full.env`, a synthetic backend named `legacy` is used:

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

`install.sh` can migrate these into `s3.d/default.env`. Prefer `s3.d/*.env` for
new setups — the legacy path does not support per-backend categories, `MIN_KEEP`,
or journal cleanup.

## Notifications

Each successful upload can notify Telegram (noisy with several backends):

```env
FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD="false"
```
