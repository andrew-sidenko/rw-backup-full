#!/usr/bin/env bash
# Общие функции rw-backup-verify (source).
set -euo pipefail

[[ -n "${__RBV_LIB:-}" ]] && return 0
__RBV_LIB=1

RBV_INSTALL_DIR="${RBV_INSTALL_DIR:-/opt/rw-backup-verify}"
RBV_CONFIG="${RBV_CONFIG:-/etc/rw-backup-verify/config.json}"
# RBV_WORK_DIR / RBV_STATE_DIR — опциональные оверрайды (тесты/отладка).
# Не задаём дефолт здесь, иначе перекрывается work_dir из config.json.

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
  mkdir -p "$d"/{queue,runs,locks,cache}
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
  # stdout: token|chat|thread
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
  local sid="$1"
  jq -c --arg id "$sid" '.storages[] | select(.id==$id)' "$RBV_CONFIG" \
    || { msg ERR "Хранилище не найдено: $sid"; exit 1; }
}

rbv_aws_env() {
  # export AWS_* from storage json on stdin / $1 json string
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
  RBV_PREFIX="$(jq -r '.prefix // "rw-backup-full"' <<<"$j" | sed 's:/*$::')"
}

rbv_aws() {
  need aws
  aws "${RBV_AWS_ENDPOINT[@]}" "$@"
}

# List sources under <prefix>/<category>/
rbv_list_sources() {
  local category="$1"
  local pref="${RBV_PREFIX}/${category}/"
  rbv_aws s3 ls "s3://${RBV_BUCKET}/${pref}" 2>/dev/null \
    | awk '/PRE/ {print $2}' | tr -d '/' | grep -v '^$' || true
}

# List object keys (files) under <prefix>/<category>/<source>/
rbv_list_archives() {
  local category="$1" source="$2"
  local pref="${RBV_PREFIX}/${category}/${source}/"
  rbv_aws s3 ls "s3://${RBV_BUCKET}/${pref}" 2>/dev/null \
    | awk '/\.tar\.gz(\.age)?$/ {print $4}' \
    | grep -E '^(remnawave_backup_|custom_bot_)' || true
}

rbv_latest_archive() {
  local category="$1" source="$2"
  rbv_list_archives "$category" "$source" | sort | tail -n1
}

# Discover jobs: lines "category|source|key"
rbv_discover() {
  local sid="$1"
  local j cats cat src key
  j="$(rbv_storage_json "$sid")"
  rbv_aws_env "$j"
  cats="$(jq -r '.categories // ["panel","custom-bot"] | join(" ")' <<<"$j")"
  local filter_sources
  filter_sources="$(jq -r '.sources // empty | if .==null or .==[] then empty else join(" ") end' <<<"$j")"
  for cat in $cats; do
    while IFS= read -r src; do
      [[ -n "$src" ]] || continue
      if [[ -n "$filter_sources" ]]; then
        [[ " $filter_sources " == *" $src "* ]] || continue
      fi
      key="$(rbv_latest_archive "$cat" "$src")"
      [[ -n "$key" ]] || continue
      printf '%s|%s|%s\n' "$cat" "$src" "$key"
    done < <(rbv_list_sources "$cat")
  done
}

# --- Schedule / queue -------------------------------------------------------

# Is storage due now? Uses last_run marker + times/interval_hours.
rbv_storage_due() {
  local sid="$1"
  local j now_hm now_epoch last interval times t
  j="$(rbv_storage_json "$sid")"
  now_epoch="$(date +%s)"
  now_hm="$(date +%H:%M)"
  local marker
  marker="$(rbv_work_dir)/locks/last_run_${sid}"
  last=0
  [[ -f "$marker" ]] && last="$(cat "$marker" 2>/dev/null || echo 0)"
  interval="$(jq -r '.verify.interval_hours // empty' <<<"$j")"
  if [[ -n "$interval" && "$interval" != "null" ]]; then
    local need=$(( interval * 3600 ))
    (( now_epoch - last >= need )) && return 0
    return 1
  fi
  # times: ["06:30","18:30"] — due if current HH:MM matches and not yet run in this minute window
  times="$(jq -r '.verify.times // [] | .[]' <<<"$j")"
  [[ -n "$times" ]] || return 1
  while IFS= read -r t; do
    [[ "$t" == "$now_hm" ]] || continue
    # уже запускали в эту минуту?
    local stamp
    stamp="$(date +%Y%m%d%H%M)"
    local done_m
    done_m="$(rbv_work_dir)/locks/due_${sid}_${stamp}"
    [[ -f "$done_m" ]] && return 1
    return 0
  done <<<"$times"
  return 1
}

rbv_mark_due_done() {
  local sid="$1"
  local stamp
  stamp="$(date +%Y%m%d%H%M)"
  date +%s > "$(rbv_work_dir)/locks/last_run_${sid}"
  : > "$(rbv_work_dir)/locks/due_${sid}_${stamp}"
}

rbv_queue_dir() { printf '%s/queue\n' "$(rbv_work_dir)"; }

# Enqueue a storage run (one file = one storage sweep). Sequential worker.
rbv_enqueue_storage() {
  local sid="$1" reason="${2:-manual}"
  local qd ts f
  qd="$(rbv_queue_dir)"
  mkdir -p "$qd"
  ts="$(date +%s%N)"
  f="${qd}/${ts}_${sid}.job"
  printf '{"storage":"%s","reason":"%s","enqueued_at":%s}\n' \
    "$sid" "$reason" "$(date +%s)" > "$f"
  msg INFO "В очередь: ${sid} (${reason}) → $(basename "$f")"
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
