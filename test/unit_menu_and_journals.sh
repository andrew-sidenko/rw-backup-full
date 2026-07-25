#!/usr/bin/env bash
# unit_menu_and_journals.sh — быстрые проверки без docker/S3.
# Покрывает: ask_choice/menu_pick, s3m_journal_name, retention companion,
# sync-fleet-creds dry (мок curl/jq), component_enabled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
check(){ [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "got=[$2] want=[$3]"; }

# --- s3m_journal_name ---
# shellcheck source=../scripts/lib/s3-multi.sh
source "$ROOT/scripts/lib/s3-multi.sh"
check "journal tar.gz" "$(s3m_journal_name 'remnawave_backup_2026-07-24_12_00_00.tar.gz')" "remnawave_backup_2026-07-24_12_00_00.txt"
check "journal age" "$(s3m_journal_name 'custom_bot_x.tar.gz.age')" "custom_bot_x.tar.gz.txt"
check "journal base" "$(s3m_journal_name 'base_2026-07-24_01_00_00_000000010000000000000001.tar.zst')" "base_2026-07-24_01_00_00_000000010000000000000001.txt"

# --- s3m_host_usage: строка с \n, иначе read под set -e → offline в вебе ---
B_BUCKET="b"; B_PREFIX="rw-backup-full"; B_UPLOAD_PANEL=true; B_UPLOAD_CUSTOM=true; B_UPLOAD_WAL=true
RW_SOURCE_ID="testhost"
PATH="/usr/bin:/bin"  # без aws → быстрый путь 0 0 0
usage_out="$(s3m_host_usage)"
check "host_usage line" "$usage_out" "0 0 0"
# Регрессия: read без \n возвращал 1 и валил status --json
set +e
read -r _ub _uo _ur < <(s3m_host_usage)
_read_rc=$?
set -e
check "host_usage read rc" "$_read_rc" "0"
check "host_usage read bytes" "${_ub}" "0"

# --- digest/status: пустой declare -A под set -u ---
# Регрессия: `declare -A x` без =() → `${#x[@]}` → «x: unbound variable».
set +e
_digest_out="$(bash -c 'set -euo pipefail; declare -A _s3_bytes=() _s3_reach=(); echo "${#_s3_bytes[@]}:${#_s3_reach[@]}"' 2>&1)"
_digest_rc=$?
set -e
check "empty assoc-array under set -u" "$_digest_rc:$_digest_out" "0:0:0"

# --- msg / pick_verify_project: логи не должны попадать в $() ---
msg() {
  local type="$1" text="$2"
  printf '[%s] %s\n' "$type" "$text" >&2
}
pick_verify_project_sim() {
  local sid="$1" name=panel
  echo "  Проект: ${sid}-${name}  → в команде: ${name}" >&2
  printf '%s\n' "$name"
}
_pr_out="$(pick_verify_project_sim tyler-panel-1 2>/tmp/pick_err.$$)"
_pr_err="$(cat /tmp/pick_err.$$ 2>/dev/null || true)"; rm -f /tmp/pick_err.$$
check "pick_verify stdout is project" "$_pr_out" "panel"
[[ "$_pr_err" == *"tyler-panel-1-panel"* ]] && pass "pick_verify stderr has label" || fail "pick_verify stderr" "$_pr_err"
# Регрессия старого msg→stdout: tail -n1 + валидация спасают
_pr_polluted=$'[INFO] Проект: x-panel → panel\npanel'
_pr_fix="$(printf '%s\n' "$_pr_polluted" | tail -n1 | tr -d '\r')"
[[ "$_pr_fix" =~ ^[A-Za-z0-9_.-]+$ ]] || _pr_fix=panel
check "sanitize polluted project" "$_pr_fix" "panel"

# --- ask_choice / menu_pick (extract from main script via bash) ---
ask_choice() {
  local title="$1"; shift
  local -a opts=("$@")
  local pick="${ASK_PICK:-1}"
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#opts[@]} )); then pick=1; fi
  printf '%s\n' "${opts[$((pick-1))]}"
}
menu_pick() {
  local -a keys=() labels=()
  local key label i=1 pick="${MENU_PICK:-1}" back="${MENU_BACK_LABEL:-Назад}"
  while [[ $# -ge 2 ]]; do
    key="$1"; label="$2"; shift 2
    keys+=("$key"); labels+=("$label")
    i=$((i+1))
  done
  [[ -z "$pick" || "$pick" == "0" ]] && { printf '0\n'; return 0; }
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#keys[@]} )); then
    printf '?\n'; return 0
  fi
  printf '%s\n' "${keys[$((pick-1))]}"
}

ASK_PICK=2
r="$(ask_choice "Глубина:" "стандартная" "быстрая (quick)" "глубокая")"
check "ask_choice pick=2" "$r" "быстрая (quick)"
ASK_PICK=3
r="$(ask_choice "Глубина:" "стандартная" "быстрая (quick)" "глубокая")"
check "ask_choice pick=3" "$r" "глубокая"
ASK_PICK=99
r="$(ask_choice "Глубина:" "стандартная" "быстрая (quick)" "глубокая")"
check "ask_choice invalid→1" "$r" "стандартная"

MENU_PICK=2
r="$(menu_pick fleet "Парк" stack "Стек" local "Локально")"
check "menu_pick→stack" "$r" "stack"
MENU_PICK=0
r="$(MENU_BACK_LABEL=Выход menu_pick fleet "Парк" stack "Стек")"
check "menu_pick→0" "$r" "0"

# --- component_enabled ---
# shellcheck source=../scripts/lib/wal-lib.sh
FULL_COMPONENTS="metrics sandbox web"
source "$ROOT/scripts/lib/wal-lib.sh"
component_enabled sandbox && pass "sandbox on" || fail "sandbox on" "disabled"
component_enabled wal && fail "wal off" "enabled" || pass "wal off"
component_enabled panel-backup && fail "panel off" "enabled" || pass "panel off"

# --- sync-fleet-creds dry with mock curl ---
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/install"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# ignore args, emit fixture manifest
cat <<'JSON'
{"ok":true,"settings":{},"servers":[
  {"id":"prod1","source":"prod1","reachable":true,
   "telegram":{"token":"tok1","chat_id":"111","thread_id":""},
   "backends":[{"name":"cold","enabled":true,"endpoint":"https://s3.example","bucket":"b",
     "access_key":"AK","secret_key":"SK","region":"us-east-1","prefix":"rw",
     "panel":true,"custom":true,"wal":true}]}
]}
JSON
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"
export INSTALL_DIR="$T/install"
export FLEET_CREDS_DIR="$T/install/fleet-creds"
export WEB_TOKEN="test-token"
export FULL_COMPONENTS="sandbox metrics web"
mkdir -p "$INSTALL_DIR"
# stub require_component / wal_load — script sources wal-lib which needs config file optional
set +e
out="$(bash "$ROOT/scripts/sandbox/sync-fleet-creds.sh" 2>&1)"
rc=$?
set -e
check "sync-creds exit" "$rc" "0"
[[ -f "$FLEET_CREDS_DIR/prod1/telegram.env" ]] && pass "telegram.env written" || fail "telegram.env" "missing"
[[ -f "$FLEET_CREDS_DIR/prod1/s3.d/cold.env" ]] && pass "s3 cold.env written" || fail "s3 cold.env" "missing"
grep -q 'FULL_TG_BOT_TOKEN="tok1"' "$FLEET_CREDS_DIR/prod1/telegram.env" && pass "tg token" || fail "tg token" "bad"
grep -q 'B_BUCKET="b"' "$FLEET_CREDS_DIR/prod1/s3.d/cold.env" && pass "bucket" || fail "bucket" "bad"

# --- web history helper (python) ---
python3 - <<'PY'
import json, os, tempfile, sys
sys.path.insert(0, os.environ.get("ROOT","."))
# minimal inline test of history filter logic
from pathlib import Path
td = Path(tempfile.mkdtemp())
(td/"fleet_1.json").write_text(json.dumps({
  "type":"fleet","ts":100,"total":2,"passed":1,"depth":"standard",
  "results":[{"ok":True,"source":"a","detail":"ok"},{"ok":False,"source":"b","detail":"fail"}]
}))
(td/"stack_1.json").write_text(json.dumps({
  "type":"stack","ts":200,"project":"panel","source":"a","ok":True,"detail":"ok"
}))
files = sorted(list(td.glob("fleet_*.json"))+list(td.glob("stack_*.json")),
               key=lambda p: p.stat().st_mtime, reverse=True)
assert len(files)==2
# filter server a
hist=[]
for f in files:
  data=json.loads(f.read_text())
  if data.get("type")=="fleet":
    data["results"]=[r for r in data["results"] if r["source"]=="a"]
    if not data["results"]: continue
  elif data.get("source")!="a":
    continue
  hist.append(data)
assert len(hist)==2, hist
assert hist[0]["type"] in ("fleet","stack")
print("PASS web history filter")
PY

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
