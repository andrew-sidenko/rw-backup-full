#!/usr/bin/env bash
# rw-backup-full e2e тест — полный цикл backup→verify→s3→restore с мок-Docker
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/rw-backup-full.sh"
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
PASS=0; FAIL=0
log_pass(){ PASS=$((PASS+1)); printf "${GREEN}PASS${RESET} %s\n" "$1"; }
log_fail(){ FAIL=$((FAIL+1)); printf "${RED}FAIL${RESET} %s  (got=[%s] want=[%s])\n" "$1" "${2:-?}" "${3:-?}"; }
check(){    [[ "$2" == "$3" ]] && log_pass "$1" || log_fail "$1" "$2" "$3"; }
has(){      grep -qF "$3" <<<"$2" 2>/dev/null && log_pass "$1" || log_fail "$1" "not found: $3" "contains $3"; }
hasnt(){    grep -qF "$3" <<<"$2" 2>/dev/null && log_fail "$1" "found: $3" "absent" || log_pass "$1"; }

T="/tmp/rw_e2e_$$"
mkdir -p "$T/backup" "$T/mock" "$T/s3"
trap 'rm -rf "$T"' EXIT

# ── age ─────────────────────────────────────────────────────────────────────
AGE_KEY="$T/age-key.txt"
age-keygen -o "$AGE_KEY" 2>/dev/null
# age-keygen пишет "# public key:" строчными! Используем grep -i
AGE_PUB=$(grep -i 'public key:' "$AGE_KEY" | awk '{print $NF}')
[[ -n "$AGE_PUB" ]] || { echo "FATAL: age keygen failed"; exit 1; }

# ── мок docker ──────────────────────────────────────────────────────────────
cat > "$T/mock/docker" << 'MD'
#!/usr/bin/env bash
S3="$T_S3"
case "$*" in
  "exec"*"pg_dumpall"*)
    echo "SET"; echo "CREATE ROLE postgres SUPERUSER;"
    echo "CREATE TABLE users(id INT); INSERT INTO users VALUES(1),(2);"
    ;;
  "exec"*"redis-cli"*"SAVE"*) echo "OK" ;;
  # docker cp: второй аргумент container:/path, третий — target
  "cp"*)
    target="${@: -1}"   # последний аргумент = dst
    echo "redis_dump_content" > "$target" 2>/dev/null || true ;;
  "exec"*"psql"*)
    while IFS= read -r _; do :; done
    echo "WARNING: role cannot be dropped, skipping"
    exit 0 ;;
  "compose down"*) echo "[mock] down" ;;
  "compose up"*)   echo "[mock] up" ;;
  "compose ps"*|"ps -a"*) echo "vpn_postgres Running"; echo "vpn_redis Running" ;;
  "inspect"*"working_dir"*) printf '%s\n' "$T_PROJ" ;;
  "logs"*) echo "" ;;
  *) echo "[mock] $*" >&2 ;;
esac
MD
chmod +x "$T/mock/docker"
cat > "$T/mock/pg_isready" << 'MPG'
#!/usr/bin/env bash
echo "accepting connections"; exit 0
MPG
chmod +x "$T/mock/pg_isready"
cat > "$T/mock/aws" << MAWS
#!/usr/bin/env bash
S="$T/s3"
case "\$1 \$2" in
  "s3 cp")
    src="\$3"; dst="\$4"
    if [[ "\$src" == s3://* ]]; then
      key="\${src#s3://*/}"; cp "\$S/\$key" "\$dst" 2>/dev/null || { echo NoSuchKey>&2; exit 1; }
    else
      key="\${dst#s3://*/}"; mkdir -p "\$S/\$(dirname "\$key")"; cp "\$src" "\$S/\$key"
    fi ;;
  "s3 ls")
    prefix="\$(echo "\$@" | grep -oP '(?<=s3://\S{1,80}/).*')"
    find "\$S/\$prefix" -type f 2>/dev/null | while read -r f; do
      echo "2026-06-13 12:00:00  \$(stat -c %s "\$f") \${f#\$S/}"
    done ;;
  "s3api list-objects-v2")
    prefix="\$(echo "\$@" | grep -oP '(?<=--prefix )\S+')"
    keys=\$(find "\$S/\$prefix" -type f 2>/dev/null | while read -r f; do printf '"%s",' "\${f#\$S/}"; done)
    echo "[\${keys%,}]" ;;
  "s3 rm") key="\${3#s3://*/}"; rm -f "\$S/\$key" ;;
esac
MAWS
chmod +x "$T/mock/aws"
export PATH="$T/mock:$PATH"

