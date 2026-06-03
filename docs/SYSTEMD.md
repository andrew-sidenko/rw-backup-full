# Systemd timer

Установка/обновление timer:

```bash
sudo rw-backup-full install-timer
```

Настройка режима и интервала:

```bash
sudo rw-backup-full configure
```

Проверка:

```bash
systemctl list-timers | grep rw-backup
sudo systemctl status rw-backup-full.timer
sudo journalctl -u rw-backup-full.service -n 100 --no-pager
```

Удаление:

```bash
sudo rw-backup-full remove-timer
```
