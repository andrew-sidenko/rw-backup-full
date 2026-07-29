# Автономный verify (отдельный сервер)

Каталог [`rw-backup-verify/`](../rw-backup-verify/) — отдельный продукт для
проверки логических бэкапов из S3 без fleet/web/`rw-backup-full`.

См. [rw-backup-verify/README-RU.md](../rw-backup-verify/README-RU.md).

Кратко:

1. `sudo ./install.sh` на сервере с Docker.
2. `rw-backup-verify storage add ... --times 06:30,18:30 --backup-hint "прод 03:00"`.
3. `rw-backup-verify telegram set ...`
4. Timer каждую минуту: due-хранилища → **одна общая очередь** → тесты по одному.
5. В одном bucket/prefix находятся `panel/<source>/` и `custom-bot/<source>/` —
   discover подхватывает все проекты автоматически.
