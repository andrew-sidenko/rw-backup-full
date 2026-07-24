#!/usr/bin/env bash
set -uo pipefail

REPORT="/root/bot-structure-report-$(hostname)-$(date +%Y%m%d_%H%M%S).txt"

redact() {
  sed -E '
s#((PASSWORD|PASS|PWD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY|JWT|COOKIE|SESSION|DSN|DATABASE_URL|SQLALCHEMY_DATABASE_URL|BOT_TOKEN|WEBHOOK_SECRET|ENCRYPTION_KEY|ROOT_PASSWORD)[A-Za-z0-9_./-]*[[:space:]]*[:=][[:space:]]*).*#\1***REDACTED***#Ig
s#(mysql(\+pymysql)?://[^:[:space:]]+:)[^@[:space:]]+@#\1***REDACTED***@#Ig
s#(postgres(ql)?://[^:[:space:]]+:)[^@[:space:]]+@#\1***REDACTED***@#Ig
s#(redis://[^@[:space:]]*@)#redis://***REDACTED***@#Ig
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

section "DISK USAGE"
df -hT
du -sh /home/* 2>/dev/null || true
du -sh /opt/* 2>/dev/null || true

section "DOCKER VERSION"
docker --version 2>/dev/null || true
docker compose version 2>/dev/null || true

section "DOCKER CONTAINERS"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Command}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

section "DATABASE-LIKE CONTAINERS"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -Ei 'postgres|postgis|mysql|mariadb|redis|mongo|clickhouse|sqlite|db|database|pg' || true

section "COMPOSE FILES FOUND"
find /home /opt /root -maxdepth 5 -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) -print 2>/dev/null || true

section "ENV FILES FOUND"
find /home /opt /root -maxdepth 5 -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '*env.example' \) -print 2>/dev/null || true

section "COMPOSE PROJECT ANALYSIS"
find /home /opt /root -maxdepth 5 -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) -printf '%h\n' 2>/dev/null | sort -u | while read -r d; do
  echo
  echo "### COMPOSE DIR: $d ###"
  ls -la "$d" 2>/dev/null || true
  echo "[services]"
  (cd "$d" && docker compose config --services 2>/dev/null) || true
  echo "[ps]"
  (cd "$d" && docker compose ps -a 2>/dev/null) || true
  echo "[rendered redacted]"
  (cd "$d" && docker compose config 2>/dev/null | redact) || true
  if [[ -d "$d/volumes" ]]; then
    echo "[volumes]"
    find "$d/volumes" -maxdepth 4 -type d -print 2>/dev/null || true
    du -sh "$d/volumes"/* 2>/dev/null || true
  fi
done

section "SERVICE / DB HINTS FROM FILES"
grep -RniE 'postgres|postgresql|mysql|mariadb|redis|mongo|sqlite|SQLALCHEMY_DATABASE_URL|DATABASE_URL|REDIS_URL|PGHOST|POSTGRES|MYSQL|MARIADB|DB_' \
  /home /opt /root \
  --include='.env' --include='.env.*' --include='*.env' --include='docker-compose.yml' --include='docker-compose.yaml' --include='compose.yml' --include='compose.yaml' \
  2>/dev/null | redact || true

section "RECENT BACKUPS"
find /opt/rw-backup-restore/backup /home /opt /root -maxdepth 5 -type f \( -name '*.tar.gz' -o -name '*.sql.gz' -o -name '*.dump' \) -printf '%TY-%Tm-%Td %TH:%TM\t%k KB\t%p\n' 2>/dev/null | sort -r | head -200 || true

section "REPORT CREATED"
echo "$REPORT"
