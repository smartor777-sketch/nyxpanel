#!/usr/bin/env bash
# nyx-containers-update.sh — обновление образов запущенных compose-стеков.
#
# Запускается systemd-таймером (2-й вторник янв/апр/июл/окт, 03:00 UTC) или вручную.
#   --dry-run  показать стеки/образы и доступные обновления, ничего не менять
#
# Политика: обновляются только стеки с пинованными тегами. Стек, где хоть один
# образ на `:latest`, пропускается с предупреждением (см. docs/UPDATE_PLAN.md §4).
# Перед pull текущие образы тегируются `<repo>:rollback-<stamp>`; при провале
# проверки выполняется автоматический откат этого стека.
set -euo pipefail

LOG_DIR=/var/log/nyx-updates
LOG="$LOG_DIR/containers.log"
MAIL_TO=${MAIL_TO:-furi_wave@mail.ru}
HOST=$(hostname -f 2>/dev/null || hostname)
RETAIN_BACKUPS=${RETAIN_BACKUPS:-4}
RETAIN_TAGS=${RETAIN_TAGS:-2}
STAMP=$(date -u +%Y%m%d-%H%M%S)
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date -u '+%F %T UTC')" "$*" | tee -a "$LOG"; }

# оставить <keep> последних каталогов бэкапов стека
prune_stack_backups() {
  local stack=$1 keep=$2
  local -a old=()
  mapfile -t old < <(find /root/backups/containers -mindepth 1 -maxdepth 1 -type d -name "${stack}-*" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +$((keep + 1)) | cut -d' ' -f2-)
  ((${#old[@]} == 0)) && return 0
  rm -rf "${old[@]}"
  log "retention: removed ${#old[@]} old backup(s) for $stack, keep=$keep"
}

# оставить <keep> последних rollback-тегов на каждый repo
prune_rollback_tags() {
  local repo keep=$1
  local -a repos=() tags=()
  mapfile -t repos < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep ':rollback-' | sed 's/:rollback-.*//' | sort -u)
  for repo in "${repos[@]}"; do
    mapfile -t tags < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -F "${repo}:rollback-" | sort)
    local n=${#tags[@]}
    if ((n > keep)); then
      local t
      for t in "${tags[@]:0:n-keep}"; do
        if docker rmi "$t" >/dev/null 2>&1; then log "retention: removed image tag $t"; fi
      done
    fi
  done
}

notify() {
  local subject=$1 body=$2
  {
    printf 'To: %s\n' "$MAIL_TO"
    printf 'From: root@%s\n' "$HOST"
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n'
    printf '%s\n' "$body"
  } | /usr/sbin/sendmail -oi -t >>"$LOG" 2>&1 || log "WARN: mail send failed"
}

repo_of() {
  local ref=${1%%@*}
  if [[ ${ref##*/} == *:* ]]; then printf '%s' "${ref%:*}"
  else printf '%s' "$ref"; fi
}

tag_of() {
  local ref=${1%%@*}
  if [[ ${ref##*/} == *:* ]]; then printf '%s' "${ref##*:}"
  else printf 'latest'; fi
}

log "=== start (dry_run=$DRY_RUN) ==="

mapfile -t dirs < <(docker ps --format '{{.Label "com.docker.compose.project.working_dir"}}' | sort -u | sed '/^$/d')
if ((${#dirs[@]} == 0)); then
  log "no running compose stacks"
  exit 0
fi

failed_stacks=()
updated_stacks=()

for dir in "${dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    log "WARN: $dir does not exist, skip"
    continue
  fi
  cd "$dir"
  if [[ -f compose.yaml ]]; then COMPOSE=compose.yaml
  elif [[ -f compose.yml ]]; then COMPOSE=compose.yml
  elif [[ -f docker-compose.yaml ]]; then COMPOSE=docker-compose.yaml
  elif [[ -f docker-compose.yml ]]; then COMPOSE=docker-compose.yml
  else log "WARN: no compose file in $dir, skip"; continue; fi

  mapfile -t images < <(docker compose config --images 2>/dev/null)
  if ((${#images[@]} == 0)); then
    log "WARN: cannot resolve images in $dir, skip"
    continue
  fi
  latest_img=""
  for img in "${images[@]}"; do
    [[ $(tag_of "$img") == latest ]] && latest_img=$img
  done
  if [[ -n "$latest_img" ]]; then
    log "SKIP $dir: image on :latest ($latest_img) — закрепите версию, иначе мажорные апдейты прилетят без контроля"
    continue
  fi

  log "stack $dir: ${images[*]}"
  if ((DRY_RUN)); then
    for img in "${images[@]}"; do
      if docker image inspect "$img" >/dev/null 2>&1; then
        log "  local: $img"
      else
        log "  will pull: $img"
      fi
    done
    continue
  fi

  BK="/root/backups/containers/$(basename "$dir")-$STAMP"
  mkdir -p "$BK"
  prune_stack_backups "$(basename "$dir")" "$RETAIN_BACKUPS"
  cp -a "$COMPOSE" "$BK/"
  docker compose config >"$BK/compose.resolved.yml"
  mapfile -t before_names < <(docker compose ps --status running --format '{{.Name}}')
  printf '%s\n' "${before_names[@]}" >"$BK/containers.before"

  : >"$BK/rollback-map.txt"
  for img in "${images[@]}"; do
    id=""
    if docker image inspect "$img" >/dev/null 2>&1; then
      id=$(docker image inspect --format '{{.Id}}' "$img")
    else
      # тега ещё нет локально (сменили пин) — берём образ запущенного контейнера того же repo
      repo=$(repo_of "$img")
      for cid in $(docker compose ps -q 2>/dev/null); do
        cur=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)
        [[ -z "$cur" ]] && continue
        if [[ $(repo_of "$cur") == "$repo" ]]; then
          id=$(docker inspect --format '{{.Image}}' "$cid")
          break
        fi
      done
    fi
    if [[ -n "$id" ]]; then
      ref="$(repo_of "$img"):rollback-$STAMP"
      docker tag "$id" "$ref"
      printf '%s\t%s\n' "$ref" "$img" >>"$BK/rollback-map.txt"
    fi
  done

  if ! docker compose pull >>"$LOG" 2>&1; then
    log "ERROR: pull failed in $dir"
    failed_stacks+=("$dir:pull")
    notify "nyx: image pull failed on $HOST ($dir)" "docker compose pull завершился ошибкой, см. $LOG"
    continue
  fi

  if ! docker compose up -d --remove-orphans >>"$LOG" 2>&1; then
    log "ERROR: up -d failed in $dir"
    failed_stacks+=("$dir:up")
    notify "nyx: compose up failed on $HOST ($dir)" "docker compose up -d завершился ошибкой, см. $LOG"
    continue
  fi

  expected=$(docker compose config --services 2>/dev/null | wc -l)
  ok=0
  for _ in $(seq 1 30); do
    running=$(docker compose ps --status running -q 2>/dev/null | wc -l)
    restarting=$(docker compose ps --format '{{.State}}' 2>/dev/null | grep -c restarting || true)
    [[ $running -ge $expected && $restarting -eq 0 ]] && { ok=1; break; }
    sleep 2
  done

  if ((ok == 0)); then
    log "ERROR: healthcheck failed in $dir (running < $expected)"
    while IFS=$'\t' read -r ref orig; do
      [[ -z "$ref" ]] && continue
      docker tag "$ref" "$orig" && log "rollback: $orig <- $ref"
    done <"$BK/rollback-map.txt"
    docker compose up -d --remove-orphans >>"$LOG" 2>&1 || true
    failed_stacks+=("$dir:health")
    notify "nyx: stack rolled back on $HOST ($dir)" "После обновления не поднялись все сервисы (running < $expected).
Выполнен откат на образы :rollback-$STAMP.
Бэкап: $BK"
    continue
  fi

  updated_stacks+=("$dir")
  log "OK $dir: ${expected} services running"
done

((DRY_RUN == 0)) && prune_rollback_tags "$RETAIN_TAGS"

if ((${#updated_stacks[@]} > 0)); then
  notify "nyx: container images updated on $HOST" "Обновлены стеки:
$(printf ' - %s\n' "${updated_stacks[@]}")

Проверка:
$(docker ps --format '{{.Names}}\t{{.Status}}' | sed 's/^/  /')"
fi

if ((${#failed_stacks[@]} > 0)); then
  log "ERROR stacks: ${failed_stacks[*]}"
  exit 1
fi

log "=== done ==="
