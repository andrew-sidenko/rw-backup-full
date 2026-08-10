#!/usr/bin/env bash
# Проверки экземпляра: toggles, baseline, rows/events, stability, ports, TG-отчёт.
# Source после common.sh.
set -euo pipefail

[[ -n "${__RBV_CHECKS:-}" ]] && return 0
__RBV_CHECKS=1

# --- toggles ----------------------------------------------------------------

rbv_check_enabled() {
  # rbv_check_enabled <kind> <name>  → 0 если включено (default true)
  # Важно: jq `false // x` даёт x — нельзя использовать // для булевых.
  # Алиасы (старые имена → новые): db_rows|user_rows_monotonic→user_rows,
  # stack_up|stability→stack.
  local kind="$1" name="$2"
  local names=("$name")
  case "$name" in
    user_rows) names=(user_rows user_rows_monotonic db_rows) ;;
    stack)     names=(stack stack_up stability) ;;
  esac
  local n v
  for n in "${names[@]}"; do
    v="$(jq -r --arg k "$kind" --arg n "$n" '
      if (.checks[$k] | type)=="object" and (.checks[$k] | has($n)) then .checks[$k][$n]|tostring
      elif (.checks.default | type)=="object" and (.checks.default | has($n)) then .checks.default[$n]|tostring
      else "__missing__" end
    ' "$RBV_CONFIG" 2>/dev/null || echo "__missing__")"
    if [[ "$v" != "__missing__" ]]; then
      case "$v" in
        false|FALSE|0|no|off) return 1 ;;
        *) return 0 ;;
      esac
    fi
  done
  # ни одного ключа нет — default on
  return 0
}

rbv_skew_sec() {
  local h
  h="$(jq -r '.checks.timezone_skew_hours // 14' "$RBV_CONFIG" 2>/dev/null || echo 14)"
  [[ "$h" =~ ^[0-9]+$ ]] || h=14
  echo $(( h * 3600 ))
}

rbv_stability_sec() {
  local s
  s="$(jq -r '.checks.stability_seconds // 180' "$RBV_CONFIG" 2>/dev/null || echo 180)"
  [[ "$s" =~ ^[0-9]+$ ]] || s=180
  echo "$s"
}

# --- archive timestamp from filename (epoch, UTC best-effort) ---------------

