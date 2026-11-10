#!/usr/bin/env bash
# nyx-docker-engine-update.sh — обновление Docker Engine из репозитория Docker CE.
#
# Запускается systemd-таймером (1-й вторник месяца, 03:00 UTC) или вручную.
#   --dry-run  только показать, что будет обновлено, ничего не менять
#
# Что делает: бэкап версий/образов, apt-get upgrade только docker-пакетов,
# ожидание dockerd, проверка контейнеров и iptables-guard, письмо при изменениях
# или ошибке. Откат — вручную по инструкции из письма/log (docs/UPDATE_PLAN.md §3).
set -euo pipefail

LOG_DIR=/var/log/nyx-updates
LOG="$LOG_DIR/docker-engine.log"
MAIL_TO=${MAIL_TO:-furi_wave@mail.ru}
HOST=$(hostname -f 2>/dev/null || hostname)
PKGS=(docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io docker-buildx-plugin docker-compose-plugin)
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u '+%F %T UTC')" "$*" | tee -a "$LOG"; }

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

log "=== start (dry_run=$DRY_RUN) ==="

apt-get update -qq >>"$LOG" 2>&1 || { log "ERROR: apt-get update failed"; notify "nyx: apt update failed on $HOST" "apt-get update завершился ошибкой, см. $LOG"; exit 1; }

mapfile -t pending < <(apt-get -s --only-upgrade install "${PKGS[@]}" 2>/dev/null | awk '/^Inst /{print $2}')
if ((${#pending[@]} == 0)); then
  log "no docker updates available"
  exit 0
fi

log "pending: ${pending[*]}"
if ((DRY_RUN)); then
  apt-get -s --only-upgrade install "${PKGS[@]}" | sed -n '/^Inst /p' | tee -a "$LOG"
  log "dry-run: no changes made"
  exit 0
fi

STAMP=$(date -u +%Y%m%d-%H%M%S)
BK="/root/backups/docker-engine/$STAMP"
mkdir -p "$BK"
dpkg-query -W -f='${Package}=${Version}\n' "${PKGS[@]}" >"$BK/versions.before" 2>/dev/null || true
docker version --format '{{.Server.Version}}' >"$BK/docker-version.before" 2>/dev/null || true
docker compose version >"$BK/compose-version.before" 2>/dev/null || true
docker images --digests >"$BK/images.before" 2>/dev/null || true
mapfile -t running_before < <(docker ps --format '{{.Names}}')
printf '%s\n' "${running_before[@]}" >"$BK/containers.before"
log "backup: $BK"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get -y --only-upgrade install "${PKGS[@]}" >>"$LOG" 2>&1; then
  log "ERROR: apt-get upgrade failed"
  notify "nyx: Docker Engine upgrade FAILED on $HOST" "$(tail -n 40 "$LOG")"
  exit 1
fi

# дождаться готовности демона
for _ in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
if ! docker info >/dev/null 2>&1; then
  log "ERROR: dockerd is not responding after upgrade"
  notify "nyx: dockerd DOWN on $HOST" "После обновления Docker Engine демон не отвечает. Бэкап версий: $BK"
  exit 1
fi

sleep 5
bad=()
for c in "${running_before[@]}"; do
  [[ -z "$c" ]] && continue
  if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false) != true ]]; then
    bad+=("$c")
  fi
done

guard_ok=1
iptables -S DOCKER-USER 2>/dev/null | grep -q 'DROP' || guard_ok=0

new_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)
new_compose=$(docker compose version 2>/dev/null || echo unknown)
{
  echo "host: $HOST"
  echo "docker: $(cat "$BK/docker-version.before" 2>/dev/null) -> $new_ver"
  echo "compose: $(cat "$BK/compose-version.before" 2>/dev/null) -> $new_compose"
  echo "containers before: ${running_before[*]:-none}"
  echo
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  echo
  echo "backup: $BK"
} >>"$LOG"

if ((${#bad[@]} > 0)) || ((guard_ok == 0)); then
  log "ERROR: not running after upgrade: ${bad[*]:-none}; guard_ok=$guard_ok"
  notify "nyx: Docker Engine upgraded, but checks FAILED on $HOST" "Не поднялись: ${bad[*]:-none}
DOCKER-USER guard: $guard_ok
Вернуться: apt-get install -y --allow-downgrades \$(cat $BK/versions.before | sed 's/=/=/')
Бэкап: $BK"
  exit 1
fi

log "OK: docker $new_ver, compose $new_compose, containers: ${#running_before[@]}, guard ok"
notify "nyx: Docker Engine updated on $HOST" "docker $(cat "$BK/docker-version.before" 2>/dev/null) -> $new_ver
compose $(cat "$BK/compose-version.before" 2>/dev/null) -> $new_compose
Контейнеры: ${running_before[*]:-none}
Бэкап: $BK"
log "=== done ==="
