#!/usr/bin/env bash
# config-restore.sh — восстановление каталога проекта из цепочки bundle.
#
#   config-restore.sh <проект> --dest /path            # последнее состояние
#   config-restore.sh <проект> --dest /path --at "2026-07-20 10:00"
#   config-restore.sh <проект> --dest /path --list     # показать историю
#   config-restore.sh <проект> --from local            # из локального git-репо
#
# Восстановление никогда не пишет в рабочий каталог проекта: только в --dest.
# Подстановка восстановленного дерева обратно на прод — осознанное ручное
# действие оператора, а не побочный эффект проверки.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wal-lib.sh
source "${SCRIPT_DIR}/../lib/wal-lib.sh"

TRACK_ROOT="${TRACK_ROOT:-/var/lib/rw-config-track}"
NAME=""; DEST=""; AT=""; SOURCE="s3"; BACKEND=""; LIST="false"

NAME="${1:-}"
[[ -n "$NAME" && "$NAME" != -* ]] || { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)    DEST="$2"; shift 2 ;;
    --at)      AT="$2"; shift 2 ;;
    --from)    SOURCE="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --list)    LIST="true"; shift ;;
    *) msg ERR "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

wal_load_full_config
command -v git >/dev/null 2>&1 || { msg ERR "Нужен git"; exit 1; }

WORK="$(mktemp -d "/var/lib/rw-wal/config-restore.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="${WORK}/repo"

if [[ "$SOURCE" == "local" ]]; then
  local_repo="${TRACK_ROOT}/${NAME}/repo"
  [[ -d "${local_repo}/.git" ]] || { msg ERR "Локальный трекер не найден: ${local_repo}"; exit 1; }
  git clone -q "$local_repo" "$REPO"
else
  BACKEND="${BACKEND:-$(s3m_backends | head -n1)}"
  [[ -n "$BACKEND" ]] || { msg ERR "Нет S3-бэкендов"; exit 1; }
  s3m_load "$BACKEND" || exit 1
  base="${B_PREFIX}/config/$(rw_source_id)/${NAME}"

  mapfile -t keys < <(s3m_aws s3 ls "s3://${B_BUCKET}/${base}/" 2>/dev/null | awk '{print $4}' | sort)
  (( ${#keys[@]} > 0 )) || { msg ERR "В S3 нет истории для ${NAME} (${base})"; exit 1; }

  # Последний полный bundle и все приращения после него.
  full=""
  for k in "${keys[@]}"; do [[ "$k" == full_* ]] && full="$k"; done
  [[ -n "$full" ]] || { msg ERR "Полный bundle не найден — цепочка неполна"; exit 1; }
  full_ts="${full#full_}"; full_ts="${full_ts:0:19}"

  chain=("$full")
  for k in "${keys[@]}"; do
    [[ "$k" == inc_* ]] || continue
    k_ts="${k#inc_}"; k_ts="${k_ts:0:19}"
    [[ "$k_ts" > "$full_ts" ]] && chain+=("$k")
  done
  msg INFO "Цепочка: 1 полный + $(( ${#chain[@]} - 1 )) приращений"

  fetch_one() { # <key> -> путь к распакованному bundle
    local k="$1" f="${WORK}/$(basename "$k")"
    s3m_aws s3 cp "s3://${B_BUCKET}/${base}/${k}" "$f" --only-show-errors 2>/dev/null || return 1
    if [[ "$f" == *.age ]]; then
      [[ -n "${SANDBOX_AGE_IDENTITY:-}" && -f "${SANDBOX_AGE_IDENTITY:-}" ]] \
        || { msg ERR "Зашифровано, нужен SANDBOX_AGE_IDENTITY"; return 1; }
      age -d -i "$SANDBOX_AGE_IDENTITY" < "$f" > "${f%.age}" && f="${f%.age}"
    fi
    case "$f" in
      *.zst|*.gz) wal_decompress_stream "$f" < "$f" > "${f}.bundle" && f="${f}.bundle" ;;
    esac
    printf '%s' "$f"
  }

  first="$(fetch_one "${chain[0]}")" || exit 1
  git clone -q "$first" "$REPO" 2>/dev/null || { msg ERR "Полный bundle повреждён"; exit 1; }
  for k in "${chain[@]:1}"; do
    inc="$(fetch_one "$k")" || { msg WARN "Пропущено приращение ${k}"; continue; }
    git -C "$REPO" fetch -q "$inc" 'refs/heads/*:refs/heads/*' 2>/dev/null \
      || msg WARN "Приращение ${k} не применилось"
  done
  git -C "$REPO" checkout -q "$(git -C "$REPO" rev-parse HEAD)" 2>/dev/null || true
fi

if [[ "$LIST" == "true" ]]; then
  echo -e "${BOLD}История ${NAME}:${RESET}"
  git -C "$REPO" log --date=iso --format='  %h  %ad  %s' | head -40
  exit 0
fi

[[ -n "$DEST" ]] || { msg ERR "Укажите --dest <каталог>"; exit 1; }

target="HEAD"
if [[ -n "$AT" ]]; then
  target="$(git -C "$REPO" rev-list -n1 --before="$AT" HEAD 2>/dev/null || true)"
  [[ -n "$target" ]] || { msg ERR "Нет снимка на момент '${AT}'"; exit 1; }
  msg INFO "Снимок на ${AT}: $(git -C "$REPO" log -1 --format='%h %ad' --date=iso "$target")"
fi

mkdir -p "$DEST"
git -C "$REPO" archive --format=tar "$target" | tar -xf - -C "$DEST"
rm -f "${DEST}/.gitignore"

msg OK "Каталог восстановлен: ${DEST}"
msg INFO "  файлов: $(find "$DEST" -type f | wc -l), размер: $(du -sh "$DEST" | awk '{print $1}')"
