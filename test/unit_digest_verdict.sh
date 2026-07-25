#!/usr/bin/env bash
# unit_digest_verdict.sh — 🟢/🔴 вердикт сервера в status-digest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIG="${ROOT}/scripts/metrics/status-digest.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

NOW=$(date +%s)
fresh_wal=$((NOW - 600))       # 10м назад
stale_wal=$((NOW - 7200))      # 2ч назад
fresh_bb=$((NOW - 3600))
fresh_panel=$((NOW - 7200))

ok_json=$(jq -nc --argjson w "$fresh_wal" --argjson b "$fresh_bb" --argjson p "$fresh_panel" '{
  host:"v1", errors:0, components:"panel-backup wal",
  panel:{last_backup_ts:$p},
  wal_instances:[{name:"panel", last_wal_ts:$w, last_basebackup_ts:$b, timer_active:true, running:true, spool:0}],
  s3_backends:[{name:"cold", enabled:true, reachable:true}]
}')

stale_json=$(jq -nc --argjson w "$stale_wal" --argjson b "$fresh_bb" --argjson p "$fresh_panel" '{
  host:"v1", errors:0, components:"panel-backup wal",
  panel:{last_backup_ts:$p},
  wal_instances:[{name:"panel", last_wal_ts:$w, last_basebackup_ts:$b, timer_active:true, running:true, spool:0}],
  s3_backends:[{name:"cold", enabled:true, reachable:true}]
}')

set +e
out="$(DIGEST_WAL_STALE_SEC=3600 bash "$DIG" --verdict-test tyler-panel-1 v1 1 "$ok_json" 0 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 && "$out" == *"tyler-panel-1"* && "$out" != *"✗"* ]] && pass "healthy → green" || fail "healthy" "rc=$rc out=$out"

set +e
out="$(DIGEST_WAL_STALE_SEC=3600 bash "$DIG" --verdict-test tyler-panel-1 v1 1 "$stale_json" 0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 && "$out" == *"поток стоит"* && "$out" == *"✗"* ]] && pass "stale WAL → red" || fail "stale WAL" "rc=$rc out=$out"

set +e
out="$(bash "$DIG" --verdict-test tyler-panel-1 v1 0 '{}' 0 'timeout after 20s' 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 && "$out" == *"недоступен"* ]] && pass "SSH down → red" || fail "SSH down" "rc=$rc out=$out"

set +e
out="$(DIGEST_WAL_STALE_SEC=3600 bash "$DIG" --verdict-test tyler-panel-1 v1 1 "$ok_json" 2 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 && "$out" == *"проверки песочницы"* ]] && pass "verify fails → red" || fail "verify fails" "rc=$rc out=$out"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
