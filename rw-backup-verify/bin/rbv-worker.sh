#!/usr/bin/env bash
# Очередь: берёт .job из queue/, для каждого storage — discover + run-one по проектам.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Сортировка по имени = FIFO (timestamp prefix)
IFS=$'\n' sorted=($(printf '%s\n' "${jobs[@]}" | sort)); unset IFS

for job in "${sorted[@]}"; do
  [[ -f "$job" ]] || continue
  sid="$(jq -r '.storage' "$job")"
  reason="$(jq -r '.reason // "queue"' "$job")"
  msg INFO "=== job $(basename "$job") storage=${sid} reason=${reason} ==="
  mapfile -t lines < <(rbv_discover "$sid" || true)
  if [[ ${#lines[@]} -eq 0 ]]; then
    msg WARN "Нет архивов в ${sid}"
    TG="$(rbv_tg_for_storage "$sid")"
    IFS='|' read -r TOK CHAT THREAD <<<"$TG"
    rbv_tg_send "$TOK" "$CHAT" "⚪ verify ${sid}: проектов/архивов не найдено" "$THREAD"
  else
    for line in "${lines[@]}"; do
      IFS='|' read -r cat src key <<<"$line"
      msg INFO "→ ${cat}/${src}/${key}"
      set +e
      "${SCRIPT_DIR}/rbv-run-one.sh" "$sid" "$cat" "$src" "$key"
      rc=$?
      set -e
      msg INFO "← ${cat}/${src} rc=${rc}"
    done
  fi
  rm -f "$job"
  rbv_mark_due_done "$sid"
done

msg OK "Очередь пуста"