rbv_parse_archive_epoch() {
  local name="$1" y m d H M S
  # remnawave_backup_2026-08-10_03_00_00.tar.gz
  if [[ "$name" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})_([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    H="${BASH_REMATCH[4]}"; M="${BASH_REMATCH[5]}"; S="${BASH_REMATCH[6]}"
    date -u -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null && return 0
  fi
  # custom_bot_X_20260810_030015.tar.gz
  if [[ "$name" =~ _([0-9]{8})_([0-9]{6})\.tar\.gz ]]; then
    local ds="${BASH_REMATCH[1]}" ts="${BASH_REMATCH[2]}"
    y="${ds:0:4}"; m="${ds:4:2}"; d="${ds:6:2}"
    H="${ts:0:2}"; M="${ts:2:2}"; S="${ts:4:2}"
    date -u -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null && return 0
  fi
  echo 0
}

# --- baseline per instance --------------------------------------------------

rbv_baseline_path() {
  local sid="$1" inst="$2"
  local safe
  safe="$(printf '%s' "$inst" | sha256sum | awk '{print $1}')"
  printf '%s/baselines/%s/%s.json\n' "$(rbv_work_dir)" "$sid" "$safe"
}

rbv_baseline_load() {
  local f
  f="$(rbv_baseline_path "$1" "$2")"
  [[ -f "$f" ]] || { echo '{}'; return 0; }
  cat "$f"
}

rbv_baseline_save() {
  local sid="$1" inst="$2" json="$3"
  local f dir
  f="$(rbv_baseline_path "$sid" "$inst")"
  dir="$(dirname "$f")"
  mkdir -p "$dir"
  printf '%s\n' "$json" > "$f"
}

# --- DB helpers (PG_CID must be set; RBV_PG_DB — целевая БД после restore) -

rbv_psql() {
  docker exec "$PG_CID" psql -U postgres -d "${RBV_PG_DB:-postgres}" -Atc "$1" 2>/dev/null || true
}

# Выбрать БД с пользовательскими таблицами (дампы ботов часто не в postgres).
# $1 — подсказка (POSTGRES_DB из PROFILE.env). stdout: число таблиц; RBV_PG_DB выставляется.
rbv_select_app_db() {
  local hint="${1:-}" db tables
  RBV_PG_DB="postgres"
  _rbv_db_tables() {
    docker exec "$PG_CID" psql -U postgres -d "$1" -Atc \
      "SELECT count(*) FROM pg_stat_user_tables" 2>/dev/null | tr -d '[:space:]' || echo 0
  }
  if [[ -n "$hint" ]]; then
    tables="$(_rbv_db_tables "$hint")"
    if [[ "$tables" =~ ^[0-9]+$ ]] && (( tables > 0 )); then
      RBV_PG_DB="$hint"
      printf '%s\n' "$tables"
      return 0
    fi
  fi
  tables="$(_rbv_db_tables postgres)"
  if [[ "$tables" =~ ^[0-9]+$ ]] && (( tables > 0 )); then
    RBV_PG_DB="postgres"
    printf '%s\n' "$tables"
    return 0
  fi
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    tables="$(_rbv_db_tables "$db")"
    if [[ "$tables" =~ ^[0-9]+$ ]] && (( tables > 0 )); then
      RBV_PG_DB="$db"
      printf '%s\n' "$tables"
      return 0
    fi
  done < <(docker exec "$PG_CID" psql -U postgres -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1" 2>/dev/null || true)
  printf '0\n'
}

rbv_find_users_table() {
  # stdout: schema.table or empty
  local t
  for t in public.users users public.user user public."User"; do
    local c
    c="$(rbv_psql "SELECT to_regclass('${t}');")"
    [[ -n "$c" && "$c" != "" ]] && { echo "$c"; return 0; }
  done
  # fuzzy
  t="$(rbv_psql "SELECT quote_ident(schemaname)||'.'||quote_ident(relname) FROM pg_stat_user_tables WHERE relname ILIKE '%user%' ORDER BY n_live_tup DESC NULLS LAST LIMIT 1;")"
  [[ -n "$t" ]] && echo "$t"
}

rbv_count_table() {
  local tbl="$1"
  local n
  n="$(rbv_psql "SELECT count(*) FROM ${tbl};")"
  n="$(echo "$n" | tr -d '[:space:]')"
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# Max epoch of "event-like" columns (best-effort по известным таблицам/полям).
rbv_max_event_epoch() {
  local epoch=0 cand e
  for cand in \
    "SELECT EXTRACT(EPOCH FROM MAX(updated_at))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(created_at))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(\"updatedAt\"))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(\"createdAt\"))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(last_online))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(updated_at))::bigint FROM nodes" \
    "SELECT EXTRACT(EPOCH FROM MAX(created_at))::bigint FROM nodes"
    do
    e="$(rbv_psql "$cand;" 2>/dev/null | tr -d '[:space:]')"
    [[ "$e" =~ ^[0-9]+$ ]] || continue
    (( e > epoch )) && epoch=$e
  done
  echo "$epoch"
}

# --- check results accumulator (JSON lines file) ----------------------------

rbv_checks_init() {
  RBV_CHECKS_FILE="${1:?}"
  echo '[]' > "$RBV_CHECKS_FILE"
}

rbv_check_add() {
  # name status detail [prev] [curr]
  local name="$1" status="$2" detail="$3" prev="${4:-}" curr="${5:-}"
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$status" --arg d "$detail" --arg p "$prev" --arg c "$curr" \
    '. + [{name:$n, status:$s, detail:$d, prev:$p, curr:$c}]' \
    "$RBV_CHECKS_FILE" > "$tmp"
  mv -f "$tmp" "$RBV_CHECKS_FILE"
}

# --- stack probes -----------------------------------------------------------

rbv_check_isolation() {
  local sample="$1"
  [[ -n "$sample" ]] || { rbv_check_add isolation skip "нет контейнера"; return 0; }
  if docker exec "$sample" getent hosts api.telegram.org >/dev/null 2>&1 \
     || docker exec "$sample" getent hosts 1.1.1.1 >/dev/null 2>&1; then
    rbv_check_add isolation fail "внешний DNS резолвится (сеть не internal?)"
    return 1
  fi
  # docker network inspect Internal flag
  if [[ -n "${NET_NAME:-}" ]]; then
    local inn
    inn="$(docker network inspect -f '{{.Internal}}' "$NET_NAME" 2>/dev/null || echo false)"
    if [[ "$inn" != "true" ]]; then
      rbv_check_add isolation fail "network.Internal=${inn}"
      return 1
    fi
  fi
  rbv_check_add isolation ok "internal, без внешнего DNS"
  return 0
}

rbv_check_stability() {
  local project="$1" compose="$2" sec="$3"
  local end now running crashed
  end=$(( $(date +%s) + sec ))
  local interval=15
  (( sec < 30 )) && interval=5
  msg INFO "stability: окно ${sec}с, интервал ${interval}с"
  while :; do
    now="$(date +%s)"
    (( now >= end )) && break
    running="$(docker compose -f "$compose" -p "$project" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
    crashed="$(docker compose -f "$compose" -p "$project" ps --status exited --status dead -q 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${crashed:-0}" -gt 0 ]]; then
      rbv_check_add stack fail "упали контейнеры: exited/dead=${crashed}, running=${running}"
      return 1
    fi
    if [[ "${running:-0}" -lt 1 ]]; then
      rbv_check_add stack fail "нет running-контейнеров"
      return 1
    fi
    msg INFO "stability: ещё ~$(( end - now ))с, running=${running}"
    sleep "$interval"
  done
  running="$(docker compose -f "$compose" -p "$project" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
  rbv_check_add stack ok "поднят, без падений ${sec}с, running=${running}"
  return 0
}

rbv_check_backend_ports() {
  # Probe internal service ports from compose.raw.json / running containers.
  local net="$1" compose_raw="$2" project="$3"
  local probe="rbv_probe_${RUN_ID}"
  docker rm -f "$probe" >/dev/null 2>&1 || true
  if ! docker run -d --name "$probe" --network "$net" \
       busybox:1.36 sleep 600 >/dev/null 2>&1; then
    rbv_check_add backend_ports skip "busybox недоступен"
    return 0
  fi
  local ok_n=0 fail_n=0 detail="" targets=""
  # Collect service:port from compose (container ports even if unpublished)
  targets="$(jq -r '
    .services // {} | to_entries[] |
    .key as $s |
    (.value.ports // [])[]? |
    (if type=="object" then (.target // .Published // empty|tostring)
     elif type=="string" then (capture("(?<p>[0-9]+)$") | .p // empty)
     else empty end) as $p |
    select($p != null and $p != "") |
    "\($s):\($p)"
  ' "$compose_raw" 2>/dev/null | sort -u | head -n 20 || true)"

  # Also from docker inspect ExposedPorts of running containers
  if [[ -z "$targets" ]]; then
    local cid
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      local name ports
      name="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$cid" 2>/dev/null || true)"
      [[ -z "$name" ]] && name="$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
      ports="$(docker inspect -f '{{range $p,$c := .Config.ExposedPorts}}{{$p}} {{end}}' "$cid" 2>/dev/null || true)"
      for p in $ports; do
        p="${p%%/*}"
        [[ "$p" =~ ^[0-9]+$ ]] && targets+="${name}:${p}"$'\n'
      done
    done < <(docker compose -f "${COMPOSE_FILE}" -p "$project" ps -q 2>/dev/null || true)
  fi

  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    local host="${t%%:*}" port="${t##*:}"
    local out=""
    # TCP ping via busybox nc, then HTTP GET
    if docker exec "$probe" nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
      out="$(docker exec "$probe" wget -qO- -T 3 "http://${host}:${port}/" 2>/dev/null \
            || docker exec "$probe" wget -qO- -T 3 "http://${host}:${port}/health" 2>/dev/null \
            || docker exec "$probe" wget -qO- -T 3 "http://${host}:${port}/api" 2>/dev/null \
            || echo "__TCP_OK__")"
      if [[ -n "$out" ]]; then
        ok_n=$((ok_n+1))
        detail+="✅ ${t} "
      else
        fail_n=$((fail_n+1))
        detail+="❌ ${t}:empty "
      fi
    else
      fail_n=$((fail_n+1))
      detail+="❌ ${t}:closed "
    fi
  done <<<"$targets"

  docker rm -f "$probe" >/dev/null 2>&1 || true

  if [[ -z "$targets" ]]; then
    rbv_check_add backend_ports skip "порты не обнаружены"
    return 0
  fi
  if (( fail_n > 0 && ok_n == 0 )); then
    rbv_check_add backend_ports fail "ok=${ok_n} fail=${fail_n} · ${detail}"
    return 1
  fi
  if (( fail_n > 0 )); then
    rbv_check_add backend_ports warn "ok=${ok_n} fail=${fail_n} · ${detail}"
    return 0
  fi
  rbv_check_add backend_ports ok "ok=${ok_n} · ${detail}"
  return 0
}

# --- Telegram formatting ----------------------------------------------------

rbv_status_icon() {
  case "$1" in
    ok) echo "✅" ;;
    fail) echo "❌" ;;
    warn) echo "⚠️" ;;
    skip) echo "⚪" ;;
    *) echo "•" ;;
  esac
}

