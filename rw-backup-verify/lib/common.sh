#!/usr/bin/env bash
# Общие функции rw-backup-verify (source).
set -euo pipefail

[[ -n "${__RBV_LIB:-}" ]] && return 0
__RBV_LIB=1

RBV_INSTALL_DIR="${RBV_INSTALL_DIR:-/opt/rw-backup-verify}"
RBV_CONFIG="${RBV_CONFIG:-/etc/rw-backup-verify/config.json}"
# RBV_WORK_DIR / RBV_STATE_DIR — опциональные оверрайды (тесты/отладка).

msg() {
  local t="$1"; shift
  local c=""
  case "$t" in
    INFO) c=$'\e[36m' ;;
    OK)   c=$'\e[32m' ;;
    WARN) c=$'\e[33m' ;;
    ERR)  c=$'\e[31m' ;;
  esac
  printf '%s[%s]%s %s\n' "$c" "$t" $'\e[0m' "$*" >&2
  if [[ -n "${RBV_LOG:-}" ]]; then
    # без ANSI в файл
    printf '[%s] %s\n' "$t" "$*" >>"$RBV_LOG" 2>/dev/null || true
  fi
}

need() { command -v "$1" >/dev/null 2>&1 || { msg ERR "Нужен $1"; exit 1; }; }

rbv_load_config() {
  [[ -f "$RBV_CONFIG" ]] || { msg ERR "Нет конфига: $RBV_CONFIG"; exit 1; }
  need jq
}

rbv_cfg() { jq -r "$1" "$RBV_CONFIG"; }

rbv_work_dir() {
  local d
  if [[ -n "${RBV_WORK_DIR:-}" ]]; then
    d="$RBV_WORK_DIR"
  elif [[ -n "${RBV_STATE_DIR:-}" ]]; then
    d="$RBV_STATE_DIR"
  else
    d="$(rbv_cfg '.work_dir // "/var/lib/rw-backup-verify"')"
  fi
  mkdir -p "$d"/{queue,runs,locks,cache,tested}
  printf '%s\n' "$d"
}

# --- Telegram ---------------------------------------------------------------

rbv_tg_send() {
  local token="$1" chat="$2" text="$3" thread="${4:-}"
  [[ -n "$token" && -n "$chat" ]] || return 0
  need curl
  local -a form=(-F "chat_id=${chat}" -F "text=${text}" -F "parse_mode=HTML")
  [[ -n "$thread" ]] && form+=(-F "message_thread_id=${thread}")
  local a
  for a in 1 2 3; do
    curl -sS -m 25 "https://api.telegram.org/bot${token}/sendMessage" \
      "${form[@]}" >/dev/null 2>&1 && return 0
    sleep $((a * 2))
  done
  msg WARN "Telegram: не удалось отправить"
  return 0
}

