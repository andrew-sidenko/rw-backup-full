# Дашборд Grafana

`dashboard.json` — готовый дашборд «rw-backup-full — бэкапы, WAL, песочница».

Импорт: Grafana → Dashboards → New → Import → Upload JSON file → выбрать
источник данных (Prometheus/VictoriaMetrics) в переменной «Источник данных».

Поток данных: скрипты пишут метрики в textfile collector
(`/var/lib/node_exporter/textfile_collector/*.prom`) на каждом сервере →
node_exporter/vmagent (push) → VictoriaMetrics → Grafana. Серверы различаются
стандартными лейблами `instance`/`host` вашего сборщика.

Панели: успех panel-бэкапов и базовых бэкапов, результаты песочницы (PITR и
логические), возраст последних бэкапов, размеры локально и в каждом
S3-бэкенде по категориям, свободное место, спул WAL, длительности операций,
доступность бэкендов, ошибки шиппера.

Рекомендуемые алерты (Grafana Alerting): rw_sandbox_pitr_last_ok == 0;
time()-rw_basebackup_last_success_timestamp_seconds > 2*интервал;
rw_wal_spool_files > 200; rw_disk_free_bytes < 5e9; rw_s3_backend_reachable == 0.