# ── конфиги ─────────────────────────────────────────────────────────────────
cat > "$T/config.env" << EOF
S3_BUCKET=primary-bucket
S3_ACCESS_KEY=ORIGAK
S3_SECRET_KEY=ORIGSK
S3_REGION=us-east-1
S3_PREFIX=rw-backup
EOF
cat > "$T/full.env" << EOF
FULL_LOCAL_RETENTION_DAYS=3
FULL_EXTERNAL_S3_RETENTION_DAYS=10
FULL_EXTERNAL_S3_RETENTION_MIN_KEEP=2
FULL_PANEL_EXTERNAL_S3_ENABLED=false
FULL_CUSTOM_EXTERNAL_S3_ENABLED=true
FULL_CUSTOM_PRIMARY_S3_ENABLED=true
FULL_EXTERNAL_S3_BUCKET=ext-bucket
FULL_EXTERNAL_S3_ACCESS_KEY=EXTAK
FULL_EXTERNAL_S3_SECRET_KEY=EXTSK
FULL_EXTERNAL_S3_REGION=us-east-1
FULL_EXTERNAL_S3_ENDPOINT=
FULL_EXTERNAL_S3_PREFIX=rw-backup-full
FULL_AGE_ENABLED=false
FULL_AGE_RECIPIENT=${AGE_PUB}
FULL_AGE_RECIPIENTS_FILE=
FULL_AGE_IDENTITY_FILE=${AGE_KEY}
FULL_NOTIFY_ON_FAILURE=false
FULL_NOTIFY_EACH_EXTERNAL_S3_UPLOAD=false
FULL_TG_BOT_TOKEN=
FULL_TG_CHAT_ID=
FULL_VERIFY_MIN_ARCHIVE_BYTES=100
FULL_VERIFY_MIN_PGDUMP_BYTES=60
EOF

# ── проект бота ─────────────────────────────────────────────────────────────
PROJ="$T/home/OneOkBotNew"
mkdir -p "$PROJ/src" "$PROJ/volumes/pgdata" "$PROJ/volumes/redis" "$PROJ/volumes/marzban"
echo "BOT_TOKEN=secret123" > "$PROJ/.env"
echo "version: '3'" > "$PROJ/docker-compose.yaml"
echo "main()" > "$PROJ/src/main.py"
echo "pgdata" > "$PROJ/volumes/pgdata/PG_VERSION"
echo "redis" > "$PROJ/volumes/redis/dump.rdb"
echo "marzban_data" > "$PROJ/volumes/marzban/data.json"

export T_S3="$T/s3" T_PROJ="$PROJ"

# ── загружаем функции ────────────────────────────────────────────────────────
LAST=$(grep -n '^load_config$' "$SCRIPT" | tail -1 | cut -d: -f1)
head -n $((LAST-1)) "$SCRIPT" > "$T/funcs.sh"
bash -n "$T/funcs.sh" || { echo "SYNTAX ERROR"; exit 1; }
source "$T/funcs.sh"
set +e

BACKUP_DIR="$T/backup"
CONFIG_FILE="$T/config.env"
FULL_CONFIG_FILE="$T/full.env"
source "$T/config.env"  2>/dev/null || true
source "$T/full.env"   2>/dev/null || true
ORIG_S3_BUCKET="${S3_BUCKET:-}"
ORIG_S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
ORIG_S3_SECRET_KEY="${S3_SECRET_KEY:-}"
ORIG_S3_REGION="${S3_REGION:-us-east-1}"
ORIG_S3_ENDPOINT=""
ORIG_S3_PREFIX="${S3_PREFIX:-}"

detect_custom_projects(){ echo "oneokbotnew|$PROJ|vpn_postgres|postgres|vpn_redis|redis|vpn_bot"; }
save_extra_configs(){ return 0; }

HOST=$(hostname -s)

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 1. BACKUP ──────────────────────────────────────${RESET}"
FULL_AGE_ENABLED=false