rbv_tg_for_storage() {
  local sid="$1"
  local tok chat thr
  tok="$(jq -r --arg id "$sid" '
    (.storages[] | select(.id==$id) | .telegram.token // empty) as $t
    | if ($t|length)>0 then $t else (.telegram.token // "") end
  ' "$RBV_CONFIG")"
  chat="$(jq -r --arg id "$sid" '
    (.storages[] | select(.id==$id) | .telegram.chat_id // empty) as $c
    | if ($c|length)>0 then $c else (.telegram.chat_id // "") end
  ' "$RBV_CONFIG")"
  thr="$(jq -r --arg id "$sid" '
    (.storages[] | select(.id==$id) | .telegram.thread_id // empty) as $h
    | if ($h|length)>0 then $h else (.telegram.thread_id // "") end
  ' "$RBV_CONFIG")"
  printf '%s|%s|%s\n' "$tok" "$chat" "$thr"
}

# --- S3 helpers -------------------------------------------------------------

rbv_storage_json() {
  local sid="$1" j
  # jq select по пустому совпадению даёт exit 0 и пустой stdout — проверяем явно.
  j="$(jq -c --arg id "$sid" '.storages[] | select(.id==$id)' "$RBV_CONFIG" 2>/dev/null || true)"
  if [[ -z "$j" ]]; then
    msg ERR "Хранилище не найдено: $sid"
    exit 1
  fi
  printf '%s\n' "$j"
}

rbv_aws_env() {
  local j="$1"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_EC2_METADATA_DISABLED
  AWS_ACCESS_KEY_ID="$(jq -r '.access_key' <<<"$j")"
  AWS_SECRET_ACCESS_KEY="$(jq -r '.secret_key' <<<"$j")"
  AWS_DEFAULT_REGION="$(jq -r '.region // "us-east-1"' <<<"$j")"
  AWS_EC2_METADATA_DISABLED=true
  local ep
  ep="$(jq -r '.endpoint // empty' <<<"$j")"
  RBV_AWS_ENDPOINT=()
  [[ -n "$ep" ]] && RBV_AWS_ENDPOINT=(--endpoint-url "$ep")
  RBV_BUCKET="$(jq -r '.bucket' <<<"$j")"
  RBV_PREFIX="$(jq -r '.prefix // ""' <<<"$j" | sed 's:/*$::')"
}

rbv_aws() {
  need aws
  aws "${RBV_AWS_ENDPOINT[@]}" "$@"
}

# Классификация имени файла → kind|family
# kind: panel|bot
# family: remnawave_backup | custom_bot_<ProjectSafe>
# (family = экземпляр внутри одной папки; у ботов проект в имени файла)
rbv_classify_name() {
  local name="$1"
  if [[ "$name" =~ ^remnawave_backup_.*\.tar\.gz(\.age)?$ ]]; then
    printf 'panel|remnawave_backup\n'
    return 0
  fi
  if [[ "$name" =~ ^custom_bot_(.+)_([0-9]{8}_[0-9]{6})\.tar\.gz(\.age)?$ ]]; then
    local fam="${BASH_REMATCH[1]}"
    # custom_bot_foo__20260810_… → fam=foo_ → убрать хвостовые _
    fam="$(sed -E 's/_+$//' <<<"$fam")"
    printf 'bot|custom_bot_%s\n' "$fam"
    return 0
  fi
  # fallback: custom_bot_X_... без строгого TS
  if [[ "$name" =~ ^custom_bot_(.+)\.tar\.gz(\.age)?$ ]]; then
    local stem="${BASH_REMATCH[1]}"
    # убрать хвостовой _YYYYMMDD_HHMMSS если есть
    stem="$(sed -E 's/_[0-9]{8}_[0-9]{6}$//' <<<"$stem")"
    stem="$(sed -E 's/_+$//' <<<"$stem")"
    printf 'bot|custom_bot_%s\n' "$stem"
    return 0
  fi
  return 1
}

# Рекурсивный листинг архивов под prefix.
# stdout lines: relative_key (от корня bucket, без s3://)
# Учитывает и корень prefix, и любую вложенность.
# Ошибки aws НЕ глотаем — иначе run выглядит как «ничего не произошло».
rbv_list_all_archive_keys() {
  local base="${RBV_PREFIX}"
  local uri="s3://${RBV_BUCKET}/"
  [[ -n "$base" ]] && uri="s3://${RBV_BUCKET}/${base}/"
  local err out rc
  err="$(mktemp)"; out="$(mktemp)"
  set +e
  rbv_aws s3 ls "$uri" --recursive >"$out" 2>"$err"
  rc=$?
  set -e
  if (( rc != 0 )); then
    msg ERR "S3 ls ${uri} rc=${rc}: $(tr '\n' ' ' <"$err" | head -c 400)"
    rm -f "$err" "$out"
    return 1
  fi
  local n
  n="$(wc -l <"$out" | tr -d ' ')"
  msg INFO "S3 ls ${uri} — объектов: ${n}"
  awk '{print $4}' "$out" \
    | grep -E '(^|/)(remnawave_backup_|custom_bot_)[^/]*\.tar\.gz(\.age)?$' \
    || true
  rm -f "$err" "$out"
}

# Discover: для каждого экземпляра (папка + family) — latest архив.
# stdout: kind|instance_id|s3_key|parent_dir
# instance_id стабилен: "<kind>:<parent_dir>:<family>"
# untested_only=true: пропустить уже протестированные ключи
rbv_discover() {
  local sid="$1"
  local untested_only="${2:-false}"
  local j key name parent kind family inst
  j="$(rbv_storage_json "$sid")"
  rbv_aws_env "$j"

  local tmp keys_file
  tmp="$(mktemp)"
  keys_file="$(mktemp)"
  if ! rbv_list_all_archive_keys >"$keys_file"; then
    rm -f "$tmp" "$keys_file"
    return 1
  fi

  local arch_n=0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    arch_n=$((arch_n + 1))
    name="$(basename "$key")"
    parent="$(dirname "$key")"
    [[ "$parent" == "." ]] && parent=""
    kind=""; family=""
    IFS='|' read -r kind family < <(rbv_classify_name "$name" || true)
    [[ -n "$kind" ]] || continue
    # sortkey = имя файла (TS в имени → лексикографический latest корректен)
    printf '%s\t%s\t%s\t%s\t%s\n' "${parent}|${family}" "$name" "$key" "$parent" "$kind" >> "$tmp"
  done <"$keys_file"
  rm -f "$keys_file"

  if [[ ! -s "$tmp" ]]; then
    msg WARN "Discover ${sid}: архивов panel/bot не найдено (ключей по маске=${arch_n})"
    rm -f "$tmp"
    return 0
  fi

  local latest_file
  latest_file="$(mktemp)"
  sort -t$'\t' -k1,1 -k2,2 "$tmp" \
    | awk -F'\t' '
      {
        g=$1
        if (g != prev) {
          if (prev != "") print last
          prev=g
        }
        last=$0
      }
      END { if (prev != "") print last }
    ' >"$latest_file"
  rm -f "$tmp"

  local out_n=0 skip_n=0
  while IFS=$'\t' read -r _grp name key parent kind; do
    [[ -n "${key:-}" ]] || continue
    family="$(rbv_classify_name "$name" | cut -d'|' -f2)"
    inst="${kind}:${parent}:${family}"
    if [[ "$untested_only" == "true" ]] && rbv_is_tested "$sid" "$key"; then
      skip_n=$((skip_n + 1))
      msg INFO "skip tested: ${key}"
      continue
    fi
    out_n=$((out_n + 1))
    printf '%s|%s|%s|%s\n' "$kind" "$inst" "$key" "$parent"
  done <"$latest_file"
  rm -f "$latest_file"

  msg INFO "Discover ${sid}: latest=${out_n} skip_tested=${skip_n} (untested_only=${untested_only})"
}

# --- Tested registry --------------------------------------------------------

rbv_tested_file() {
  printf '%s/tested/%s.json\n' "$(rbv_work_dir)" "$1"
}

rbv_is_tested() {
  local sid="$1" key="$2"
  local f
  f="$(rbv_tested_file "$sid")"
  [[ -f "$f" ]] || return 1
  jq -e --arg k "$key" '.[$k] != null' "$f" >/dev/null 2>&1
}

rbv_mark_tested() {
  local sid="$1" key="$2" ok="$3" run_id="${4:-}"
  local f tmp
  f="$(rbv_tested_file "$sid")"
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || echo '{}' > "$f"
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson ok "$ok" --arg r "$run_id" --argjson ts "$(date +%s)" \
    '.[$k] = {ok:$ok, tested_at:$ts, run_id:$r}' "$f" > "$tmp"
  mv -f "$tmp" "$f"
}

# --- Global schedule --------------------------------------------------------

# Глобальная частота (не per-storage):
#   verify.interval_hours  ИЛИ  verify.times ["HH:MM",...]
# fallback: interval_hours=12
rbv_global_due() {
  local now_epoch now_hm last interval times t
  now_epoch="$(date +%s)"
  now_hm="$(date +%H:%M)"
  local marker
  marker="$(rbv_work_dir)/locks/last_run_global"
  last=0
  [[ -f "$marker" ]] && last="$(cat "$marker" 2>/dev/null || echo 0)"

  interval="$(rbv_cfg '.verify.interval_hours // empty')"
  if [[ -n "$interval" && "$interval" != "null" && "$interval" != "" ]]; then
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || {
      msg ERR "verify.interval_hours должно быть целым > 0 (сейчас: ${interval})"
      return 1
    }
    local need=$(( interval * 3600 ))
    (( now_epoch - last >= need )) && return 0
    return 1
  fi

  times="$(jq -r '.verify.times // [] | .[]' "$RBV_CONFIG" 2>/dev/null || true)"
  if [[ -z "$times" ]]; then
    # дефолт: каждые 12ч
    (( now_epoch - last >= 43200 )) && return 0
    return 1
  fi
  while IFS= read -r t; do
    [[ "$t" == "$now_hm" ]] || continue
    local stamp done_m
    stamp="$(date +%Y%m%d%H%M)"
    done_m="$(rbv_work_dir)/locks/due_global_${stamp}"
    [[ -f "$done_m" ]] && return 1
    return 0
  done <<<"$times"
  return 1
}

rbv_mark_global_done() {
  local stamp
  stamp="$(date +%Y%m%d%H%M)"
  date +%s > "$(rbv_work_dir)/locks/last_run_global"
  : > "$(rbv_work_dir)/locks/due_global_${stamp}"
}

rbv_queue_dir() { printf '%s/queue\n' "$(rbv_work_dir)"; }

# Job = один экземпляр (архив) для теста. FIFO по timestamp в имени файла.
rbv_enqueue_instance() {
  local sid="$1" kind="$2" inst="$3" key="$4" parent="$5" reason="${6:-manual}"
  local qd ts f safe
  qd="$(rbv_queue_dir)"
  mkdir -p "$qd"
  ts="$(date +%s%N)"
  safe="$(printf '%s' "$inst" | tr '/:' '__')"
  f="${qd}/${ts}_${sid}_${safe}.job"
  jq -nc \
    --arg sid "$sid" --arg kind "$kind" --arg inst "$inst" \
    --arg key "$key" --arg parent "$parent" --arg reason "$reason" \
    --argjson enq "$(date +%s)" \
    '{storage:$sid,kind:$kind,instance:$inst,key:$key,parent:$parent,reason:$reason,enqueued_at:$enq}' \
    > "$f"
  msg INFO "В очередь: ${sid} ${kind} ${inst} → $(basename "$f")"
}

# Обход всех хранилищ: discover untested latest → enqueue
rbv_enqueue_all_untested() {
  local reason="${1:-schedule}"
  local sid
  mapfile -t ids < <(jq -r '.storages[].id' "$RBV_CONFIG")
  for sid in "${ids[@]}"; do
    msg INFO "Discover ${sid} (deep, untested latest)…"
    while IFS='|' read -r kind inst key parent; do
      [[ -n "$key" ]] || continue
      rbv_enqueue_instance "$sid" "$kind" "$inst" "$key" "$parent" "$reason"
    done < <(rbv_discover "$sid" true)
  done
}

rbv_queue_lock() {
  local lock
  lock="$(rbv_work_dir)/locks/worker.lock"
  exec 9>"$lock"
  flock -n 9 || return 1
  return 0
}

# --- Config mutate ----------------------------------------------------------

rbv_save_config() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; msg ERR "Битый JSON"; exit 1; }
  mv -f "$tmp" "$RBV_CONFIG"
  chmod 600 "$RBV_CONFIG"
}
