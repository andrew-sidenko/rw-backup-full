# rw-backup-verify — автономная проверка логических бэкапов

Отдельный проект для сервера-песочницы. **Не связан** с веб-парком, SSH на прод
и `fleet.json` из `rw-backup-full`. Ставится сам по себе: указываете S3-хранилища,
расписание проверок и Telegram — дальше очередь сама берёт последние логические
архивы, поднимает стек в изоляции и шлёт подробный отчёт.

## Идея

| Что | Как |
|---|---|
| Хранилища | Отдельные записи (endpoint/bucket/keys/prefix) |
| Проекты | Авто-обнаружение под `<prefix>/panel/<source>/` и `<prefix>/custom-bot/<source>/` |
| Что тестируем | **Последний** логический архив (`remnawave_backup_*.tar.gz` / `custom_bot_*.tar.gz`) |
| Расписание | У каждого хранилища свои `times` или `interval_hours` |
| Очередь | Все due-задания выполняются **строго по одному**, даже если тайминги совпали |
| Подсказка `backup_hint` | Только описание, как часто бэкапы **создаются** на проде — на тесты не влияет |
| Telegram | Глобальный + опционально per-storage |

Интервалы создания бэкапов на проде и расписание тестов независимы: тест всегда
берёт то, что уже лежит в S3 как «latest».

## Раскладка в S3 (как у rw-backup-full)

```
s3://<bucket>/<prefix>/panel/<source>/remnawave_backup_<TS>.tar.gz
s3://<bucket>/<prefix>/custom-bot/<source>/custom_bot_<project>_<TS>.tar.gz
```

Внутри panel-архива: `dump_*.sql.gz` + `remnawave_dir_*.tar.gz`.  
Внутри bot-архива: `postgres_dump.sql.gz` + `project_dir.tar.gz` + `PROFILE.env`.

## Быстрый старт

```bash
# на чистом сервере с Docker + awscli + jq
sudo ./install.sh
sudo rw-backup-verify storage add \
  --id cf-oneok \
  --endpoint https://... \
  --bucket oneok \
  --access-key ... --secret-key ... \
  --prefix oneok-wal \
  --times 06:30,18:30 \
  --backup-hint "прод: ежедневно 03:00"

sudo rw-backup-verify telegram set --token <bot> --chat-id <id>
sudo systemctl enable --now rw-backup-verify.timer

# вручную сейчас (всё хранилище, последовательно по проектам):
sudo rw-backup-verify run --storage cf-oneok
sudo rw-backup-verify discover cf-oneok
```

Конфиг: `/etc/rw-backup-verify/config.json`  
Рабочий каталог: `/var/lib/rw-backup-verify`  
Логи: `journalctl -u rw-backup-verify.service`

## Команды

```
rw-backup-verify storage list|add|remove|show
rw-backup-verify telegram set|show
rw-backup-verify discover <storage-id>
rw-backup-verify run [--storage ID] [--due]     # --due = только по расписанию
rw-backup-verify run-one <storage> <category> <source> [archive-hint]
rw-backup-verify queue status|clear
```

## Изоляция

Как в `verify-stack`: сеть `--internal`, без published ports, без `docker.sock`,
без external networks/volumes. Поднимается настоящий стек с секретами из архива —
наружу он не выходит.

## Связь с rw-backup-full

Форматы архивов и префиксы S3 совместимы. Этот проект **не** вызывает
`rw-backup-full` и не читает его конфиг. WAL/PITR в v1 не входит — только
логические бэкапы panel/custom-bot.