backup_custom_project_entry "oneokbotnew|$PROJ|vpn_postgres|postgres|vpn_redis|redis|vpn_bot" >/dev/null 2>&1
check "backup rc=0" "$?" "0"
ARCHIVE=$(ls -1t "$T/backup"/custom_bot_*.tar.gz 2>/dev/null | head -1)
check "backup: архив создан" "$(test -f "$ARCHIVE" && echo yes)" "yes"
[[ -f "$ARCHIVE" ]] && L=$(tar -tzf "$ARCHIVE" 2>/dev/null) || L=""
has    "backup: PROFILE.env"       "$L" "PROFILE.env"
has    "backup: project_dir.tar.gz" "$L" "project_dir.tar.gz"
has    "backup: postgres_dump.sql.gz" "$L" "postgres_dump.sql.gz"
has    "backup: redis_dump.rdb"    "$L" "redis_dump.rdb"
hasnt  "backup: pgdata исключён"   "$L" "volumes/pgdata"
hasnt  "backup: redis live исключён" "$L" "volumes/redis/dump.rdb"
has    "backup: .env включён"      "$L" ".env"
PROF=$(tar -xzOf "$ARCHIVE" --wildcards "*/PROFILE.env" 2>/dev/null)
has    "backup: PROJECT_BASE=OneOkBotNew" "$PROF" "PROJECT_BASE=OneOkBotNew"
has    "backup: PROJECT_DIR"              "$PROF" "PROJECT_DIR"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 2. VERIFY ──────────────────────────────════════${RESET}"
verify_custom_archive "$ARCHIVE" >/dev/null 2>&1
check "verify: валидный rc=0" "$?" "0"

echo "x" > "$T/broken.tar.gz"
verify_custom_archive "$T/broken.tar.gz" >/dev/null 2>&1
check "verify: битый rc=1" "$?" "1"

# Пустой pg-дамп (gzip пустого файла = ~20 байт < FULL_VERIFY_MIN_PGDUMP_BYTES=60)
mkdir -p "$T/bpg"
echo "x" > "$T/bpg/PROFILE.env"
tar -czf "$T/bpg/project_dir.tar.gz" -C / etc/hostname 2>/dev/null
true | gzip > "$T/bpg/postgres_dump.sql.gz"   # пустой stdin → ~20 байт gzip
echo r > "$T/bpg/redis_dump.rdb"
(cd "$T" && tar -czf bad_pg.tar.gz bpg)
verify_custom_archive "$T/bad_pg.tar.gz" >/dev/null 2>&1
check "verify: пустой pg-дамп (${FULL_VERIFY_MIN_PGDUMP_BYTES}б порог) rc=1" "$?" "1"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 3. AGE ШИФРОВАНИЕ ─────────────────────────────${RESET}"
check "age: публичный ключ прочитан" "$(test -n "$FULL_AGE_RECIPIENT" && echo yes)" "yes"
cp "$ARCHIVE" "$T/enc_src.tar.gz"

FULL_AGE_ENABLED=false
maybe_encrypt_for_upload "$T/enc_src.tar.gz" "true" >/dev/null 2>&1
check "age off: passthrough"    "$ENCRYPT_RESULT_FILE" "$T/enc_src.tar.gz"
check "age off: нет .age файла" "$(test -f "$T/enc_src.tar.gz.age" && echo yes || echo no)" "no"

FULL_AGE_ENABLED=true
cp "$ARCHIVE" "$T/enc_src2.tar.gz"
maybe_encrypt_for_upload "$T/enc_src2.tar.gz" "false" >/dev/null 2>&1
check "age on: ENCRYPT_RESULT_FILE=.age" "$ENCRYPT_RESULT_FILE" "$T/enc_src2.tar.gz.age"
check "age on: оригинал удалён"  "$(test -f "$T/enc_src2.tar.gz" && echo yes || echo no)" "no"
check "age on: .age создан"      "$(test -f "$T/enc_src2.tar.gz.age" && echo yes)" "yes"
age -d -i "$AGE_KEY" -o "$T/decrypted.tar.gz" "$T/enc_src2.tar.gz.age" >/dev/null 2>&1
check "age: round-trip валиден"  "$(gzip -t "$T/decrypted.tar.gz" 2>/dev/null && echo ok)" "ok"
FULL_AGE_ENABLED=false

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 4. S3 UPLOAD ──────────────────────────────────${RESET}"
primary_s3_upload "$ARCHIVE" "oneokbotnew" >/dev/null 2>&1
check "primary s3: rc=0" "$?" "0"
check "primary s3: файл загружен" \
  "$(find "$T/s3/rw-backup/custom-bot/$HOST" -type f 2>/dev/null | wc -l | tr -d ' ')" "1"

full_s3_upload "$ARCHIVE" "custom-bot" "oneokbotnew" >/dev/null 2>&1
check "external s3: rc=0" "$?" "0"
check "external s3: файл загружен" \
  "$(find "$T/s3/rw-backup-full/custom-bot/$HOST" -type f 2>/dev/null | wc -l | tr -d ' ')" "1"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 5. RETENTION ──────────────────────────────────${RESET}"
