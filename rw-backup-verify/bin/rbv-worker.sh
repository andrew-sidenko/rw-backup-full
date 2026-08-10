#!/usr/bin/env bash
# Очередь: каждый .job = один экземпляр (latest untested archive).
# Выполняются строго по одному (FIFO).
set -euo pipefail
_self="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

rbv_load_config
WD="$(rbv_work_dir)"
QD="$(rbv_queue_dir)"

if ! rbv_queue_lock; then
  msg INFO "Воркер уже работает — выход"
  exit 0
fi

shopt -s nullglob
jobs=("$QD"/*.job)
if [[ ${#jobs[@]} -eq 0 ]]; then
  exit 0
fi

IFS=$'\n' sorted=($(printf '%s\n' "${jobs[@]}" | sort)); unset IFS

for job in "${sorted[@]}"; do
  [[ -f "$job" ]] || continue
  sid="$(jq -r '.storage' "$job")"
  kind="$(jq -r '.kind' "$job")"
  inst="$(jq -r '.instance' "$job")"
  key="$(jq -r '.key' "$job")"
  parent="$(jq -r '.parent // empty' "$job")"
  reason="$(jq -r '.reason // "queue"' "$job")"
  msg INFO "=== job $(basename "$job") ${sid} ${kind} ${inst} ==="
  msg INFO "key=${key} reason=${reason}"

  # ключ в S3 может быть с prefix; rbv-run-one ждёт полный key относительно bucket
  set +e
  "${SCRIPT_DIR}/rbv-run-one.sh" "$sid" "$kind" "$inst" "$key" "$parent"
  rc=$?
  set -e
  ok_json=false
  (( rc == 0 )) && ok_json=true
  run_id="$(ls -1dt "${WD}/runs/"* 2>/dev/null | head -n1 | xargs -r basename || true)"
  rbv_mark_tested "$sid" "$key" "$ok_json" "${run_id:-}"
  msg INFO "← rc=${rc} marked tested"
  rm -f "$job"
done

msg OK "Очередь пуста"
