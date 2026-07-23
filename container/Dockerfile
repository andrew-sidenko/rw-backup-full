# rw-backup-full toolkit — единый образ для текущих хостов и (в будущем) k8s.
#
# Роли одного образа (переключаются командой контейнера / RW_ROLE):
#   host-agent — агент прод-хоста: логические бэкапы, WAL-слой, метрики (по расписанию)
#   sandbox    — песочница: verify + метрики по расписанию
#   web        — веб-сервис управления парком
#   <команда>  — разовый запуск: docker run --rm ... rw-backup-full-образ status --json
#
# Сборка из корня репозитория:
#   docker build -t rw-backup-full:5.1.0 -f container/Dockerfile .

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG SUPERCRONIC_VERSION=v0.2.33
ARG TARGETARCH=amd64

# Базовые утилиты
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl ca-certificates gnupg tzdata \
      gzip zstd age openssl openssh-client jq git rsync \
      util-linux coreutils findutils procps \
      python3 python3-venv \
      awscli \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI + compose-плагин из официального репозитория Docker
# (демон в образ НЕ ставится — используется хостовый /var/run/docker.sock)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Клиенты PostgreSQL 16 и 17 из PGDG — pg_dump/pg_basebackup/psql под версии
# серверов панелей и ботов
RUN install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-16 postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

# supercronic — планировщик для контейнеров (без демона, логи в stdout)
RUN curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/supercronic

# Зависимости веб-сервиса в отдельном venv (нужны только роли web)
RUN python3 -m venv /opt/webvenv \
    && /opt/webvenv/bin/pip install --no-cache-dir -q fastapi uvicorn pydantic

# Скрипты проекта
ENV INSTALL_DIR=/opt/rw-backup-restore
COPY scripts/                 ${INSTALL_DIR}/scripts/
COPY web/app.py               ${INSTALL_DIR}/web/app.py
COPY grafana/                 ${INSTALL_DIR}/grafana/
COPY config/                  ${INSTALL_DIR}/config-examples/
COPY container/entrypoint.sh  /entrypoint.sh
COPY container/render-cron.sh ${INSTALL_DIR}/scripts/container/render-cron.sh

RUN chmod +x /entrypoint.sh \
      ${INSTALL_DIR}/scripts/container/render-cron.sh \
      ${INSTALL_DIR}/scripts/rw-backup-full.sh \
      ${INSTALL_DIR}/scripts/wal/*.sh \
      ${INSTALL_DIR}/scripts/panel/*.sh \
      ${INSTALL_DIR}/scripts/metrics/*.sh \
      ${INSTALL_DIR}/scripts/sandbox/*.sh \
    && ln -sf ${INSTALL_DIR}/scripts/rw-backup-full.sh /usr/local/bin/rw-backup-full \
    && mkdir -p /var/lib/node_exporter/textfile_collector

LABEL org.opencontainers.image.title="rw-backup-full" \
      org.opencontainers.image.description="Backup toolkit: panels, bots, WAL/PITR, sandbox verify, fleet web" \
      org.opencontainers.image.source="https://github.com/andrew-sidenko/rw-backup-full"

WORKDIR ${INSTALL_DIR}
ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