for d in 0 5 12 20 40; do
  ts=$(date -u -d "-$d days" +%Y%m%d_%H%M%S)
  key="rw-backup-full/custom-bot/$HOST/custom_bot_test_${ts}.tar.gz"
  mkdir -p "$T/s3/rw-backup-full/custom-bot/$HOST"
  cp "$ARCHIVE" "$T/s3/$key"
done
FULL_EXTERNAL_S3_RETENTION_DAYS=10
full_s3_retention_cleanup >/dev/null 2>&1
rem=$(find "$T/s3/rw-backup-full/custom-bot/$HOST" -type f 2>/dev/null | wc -l | tr -d ' ')
check "retention: ≤3 файлов осталось (удалены старые)"  "$(( rem <= 3 ))" "1"
check "retention: ≥2 файлов (min_keep)"                 "$(( rem >= 2 ))" "1"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 6. RESTORE полный цикл ────────────────────────${RESET}"
mkdir -p "$PROJ/src"
echo "old" > "$PROJ/src/old.py"

# стандартный мок docker для restore
docker(){
  case "$*" in
    "compose down"*) echo "down" ;;
    "compose up -d postgres") echo "pg up" ;;
    "compose up -d redis")    echo "redis up" ;;
    "compose up -d")          echo "all up" ;;
    "compose ps"*|"ps -a"*)   echo "Running" ;;
    "exec -i"*"psql"*)
      while IFS= read -r _; do :; done
      echo "WARNING: role cannot be dropped"; return 0 ;;
    "exec"*"pg_isready"*) echo "accepting connections"; return 0 ;;
    "logs"*) echo "" ;;
    *) echo "[d] $*" >&2 ;;
  esac
}
pg_isready(){ return 0; }

out=$(restore_custom_archive "$ARCHIVE" "yes" 2>&1)
check "restore: rc=0"                  "$?" "0"
check "restore: src/main.py"           "$(test -f "$PROJ/src/main.py" && echo yes)" "yes"
check "restore: .env"                  "$(test -f "$PROJ/.env" && echo yes)"        "yes"
check "restore: BOT_TOKEN в .env"      "$(grep -q BOT_TOKEN "$PROJ/.env" && echo yes || echo no)" "yes"
check "restore: marzban данные"        "$(test -f "$PROJ/volumes/marzban/data.json" && echo yes)" "yes"
OLD=$(ls -d "$T/home/OneOkBotNew.before_restore_"* 2>/dev/null | head -1)
check "restore: before_restore сохранён" "$(test -d "${OLD:-/x}" && echo yes)" "yes"
has   "restore: Redis упомянут"  "$out" "Redis"
has   "restore: PostgreSQL ok"   "$out" "PostgreSQL"
has   "restore: завершён"        "$out" "Restore завершён"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 7. RESTORE ошибки ─────────────────────────────${RESET}"

# 7a: нет ключа age
FULL_AGE_IDENTITY_FILE=""
age -r "$AGE_PUB" -o "$T/enc_arch.tar.gz.age" "$ARCHIVE" >/dev/null 2>&1
out=$(restore_custom_archive "$T/enc_arch.tar.gz.age" "yes" 2>&1)
check "restore: нет ключа → rc=1"       "$?" "1"
has   "restore: подсказка IDENTITY_FILE" "$out" "FULL_AGE_IDENTITY_FILE"

# 7b: неверный ключ
age-keygen -o "$T/wrong.txt" 2>/dev/null
FULL_AGE_IDENTITY_FILE="$T/wrong.txt"
out=$(restore_custom_archive "$T/enc_arch.tar.gz.age" "yes" 2>&1)
check "restore: неверный ключ → rc=1"  "$?" "1"
has   "restore: сообщение о сбое"      "$out" "провалилась"

# 7c: правильный ключ
FULL_AGE_IDENTITY_FILE="$AGE_KEY"
mkdir -p "$PROJ"
out=$(restore_custom_archive "$T/enc_arch.tar.gz.age" "yes" 2>&1)
check "restore: правильный ключ → rc=0" "$?" "0"

# 7d: corrupt архив
echo "XXXX" > "$T/corrupt.tar.gz"
restore_custom_archive "$T/corrupt.tar.gz" "yes" >/dev/null 2>&1
check "restore: corrupt → rc=1" "$?" "1"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 8. PG ERRORS harmless vs real ─────────────────${RESET}"

