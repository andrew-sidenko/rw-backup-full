#!/usr/bin/env bash
set -uo pipefail

REPORT="/root/bot-structure-report-$(hostname)-$(date +%Y%m%d_%H%M%S).txt"

redact() {
  sed -E '
s#((PASSWORD|PASS|PWD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY|JWT|COOKIE|SESSION|DSN|DATABASE_URL|SQLALCHEMY_DATABASE_URL|BOT_TOKEN|WEBHOOK_SECRET|ENCRYPTION_KEY|ROOT_PASSWORD)[A-Za-z0-9_./-]*[[:space:]]*[:=][[:space:]]*).*#\1***REDACTED***#Ig
s#(mysql(\+pymysql)?://[^:[:space:]]+:)[^@[:space:]]+@#\1***REDACTED***@#Ig
s#(postgres(ql)?://[^:[:space:]]+:)[^@[:space:]]+@#\1***REDACTED***@#Ig
s#(redis://[^@[:space:]]*@)#redis://***REDACTED***@#Ig
s#([A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})#***JWT_REDACTED***#g
'
}

section() {
  echo
  echo "===== $* ====="
}

exec > >(tee "$REPORT") 2>&1

section "HOST INFO"
date -Is
hostnamectl 2>/dev/null || true
uname -a
uptime
whoami
pwd

section "DISK USAGE"
df -hT
echo
du -sh /home/* 2>/dev/null || true
du -sh /opt/* 2>/dev/null || true

section "DOCKER VERSION"
docker --version 2>/dev/null || true
docker compose version 2>/dev/null || true

section "DOCKER CONTAINERS"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Command}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

section "DATABASE-LIKE CONTAINERS"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -Ei 'postgres|postgis|mysql|mariadb|redis|valkey|mongo|clickhouse|sqlite|db|database|pg' || true

section "DOCKER VOLUMES"
docker volume ls 2>/dev/null || true

section "DOCKER NETWORKS"
docker network ls 2>/dev/null || true

section "COMPOSE FILES FOUND"
find /home /opt /root \
  -maxdepth 5 \
  -type f \
  \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
  -print 2>/dev/null || true

section "ENV FILES FOUND"
find /home /opt /root \
  -maxdepth 5 \
  -type f \
  \( -name '.env' -o -name '.env.*' -o -name '*env.example' -o -name '*.env' \) \
  -print 2>/dev/null || true

section "PROJECT-LIKE DIRECTORIES"
find /home /opt /root \
  -maxdepth 4 \
  -type f \
  \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' -o -name 'requirements.txt' -o -name 'pyproject.toml' -o -name 'package.json' \) \
  -printf '%h\n' 2>/dev/null | sort -u || true

section "CONTAINER LABELS / WORKDIR / MOUNTS / ENV REDACTED"
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
  echo
  echo "--- CONTAINER: $c ---"
  docker inspect "$c" --format 'Name={{.Name}} Image={{.Config.Image}} Status={{.State.Status}} Running={{.State.Running}} RestartPolicy={{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || true
  echo "[compose labels]"
  docker inspect "$c" --format '{{json .Config.Labels}}' 2>/dev/null | redact || true
  echo "[ports]"
  docker inspect "$c" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null || true
  echo "[mounts]"
  docker inspect "$c" --format '{{json .Mounts}}' 2>/dev/null | redact || true
  echo "[env redacted]"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sort | redact || true
done

section "COMPOSE PROJECT ANALYSIS"
COMPOSE_DIRS="$(find /home /opt /root \
  -maxdepth 5 \
  -type f \
  \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
  -printf '%h\n' 2>/dev/null | sort -u)"

for d in $COMPOSE_DIRS; do
  echo
  echo "### COMPOSE DIR: $d ###"
  echo "[ls -la]"
  ls -la "$d" 2>/dev/null || true
  echo "[tree-like dirs maxdepth 3]"
  find "$d" -maxdepth 3 -type d -print 2>/dev/null || true
  echo "[important files maxdepth 3]"
  find "$d" -maxdepth 3 -type f \
    \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' -o -name '.env' -o -name '.env.*' -o -name '*.env' -o -name 'requirements.txt' -o -name 'pyproject.toml' -o -name 'package.json' -o -name 'Dockerfile' -o -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
    -printf '%p\t%k KB\n' 2>/dev/null || true
  echo "[docker compose services]"
  (cd "$d" && docker compose config --services 2>/dev/null) || true
  echo "[docker compose ps -a]"
  (cd "$d" && docker compose ps -a 2>/dev/null) || true
  echo "[docker compose rendered config redacted]"
  (cd "$d" && docker compose config 2>/dev/null | redact) || true
done

section "HOME BOT DIRECTORIES STRUCTURE"
find /home -maxdepth 2 -mindepth 1 -type d -print 2>/dev/null | while read -r d; do
  echo
  echo "### DIR: $d ###"
  ls -la "$d" 2>/dev/null || true
  if [[ -d "$d/volumes" ]]; then
    echo "[volumes dirs maxdepth 4]"
    find "$d/volumes" -maxdepth 4 -type d -print 2>/dev/null || true
    echo "[volumes size]"
    du -sh "$d/volumes"/* 2>/dev/null || true
  fi
  echo "[db-like files maxdepth 5]"
  find "$d" -maxdepth 5 -type f \
    \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.rdb' -o -name 'dump.rdb' -o -name '*.sql' -o -name '*.sql.gz' \) \
    -printf '%p\t%k KB\n' 2>/dev/null || true
done

section "SERVICE / DB HINTS FROM FILES"
grep -RniE 'postgres|postgresql|mysql|mariadb|redis|valkey|mongo|sqlite|SQLALCHEMY_DATABASE_URL|DATABASE_URL|REDIS_URL|PGHOST|POSTGRES|MYSQL|MARIADB|DB_' \
  /home /opt /root \
  --include='.env' \
  --include='.env.*' \
  --include='*.env' \
  --include='docker-compose.yml' \
  --include='docker-compose.yaml' \
  --include='compose.yml' \
  --include='compose.yaml' \
  2>/dev/null | redact || true

section "RECENT BACKUPS"
find /home /opt /root /var/backups /opt/rw-backup-restore/backup \
  -maxdepth 5 \
  -type f \
  \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump' -o -name '*.bak' \) \
  -printf '%TY-%Tm-%Td %TH:%TM\t%k KB\t%p\n' 2>/dev/null | sort -r | head -200 || true

section "REPORT CREATED"
echo "$REPORT"
