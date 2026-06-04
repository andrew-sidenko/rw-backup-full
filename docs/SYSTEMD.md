# systemd timer

Install or update timer:

```bash
sudo rw-backup-full install-timer
```

Timer settings are stored in:

```text
/opt/rw-backup-restore/rw-backup-full.env
```

Variables:

```env
FULL_TIMER_MODE="backup-all"
FULL_TIMER_INTERVAL_HOURS="3"
```

Modes:

- `backup-all`
- `panel-backup`
- `custom-backup`
