#!/usr/bin/env bash
# Smoke: конфиг, очередь, расписание due — без Docker/S3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL $1 — $2"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export RBV_CONFIG="$T/config.json"
export RBV_STATE_DIR="$T/state"
mkdir -p "$RBV_STATE_DIR"

cp "$ROOT/config/config.example.json" "$RBV_CONFIG"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

# --- add storage via CLI ---
"$ROOT/bin/rw-backup-verify" storage add \
  --id s1 --bucket b --access-key a --secret-key s \
  --prefix rw-backup-full --times 06:30,18:30 \
  --backup-hint "прод 03:00" >/dev/null
"$ROOT/bin/rw-backup-verify" storage add \
  --id s2 --bucket b2 --access-key a --secret-key s \
  --interval-hours 1 --prefix p >/dev/null

n="$(jq '.storages|length' "$RBV_CONFIG")"
[[ "$n" == "2" ]] && pass "storage add x2" || fail "storage add" "n=$n"

hint="$(jq -r '.storages[]|select(.id=="s1")|.backup_hint' "$RBV_CONFIG")"
[[ "$hint" == "прод 03:00" ]] && pass "backup_hint" || fail "backup_hint" "$hint"

# --- telegram ---
"$ROOT/bin/rw-backup-verify" telegram set --token tok --chat-id 123 >/dev/null
tok="$(jq -r '.telegram.token' "$RBV_CONFIG")"
[[ "$tok" == "tok" ]] && pass "telegram set" || fail "telegram" "$tok"

# --- enqueue FIFO ---
rbv_enqueue_storage s2 manual
sleep 0.01
rbv_enqueue_storage s1 manual
mapfile -t jobs < <(ls -1 "$(rbv_queue_dir)"/*.job | sort)
base1="$(basename "${jobs[0]}")"
base2="$(basename "${jobs[1]}")"
[[ "$base1" == *"_s2.job" ]] && pass "FIFO first=s2" || fail "FIFO" "$base1"
[[ "$base2" == *"_s1.job" ]] && pass "FIFO second=s1" || fail "FIFO2" "$base2"

# --- interval due ---
# last_run = now → not due; last_run = 2h ago → due for interval_hours=1
mkdir -p "$(rbv_work_dir)/locks"
date +%s > "$(rbv_work_dir)/locks/last_run_s2"
if rbv_storage_due s2; then fail "interval not due" "was due"; else pass "interval not due"; fi
echo $(( $(date +%s) - 7200 )) > "$(rbv_work_dir)/locks/last_run_s2"
if rbv_storage_due s2; then pass "interval due"; else fail "interval due" "not due"; fi

# --- times due only at matching HH:MM ---
# force a fake "now" by writing due marker logic: if current time is in list
now_hm="$(date +%H:%M)"
jq --arg t "$now_hm" '(.storages[]|select(.id=="s1")|.verify.times)=[$t]' \
  "$RBV_CONFIG" > "$T/c2.json" && mv "$T/c2.json" "$RBV_CONFIG"
rm -f "$(rbv_work_dir)/locks/due_s1_"*
if rbv_storage_due s1; then pass "times due now"; else fail "times due" "not"; fi
rbv_mark_due_done s1
if rbv_storage_due s1; then fail "times already marked" "still due"; else pass "times marked done"; fi

# --- remove ---
"$ROOT/bin/rw-backup-verify" storage remove s2 >/dev/null
n="$(jq '.storages|length' "$RBV_CONFIG")"
[[ "$n" == "1" ]] && pass "storage remove" || fail "remove" "n=$n"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