# 8a: cannot be dropped → не fatal (rc=0)
docker(){
  case "$*" in
    "compose down"*|"compose up"*|"compose ps"*|"logs"*) echo "ok" ;;
    "exec"*"pg_isready"*) return 0 ;;
    "exec -i"*"psql"*)
      while IFS= read -r _; do :; done
      echo "ERROR:  role \"postgres\" cannot be dropped because some objects depend on it"
      return 1 ;;
    *) echo "[d] $*" >&2 ;;
  esac
}
mkdir -p "$PROJ"
out=$(restore_custom_archive "$ARCHIVE" "yes" 2>&1)
check "pg harmless: rc=0"               "$?" "0"
has   "pg harmless: WARN или OK выдан"  "$out" "PostgreSQL"

# 8b: реальные ошибки → fatal (rc=1)
docker(){
  case "$*" in
    "compose down"*|"compose up"*|"compose ps"*|"logs"*) echo "ok" ;;
    "exec"*"pg_isready"*) return 0 ;;
    "exec -i"*"psql"*)
      while IFS= read -r _; do :; done
      for i in 1 2 3 4 5; do
        echo "ERROR:  invalid input syntax for type integer: 'NaN' at line $i"
      done
      return 1 ;;
    *) echo "[d] $*" >&2 ;;
  esac
}
mkdir -p "$PROJ"
restore_custom_archive "$ARCHIVE" "yes" >/dev/null 2>&1
check "pg real errors: rc=1" "$?" "1"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 9. РЕГИСТР oneokbotnew vs OneOkBotNew ─────────${RESET}"
CW="$T/case_work"; mkdir -p "$CW"
printf 'PROJECT_NAME=oneokbotnew\nPROJECT_DIR=%s/home/OneOkBotNew\nPROJECT_BASE=OneOkBotNew\nPOSTGRES_CONTAINER=vpn_postgres\nPOSTGRES_SERVICE=postgres\nREDIS_CONTAINER=vpn_redis\nREDIS_SERVICE=redis\n' "$T" > "$CW/PROFILE.env"
mkdir -p "$T/OneOkBotNew/src"
echo "app" > "$T/OneOkBotNew/src/app.py"
tar -czf "$CW/project_dir.tar.gz" -C "$T" OneOkBotNew
head -c 5000 /dev/urandom | gzip > "$CW/postgres_dump.sql.gz"
echo r > "$CW/redis_dump.rdb"
CASE_ARCH="$T/backup/custom_bot_case.tar.gz"
(cd "$T" && tar -czf "$CASE_ARCH" case_work)

docker(){
  case "$*" in
    "compose down"*|"compose up"*|"compose ps"*|"logs"*) echo "ok" ;;
    "exec"*"pg_isready"*) return 0 ;;
    "exec -i"*"psql"*) while IFS= read -r _; do :; done; return 0 ;;
    *) echo "[d] $*" >&2 ;;
  esac
}
mkdir -p "$T/home/OneOkBotNew"
out=$(restore_custom_archive "$CASE_ARCH" "yes" 2>&1)
check "case: rc=0"                     "$?" "0"
check "case: папка восстановлена"      "$(test -f "$T/home/OneOkBotNew/src/app.py" && echo yes)" "yes"
has   "case: имя в логе верное"        "$out" "OneOkBotNew"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 10. TRAP RETURN не сносит tmp ─────────────────${RESET}"
# Воспроизводим баг: trap RETURN + source → tmp удаляется
mkdir -p "$PROJ"
out=$(restore_custom_archive "$ARCHIVE" "yes" 2>&1)
check "trap-fix: нет 'пуста' в логе"   "$(grep -c 'пуста' <<<"$out")" "0"
check "trap-fix: restore rc=0"         "$?" "0"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}── 11. S3 LIST ────────────────────────────────────${RESET}"
list=$(s3_list_custom_backups 2>/dev/null)
check "s3_list: не пустой"    "$(test -n "$list" && echo yes)" "yes"
has   "s3_list: custom_bot"   "$list" "custom_bot"
mkdir -p "$T/s3/rw-backup-full/panel/$HOST"
cp "$ARCHIVE" "$T/s3/rw-backup-full/panel/$HOST/remnawave_backup_20260613.tar.gz"
list2=$(s3_list_custom_backups 2>/dev/null)
hasnt "s3_list: панельные отфильтрованы" "$list2" "remnawave_backup"

# ════════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "${BOLD}══════════════════════════════════════════════════${RESET}"
printf "  %s %d тестов | ${GREEN}✓ PASS: %d${RESET} | ${RED}✗ FAIL: %d${RESET}\n" \
  "${BOLD}" "$((PASS+FAIL))" "$PASS" "$FAIL"
printf '%s\n' "${BOLD}══════════════════════════════════════════════════${RESET}"
exit $FAIL
