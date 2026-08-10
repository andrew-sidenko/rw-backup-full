#!/usr/bin/env bash
# Smoke: classify, grouping, tested, global schedule — без Docker/S3.
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

# --- classify ---
out="$(rbv_classify_name 'remnawave_backup_2026-08-10_03_00_00.tar.gz')"
[[ "$out" == "panel|remnawave_backup" ]] && pass "classify panel" || fail "classify panel" "$out"

out="$(rbv_classify_name 'custom_bot_OneOkBotNew_20260810_030015.tar.gz')"
[[ "$out" == "bot|custom_bot_OneOkBotNew" ]] && pass "classify bot" || fail "classify bot" "$out"

out="$(rbv_classify_name 'custom_bot_vpnnew_20260810_030045.tar.gz.age')"
[[ "$out" == "bot|custom_bot_vpnnew" ]] && pass "classify bot age" || fail "classify bot age" "$out"

# --- storage + schedule ---
"$ROOT/bin/rw-backup-verify" storage add \
  --id s1 --bucket b --access-key a --secret-key s \
  --prefix rw-backup-full --backup-hint "прод 03:00" >/dev/null
"$ROOT/bin/rw-backup-verify" schedule set --interval-hours 6 >/dev/null
ih="$(jq -r '.verify.interval_hours' "$RBV_CONFIG")"
[[ "$ih" == "6" ]] && pass "global interval" || fail "global interval" "$ih"

"$ROOT/bin/rw-backup-verify" telegram set --token tok --chat-id 123 >/dev/null
pass "telegram set"

# --- tested registry ---
rbv_mark_tested s1 "rw-backup-full/panel/h1/remnawave_backup_1.tar.gz" true "run1"
if rbv_is_tested s1 "rw-backup-full/panel/h1/remnawave_backup_1.tar.gz"; then
  pass "is_tested yes"
else
  fail "is_tested yes" "false"
fi
if rbv_is_tested s1 "other-key"; then
  fail "is_tested no" "true"
else
  pass "is_tested no"
fi

# --- grouping logic (simulate discover awk path) ---
# parent A: two bots + two versions each; parent B: panel versions
# Expect latest per family
tmp="$(mktemp)"
{
  printf '%s\t%s\t%s\t%s\t%s\n' "p/A|custom_bot_bot1" "custom_bot_bot1_20260801_010000.tar.gz" "p/A/custom_bot_bot1_20260801_010000.tar.gz" "p/A" "bot"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/A|custom_bot_bot1" "custom_bot_bot1_20260810_030000.tar.gz" "p/A/custom_bot_bot1_20260810_030000.tar.gz" "p/A" "bot"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/A|custom_bot_bot2" "custom_bot_bot2_20260810_020000.tar.gz" "p/A/custom_bot_bot2_20260810_020000.tar.gz" "p/A" "bot"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/B|remnawave_backup" "remnawave_backup_2026-08-01_03_00_00.tar.gz" "p/B/remnawave_backup_2026-08-01_03_00_00.tar.gz" "p/B" "panel"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/B|remnawave_backup" "remnawave_backup_2026-08-10_03_00_00.tar.gz" "p/B/remnawave_backup_2026-08-10_03_00_00.tar.gz" "p/B" "panel"
} > "$tmp"
latest="$(sort -t$'\t' -k1,1 -k2,2 "$tmp" | awk -F'\t' '
  { g=$1; if (g!=prev){ if(prev!="") print last; prev=g } last=$0 }
  END { if(prev!="") print last }
')"
n="$(printf '%s\n' "$latest" | grep -c . || true)"
[[ "$n" == "3" ]] && pass "group count=3" || fail "group count" "n=$n"
printf '%s\n' "$latest" | grep -q 'custom_bot_bot1_20260810_030000' && pass "bot1 latest" || fail "bot1 latest" "missing"
printf '%s\n' "$latest" | grep -q 'custom_bot_bot2_20260810_020000' && pass "bot2 kept" || fail "bot2" "missing"
printf '%s\n' "$latest" | grep -q 'remnawave_backup_2026-08-10' && pass "panel latest" || fail "panel latest" "missing"
rm -f "$tmp"

# --- enqueue FIFO ---
rbv_enqueue_instance s1 bot "bot:p/A:custom_bot_bot1" "p/A/custom_bot_bot1_x.tar.gz" "p/A" manual
sleep 0.01
rbv_enqueue_instance s1 panel "panel:p/B:remnawave_backup" "p/B/remnawave_backup_x.tar.gz" "p/B" manual
mapfile -t jobs < <(ls -1 "$(rbv_queue_dir)"/*.job | sort)
[[ "$(jq -r .kind "${jobs[0]}")" == "bot" ]] && pass "FIFO first=bot" || fail "FIFO" "$(jq -r .kind "${jobs[0]}")"
[[ "$(jq -r .kind "${jobs[1]}")" == "panel" ]] && pass "FIFO second=panel" || fail "FIFO2" "bad"

# --- global due ---
mkdir -p "$(rbv_work_dir)/locks"
date +%s > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then fail "global not due" "was due"; else pass "global not due"; fi
echo $(( $(date +%s) - 7*3600 )) > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then pass "global due"; else fail "global due" "not"; fi

"$ROOT/bin/rw-backup-verify" schedule set --times "$(date +%H:%M)" >/dev/null
rm -f "$(rbv_work_dir)/locks/due_global_"*
# clear interval so times path used — schedule set replaces verify object
if rbv_global_due; then pass "times due"; else fail "times due" "not"; fi

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
