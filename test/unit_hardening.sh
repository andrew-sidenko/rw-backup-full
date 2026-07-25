#!/usr/bin/env bash
# unit_hardening.sh — регрессии классов багов, из‑за которых веб/меню
# «тихо» ломались (offline, unbound, [INFO] в пути S3).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
check(){ [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "got=[$2] want=[$3]"; }

# 1) пустой declare -A под set -u
set +e
out="$(bash -c 'set -euo pipefail; declare -A a=() b=(); echo "${#a[@]}:${#b[@]}"' 2>&1)"
rc=$?
set -e
check "assoc=() under set -u" "$rc:$out" "0:0:0"

set +e
out="$(bash -c 'set -euo pipefail; declare -A a; echo "${#a[@]}"' 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "bare declare -A still unbound (known)" || fail "bare declare -A" "expected fail"

# 2) printf без \\n + read под set -e (старый s3m_host_usage)
set +e
bash -c 'set -euo pipefail; f(){ printf "1 2 3"; }; read -r a b c < <(f); echo ok' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "read without newline dies" || fail "read without newline" "expected die"

set +e
bash -c 'set -euo pipefail; f(){ printf "1 2 3\n"; }; read -r a b c < <(f); echo ok' >/dev/null 2>&1
rc=$?
set -e
check "read with newline ok" "$rc" "0"

# 3) msg→stdout загрязняет $()
pollute(){ echo "[INFO] Проект: x"; printf 'panel\n'; }
clean(){ echo "[INFO] Проект: x" >&2; printf 'panel\n'; }
got="$(pollute | tail -n1)"
check "sanitize polluted pick" "$got" "panel"
got="$(clean)"
check "clean pick stdout" "$got" "panel"

# 4) du/df pipefail killers
set +e
bash -c 'set -euo pipefail; x="$(du -sb /no/such/dir_$$ 2>/dev/null | awk "{print \$1}")"; echo survived' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "du missing dir dies under pipefail" || fail "du missing" "expected die"

set +e
bash -c 'set -euo pipefail; x="$(du -sb /no/such/dir_$$ 2>/dev/null | awk "{print \$1}" || true)"; [[ "$x" =~ ^[0-9]*$ ]] || x=0; echo survived' >/dev/null 2>&1
rc=$?
set -e
check "du || true survives" "$rc" "0"

# 5) status_json фрагмент: disk_free + empty assoc + live usage newline
# shellcheck source=../scripts/lib/s3-multi.sh
source "$ROOT/scripts/lib/s3-multi.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/backup" "$T/s3.d"
cat > "$T/s3.d/cold.env" <<'EOF'
B_ENABLED=true
B_ENDPOINT=https://example.invalid
B_BUCKET=b
B_ACCESS_KEY=AK
B_SECRET_KEY=SK
B_REGION=us-east-1
B_PREFIX=rw-backup-full
B_UPLOAD_PANEL=true
B_UPLOAD_CUSTOM=true
B_UPLOAD_WAL=true
EOF
export INSTALL_DIR="$T" S3D_DIR="$T/s3.d" BACKUP_DIR="$T/backup"
export WAL_ROOT="$T/wal" WAL_METRICS_DIR="$T/metrics" INSTANCES_DIR="$T/instances.d"
export FULL_COMPONENTS="metrics sandbox web" RW_SOURCE_ID="testhost"
mkdir -p "$WAL_METRICS_DIR" "$INSTANCES_DIR"
# Пустой prom (как на sandbox без S3 sizes) — status не должен падать
: > "$WAL_METRICS_DIR/rw_exporter.prom"
PATH_SAVE="$PATH"
export PATH="/usr/bin:/bin"  # без aws → live usage быстрый путь
# Вытащим status_json через bash -c с source главного скрипта — тяжело.
# Вместо этого прогоняем критичный фрагмент как в status_json.
set +e
json_frag="$(bash -c '
set -euo pipefail
source "'"$ROOT"'/scripts/lib/s3-multi.sh"
INSTALL_DIR="'"$T"'"; S3D_DIR="'"$T"'/s3.d"; BACKUP_DIR="'"$T"'/backup"
WAL_ROOT="'"$T"'/wal"; WAL_METRICS_DIR="'"$T"'/metrics"; INSTANCES_DIR="'"$T"'/instances.d"
RW_SOURCE_ID=testhost
declare -A _s3b=() _s3o=() _s3r=() _s3seen=()
df_avail="$(df -B1 --output=avail "${BACKUP_DIR}" 2>/dev/null | tail -n1 | tr -d " " || true)"
[[ "$df_avail" =~ ^[0-9]+$ ]] || df_avail=0
lb_bytes="$(du -sb "$BACKUP_DIR" "$WAL_ROOT" 2>/dev/null | awk "{s+=\$1} END{print s+0}" || true)"
[[ "$lb_bytes" =~ ^[0-9]+$ ]] || lb_bytes=0
printf "{"
printf "\"disk_free_bytes\":%s," "$df_avail"
printf "\"local_backup_bytes\":%s," "$lb_bytes"
printf "\"s3_backends\":["
first=1
for n in $(s3m_backends 2>/dev/null); do
  (( first )) || printf ","
  first=0
  if s3m_load "$n" 2>/dev/null; then
    _bytes=0; _objs=0; _rv=0
    read -r _bytes _objs _rv < <(s3m_host_usage 2>/dev/null || echo "0 0 0") || true
    [[ "$_bytes" =~ ^[0-9]+$ ]] || _bytes=0
    printf "{\"name\":\"%s\",\"bytes\":%s,\"objects\":%s,\"size_source\":\"live\"}" "$n" "$_bytes" "${_objs:-0}"
  fi
done
printf "]}"
printf "\n"
' 2>/dev/null)"
rc=$?
set -e
export PATH="$PATH_SAVE"
check "status_json fragment rc" "$rc" "0"
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$json_frag" && pass "status_json fragment is JSON" || fail "status_json fragment JSON" "$json_frag"

# 6) select_* UI не должен попадать в stdout (симуляция)
select_sim() {
  echo "Выбери проект:" >&2
  echo " 1. foo" >&2
  printf '%s\n' 'foo|/home/foo|pg'
}
got="$(select_sim)"
check "select_* stdout clean" "$got" "foo|/home/foo|pg"

# 7) verify-fleet empty src_tag guard pattern
set +e
bash -c 'set -euo pipefail; declare -A R=(); src=""; src="${src:-unknown}"; R[$src]+="x"; echo ${#R[@]}' >/dev/null 2>&1
rc=$?
set -e
check "empty src_tag → unknown" "$rc" "0"

# 8) status-digest S3 block with empty prom
set +e
bash -c '
set -euo pipefail
EXPORTER_PROM="'"$T"'/metrics/rw_exporter.prom"
declare -A _s3_bytes=() _s3_objs=() _s3_reach=()
while IFS= read -r line; do
  case "$line" in
    "rw_s3_category_bytes{"*) : ;;
  esac
done < "$EXPORTER_PROM"
if (( ${#_s3_bytes[@]} > 0 || ${#_s3_reach[@]} > 0 )); then echo HAS; else echo NO; fi
' >/tmp/digest_sim.out 2>&1
rc=$?
set -e
check "digest empty prom" "$rc:$(cat /tmp/digest_sim.out)" "0:NO"

# 9) wal_metric_write создаёт каталог (раньше молча no-op → UI «—/—»)
MDIR="$T/metrics-create-me"
rm -rf "$MDIR"
set +e
bash -c '
set -euo pipefail
source "'"$ROOT"'/scripts/lib/wal-lib.sh"
WAL_METRICS_DIR="'"$MDIR"'"
printf "rw_fleet_verify_checks_total 3\nrw_fleet_verify_checks_passed 2\n" | wal_metric_write "rw_fleet_verify"
[[ -f "'"$MDIR"'/rw_fleet_verify.prom" ]]
grep -q "rw_fleet_verify_checks_total 3" "'"$MDIR"'/rw_fleet_verify.prom"
' >/tmp/metric_write.out 2>&1
rc=$?
set -e
check "wal_metric_write mkdir+write" "$rc" "0"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
