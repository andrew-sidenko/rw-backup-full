# rw-backup-full v4

Надстройка над [distillium/remnawave-backup-restore](https://github.com/distillium/remnawave-backup-restore) для резервного копирования панелей Remnawave и кастомных Telegram-ботов, с непрерывной WAL-архивацией PostgreSQL, восстановлением на точку во времени (PITR) и автоматической проверкой бэкапов в песочнице.

## Что нового в v4

| Возможность | v3 | v4 |
|---|---|---|
| Логический бэкап панели (через оригинальный rw-backup) | ✅ | ✅ |
| Бэкап кастомных ботов из `/home` (pg_dumpall + Redis + каталог) | ✅ | ✅ |
| Дублирование во внешний S3, age-шифрование, Telegram | ✅ | ✅ |
| **Непрерывная WAL-архивация PostgreSQL (локально + S3)** | — | ✅ |
| **Полные базовые бэкапы `pg_basebackup` по расписанию** | — | ✅ |
| **Восстановление из полного бэкапа и/или WAL (PITR)** | — | ✅ |
| **Автопроверка бэкапов в песочнице на отдельном сервере** | — | ✅ |
| **Метрики в VictoriaMetrics (textfile collector)** | — | ✅ |

Ключевая идея v4: логические дампы (`pg_dumpall`) каждые N часов — это потеря до N часов данных при аварии. WAL-архивация снижает потерю до `INST_ARCHIVE_TIMEOUT` секунд (по умолчанию 5 минут) и при этом **разгружает серверы**: тяжёлый `pg_dumpall` можно гонять реже, а непрерывная архивация почти ничего не стоит — это копирование готовых 16-МБ файлов.

## Архитектура WAL-слоя

```
контейнер postgres                 хост                              S3
┌─────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────┐
│ archive_command ────┼──▶│ /var/lib/rw-wal/<inst>/  │   │ <prefix>/wal/<host>/│
│  (атомарный cp,     │   │   spool/incoming/        │   │   <inst>/           │
│   БЕЗ сети)         │   │        │ wal-ship.sh     │   │     basebackup/     │
│                     │   │        ▼ (таймер, 1 мин) │──▶│     wal/            │
│ pg_basebackup ──────┼──▶│   archive/  (сжатие,     │   │                     │
│  (таймер, 24 ч)     │   │   basebackup/  шифрование│   │                     │
└─────────────────────┘   └──────────────────────────┘   └─────────────────────┘
```

Принципиальные решения:

- **`archive_command` не ходит в сеть.** Он только атомарно копирует сегмент в спул на хосте. Если бы он писал в S3 напрямую, любой сбой S3 привёл бы к росту `pg_wal` и остановке БД с заполненным диском. Отправкой занимается отдельный шиппер на хосте — с ретраями, не блокируя PostgreSQL.
- **Образы postgres не модифицируются.** В контейнер монтируется только каталог спула (`docker-compose.override.yml`), параметры ставятся через `ALTER SYSTEM`. Обновления панели ничего не ломают.
- **WAL никогда не удаляется по возрасту.** Retention удаляет сегменты только старше стартового сегмента самого старого хранимого базового бэкапа — отдельно для локального хранилища и для S3. Любой хранимый базовый бэкап всегда восстановим.
- **Локальная копия + S3.** Сегмент удаляется из спула только после попадания в локальный архив; из локального архива — только по границе retention. Отказ S3 не приводит к потере WAL.

## Установка

### Прод-сервер (панель и/или боты)

```bash
git clone https://github.com/andrew-sidenko/rw-backup-full.git
cd rw-backup-full
sudo ./install.sh
```

Зависимости: `docker` + `docker compose`, `flock` (util-linux). Рекомендуется: `awscli` (S3), `zstd` (сжатие быстрее и компактнее gzip), `age` (если нужно шифрование).

```bash
apt update && apt install -y awscli zstd age
```

Установка идемпотентна: повторный запуск обновляет скрипты и systemd-юниты, не трогая ваши конфиги (`config.env`, `rw-backup-full.env`, `instances.d/`).

### Сервер-песочница (проверка бэкапов)

Отдельный недорогой сервер. Нужны только docker и awscli; доступа к проду не требуется — проверяется содержимое S3.

```bash
git clone https://github.com/andrew-sidenko/rw-backup-full.git
cd rw-backup-full
sudo ./install.sh --sandbox
```

## Настройка (прод)

### 1. Базовая настройка v3-части

```bash
sudo rw-backup-full configure-s3        # внешний S3 (бакет, ключи, endpoint)
sudo rw-backup-full configure-telegram  # уведомления
sudo rw-backup-full install-timer       # периодичность логических бэкапов
```

Все настройки живут в `/opt/rw-backup-restore/rw-backup-full.env`. Оригинальный `config.env` distillium-скрипта не изменяется никогда.

### 2. Описание инстансов WAL

Инстанс — одна PostgreSQL-база (панель или бот). На каждый — файл в `/opt/rw-backup-restore/instances.d/<имя>.env`:

```bash
cp /opt/rw-backup-restore/config-examples/instances.d/panel.env.example \
   /opt/rw-backup-restore/instances.d/panel.env
nano /opt/rw-backup-restore/instances.d/panel.env
```

Минимум, который нужно проверить:

```bash
INST_CONTAINER="remnawave-db"                      # имя контейнера БД
INST_COMPOSE_FILE="/opt/remnawave/docker-compose.yml"
INST_COMPOSE_SERVICE="remnawave-db"                # имя сервиса в compose
INST_PGUSER="postgres"                             # как DB_USER в config.env
```

**Периодичность задаёте вы:**

```bash
INST_BASEBACKUP_INTERVAL_HOURS="24"   # полный базовый бэкап
INST_WAL_SHIP_INTERVAL_MIN="1"        # отправка WAL из спула
INST_ARCHIVE_TIMEOUT="300"            # макс. возраст незакрытого сегмента, сек (= ваш RPO)
```

**Хранение** (в штуках базовых бэкапов; WAL подчищается автоматически):

```bash
INST_LOCAL_BASEBACKUP_KEEP="2"
INST_S3_BASEBACKUP_KEEP="7"
```

Для ботов — второй пример: `custom-bot.env.example` (контейнер вида `vpn_postgres`, compose в `/home/<проект>/`).

### 3. Включение архивации

⚠️ **Требуется рестарт контейнера БД** (параметр `archive_mode` в PostgreSQL применяется только при старте). Простой — секунды, но выбирайте время.

```bash
sudo rw-backup-full wal-enable panel
```

Скрипт: подготовит спул → создаст `docker-compose.override.yml` с монтированием → выставит `archive_mode/archive_command/archive_timeout` через `ALTER SYSTEM` → пересоздаст контейнер → **сквозным тестом** переключит WAL-сегмент и убедится, что он дошёл до спула → включит таймеры с вашими интервалами.

Затем первый базовый бэкап:

```bash
sudo rw-backup-full basebackup panel
```

С этого момента точка восстановления непрерывно двигается вперёд.

### 4. Проверка состояния

```bash
sudo rw-backup-full wal-status
```

Показывает по каждому инстансу: `archive_mode`, счётчик ошибок архиватора (`pg_stat_archiver.failed_count` — должен быть стабилен), размер спула (рост = шиппер не справляется), количество базовых бэкапов, активность таймеров.

Логи: `journalctl -u rw-wal-ship@panel.service -f`, `journalctl -u rw-basebackup@panel.service`.

## Восстановление

Все сценарии — через `pitr-restore.sh`. **По умолчанию восстановление безопасно**: рабочая БД не трогается, копия поднимается во временном контейнере на свободном порту.

### Посмотреть, что есть

```bash
ls /var/lib/rw-wal/panel/basebackup/*.meta
aws s3 ls s3://BUCKET/rw-backup-full/wal/HOST/panel/basebackup/
```

### Восстановление на последнюю точку (весь доступный WAL)

```bash
sudo rw-backup-full pitr-restore panel --target latest
# => БД доступна на 127.0.0.1:<порт>, рабочая панель не затронута
```

### Восстановление на момент времени (PITR)

Например, за 5 минут до ошибочного `DELETE`:

```bash
sudo rw-backup-full pitr-restore panel --target-time "2026-07-22 09:30:00+00"
```

Дальше два пути: выгрузить нужные данные `pg_dump`-ом из временного контейнера и залить в прод, либо заменить прод целиком (ниже).

### Восстановление из S3 (сервер утрачен)

На новом сервере: установить проект, заполнить `FULL_EXTERNAL_S3_*`, скопировать `instances.d/*.env`, затем:

```bash
sudo rw-backup-full pitr-restore panel --from s3 --target latest
```

### Только полный бэкап, без WAL

```bash
sudo rw-backup-full pitr-restore panel --target immediate --backup base_2026-07-22_03_00_01_0000000100000000000000A7
```

### Замена рабочей БД (деструктивно)

```bash
sudo rw-backup-full pitr-restore panel --target latest --in-place
```

Остановит сервис БД, отложит старый PGDATA в `*.before_restore_<дата>` (не удаляет!), развернёт восстановленные данные и подскажет команды запуска. После успешного старта заново включите архивацию: `wal-enable` (восстановленная БД стартует с чистым `archive_mode`).

### Зашифрованные бэкапы

```bash
sudo rw-backup-full pitr-restore panel --target latest --age-identity /root/age-restore.key
```

Приватный ключ age на прод-сервере не хранится — держите его в менеджере секретов и на песочнице.

### Логические бэкапы (v3)

Работают как раньше: панель — `rw-backup restore` (оригинальный distillium), боты — `rw-backup-full custom-restore`. WAL-слой их дополняет, а не заменяет: логический дамп — это переносимый и понятный формат, PITR — это минимальная потеря данных.

## Песочница: автоматическая проверка бэкапов

Бэкап, который ни разу не восстанавливали, — это лотерея. Песочница ежедневно проверяет **реальную восстановимость** того, что лежит в S3:

1. **PITR-цепочки** каждого инстанса: скачивает свежий базовый бэкап (с проверкой SHA256), проигрывает весь WAL, поднимает временный postgres и выполняет:
   - `SELECT 1` — БД жива и вышла из recovery;
   - `count(*)` по ключевым таблицам из `INST_VERIFY_TABLES` (пустая таблица = провал);
   - полный `pg_dumpall` восстановленной базы — ловит битые страницы, невидимые через count;
   - возраст базового бэкапа (свежесть цепочки).
2. **Логические архивы**: свежие `remnawave_backup_*.tar.gz` и `custom_bot_*.tar.gz` из S3 распаковываются, дамп заливается в чистый временный postgres, проверяется наличие пользовательских таблиц и строк.

Результат: Telegram-отчёт (при провале — всегда) + метрики. Временные контейнеры и данные удаляются автоматически.

### Настройка песочницы

```bash
sudo ./install.sh --sandbox
nano /opt/rw-backup-restore/rw-backup-full.env
#   FULL_EXTERNAL_S3_* — доступ на ЧТЕНИЕ того же бакета
#   FULL_TG_*          — куда слать отчёты
#   SANDBOX_AGE_IDENTITY — приватный ключ age (если бэкапы шифруются)
scp prod:/opt/rw-backup-restore/instances.d/*.env /opt/rw-backup-restore/instances.d/
sudo rw-backup-full verify        # пробный прогон вручную
```

Расписание — `rw-sandbox-verify.timer` (ежедневно ~05:30, меняется через `systemctl edit rw-sandbox-verify.timer`).

Ручные варианты:

```bash
sudo rw-backup-full verify --instance panel   # один инстанс
sudo rw-backup-full verify --skip-logical     # только PITR-цепочки
sudo rw-backup-full verify --local            # на проде, из локального архива
```

Рекомендация по правам S3: прод — ключ с записью, песочница — отдельный ключ **только на чтение**. Тогда компрометация песочницы не угрожает бэкапам, а компрометация прода не отменяет уже сделанных проверок.

## Мониторинг

Все компоненты пишут метрики в textfile collector (`/var/lib/node_exporter/textfile_collector/`), откуда их забирает vmagent/node_exporter. Ключевые:

| Метрика | Алерт |
|---|---|
| `rw_wal_spool_files` | > 200 — шиппер не справляется / S3 недоступен |
| `rw_wal_ship_failures` | > 0 |
| `rw_basebackup_last_success_timestamp_seconds` | старше 2× интервала |
| `rw_basebackup_last_result` | == 0 |
| `rw_sandbox_pitr_last_ok` | == 0 — **бэкап не восстанавливается** |
| `rw_sandbox_last_run_timestamp_seconds` | старше 2 суток — песочница молчит |

Дополнительно на стороне PostgreSQL стоит алертить `pg_stat_archiver.failed_count` (рост = archive_command падает, `pg_wal` копится).

## Команды (справочник)

```
rw-backup-full                     интерактивное меню (пп. 13–15 — WAL/песочница)
rw-backup-full wal-enable <inst>     включить архивацию (рестарт БД!)
rw-backup-full wal-disable <inst>    выключить и убрать override/таймеры
rw-backup-full basebackup <inst>     полный базовый бэкап сейчас [--no-s3]
rw-backup-full wal-ship <inst>       прогнать шиппер сейчас
rw-backup-full wal-retention <inst>  очистка сейчас [--dry-run]
rw-backup-full wal-timers <inst>     переустановить таймеры (после смены интервалов)
rw-backup-full wal-status            состояние всех инстансов
rw-backup-full pitr-restore <inst>   восстановление (--help — все опции)
rw-backup-full verify                проверка бэкапов в песочнице
```

После изменения интервалов в `instances.d/<inst>.env` выполните `rw-backup-full wal-timers <inst>` — drop-in'ы systemd перегенерируются.

## Устранение неполадок

**`failed_count` растёт / в логах postgres ошибки archive_command.**
`docker exec <db> ls -la /wal-spool` — каталог должен быть виден и доступен на запись пользователю postgres (uid 999). Если монтирования нет — проверьте, что контейнер пересоздан после `wal-enable` (`docker compose up -d`, не `restart`).

**Спул растёт, S3-выгрузка молчит.**
`journalctl -u rw-wal-ship@<inst>.service -n 50`. Чаще всего — реквизиты S3 или endpoint. Данные не теряются: сегменты копятся локально и уйдут при восстановлении связи. При > 2000 сегментов archive_command начнёт отваливаться намеренно (см. `WAL_SPOOL_MAX_FILES` в `pg-archive-command.sh`) — это защита диска и громкий сигнал.

**`pitr-restore` не находит WAL после базового бэкапа.**
Проверьте, что шиппер работал в момент бэкапа и после (`wal-status`). Восстановиться на момент самого базового бэкапа можно всегда: `--target immediate`.

**Песочница: `бэкап зашифрован, SANDBOX_AGE_IDENTITY не задан`.**
Положите приватный ключ age на песочницу и укажите путь в `rw-backup-full.env`.

**Patroni-кластер.**
`wal-enable` намеренно останавливается: в Patroni параметры `archive_*` задаются через `patronictl edit-config` (DCS), иначе Patroni их перезапишет. Спул/шиппер/basebackup при этом использовать можно — настройте `archive_command` на тот же `archive-command.sh` вручную через DCS.

## Структура проекта

```
install.sh                        установка (роли prod / --sandbox)
scripts/
  rw-backup-full.sh               основной скрипт (v3 + диспетчер v4)
  lib/wal-lib.sh                  общая библиотека WAL-слоя
  wal/
    pg-archive-command.sh         archive_command внутри контейнера (POSIX sh)
    wal-ship.sh                   спул → локальный архив → S3
    basebackup.sh                 pg_basebackup + метаданные + S3
    wal-retention.sh              безопасная очистка (по границе бэкапов)
    enable-archiving.sh           включение/выключение архивации
    wal-timers.sh                 per-instance интервалы таймеров
    pitr-restore.sh               восстановление: полный бэкап / PITR / in-place
  sandbox/verify-backup.sh        автопроверка бэкапов
config/
  rw-backup-full.env.example      общий конфиг (v3 + секция v4)
  instances.d/*.example           примеры инстансов (панель, бот)
systemd/                          юниты: ship@, basebackup@, sandbox-verify
```

## Хранилище на диске (прод)

```
/var/lib/rw-wal/<inst>/
  spool/incoming/     сырые сегменты из archive_command (транзит)
  archive/            сжатые [зашифрованные] сегменты — локальная копия
  basebackup/         base_*.tar.zst[.age] + base_*.meta
  state/              маркеры выгрузки в S3, last_success
```

В S3: `<FULL_EXTERNAL_S3_PREFIX>/wal/<hostname>/<inst>/{basebackup,wal}/`. Логические архивы v3 лежат в прежних префиксах `panel/` и `custom-bot/` — форматы и имена v3/оригинала не менялись.

## Совместимость

- Оригинальный `config.env` и его переменные (`BOT_TOKEN`, `CHAT_ID`, `S3_*`) читаются только на чтение.
- Панельный бэкап по-прежнему делает оригинальный `rw-backup` (distillium); формат `remnawave_backup_<TS>.tar.gz` и структура архива не изменены.
- Формат архивов ботов `custom_bot_<проект>_<TS>.tar.gz` из v3 не изменён.
- Все v3-команды и меню работают без изменений; v4 — строго аддитивный слой.

## Лицензия

MIT (см. LICENSE).
