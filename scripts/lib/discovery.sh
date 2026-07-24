#!/usr/bin/env bash
# discovery.sh — обнаружение отслеживаемых проектов на сервере.
#
# Единая логика для бэкапа, трекера конфигов и песочницы: панель и
# compose-проекты ботов в /home определяются ОДИНАКОВО, чтобы список
# отслеживаемого не разъезжался между инструментами.
#
# Формат строки проекта (поля через '|'):
#   name|kind|root_dir|compose_file|db_container|db_service|redis_container|app_containers

[[ -n "${__DISCOVERY_LOADED:-}" ]] && return 0
__DISCOVERY_LOADED=1

disc_label() { # <container> <label>
  docker inspect -f "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true
}

# Панель: корневой каталог целиком (в стандартной установке /opt/remnawave).
disc_panel() {
  local root="${PANEL_ROOT_DIR:-/opt/remnawave}"
  local db="${PANEL_DB_CONTAINER:-remnawave-db}"
  [[ -d "$root" ]] || return 0

  local compose=""
  for c in "${root}/docker-compose.yml" "${root}/docker-compose.yaml"; do
    [[ -f "$c" ]] && { compose="$c"; break; }
  done

  local db_service="" redis="" apps=()
  if command -v docker >/dev/null 2>&1; then
    db_service="$(disc_label "$db" 'com.docker.compose.service')"
    local project
    project="$(disc_label "$db" 'com.docker.compose.project')"
    if [[ -n "$project" && "$project" != "<no value>" ]]; then
      while read -r c; do
        [[ -n "$c" ]] || continue
        [[ "$(disc_label "$c" 'com.docker.compose.project')" == "$project" ]] || continue
        [[ "$c" == "$db" ]] && continue
        local img; img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)"
        if [[ "$img" =~ redis|valkey ]]; then redis="$c"; else apps+=("$c"); fi
      done < <(docker ps -a --format '{{.Names}}')
    fi
  fi

  printf 'panel|panel|%s|%s|%s|%s|%s|%s\n' \
    "$root" "$compose" "$db" "${db_service:-remnawave-db}" "$redis" "${apps[*]}"
}

# Боты: compose-проекты, рабочий каталог которых лежит в /home.
# Каталог проекта берётся целиком — в ботах кроме конфигов есть исполняемый
# код, ресурсы, шаблоны, миграции: без них восстановление с нуля неполное.
disc_bots() {
  command -v docker >/dev/null 2>&1 || return 0
  declare -A dirs
  local c project workdir

  while read -r c; do
    [[ -n "$c" ]] || continue
    project="$(disc_label "$c" 'com.docker.compose.project')"
    workdir="$(disc_label "$c" 'com.docker.compose.project.working_dir')"
    [[ -n "$project" && "$project" != "<no value>" ]] || continue
    [[ -n "$workdir" && "$workdir" != "<no value>" ]] || continue
    [[ "$workdir" == /home/* ]] || continue
    [[ -d "$workdir" ]] || continue
    dirs["$project"]="$workdir"
  done < <(docker ps -a --format '{{.Names}}')

  for project in "${!dirs[@]}"; do
    local dir="${dirs[$project]}" pg="" pg_service="" redis="" apps=()
    while read -r c; do
      [[ -n "$c" ]] || continue
      [[ "$(disc_label "$c" 'com.docker.compose.project')" == "$project" ]] || continue
      local svc img
      svc="$(disc_label "$c" 'com.docker.compose.service')"
      img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)"
      if [[ "$svc" == "postgres" || "$img" =~ postgres ]]; then
        pg="$c"; pg_service="${svc:-postgres}"
      elif [[ "$svc" == "redis" || "$img" =~ redis|valkey ]]; then
        redis="$c"
      else
        apps+=("$c")
      fi
    done < <(docker ps -a --format '{{.Names}}')

    local compose=""
    for f in "${dir}/docker-compose.yml" "${dir}/docker-compose.yaml"; do
      [[ -f "$f" ]] && { compose="$f"; break; }
    done

    printf '%s|bot|%s|%s|%s|%s|%s|%s\n' \
      "$project" "$dir" "$compose" "$pg" "${pg_service:-postgres}" "$redis" "${apps[*]}"
  done
}

# Все проекты сервера.
disc_all() {
  disc_panel
  disc_bots
}

# Один проект по имени.
disc_one() { # <name>
  disc_all | awk -F'|' -v n="$1" '$1 == n'
}