rbv_html_esc() {
  # bash ${var//pat/&amp;} подставляет match в & — поэтому sed
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

rbv_format_tg_report() {
  # args via env-like: uses RBV_CHECKS_FILE and prints body to stdout
  local sid="$1" kind="$2" inst="$3" key="$4" overall="$5"
  local icon="🟢"
  [[ "$overall" == "true" ]] || icon="🔴"
  local path="s3://${RBV_BUCKET}/${key}"
  printf '%s <b>VERIFY %s</b>\n' "$icon" "$(echo "$kind" | tr 'a-z' 'A-Z')"
  printf '🗄 Хранилище: <b>%s</b>\n' "$(rbv_html_esc "$sid")"
  printf '🆔 Экземпляр: <code>%s</code>\n' "$(rbv_html_esc "$inst")"
  printf '📁 Путь: <code>%s</code>\n' "$(rbv_html_esc "$path")"
  printf '📦 Архив: <code>%s</code>\n' "$(rbv_html_esc "$(basename "$key")")"
  printf '\n<b>Проверки</b>\n'
  jq -r '.[] | "\(.status)|\(.name)|\(.detail)|\(.prev)|\(.curr)"' "$RBV_CHECKS_FILE" 2>/dev/null \
    | while IFS='|' read -r st name detail prev curr; do
        local ic
        ic="$(rbv_status_icon "$st")"
        printf '%s <b>%s</b> — %s\n' "$ic" "$(rbv_html_esc "$name")" "$(rbv_html_esc "$detail")"
        if [[ -n "$prev" || -n "$curr" ]]; then
          printf '   └ prev=<code>%s</code> → curr=<code>%s</code>\n' \
            "$(rbv_html_esc "${prev:-—}")" "$(rbv_html_esc "${curr:-—}")"
        fi
      done
  # diffs section
  local diffs
  diffs="$(jq -r '[.[] | select(.status=="fail" and (.prev!="" or .curr!=""))] | length' "$RBV_CHECKS_FILE" 2>/dev/null || echo 0)"
  if [[ "${diffs:-0}" -gt 0 ]]; then
    printf '\n<b>⚠ Расхождения</b>\n'
    jq -r '.[] | select(.status=="fail") | "• \(.name): \(.prev) → \(.curr) (\(.detail))"' \
      "$RBV_CHECKS_FILE" 2>/dev/null \
      | while IFS= read -r line; do
          printf '%s\n' "$(rbv_html_esc "$line")"
        done
  fi
}

rbv_tg_send_long() {
  # Split long HTML text into ≤3500 chunks
  local token="$1" chat="$2" text="$3" thread="${4:-}"
  local chunk="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ${#chunk} + ${#line} + 1 > 3500 )); then
      rbv_tg_send "$token" "$chat" "$chunk" "$thread"
      chunk=""
    fi
    chunk+="${line}"$'\n'
  done <<<"$text"
  [[ -n "$chunk" ]] && rbv_tg_send "$token" "$chat" "$chunk" "$thread"
}

rbv_tg_send_logs() {
  local token="$1" chat="$2" thread="$3" project="$4" compose="$5"
  local tmp logs
  tmp="$(mktemp)"
  {
    echo "=== compose ps ==="
    docker compose -f "$compose" -p "$project" ps 2>&1 || true
    echo
    local cid
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      local name
      name="$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
      echo "=== logs: ${name} (tail 80) ==="
      docker logs --tail 80 "$cid" 2>&1 || true
      echo
    done < <(docker compose -f "$compose" -p "$project" ps -aq 2>/dev/null || true)
  } > "$tmp"
  # as message chunks (document upload needs multipart file — keep text for simplicity)
  logs="$(head -c 12000 "$tmp")"
  rbv_tg_send_long "$token" "$chat" "📄 <b>Логи контейнеров</b>
<pre>$(printf '%s' "$logs" | sed 's/[<>&]//g' | head -c 11000)</pre>" "$thread"
  rm -f "$tmp"
}
