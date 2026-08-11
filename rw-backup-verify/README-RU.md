# rw-backup-verify — автономная проверка логических бэкапов

Отдельный проект для сервера-песочницы. **Не связан** с веб-парком, SSH на прод
и `fleet.json` из `rw-backup-full`.

## Как работает

1. Глобальное расписание (`verify.interval_hours` или `verify.times`) — одна частота на все хранилища.
2. В это время обходятся **все** S3-записи: глубокий рекурсивный обход prefix.
3. В любой вложенности ищутся архивы `remnawave_backup_*.tar.gz` и `custom_bot_*.tar.gz`.
4. В каждой папке экземпляры группируются по семейству имён (панель / каждый бот-проект).
5. Берётся **только latest** каждого экземпляра; если этот ключ уже в `tested/` — пропуск.
6. Очередь FIFO: все due-экземпляры выполняются **строго по одному**.
7. Подробный отчёт в Telegram.

`backup_hint` у хранилища — только подсказка, как часто бэкапы **создаются** на проде.

## Раскладка в S3 (гибкая)

Поддерживается и канон `rw-backup-full`, и произвольная вложенность:

```
s3://bucket/<prefix>/panel/<source>/remnawave_backup_….tar.gz
s3://bucket/<prefix>/custom-bot/<source>/custom_bot_<proj>_….tar.gz
s3://bucket/<prefix>/clients/acme/panel/remnawave_backup_….tar.gz
s3://bucket/<prefix>/clients/acme/bots/custom_bot_bot1_….tar.gz
s3://bucket/<prefix>/clients/acme/bots/custom_bot_bot2_….tar.gz
```

В одной папке могут лежать архивы с разных серверов/проектов — каждый
`custom_bot_<имя>_…` и `remnawave_backup_…` = отдельный экземпляр.

## Быстрый старт

```bash
sudo ./install.sh

rw-backup-verify storage add \
  --id cf-oneok --endpoint https://... --bucket oneok \
  --access-key ... --secret-key ... --prefix oneok-wal \
  --backup-hint "прод: ежедневно 03:00"

rw-backup-verify schedule set --interval-hours 12
# или: rw-backup-verify schedule set --times 06:30,18:30

rw-backup-verify telegram set --token <bot> --chat-id <id>
# алиасы: tel / tg
rw-backup-verify discover cf-oneok          # что будет тестироваться
rw-backup-verify run --storage cf-oneok     # сейчас
```

## Проверки (включаются/выключаются раздельно для panel и bot)

В `/etc/rw-backup-verify/config.json` → `checks.panel` / `checks.bot`:

| Ключ | Смысл |
|---|---|
| `user_rows` | **bot:** строго `public.users`; **panel:** эвристика. Не пуста и ≥ предыдущей проверки (baseline) |
| `event_freshness` | **bot:** max(timestamp) из `payment_webhook_events`; **panel:** users/nodes. Окно [prev_backup − skew … curr_backup + skew] |
| `stack` | поднять compose в `--internal` + без падений `stability_seconds` |
| `isolation` | сеть `Internal=true` + нет внешнего TCP egress (DNS на internal часто резолвится — это не leak). **Preflight** до download: если хост не изолирует — все тесты стоп. В stack — до stability/ports. |
| `backend_ports` | TCP/HTTP к портам сервисов, ответ не пустой |

**Bot:** если нет `users` / `payment_webhook_events` или у webhook нет timestamp-полей —
в `runs/<id>/report.txt` печатаются колонки этих таблиц (чтобы увидеть реальную схему).

`timezone_skew_hours` (по умолчанию 14) — допуск на разные TZ серверов.

Старые имена `db_rows` / `user_rows_monotonic` / `stack_up` / `stability` ещё читаются как алиасы.

Отключить пример:
```json
"checks": { "bot": { "backend_ports": false, "stack": false } }
```

## Telegram-отчёт

- хранилище, полный S3-путь, id экземпляра
- список проверок с ✅/❌/⚠️/⚪ и значениями prev→curr
- блок «Расхождения» при fail
- при ошибке — второе сообщение с логами контейнеров

## Восстановление при тесте

| Вид | Основа | Шаги |
|---|---|---|
| **panel** | dump-path verify-stack | `dump_*.sql.gz` + `remnawave_dir_*.tar.gz` → PG + isolate compose |
| **bot** | `custom-restore` | PROFILE + postgres dump + redis RDB → isolate |

Изоляция: сеть `--internal`, без published ports / docker.sock / external nets.

## Команды

```
rw-backup-verify storage list|add|remove|show
rw-backup-verify schedule show|set
rw-backup-verify telegram|tel|tg set|show
rw-backup-verify discover <id> [--all]
rw-backup-verify run [--due] [--storage ID]
rw-backup-verify queue status|clear|work
rw-backup-verify tick
```

Конфиг: `/etc/rw-backup-verify/config.json`  
Состояние tested: `/var/lib/rw-backup-verify/tested/<storage>.json`

Тесты (без Docker/S3):

```bash
bash test/unit_config_queue.sh
bash test/unit_logic_full.sh
```

Ручной `run` пишет шаги в stderr и в `work_dir/logs/run_*.log`
(по умолчанию `/var/lib/rw-backup-verify/logs/`). Отчёты прогонов —
`work_dir/runs/<id>/`. Архивы кэшируются в `work_dir/cache/archives/`
(повторный прогон не качает S3). В `runs/<id>/` также лежат дампы compose
из бэкапа и isolated-версии (`compose.from-backup*`, `compose.isolated*`,
`compose.ps.txt`, `compose.logs.txt`) — для ручной корректировки инфры.

Panel (Remnawave): compose обычно схож, отличается в основном расположением БД
(URL переписывается на sandbox `remnawave-db`). Bot: схемы разные (swarm/
`BACKEND_IMAGE`, infra-compose и т.д.) — смотрите дамп; без image tags в архиве
stack будет skip.

Освободить диск:

```bash
rw-backup-verify runs prune --keep 0   # архивы остаются в cache
rw-backup-verify cache list
# при необходимости: docker system prune -af
```

После каждого job тяжёлые `extract/`/sql из `runs/<id>/` удаляются автоматически
(остаются report + compose.*); перед большим restore — gate ≥max(1.5 GiB, 4×sql.gz).

**Кэш архивов** (`work_dir/cache/archives/`): при **каждом** `run` и `tick`
(ручной = по расписанию) старые скачанные удаляются; остаётся **только последний
на экземпляр** — для повторного ручного прогона без S3.

```bash
rw-backup-verify run --storage tw-oneok
rw-backup-verify cache list
rw-backup-verify cache prune [--storage tw-oneok]   # вручную то же правило
```
