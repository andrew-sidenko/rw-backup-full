# rw-backup-full v5.5

Full-featured backup system for Remnawave panels and custom Telegram bots: logical archives (format-compatible with [distillium/remnawave-backup-restore](https://github.com/distillium/remnawave-backup-restore)), continuous PostgreSQL WAL archiving with PITR, multiple external S3 backends with per-backend retention, sandbox restore verification, fleet web console, and Grafana metrics.

**Russian docs (authoritative):** [README-RU.md](README-RU.md) · [docs/FLEET-VERIFY-RU.md](docs/FLEET-VERIFY-RU.md) · [CHANGELOG.md](CHANGELOG.md)

## Roles and components

Each host declares what it does via `FULL_COMPONENTS` in `rw-backup-full.env`:

| Component | Role |
|---|---|
| `panel-backup` / `custom-backup` | Logical backups of panel / `/home` bots |
| `wal` | Continuous WAL + base backups + PITR |
| `config-track` | Whole-directory tracker (configs/code) |
| `metrics` | Prometheus textfile exporter |
| `sandbox` | Restore verification (dedicated host) |
| `web` | Fleet management UI (sandbox) |

`install.sh` (prod) vs `install.sh --sandbox` picks a sensible default list. The interactive menu **only shows sections for enabled components** — on a sandbox (`metrics sandbox web`) backup/WAL items are hidden.

```bash
sudo ./install.sh              # production
sudo ./install.sh --sandbox    # verification + web console
rw-backup-full apply-components
```

## Sandbox restore checks

On the sandbox host:

```bash
rw-backup-full sync-creds                          # refresh S3/TG from fleet servers
rw-backup-full verify-fleet [--server ID] [--depth deep]
rw-backup-full verify-stack panel --source <ID> [--db-mode dump|base|pitr] [--keep]
rw-backup-full status-digest                       # same as 09:00/21:00 summary
```

Credentials are never hand-edited on the sandbox: the web service pulls each server’s `fleet-manifest` over SSH (S3 backends + Telegram). `sync-creds` materializes them under `fleet-creds/<server-id>/`. Per-server events go to that server’s Telegram; fleet-wide errors are broadcast to all servers’ Telegram chats. Brief digests run at **09:00 and 21:00** and include occupied/free disk plus the space each backup occupies in every S3 storage.

By default heavy operations run at night (logical dump 03:00, panel basebackup 04:30, bot basebackup 05:00) while WAL ships continuously; a per-server random offset (`FULL_SCHEDULE_JITTER_SEC`) avoids hammering S3 from many servers at once. Set `FULL_S3_STRICT="true"` to fail a backup (with an alert) when the copy did not reach every configured S3 storage.

Each backup/check uploads a **`.txt` journal** next to the archive (same stem name) in S3; retention deletes the journal with the data.

## Web console

Runs on the sandbox (`http://127.0.0.1:8787`, token in `/etc/rw-backup-web.env`):

- per-server status: components, backup freshness, WAL instances (spool, basebackup + WAL freshness), error count
- storage sizes per server: locally occupied + free disk, and size/objects per S3 backend (with unreachable flag)
- latest verify verdict per server, plus a fleet summary card (online count, total S3 usage, total errors)
- sandbox summary: last fleet-verify pass/fail, credential sync age
- verify history (fleet + stack runs) and per-server history
- APIs: `/api/fleet/manifest`, `/api/fleet/overview`, `/api/verify/history`, `/api/servers/{id}/verify`

## Quick start (production)

```bash
sudo ./install.sh
rw-backup-full s3-add
rw-backup-full install-timer
rw-backup-full wal-enable <instance>    # restarts DB container — confirm when asked
```

Grafana dashboard: `/opt/rw-backup-restore/grafana/dashboard.json`

## License

See [LICENSE](LICENSE).
